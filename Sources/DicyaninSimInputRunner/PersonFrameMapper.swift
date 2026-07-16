import Foundation
import simd
import DicyaninLabsMoCapRecording
import DicyaninHandTrackingTransport
import DicyaninSimInputTransport

#if os(iOS)
import ARKit

/// Maps ARKit world-space captures from the iPhone (which observes the person
/// from the outside) into the person's own head-relative frame: x right, y up,
/// negative z in front of the person. That frame is what the visionOS
/// simulator consumes, since the tracked person IS the simulated wearer.
///
/// The person's forward axis is the horizontal direction from their head
/// toward the iPhone camera (the phone sits on the desk in front of them).
enum PersonFrameMapper {
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

    /// Build the person frame from the tracked body and the camera pose.
    static func frame(bodyWorldJoints: [ARKitBodyJoint: simd_float4x4],
                      cameraTransform: simd_float4x4) -> Frame? {
        guard let head = bodyWorldJoints[.head] else { return nil }
        let origin = translation(head)
        let cameraPosition = translation(cameraTransform)
        var toCamera = cameraPosition - origin
        toCamera.y = 0
        let length = simd_length(toCamera)
        guard length > 0.05 else { return nil }
        let forward = toCamera / length
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(forward, up))
        return Frame(origin: origin, right: right, up: up, forward: forward)
    }

    /// Wire hand joint for each captured ARKit hand joint, in the canonical
    /// 21-joint `HandJointID` order shared with the webcam runner.
    static let handJointFor: [HandJointID: ARKitHandJoint] = [
        .wrist: .wrist,
        .thumbKnuckle: .thumbKnuckle, .thumbIntermediateBase: .thumbIntermediateBase,
        .thumbIntermediateTip: .thumbIntermediateTip, .thumbTip: .thumbTip,
        .indexKnuckle: .indexFingerKnuckle, .indexIntermediateBase: .indexFingerIntermediateBase,
        .indexIntermediateTip: .indexFingerIntermediateTip, .indexTip: .indexFingerTip,
        .middleKnuckle: .middleFingerKnuckle, .middleIntermediateBase: .middleFingerIntermediateBase,
        .middleIntermediateTip: .middleFingerIntermediateTip, .middleTip: .middleFingerTip,
        .ringKnuckle: .ringFingerKnuckle, .ringIntermediateBase: .ringFingerIntermediateBase,
        .ringIntermediateTip: .ringFingerIntermediateTip, .ringTip: .ringFingerTip,
        .littleKnuckle: .littleFingerKnuckle, .littleIntermediateBase: .littleFingerIntermediateBase,
        .littleIntermediateTip: .littleFingerIntermediateTip, .littleTip: .littleFingerTip,
    ]

    struct MappedHand {
        let position: SIMD3<Float>
        let yaw: Float
        let joints: [SIMD3<Float>]
        let isPinching: Bool
    }

    /// Map one hand's world joints into the person frame, in wire order.
    /// Missing joints fall back to the wrist so the array stays dense.
    static func mapHand(_ worldJoints: [ARKitHandJoint: simd_float4x4],
                        frame: Frame) -> MappedHand? {
        guard let wristWorld = worldJoints[.wrist] else { return nil }
        let wrist = frame.map(translation(wristWorld))

        var joints: [SIMD3<Float>] = []
        joints.reserveCapacity(HandJointID.count)
        for id in HandJointID.allCases {
            if let arJoint = handJointFor[id], let m = worldJoints[arJoint] {
                joints.append(frame.map(translation(m)))
            } else {
                joints.append(wrist)
            }
        }

        var yaw: Float = 0
        if let middle = worldJoints[.middleFingerKnuckle] {
            let dir = frame.map(translation(middle)) - wrist
            if simd_length(SIMD2(dir.x, dir.z)) > 0.005 {
                yaw = atan2(dir.x, -dir.z)
            }
        }

        var isPinching = false
        if let thumb = worldJoints[.thumbTip], let index = worldJoints[.indexFingerTip] {
            isPinching = simd_distance(translation(thumb), translation(index)) < 0.025
        }

        return MappedHand(position: wrist, yaw: yaw, joints: joints, isPinching: isPinching)
    }

    /// Map the full body into the person frame, in `ARKitBodyJoint.allCases`
    /// wire order. Missing joints fall back to the frame origin.
    static func mapBody(_ worldJoints: [ARKitBodyJoint: simd_float4x4],
                        frame: Frame) -> [SIMD3<Float>] {
        ARKitBodyJoint.allCases.map { joint in
            guard let m = worldJoints[joint] else { return .zero }
            return frame.map(translation(m))
        }
    }
}
#endif
