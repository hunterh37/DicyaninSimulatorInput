import SwiftUI
import DicyaninHandTrackingTransport

#if os(macOS)
import AVFoundation
import Vision

/// Drop-in macOS runner screen: webcam preview, live body + hand wireframe
/// overlays, server status, and operator tuning. Embed in the runner app root:
/// ```swift
/// @StateObject private var broadcaster = MacSimInputBroadcaster()
/// var body: some View { SimInputMacRunnerView(broadcaster: broadcaster) }
/// ```
public struct SimInputMacRunnerView: View {
    @ObservedObject private var broadcaster: MacSimInputBroadcaster

    public init(broadcaster: MacSimInputBroadcaster) {
        self.broadcaster = broadcaster
    }

    public var body: some View {
        VStack(spacing: 0) {
            preview
            controls
        }
        .background(Color.black)
        .task { await broadcaster.start() }
        .onDisappear { broadcaster.stop() }
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                if broadcaster.cameraAuthorized {
                    MacCameraPreview(session: broadcaster.session, mirrored: broadcaster.mirrored)
                    BodyHandOverlay(bodyOverlay: broadcaster.bodyOverlay,
                                    hands: broadcaster.hands,
                                    size: geo.size,
                                    videoSize: broadcaster.videoSize)
                } else {
                    cameraDeniedNotice
                }
                VStack { statusBar; Spacer() }
            }
        }
        .frame(minHeight: 380)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusDot("Body", on: broadcaster.isBodyTracked)
            statusDot("L", on: broadcaster.isLeftHandTracked)
            statusDot("R", on: broadcaster.isRightHandTracked)
            Divider().frame(height: 14)
            Text("\(broadcaster.fps) fps")
            Spacer()
            serverLabel
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func statusDot(_ label: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(label)
        }
    }

    @ViewBuilder
    private var serverLabel: some View {
        switch broadcaster.serverState {
        case .setup:
            Text("starting").foregroundStyle(.secondary)
        case .ready(let port):
            Text(":\(String(port)) clients \(broadcaster.clientCount)")
                .foregroundStyle(broadcaster.clientCount > 0 ? .green : .primary)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    if broadcaster.isRunning {
                        broadcaster.stop()
                    } else {
                        Task { await broadcaster.start() }
                    }
                } label: {
                    Text(broadcaster.isRunning ? "Stop" : "Start")
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(broadcaster.isRunning ? .red : .green)
                Spacer()
                Toggle("Mirror (selfie view)", isOn: $broadcaster.mirrored)
            }
            slider("Horizontal reach", value: $broadcaster.horizontalSpan, range: 0.2...0.8)
            slider("Vertical reach", value: $broadcaster.verticalSpan, range: 0.2...0.6)
            Text("Stand back so the camera sees your whole body. In the visionOS simulator app, connect with `SimulatorInputController` to receive body + hands live.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.background)
    }

    private func slider(_ title: String, value: Binding<Float>,
                        range: ClosedRange<Float>) -> some View {
        HStack {
            Text(title).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f m", value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var cameraDeniedNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash").font(.largeTitle)
            Text("Camera access denied")
            Text("Enable it in System Settings, Privacy & Security, Camera.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Draws the body wireframe (green) and hand skeletons (blue/orange) over the
/// live preview, matching the preview layer's aspect-fill scale and crop.
private struct BodyHandOverlay: View {
    let bodyOverlay: [VNHumanBodyPose3DObservation.JointName: CGPoint]
    let hands: [MacDetectedHand]
    let size: CGSize
    let videoSize: CGSize

    private static let chains: [[HandJointID]] = [
        [.wrist, .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
        [.wrist, .indexKnuckle, .indexIntermediateBase, .indexIntermediateTip, .indexTip],
        [.wrist, .middleKnuckle, .middleIntermediateBase, .middleIntermediateTip, .middleTip],
        [.wrist, .ringKnuckle, .ringIntermediateBase, .ringIntermediateTip, .ringTip],
        [.wrist, .littleKnuckle, .littleIntermediateBase, .littleIntermediateTip, .littleTip],
    ]

    var body: some View {
        Canvas { ctx, _ in
            // Body wireframe.
            var bodyPath = Path()
            for (a, b) in MacBodyMapper.overlayBones {
                guard let pa = bodyOverlay[a], let pb = bodyOverlay[b] else { continue }
                bodyPath.move(to: point(pa))
                bodyPath.addLine(to: point(pb))
            }
            ctx.stroke(bodyPath, with: .color(.green.opacity(0.8)), lineWidth: 2)
            for (_, p) in bodyOverlay {
                let c = point(p)
                let dot = CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: dot), with: .color(.green))
            }

            // Hands.
            for hand in hands {
                let color: Color = hand.isLeft ? .blue : .orange
                for chain in Self.chains {
                    var path = Path()
                    var started = false
                    for id in chain {
                        guard let p = hand.overlay[id] else { continue }
                        if started { path.addLine(to: point(p)) }
                        else { path.move(to: point(p)); started = true }
                    }
                    ctx.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 2)
                }
                for (_, p) in hand.overlay {
                    let c = point(p)
                    let dot = CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)
                    ctx.fill(Path(ellipseIn: dot), with: .color(color))
                }
                if hand.isPinching,
                   let thumb = hand.overlay[.thumbTip], let index = hand.overlay[.indexTip] {
                    var path = Path()
                    path.move(to: point(thumb))
                    path.addLine(to: point(index))
                    ctx.stroke(path, with: .color(.yellow), lineWidth: 3)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        guard videoSize.width > 0, videoSize.height > 0,
              size.width > 0, size.height > 0 else {
            return CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        let drawn = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let offset = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
        return CGPoint(x: offset.x + p.x * drawn.width,
                       y: offset.y + p.y * drawn.height)
    }
}

/// Live camera preview backed by `AVCaptureVideoPreviewLayer`.
private struct MacCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.mirrored = mirrored
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        var mirrored = false {
            didSet { applyMirror() }
        }

        private func applyMirror() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.setAffineTransform(
                mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            CATransaction.commit()
        }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = previewLayer
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
#endif
