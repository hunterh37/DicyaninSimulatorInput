import SwiftUI
import DicyaninLabsMoCapRecording

#if os(iOS)
import ARKit
import RealityKit

/// Drop-in iPhone runner screen: camera preview, live body + hand wireframe
/// overlays, server status, and a start/stop control. Embed in the runner
/// app's root:
/// ```swift
/// @StateObject private var broadcaster = SimInputBroadcaster()
/// var body: some View { SimInputRunnerView(broadcaster: broadcaster) }
/// ```
public struct SimInputRunnerView: View {
    @ObservedObject private var broadcaster: SimInputBroadcaster

    public init(broadcaster: SimInputBroadcaster) {
        self.broadcaster = broadcaster
    }

    public var body: some View {
        ZStack {
            ARSessionPreview(session: broadcaster.arSession)
                .ignoresSafeArea()
            overlays
            VStack {
                statusBar
                Spacer()
                controls
            }
            .padding()
        }
        .onAppear { broadcaster.start() }
        .onDisappear { broadcaster.stop() }
    }

    private var overlays: some View {
        GeometryReader { geo in
            let size = geo.size
            let orientation = UIInterfaceOrientation.portrait
            Canvas { context, _ in
                if let body = broadcaster.liveBody {
                    draw(points: body.projectedPoints(viewportSize: size, orientation: orientation),
                         bones: body.bones, color: .green, context: &context)
                }
                if let left = broadcaster.liveLeftHand {
                    draw(points: left.projectedPoints(viewportSize: size, orientation: orientation),
                         bones: left.bones, color: .cyan, context: &context)
                }
                if let right = broadcaster.liveRightHand {
                    draw(points: right.projectedPoints(viewportSize: size, orientation: orientation),
                         bones: right.bones, color: .orange, context: &context)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw<J: Hashable>(points: [J: CGPoint],
                                   bones: [(J, J)],
                                   color: Color,
                                   context: inout GraphicsContext) {
        var path = Path()
        for (child, parent) in bones {
            guard let a = points[child], let b = points[parent] else { continue }
            path.move(to: a)
            path.addLine(to: b)
        }
        context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 2)
        for (_, p) in points {
            let dot = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(color))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusDot("Body", on: broadcaster.isBodyTracked)
            statusDot("L", on: broadcaster.isLeftHandTracked)
            statusDot("R", on: broadcaster.isRightHandTracked)
            Spacer()
            serverLabel
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusDot(_ label: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(label).font(.caption.monospaced())
        }
    }

    @ViewBuilder
    private var serverLabel: some View {
        switch broadcaster.serverState {
        case .setup:
            Text("starting").font(.caption.monospaced()).foregroundStyle(.secondary)
        case .ready(let port):
            Text(":\(String(port)) clients \(broadcaster.clientCount)")
                .font(.caption.monospaced())
        case .failed(let message):
            Text(message).font(.caption.monospaced()).foregroundStyle(.red)
        }
    }

    private var controls: some View {
        Button {
            broadcaster.isRunning ? broadcaster.stop() : broadcaster.start()
        } label: {
            Text(broadcaster.isRunning ? "Stop" : "Start")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(broadcaster.isRunning ? .red : .green)
    }
}

/// Minimal ARView wrapper that displays the broadcaster's session feed.
private struct ARSessionPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
#endif
