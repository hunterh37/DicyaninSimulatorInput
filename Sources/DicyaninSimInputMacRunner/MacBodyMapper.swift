import Foundation
import simd
import DicyaninLabsMoCapRecording

#if os(macOS)
import Vision

/// Maps Vision 3D body-pose observations (17 joints, camera-relative meters)
/// into the head-relative person frame and the 30-joint `ARKitBodyJoint`
/// wire order the visionOS consumer expects. Missing intermediate joints
/// (spine chain, neck chain, toes) are interpolated from the joints Vision
/// does provide, so the receiver always gets a dense skeleton.
enum MacBodyMapper {
    struct Frame {
        let origin: SIMD3<Float>
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let forward: SIMD3<Float>

        func map(_ world: SIMD3<Float>) -> SIMD3<Float> {
            let d = world - origin
            return SIMD3(simd_dot(d, right), simd_dot(d, up), -simd_dot(d, forward))
        }
    }

    static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Camera-relative positions per Vision joint, from one observation.
    static func cameraJoints(_ observation: VNHumanBodyPose3DObservation)
        -> [VNHumanBodyPose3DObservation.JointName: SIMD3<Float>] {
        var out: [VNHumanBodyPose3DObservation.JointName: SIMD3<Float>] = [:]
        let names: [VNHumanBodyPose3DObservation.JointName] = [
            .root, .spine, .centerShoulder, .centerHead, .topHead,
            .leftShoulder, .leftElbow, .leftWrist,
            .rightShoulder, .rightElbow, .rightWrist,
            .leftHip, .leftKnee, .leftAnkle,
            .rightHip, .rightKnee, .rightAnkle,
        ]
        for name in names {
            if let m = try? observation.cameraRelativePosition(name) {
                out[name] = translation(m)
            }
        }
        return out
    }

    /// Person frame: origin at the head, forward is the horizontal direction
    /// from the head toward the camera (the camera sits at the origin of the
    /// camera-relative space and the person faces it).
    static func frame(cameraJoints: [VNHumanBodyPose3DObservation.JointName: SIMD3<Float>])
        -> Frame? {
        guard let head = cameraJoints[.centerHead] else { return nil }
        var toCamera = -head
        toCamera.y = 0
        let length = simd_length(toCamera)
        guard length > 0.05 else { return nil }
        let forward = toCamera / length
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(forward, up))
        return Frame(origin: head, right: right, up: up, forward: forward)
    }

    /// Full 30-joint body in `ARKitBodyJoint.allCases` wire order, head
    /// relative. Returns nil when the core torso joints are missing.
    static func mapBody(cameraJoints: [VNHumanBodyPose3DObservation.JointName: SIMD3<Float>],
                        frame: Frame) -> [SIMD3<Float>]? {
        guard let root = cameraJoints[.root],
              let shoulder = cameraJoints[.centerShoulder],
              let head = cameraJoints[.centerHead] else { return nil }
        let spineMid = cameraJoints[.spine] ?? simd_mix(root, shoulder, SIMD3(repeating: 0.5))

        func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            simd_mix(a, b, SIMD3(repeating: t))
        }

        var byJoint: [ARKitBodyJoint: SIMD3<Float>] = [:]
        byJoint[.root] = root
        byJoint[.hips] = root
        // Spine chain: root -> spineMid -> centerShoulder.
        byJoint[.spine1] = lerp(root, spineMid, 0.25)
        byJoint[.spine2] = lerp(root, spineMid, 0.50)
        byJoint[.spine3] = lerp(root, spineMid, 0.75)
        byJoint[.spine4] = spineMid
        byJoint[.spine5] = lerp(spineMid, shoulder, 0.33)
        byJoint[.spine6] = lerp(spineMid, shoulder, 0.66)
        byJoint[.spine7] = shoulder
        // Neck chain: centerShoulder -> centerHead.
        byJoint[.neck1] = lerp(shoulder, head, 0.25)
        byJoint[.neck2] = lerp(shoulder, head, 0.50)
        byJoint[.neck3] = lerp(shoulder, head, 0.75)
        byJoint[.neck4] = lerp(shoulder, head, 0.90)
        byJoint[.head] = head

        // Arms. shoulder_1 sits between the spine top and the arm joint.
        if let ls = cameraJoints[.leftShoulder] {
            byJoint[.leftShoulder] = lerp(shoulder, ls, 0.5)
            byJoint[.leftArm] = ls
        }
        byJoint[.leftForearm] = cameraJoints[.leftElbow]
        byJoint[.leftHand] = cameraJoints[.leftWrist]
        if let rs = cameraJoints[.rightShoulder] {
            byJoint[.rightShoulder] = lerp(shoulder, rs, 0.5)
            byJoint[.rightArm] = rs
        }
        byJoint[.rightForearm] = cameraJoints[.rightElbow]
        byJoint[.rightHand] = cameraJoints[.rightWrist]

        // Legs. Toes extend a little past the ankle, forward and down.
        if let hip = cameraJoints[.leftHip] { byJoint[.leftUpLeg] = hip }
        byJoint[.leftLeg] = cameraJoints[.leftKnee]
        if let ankle = cameraJoints[.leftAnkle] {
            byJoint[.leftFoot] = ankle
            byJoint[.leftToes] = ankle + frame.forward * 0.12 - SIMD3(0, 0.05, 0)
        }
        if let hip = cameraJoints[.rightHip] { byJoint[.rightUpLeg] = hip }
        byJoint[.rightLeg] = cameraJoints[.rightKnee]
        if let ankle = cameraJoints[.rightAnkle] {
            byJoint[.rightFoot] = ankle
            byJoint[.rightToes] = ankle + frame.forward * 0.12 - SIMD3(0, 0.05, 0)
        }

        // Fill any hole from the joint's parent so the wire array stays dense.
        return ARKitBodyJoint.allCases.map { joint in
            var j: ARKitBodyJoint? = joint
            while let current = j {
                if let p = byJoint[current] { return frame.map(p) }
                j = current.parent
            }
            return frame.map(root)
        }
    }

    /// Normalized (0...1, top-left origin) image points for overlay drawing.
    static func overlayPoints(_ observation: VNHumanBodyPose3DObservation,
                              mirrored: Bool)
        -> [VNHumanBodyPose3DObservation.JointName: CGPoint] {
        var out: [VNHumanBodyPose3DObservation.JointName: CGPoint] = [:]
        let names: [VNHumanBodyPose3DObservation.JointName] = [
            .root, .spine, .centerShoulder, .centerHead,
            .leftShoulder, .leftElbow, .leftWrist,
            .rightShoulder, .rightElbow, .rightWrist,
            .leftHip, .leftKnee, .leftAnkle,
            .rightHip, .rightKnee, .rightAnkle,
        ]
        for name in names {
            guard let p = try? observation.pointInImage(name) else { continue }
            let x = mirrored ? 1 - p.location.x : p.location.x
            out[name] = CGPoint(x: x, y: 1 - p.location.y)
        }
        return out
    }

    /// Bone pairs for the overlay wireframe, in Vision joint names.
    static let overlayBones: [(VNHumanBodyPose3DObservation.JointName,
                               VNHumanBodyPose3DObservation.JointName)] = [
        (.root, .spine), (.spine, .centerShoulder), (.centerShoulder, .centerHead),
        (.centerShoulder, .leftShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.centerShoulder, .rightShoulder), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.root, .leftHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.root, .rightHip), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]
}
#endif
