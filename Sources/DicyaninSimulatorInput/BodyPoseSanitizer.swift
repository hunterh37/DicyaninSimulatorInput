import Foundation
import simd
import DicyaninLabsMoCapRecording

/// Anatomical sanitizer for received head-relative body joints.
///
/// Webcam pose sources (Vision 3D body pose) keep emitting positions for
/// joints that are outside the camera view, and those positions are garbage:
/// legs folded above the head, knees inside the chest. This filter walks the
/// skeleton hierarchy and gates every bone against its nearest neighbor:
/// plausible length (relative to a canonical bone length) and a per-joint
/// max angle cone (relative to the parent bone or the body's up axis).
///
/// Rejected or missing joints are extrapolated instead of dropped: the joint
/// holds its last accepted parent-relative offset and eases toward a rest
/// offset (legs straight down, spine straight up), so the consumer always
/// receives a dense, plausible skeleton and dropouts never snap.
public struct BodyPoseSanitizer {
    public init() {}

    /// Reference frame a joint's angle cone is measured against.
    private enum Reference {
        /// Direction of the sanitized parent bone.
        case parentBone
        /// The torso up axis (sanitized hips -> upper spine, fallback +y).
        case up
        /// Opposite of the torso up axis.
        case down
        /// No angle gate, length gate only.
        case none
    }

    private struct Constraint {
        /// Canonical bone length in meters (parent joint -> this joint).
        let length: Float
        /// Rest direction of the bone in the person frame (unit vector).
        let restDirection: SIMD3<Float>
        /// Angle reference and max deviation in radians.
        let reference: Reference
        let maxAngle: Float
    }

    /// Person frame: x right (person's left at -x in the mirror mapping),
    /// y up, +z toward the viewer.
    private static let constraints: [ARKitBodyJoint: Constraint] = {
        func c(_ length: Float, _ rest: SIMD3<Float>,
               _ reference: Reference, _ maxDegrees: Float) -> Constraint {
            Constraint(length: length, restDirection: simd_normalize(rest),
                       reference: reference, maxAngle: maxDegrees * .pi / 180)
        }
        var t: [ARKitBodyJoint: Constraint] = [:]
        // Spine chain: hips up to the shoulder line. Torso stays near the up
        // axis; a spine segment pointing sideways or down is a bad detection.
        for j: ARKitBodyJoint in [.spine1, .spine2, .spine3, .spine4] {
            t[j] = c(0.06, [0, 1, 0], .up, 60)
        }
        for j: ARKitBodyJoint in [.spine5, .spine6, .spine7] {
            t[j] = c(0.075, [0, 1, 0], .up, 60)
        }
        for j: ARKitBodyJoint in [.neck1, .neck2, .neck3] {
            t[j] = c(0.06, [0, 1, 0], .up, 70)
        }
        t[.neck4] = c(0.04, [0, 1, 0], .up, 70)
        t[.head] = c(0.03, [0, 1, 0], .up, 70)
        // Shoulders and hip sockets: short lateral bones, length gate only.
        t[.leftShoulder] = c(0.09, [-1, 0, 0], .none, 0)
        t[.leftArm] = c(0.08, [-1, 0, 0], .none, 0)
        t[.rightShoulder] = c(0.09, [1, 0, 0], .none, 0)
        t[.rightArm] = c(0.08, [1, 0, 0], .none, 0)
        t[.leftUpLeg] = c(0.10, [-1, -0.2, 0], .none, 0)
        t[.rightUpLeg] = c(0.10, [1, -0.2, 0], .none, 0)
        // Arms can point anywhere from the shoulder; elbows and wrists hinge
        // within a cone of the segment above them.
        t[.leftForearm] = c(0.28, [-0.2, -1, 0], .parentBone, 160)
        t[.rightForearm] = c(0.28, [0.2, -1, 0], .parentBone, 160)
        t[.leftHand] = c(0.26, [-0.1, -1, 0], .parentBone, 95)
        t[.rightHand] = c(0.26, [0.1, -1, 0], .parentBone, 95)
        // Legs: a thigh more than 120 degrees away from straight-down (a high
        // kick is about 120) is a bad detection, which is exactly the
        // legs-above-the-head glitch when they are out of the webcam view.
        t[.leftLeg] = c(0.45, [0, -1, 0], .down, 120)
        t[.rightLeg] = c(0.45, [0, -1, 0], .down, 120)
        // Knees hinge backward only, up to deep flexion.
        t[.leftFoot] = c(0.42, [0, -1, 0], .parentBone, 150)
        t[.rightFoot] = c(0.42, [0, -1, 0], .parentBone, 150)
        t[.leftToes] = c(0.15, [0, -0.4, 0.9], .parentBone, 100)
        t[.rightToes] = c(0.15, [0, -0.4, 0.9], .parentBone, 100)
        return t
    }()

    /// Accepted measured length as a ratio of the canonical bone length.
    private static let minLengthRatio: Float = 0.35
    private static let maxLengthRatio: Float = 2.2
    /// Max per-frame joint travel; larger jumps are treated as glitches.
    private static let maxJumpPerFrame: Float = 0.6
    /// Ease factor per frame from the held offset toward the rest offset.
    private static let restDecay: Float = 0.04
    /// Ease factor per frame toward newly accepted data.
    private static let acceptSmoothing: Float = 0.5
    /// Hips rest position in the head-relative frame (head is the origin).
    private static let hipsRest = SIMD3<Float>(0, -0.65, 0)
    private static let hipsMinY: Float = -1.2
    private static let hipsMaxY: Float = -0.3

    /// Last sanitized parent-relative offset per joint.
    private var heldOffsets: [ARKitBodyJoint: SIMD3<Float>] = [:]
    private var heldHips: SIMD3<Float>?
    private var lastOutput: [ARKitBodyJoint: SIMD3<Float>] = [:]

    private static func isDetected(_ p: SIMD3<Float>?) -> Bool {
        guard let p else { return false }
        return simd_length_squared(p) > 1e-6
    }

    /// Sanitize one frame of head-relative joints. Always returns a dense
    /// skeleton (every `ARKitBodyJoint`); undetected or implausible joints
    /// are extrapolated from their nearest sanitized neighbor.
    public mutating func sanitize(_ raw: [ARKitBodyJoint: SIMD3<Float>])
        -> [ARKitBodyJoint: SIMD3<Float>] {
        var out: [ARKitBodyJoint: SIMD3<Float>] = [:]

        // Anchor: hips (root shares its position). Gate on plausible height
        // below the head and on frame-to-frame travel.
        var hips = heldHips ?? Self.hipsRest
        if let rawHips = raw[.hips], Self.isDetected(rawHips),
           rawHips.y > Self.hipsMinY, rawHips.y < Self.hipsMaxY,
           heldHips.map({ simd_length($0 - rawHips) < Self.maxJumpPerFrame }) ?? true {
            hips = simd_mix(hips, rawHips, SIMD3(repeating: Self.acceptSmoothing))
        } else {
            hips = simd_mix(hips, Self.hipsRest, SIMD3(repeating: Self.restDecay))
        }
        heldHips = hips
        out[.root] = hips
        out[.hips] = hips

        // Torso up axis from the raw spine when plausible, for angle gates.
        var torsoUp = SIMD3<Float>(0, 1, 0)
        if let top = raw[.spine7] ?? raw[.neck1], Self.isDetected(top),
           Self.isDetected(raw[.hips]) {
            let d = top - raw[.hips]!
            if simd_length(d) > 0.1, simd_normalize(d).y > 0.3 {
                torsoUp = simd_normalize(d)
            }
        }

        // Children in hierarchy order (allCases lists parents first).
        for joint in ARKitBodyJoint.allCases {
            guard let constraint = Self.constraints[joint],
                  let parent = joint.parent, let parentPos = out[parent] else { continue }
            let restOffset = Self.restOffset(joint, constraint: constraint, torsoUp: torsoUp)
            var offset = heldOffsets[joint] ?? restOffset

            if let candidate = Self.acceptedOffset(joint, constraint: constraint,
                                                   raw: raw, parentPos: parentPos,
                                                   parentBoneDir: Self.parentBoneDir(joint, out: out),
                                                   torsoUp: torsoUp,
                                                   lastPos: lastOutput[joint]) {
                offset = simd_mix(offset, candidate, SIMD3(repeating: Self.acceptSmoothing))
            } else {
                offset = simd_mix(offset, restOffset, SIMD3(repeating: Self.restDecay))
            }
            heldOffsets[joint] = offset
            out[joint] = parentPos + offset
        }

        lastOutput = out
        return out
    }

    /// Reset all held state (call on disconnect or person change).
    public mutating func reset() {
        heldOffsets.removeAll()
        heldHips = nil
        lastOutput.removeAll()
    }

    /// Raw parent-relative offset if it passes every gate, else nil.
    private static func acceptedOffset(_ joint: ARKitBodyJoint,
                                       constraint: Constraint,
                                       raw: [ARKitBodyJoint: SIMD3<Float>],
                                       parentPos: SIMD3<Float>,
                                       parentBoneDir: SIMD3<Float>?,
                                       torsoUp: SIMD3<Float>,
                                       lastPos: SIMD3<Float>?) -> SIMD3<Float>? {
        guard let parent = joint.parent,
              let rawPos = raw[joint], isDetected(rawPos),
              let rawParent = raw[parent], isDetected(rawParent) else { return nil }

        // Velocity gate against the last sanitized output.
        if let lastPos, simd_length(rawPos - lastPos) > maxJumpPerFrame { return nil }

        // Length gate: measured raw bone vs canonical length.
        let rawBone = rawPos - rawParent
        let length = simd_length(rawBone)
        guard length > constraint.length * minLengthRatio,
              length < constraint.length * maxLengthRatio else { return nil }
        let dir = rawBone / length

        // Angle cone gate against the joint's nearest-neighbor reference.
        let referenceDir: SIMD3<Float>?
        switch constraint.reference {
        case .parentBone: referenceDir = parentBoneDir
        case .up: referenceDir = torsoUp
        case .down: referenceDir = -torsoUp
        case .none: referenceDir = nil
        }
        if let referenceDir {
            let angle = acos(simd_clamp(simd_dot(dir, referenceDir), -1, 1))
            guard angle <= constraint.maxAngle else { return nil }
        }

        // Re-express with the canonical length clamped toward the mesh scale
        // so a person/camera scale mismatch cannot stretch the skeleton.
        let clamped = simd_clamp(length, constraint.length * 0.6, constraint.length * 1.6)
        return dir * clamped
    }

    /// Direction of the sanitized bone above this joint, if meaningful.
    private static func parentBoneDir(_ joint: ARKitBodyJoint,
                                      out: [ARKitBodyJoint: SIMD3<Float>]) -> SIMD3<Float>? {
        guard let parent = joint.parent, let grand = parent.parent,
              let a = out[grand], let b = out[parent] else { return nil }
        let d = b - a
        let length = simd_length(d)
        guard length > 0.02 else { return nil }
        return d / length
    }

    /// Rest offset for a joint: canonical length along its rest direction,
    /// with the vertical part following the current torso axis so a leaning
    /// body keeps its extrapolated limbs attached naturally.
    private static func restOffset(_ joint: ARKitBodyJoint,
                                   constraint: Constraint,
                                   torsoUp: SIMD3<Float>) -> SIMD3<Float> {
        let rest = constraint.restDirection
        let vertical = torsoUp * rest.y
        let lateral = SIMD3<Float>(rest.x, 0, rest.z)
        var dir = vertical + lateral
        let length = simd_length(dir)
        dir = length > 0.001 ? dir / length : rest
        return dir * constraint.length
    }
}
