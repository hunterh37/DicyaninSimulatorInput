import Foundation
import simd
import DicyaninLabsMoCapRecording
import DicyaninHandTrackingTransport
import DicyaninSimInputTransport

#if os(iOS)
import ARKit
import QuartzCore

/// iPhone-side controller: runs ARKit body tracking + Vision hand tracking
/// (reusing `ARBodyCaptureSession` from DicyaninLabsMoCapRecording) and
/// broadcasts head-relative `SimInputPacket`s over TCP for the visionOS
/// simulator to consume as live full-body + hand input.
///
/// Set the iPhone on the desk in front of you, front camera facing you, start
/// the broadcaster, and connect from the visionOS app.
@MainActor
public final class SimInputBroadcaster: ObservableObject {
    @Published public private(set) var serverState: SimInputSender.State = .setup
    @Published public private(set) var clientCount = 0
    @Published public private(set) var isBodyTracked = false
    @Published public private(set) var isLeftHandTracked = false
    @Published public private(set) var isRightHandTracked = false
    @Published public private(set) var isRunning = false

    /// Live snapshots republished for overlay rendering in the runner UI.
    @Published public private(set) var liveBody: LiveBodySnapshot?
    @Published public private(set) var liveLeftHand: LiveHandSnapshot?
    @Published public private(set) var liveRightHand: LiveHandSnapshot?

    /// The AR session to attach to an `ARView`/preview if desired.
    public var arSession: ARSession { capture.session }

    public var isSupported: Bool { capture.isSupported }

    private let recorder = MoCapRecorder()
    private lazy var capture = ARBodyCaptureSession(recorder: recorder)
    private var sender: SimInputSender?
    private let port: UInt16

    /// Broadcast rate cap. Body anchors update at 60 Hz; 30 Hz is plenty for
    /// simulator input and halves the wire traffic.
    private let minSendInterval: CFTimeInterval = 1.0 / 30.0
    private var lastSend: CFTimeInterval = 0

    // Latest mapped state, held between updates so every packet is complete.
    private var latestFrame: PersonFrameMapper.Frame?
    private var lastLeftPosition: SIMD3<Float> = [-0.22, -0.26, -0.72]
    private var lastRightPosition: SIMD3<Float> = [0.22, -0.26, -0.72]

    public init(port: UInt16 = SimInputWire.defaultPort) {
        self.port = port
    }

    public func start() {
        guard !isRunning else { return }
        guard isSupported else {
            serverState = .failed("ARKit body tracking is not supported on this device")
            return
        }
        do {
            let sender = try SimInputSender(port: port)
            self.sender = sender
            sender.onStateChange = { [weak self] state in
                Task { @MainActor in self?.serverState = state }
            }
            sender.onClientCountChange = { [weak self] count in
                Task { @MainActor in self?.clientCount = count }
            }
            sender.start()
        } catch {
            serverState = .failed(error.localizedDescription)
            return
        }

        capture.onLiveBody = { [weak self] snapshot in
            Task { @MainActor in self?.handleBody(snapshot) }
        }
        capture.onLiveHands = { [weak self] left, right in
            Task { @MainActor in self?.handleHands(left, right) }
        }
        capture.run()
        isRunning = true
    }

    public func stop() {
        capture.pause()
        capture.onLiveBody = nil
        capture.onLiveHands = nil
        sender?.stop()
        sender = nil
        isRunning = false
        isBodyTracked = false
        isLeftHandTracked = false
        isRightHandTracked = false
        clientCount = 0
        serverState = .setup
        liveBody = nil
        liveLeftHand = nil
        liveRightHand = nil
        latestFrame = nil
    }

    // MARK: - Capture handling

    private func handleBody(_ snapshot: LiveBodySnapshot) {
        liveBody = snapshot
        isBodyTracked = capture.isBodyTracked
        latestFrame = PersonFrameMapper.frame(
            bodyWorldJoints: snapshot.worldJoints,
            cameraTransform: snapshot.camera.transform
        )
        broadcastIfDue()
    }

    private func handleHands(_ left: LiveHandSnapshot?, _ right: LiveHandSnapshot?) {
        liveLeftHand = left
        liveRightHand = right
        isLeftHandTracked = left != nil
        isRightHandTracked = right != nil
        broadcastIfDue()
    }

    private func broadcastIfDue() {
        guard let sender, let frame = latestFrame else { return }
        let now = CACurrentMediaTime()
        guard now - lastSend >= minSendInterval else { return }
        lastSend = now

        let left = liveLeftHand.flatMap { PersonFrameMapper.mapHand($0.worldJoints, frame: frame) }
        let right = liveRightHand.flatMap { PersonFrameMapper.mapHand($0.worldJoints, frame: frame) }
        if let left { lastLeftPosition = left.position }
        if let right { lastRightPosition = right.position }

        let hands = HandPosePacket(
            leftPosition: lastLeftPosition,
            rightPosition: lastRightPosition,
            leftYaw: left?.yaw ?? 0,
            rightYaw: right?.yaw ?? 0,
            isPinching: (left?.isPinching ?? false) || (right?.isPinching ?? false),
            leftTracked: left != nil,
            rightTracked: right != nil,
            leftJoints: left?.joints,
            rightJoints: right?.joints
        )

        let body = liveBody.map { PersonFrameMapper.mapBody($0.worldJoints, frame: frame) }
        sender.broadcast(SimInputPacket(
            hands: hands,
            bodyJoints: body,
            bodyTracked: isBodyTracked
        ))
    }
}
#endif
