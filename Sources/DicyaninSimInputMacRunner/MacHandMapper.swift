import Foundation
import simd
import CoreGraphics
import DicyaninHandTrackingTransport

#if os(macOS)
import Vision

/// A hand detected in one webcam frame, mapped into the head-relative frame
/// plus normalized overlay points for on-screen drawing. Same conventions as
/// the WebcamHandRunner: x right, y up, negative z in front of the wearer.
public struct MacDetectedHand: Identifiable, Sendable {
    public let id = UUID()
    public var headPosition: SIMD3<Float>
    public var yaw: Float
    public var isPinching: Bool
    public var joints: [HandJointID: SIMD3<Float>]
    /// Normalized (0...1, top-left origin) screen points for overlay drawing.
    public var overlay: [HandJointID: CGPoint]
    public var isLeft: Bool

    /// Wire array in `HandJointID.allCases` order; undetected joints fall
    /// back to the wrist so the receiver always gets a complete skeleton.
    public var wireJoints: [SIMD3<Float>] {
        HandJointID.allCases.map { joints[$0] ?? headPosition }
    }
}

/// Maps `VNHumanHandPoseObservation`s (2D) into head-relative hands. Depth is
/// approximated from apparent hand size; finger articulation is scaled to a
/// realistic palm length. Identical mapping to the proven WebcamHandRunner.
enum MacHandMapper {
    /// Vision joint for each canonical wire joint.
    static let visionJoint: [HandJointID: VNHumanHandPoseObservation.JointName] = [
        .wrist: .wrist,
        .thumbKnuckle: .thumbCMC, .thumbIntermediateBase: .thumbMP,
        .thumbIntermediateTip: .thumbIP, .thumbTip: .thumbTip,
        .indexKnuckle: .indexMCP, .indexIntermediateBase: .indexPIP,
        .indexIntermediateTip: .indexDIP, .indexTip: .indexTip,
        .middleKnuckle: .middleMCP, .middleIntermediateBase: .middlePIP,
        .middleIntermediateTip: .middleDIP, .middleTip: .middleTip,
        .ringKnuckle: .ringMCP, .ringIntermediateBase: .ringPIP,
        .ringIntermediateTip: .ringDIP, .ringTip: .ringTip,
        .littleKnuckle: .littleMCP, .littleIntermediateBase: .littlePIP,
        .littleIntermediateTip: .littleDIP, .littleTip: .littleTip,
    ]

    /// Real-world palm length (wrist to middle knuckle) the skeleton is scaled to.
    static let palmLength: Float = 0.09
    static let baseY: Float = -0.20
    static let baseZ: Float = -0.72

    static func map(_ observation: VNHumanHandPoseObservation,
                    aspect: CGFloat,
                    mirrored: Bool,
                    horizontalSpan: Float,
                    verticalSpan: Float) -> MacDetectedHand? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        func pt(_ name: VNHumanHandPoseObservation.JointName, min: Float = 0.3) -> CGPoint? {
            guard let p = points[name], p.confidence > min else { return nil }
            return CGPoint(x: p.location.x, y: p.location.y)
        }
        guard let wrist = pt(.wrist) else { return nil }
        let middleMCP = pt(.middleMCP) ?? wrist
        let thumbTip = pt(.thumbTip) ?? wrist
        let indexTip = pt(.indexTip) ?? wrist

        // Depth proxy: a bigger hand (wrist to middleMCP span) reads as closer.
        let handSpan = hypot(middleMCP.x - wrist.x, middleMCP.y - wrist.y)
        let depthScale = Float(min(max(handSpan, 0.05), 0.30) - 0.05) / 0.25
        let headZ = baseZ + 0.18 * (0.5 - depthScale)

        func project(_ p: CGPoint) -> SIMD3<Float> {
            let nx = mirrored ? (1.0 - p.x) : p.x
            let headX = Float(nx - 0.5) * 2 * horizontalSpan
            let headY = baseY + Float(p.y - 0.5) * 2 * verticalSpan
            return SIMD3(headX, headY, headZ)
        }
        func flip(_ p: CGPoint) -> CGPoint {
            CGPoint(x: mirrored ? 1 - p.x : p.x, y: 1 - p.y)
        }

        let wristHead = project(wrist)
        let palmNorm = Float(hypot((middleMCP.x - wrist.x) * aspect, middleMCP.y - wrist.y))
        let metersPerNorm = palmLength / max(palmNorm, 0.02)
        func jointPosition(_ p: CGPoint) -> SIMD3<Float> {
            let dx = Float((p.x - wrist.x) * aspect) * (mirrored ? -1 : 1) * metersPerNorm
            let dy = Float(p.y - wrist.y) * metersPerNorm
            return wristHead + SIMD3(dx, dy, 0)
        }

        var joints: [HandJointID: SIMD3<Float>] = [:]
        var overlay: [HandJointID: CGPoint] = [:]
        for (id, vn) in visionJoint {
            guard let p = pt(vn, min: 0.15) else { continue }
            joints[id] = jointPosition(p)
            overlay[id] = flip(p)
        }
        joints[.wrist] = wristHead
        overlay[.wrist] = flip(wrist)

        let dirX = Float(middleMCP.x - wrist.x) * (mirrored ? -1 : 1)
        let dirY = Float(middleMCP.y - wrist.y)
        let yaw = atan2(dirX, max(dirY, 0.001))

        let pinchDist = hypot(thumbTip.x - indexTip.x, thumbTip.y - indexTip.y)
        let isPinching = handSpan > 0.04 && pinchDist < handSpan * 0.45

        return MacDetectedHand(
            headPosition: wristHead,
            yaw: yaw,
            isPinching: isPinching,
            joints: joints,
            overlay: overlay,
            isLeft: wristHead.x < 0)
    }
}
#endif
