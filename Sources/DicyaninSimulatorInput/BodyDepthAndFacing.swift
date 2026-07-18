import Foundation
import simd
import DicyaninLabsMoCapRecording

/// Monocular depth recovery for the arm chains.
///
/// A single webcam gives reliable image-plane (x, y) joint positions but a
/// near-flat, noisy z, so an arm reaching toward the camera collapses onto the
/// torso plane. This reconstructor rebuilds each arm bone's z from its known
/// canonical length: with the bone length L fixed and the projected planar
/// span p measured, the out-of-plane component is `sqrt(L^2 - p^2)`
/// (foreshortening). The front/back sign is resolved from the raw z when it
/// clears the sensor noise floor and held through the ambiguous near-frontal
/// region otherwise, with a forward (toward-camera) prior on cold start.
/// Reconstructed z is temporally smoothed so recovered reach never snaps.
public struct LimbDepthReconstructor {
    public init() {}

    /// Canonical bone lengths (parent joint -> this joint), meters. Match the
    /// sanitizer's arm constraints so the two stages agree on scale.
    private static let boneLength: [ARKitBodyJoint: Float] = [
        .leftForearm: 0.28, .rightForearm: 0.28,  // upper arm (shoulder -> elbow)
        .leftHand: 0.26, .rightHand: 0.26          // forearm (elbow -> wrist)
    ]

    private static let chains: [[ARKitBodyJoint]] = [
        [.leftArm, .leftForearm, .leftHand],
        [.rightArm, .rightForearm, .rightHand]
    ]

    /// Raw z magnitude below this is treated as sensor noise (no sign info).
    private static let noiseFloor: Float = 0.03
    /// Forward (toward camera, +z) prior when no history and no raw sign.
    private static let forwardBias: Float = 1
    /// Per-frame ease toward the newly reconstructed z.
    private static let smoothing: Float = 0.4

    private var sign: [ARKitBodyJoint: Float] = [:]
    private var smoothedZ: [ARKitBodyJoint: Float] = [:]

    public mutating func reset() {
        sign.removeAll()
        smoothedZ.removeAll()
    }

    /// Rewrite the z of every arm joint from bone-length foreshortening.
    public mutating func reconstruct(_ joints: inout [ARKitBodyJoint: SIMD3<Float>]) {
        for chain in Self.chains {
            guard var parent = joints[chain[0]], isValid(parent) else { continue }
            for index in 1 ..< chain.count {
                let joint = chain[index]
                guard let child = joints[joint], isValid(child),
                      let length = Self.boneLength[joint] else { break }

                let delta = child - parent
                let planar = (delta.x * delta.x + delta.y * delta.y).squareRoot()
                let zMagnitude = planar < length
                    ? (length * length - planar * planar).squareRoot()
                    : 0

                let resolvedSign: Float
                if abs(delta.z) > Self.noiseFloor {
                    resolvedSign = delta.z >= 0 ? 1 : -1
                } else {
                    resolvedSign = sign[joint] ?? Self.forwardBias
                }
                sign[joint] = resolvedSign

                var z = parent.z + resolvedSign * zMagnitude
                z = smoothedZ[joint].map {
                    $0 + (z - $0) * Self.smoothing
                } ?? z
                smoothedZ[joint] = z

                let rebuilt = SIMD3<Float>(child.x, child.y, z)
                joints[joint] = rebuilt
                parent = rebuilt
            }
        }
    }

    private func isValid(_ p: SIMD3<Float>) -> Bool {
        simd_length_squared(p) > 1e-6
    }
}

/// Estimates the person's body yaw (turn about the vertical axis) from the
/// shoulder and hip lines.
///
/// The lateral separation of the shoulders (and hips) shrinks as the person
/// turns away from the camera; the lost width reappears as depth. Using the
/// same bone-length-foreshortening recovery as ``LimbDepthReconstructor`` with
/// an adaptively calibrated max width (the widest span seen, taken as the
/// facing-camera pose), the shoulder line's true xz direction is recovered and
/// its heading gives the yaw. Shoulder and hip estimates are averaged when both
/// are present and the result is heavily smoothed for a stable heading.
public struct BodyFacingEstimator {
    public init() {}

    private static let smoothing: Float = 0.15
    private static let noiseFloor: Float = 0.02
    /// Adaptive width slowly decays so a one-off wide misdetection cannot pin
    /// the calibration permanently.
    private static let widthDecay: Float = 0.997
    private static let minWidth: Float = 0.12

    private var shoulderWidth: Float = 0.34
    private var hipWidth: Float = 0.24
    private var yaw: Float = 0

    public mutating func reset() {
        shoulderWidth = 0.34
        hipWidth = 0.24
        yaw = 0
    }

    /// Update from a sanitized frame; returns the smoothed body yaw in radians
    /// (0 = squarely facing the camera).
    public mutating func update(_ joints: [ARKitBodyJoint: SIMD3<Float>]) -> Float {
        var samples: [Float] = []
        if let heading = heading(from: joints[.leftArm], to: joints[.rightArm],
                                 width: &shoulderWidth) {
            samples.append(heading)
        }
        if let heading = heading(from: joints[.leftUpLeg], to: joints[.rightUpLeg],
                                 width: &hipWidth) {
            samples.append(heading)
        }
        guard !samples.isEmpty else {
            yaw += (0 - yaw) * Self.smoothing
            return yaw
        }
        let raw = samples.reduce(0, +) / Float(samples.count)
        yaw += (raw - yaw) * Self.smoothing
        return yaw
    }

    private func isValid(_ p: SIMD3<Float>?) -> Bool {
        guard let p else { return false }
        return simd_length_squared(p) > 1e-6
    }

    /// Heading of a left->right lateral line with depth recovered from `width`.
    private func heading(from left: SIMD3<Float>?, to right: SIMD3<Float>?,
                         width: inout Float) -> Float? {
        guard isValid(left), isValid(right), let left, let right else { return nil }
        let delta = right - left
        let planar = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        width = max(max(width * Self.widthDecay, Self.minWidth), planar)

        var z = delta.z
        if planar < width {
            let magnitude = (width * width - planar * planar).squareRoot()
            let sign: Float = abs(delta.z) > Self.noiseFloor
                ? (delta.z >= 0 ? 1 : -1)
                : (z >= 0 ? 1 : -1)
            z = sign * magnitude
        }
        guard abs(delta.x) > 1e-4 || abs(z) > 1e-4 else { return nil }
        return atan2(z, delta.x)
    }
}
