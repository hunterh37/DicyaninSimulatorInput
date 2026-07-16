import Foundation
import simd

/// Tracks the person's translation through the capture space so the visionOS
/// consumer can move the rendered body around the room instead of pinning it
/// at the origin.
///
/// The reference point and axes are captured on the first tracked frame (so
/// the offset starts at zero exactly where the person is standing), each
/// update projects the current head position onto those fixed axes, and the
/// result is EMA-smoothed so depth-estimate noise never jitters the figure.
/// Call ``reset()`` on tracking loss so the next detection re-zeros cleanly.
public struct SimInputRootTracker: Sendable {
    private var refOrigin: SIMD3<Float>?
    private var xAxis: SIMD3<Float> = [1, 0, 0]
    private var yAxis: SIMD3<Float> = [0, 1, 0]
    private var zAxis: SIMD3<Float> = [0, 0, 1]
    private var smoothed: SIMD3<Float> = .zero
    private let smoothing: Float

    public init(smoothing: Float = 0.25) {
        self.smoothing = smoothing
    }

    /// Feed the current head position (capture space) plus the axes matching
    /// the runner's joint-mapping convention. Returns the smoothed offset in
    /// those axes; zero on the first tracked frame.
    public mutating func update(position: SIMD3<Float>,
                                xAxis: SIMD3<Float>,
                                yAxis: SIMD3<Float>,
                                zAxis: SIMD3<Float>) -> SIMD3<Float> {
        guard let origin = refOrigin else {
            refOrigin = position
            self.xAxis = xAxis
            self.yAxis = yAxis
            self.zAxis = zAxis
            smoothed = .zero
            return .zero
        }
        let d = position - origin
        let target = SIMD3(simd_dot(d, self.xAxis),
                           simd_dot(d, self.yAxis),
                           simd_dot(d, self.zAxis))
        smoothed = simd_mix(smoothed, target, SIMD3(repeating: smoothing))
        return smoothed
    }

    public mutating func reset() {
        refOrigin = nil
        smoothed = .zero
    }
}
