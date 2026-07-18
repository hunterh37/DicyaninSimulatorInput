import Foundation
import simd
import Combine
import DicyaninLabsMoCapRecording
import DicyaninHandTrackingTransport
import DicyaninSimInputTransport
import DicyaninMockHandTracking

/// visionOS-side singleton: connects to the iPhone runner and feeds the
/// received poses into the simulator.
///
/// Hands flow into `MockHandTrackingController.shared` through its existing
/// `apply(_:)` seam, so every consumer of the mock controller (glove, gesture
/// models, joint-based logic) gets iPhone-driven hand input with no changes.
/// The body skeleton is published here, head-relative (x right, y up,
/// negative z in front), for avatar driving or full-body interactions.
///
/// ```swift
/// // Root view of the visionOS app, simulator builds:
/// .task { SimulatorInputController.shared.connect() }
/// ```
@MainActor
public final class SimulatorInputController: ObservableObject {
    public static let shared = SimulatorInputController()

    /// True while the receiver task is running (connected or reconnecting).
    @Published public private(set) var isConnected = false

    /// True while the runner reports a tracked body.
    @Published public private(set) var isBodyTracked = false

    /// Latest head-relative body joint positions, keyed by joint.
    @Published public private(set) var bodyJoints: [ARKitBodyJoint: SIMD3<Float>] = [:]

    /// Smoothed displacement of the tracked person from where they were first
    /// detected, in the same axes as `bodyJoints`. Add it to a body
    /// representation's placement so the figure walks around the room with the
    /// person instead of staying pinned at the origin. Zero until a runner
    /// that sends it connects.
    @Published public private(set) var bodyRootOffset: SIMD3<Float> = .zero

    /// Smoothed body yaw of the tracked person in radians, in the head-relative
    /// frame (0 = squarely facing the camera, positive = turning so the right
    /// shoulder rotates away from the camera). Drives the humanoid root so the
    /// figure turns with the person. Zero until a tracked body is received.
    @Published public private(set) var bodyYaw: Float = 0

    /// Monocular depth pass: rebuilds arm-joint z from bone-length
    /// foreshortening so arms reaching toward the camera extend instead of
    /// collapsing onto the torso plane. Set to nil to publish planar arms.
    public var depthReconstructor: LimbDepthReconstructor? = LimbDepthReconstructor()

    /// Body-yaw estimator from the shoulder/hip lines. Set to nil to keep the
    /// figure squarely facing the camera.
    public var facingEstimator: BodyFacingEstimator? = BodyFacingEstimator()

    /// Whether received hand packets should be forwarded into
    /// `MockHandTrackingController.shared`. On by default.
    public var drivesMockHands = true

    /// Anatomical filter applied to every received body frame: implausible
    /// joints (off-camera legs reported above the head, teleporting limbs)
    /// are rejected and extrapolated from their nearest valid neighbor. Set
    /// to nil to publish raw joints.
    public var sanitizer: BodyPoseSanitizer? = BodyPoseSanitizer()

    private var receiver: SimInputReceiver?
    private var task: Task<Void, Never>?

    private init() {}

    /// Connect by host and port. Use the default `"localhost"` when the
    /// visionOS simulator reaches the iPhone through the Mac (USB port forward
    /// such as `pymobiledevice3 usbmux forward`, or any local relay);
    /// otherwise pass the iPhone's LAN IP.
    public func connect(host: String = "localhost",
                        port: UInt16 = SimInputWire.defaultPort) {
        connect(to: .host(host, port: port))
    }

    /// Discover the iPhone runner over Bonjour on the same network.
    public func connect(bonjourName: String? = nil) {
        connect(to: .bonjour(name: bonjourName))
    }

    private func connect(to endpoint: SimInputReceiver.Endpoint) {
        disconnect()
        let receiver = SimInputReceiver(endpoint)
        self.receiver = receiver
        task = Task { @MainActor in
            isConnected = true
            for await packet in receiver.packets() {
                apply(packet)
            }
            isConnected = false
        }
    }

    public func disconnect() {
        receiver?.cancel()
        receiver = nil
        task?.cancel()
        task = nil
        isConnected = false
        isBodyTracked = false
        bodyYaw = 0
        sanitizer?.reset()
        depthReconstructor?.reset()
        facingEstimator?.reset()
    }

    /// Apply one packet: body joints published here, hands forwarded to the
    /// mock hand-tracking controller. Public so recordings or tests can drive
    /// the controller without a network connection.
    public func apply(_ packet: SimInputPacket) {
        isBodyTracked = packet.bodyTracked
        if let joints = packet.bodyJointsByID() {
            var frame = sanitizer != nil ? sanitizer!.sanitize(joints) : joints
            depthReconstructor?.reconstruct(&frame)
            if let facing = facingEstimator?.update(frame) {
                bodyYaw = facing
            }
            bodyJoints = frame
        }
        if packet.bodyTracked, let offset = packet.rootOffset {
            bodyRootOffset = offset
        }
        if drivesMockHands {
            MockHandTrackingController.shared.apply(packet.hands)
        }
    }

    /// Stream of body joint updates, current value first.
    public func bodyUpdates() -> AsyncStream<[ARKitBodyJoint: SIMD3<Float>]> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for await joints in $bodyJoints.values {
                    continuation.yield(joints)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
