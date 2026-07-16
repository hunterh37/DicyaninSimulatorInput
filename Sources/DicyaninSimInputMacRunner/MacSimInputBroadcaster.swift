import Foundation
import simd
import DicyaninHandTrackingTransport
import DicyaninSimInputTransport

#if os(macOS)
import AVFoundation
import Vision
import QuartzCore

/// Mac-side controller: watches the webcam, estimates 3D body pose + hand
/// poses with Vision, and broadcasts head-relative `SimInputPacket`s over TCP
/// for the visionOS simulator to consume as live full-body + hand input.
///
/// Same wire contract as `SimInputBroadcaster` on iPhone, so the visionOS
/// consumer (`SimulatorInputController`) works with either runner unchanged.
@MainActor
public final class MacSimInputBroadcaster: ObservableObject {
    @Published public private(set) var serverState: SimInputSender.State = .setup
    @Published public private(set) var clientCount = 0
    @Published public private(set) var isBodyTracked = false
    @Published public private(set) var isLeftHandTracked = false
    @Published public private(set) var isRightHandTracked = false
    @Published public private(set) var isRunning = false
    @Published public private(set) var cameraAuthorized = true
    @Published public private(set) var fps = 0

    /// Live overlay state republished for the runner UI.
    @Published public private(set) var hands: [MacDetectedHand] = []
    @Published public private(set) var bodyOverlay: [VNHumanBodyPose3DObservation.JointName: CGPoint] = [:]
    @Published public private(set) var videoSize = CGSize(width: 16, height: 9)

    // Operator tuning.
    @Published public var mirrored = true {
        didSet { pipeline.mirrored = mirrored }
    }
    @Published public var horizontalSpan: Float = 0.45 {
        didSet { pipeline.horizontalSpan = horizontalSpan }
    }
    @Published public var verticalSpan: Float = 0.35 {
        didSet { pipeline.verticalSpan = verticalSpan }
    }

    public let session = AVCaptureSession()
    private let pipeline = MacVisionPipeline()
    private var sender: SimInputSender?
    private let port: UInt16
    private var sessionConfigured = false

    /// Broadcast rate cap, matching the iPhone runner.
    private let minSendInterval: CFTimeInterval = 1.0 / 30.0
    private var lastSend: CFTimeInterval = 0
    private var lastLeftPosition: SIMD3<Float> = [-0.22, -0.26, -0.72]
    private var lastRightPosition: SIMD3<Float> = [0.22, -0.26, -0.72]

    private var fpsCounter = 0
    private var fpsTimer: Timer?

    public init(port: UInt16 = SimInputWire.defaultPort) {
        self.port = port
    }

    public func start() async {
        guard !isRunning else { return }
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

        pipeline.mirrored = mirrored
        pipeline.horizontalSpan = horizontalSpan
        pipeline.verticalSpan = verticalSpan
        pipeline.onFrame = { [weak self] frame in
            Task { @MainActor in self?.publish(frame) }
        }
        await configureCamera()
        guard cameraAuthorized else {
            sender?.stop()
            sender = nil
            serverState = .setup
            return
        }
        startFPSTimer()
        isRunning = true
    }

    /// AVCaptureSession start/stop block, so they run off the main actor.
    /// The session itself is thread-safe for these calls.
    private nonisolated static func onSessionQueue(_ session: AVCaptureSession,
                                                   _ work: @escaping @Sendable (AVCaptureSession) -> Void) {
        nonisolated(unsafe) let session = session
        DispatchQueue.global(qos: .userInitiated).async { work(session) }
    }

    public func stop() {
        Self.onSessionQueue(session) { if $0.isRunning { $0.stopRunning() } }
        pipeline.onFrame = nil
        sender?.stop()
        sender = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        isRunning = false
        isBodyTracked = false
        isLeftHandTracked = false
        isRightHandTracked = false
        clientCount = 0
        serverState = .setup
        hands = []
        bodyOverlay = [:]
        fps = 0
        fpsCounter = 0
    }

    // MARK: - Camera

    private func configureCamera() async {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        cameraAuthorized = granted
        guard granted else { return }
        guard !sessionConfigured else {
            Self.onSessionQueue(session) { if !$0.isRunning { $0.startRunning() } }
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .high
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        if let device, let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(pipeline, queue: pipeline.queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        sessionConfigured = true

        Self.onSessionQueue(session) { $0.startRunning() }
    }

    // MARK: - Publish

    private func publish(_ frame: MacVisionFrame) {
        hands = frame.hands
        bodyOverlay = frame.bodyOverlay
        if frame.frameSize != videoSize { videoSize = frame.frameSize }
        isBodyTracked = frame.bodyJoints != nil
        fpsCounter += 1

        var left = frame.hands.first(where: { $0.isLeft })
        var right = frame.hands.first(where: { !$0.isLeft })
        if frame.hands.count == 1, let only = frame.hands.first {
            if only.isLeft { right = nil } else { left = nil }
        }
        isLeftHandTracked = left != nil
        isRightHandTracked = right != nil

        guard let sender else { return }
        let now = CACurrentMediaTime()
        guard now - lastSend >= minSendInterval else { return }
        lastSend = now

        if let l = left { lastLeftPosition = l.headPosition }
        if let r = right { lastRightPosition = r.headPosition }

        let handsPacket = HandPosePacket(
            leftPosition: lastLeftPosition,
            rightPosition: lastRightPosition,
            leftYaw: left?.yaw ?? 0,
            rightYaw: right?.yaw ?? 0,
            isPinching: (left?.isPinching ?? false) || (right?.isPinching ?? false),
            leftTracked: left != nil,
            rightTracked: right != nil,
            leftJoints: left?.wireJoints,
            rightJoints: right?.wireJoints)

        sender.broadcast(SimInputPacket(
            hands: handsPacket,
            bodyJoints: frame.bodyJoints,
            bodyTracked: frame.bodyJoints != nil,
            rootOffset: frame.rootOffset))
    }

    private func startFPSTimer() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fps = self.fpsCounter
                self.fpsCounter = 0
            }
        }
    }
}
#endif
