import SwiftUI
import DicyaninSimulatorInput
import DicyaninMockHandTracking

/// Control window: connect to the iPhone runner (Bonjour or manual host),
/// live status, and immersive space toggle.
struct SimInputViewerControlView: View {
    static let immersiveSpaceID = "SimInputViewer"

    @ObservedObject private var controller = SimulatorInputController.shared
    @ObservedObject private var mockHands = MockHandTrackingController.shared

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var host = ""
    @State private var immersiveSpaceOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Simulator Input Viewer")
                .font(.title2.bold())

            connectionSection
            statusSection
            immersiveSection

            Spacer()
        }
        .padding(24)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection").font(.headline)

            if controller.isConnected {
                Button("Disconnect", role: .destructive) {
                    controller.disconnect()
                }
            } else {
                Button("Connect (Bonjour)") {
                    controller.connect(bonjourName: nil)
                }
                HStack {
                    TextField("iPhone IP, e.g. 192.168.1.23", text: $host)
                        .textFieldStyle(.roundedBorder)
                    Button("Connect") {
                        controller.connect(host: host)
                    }
                    .disabled(host.isEmpty)
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status").font(.headline)
            statusRow("Receiver", on: controller.isConnected)
            statusRow("Body tracked", on: controller.isBodyTracked)
            statusRow("Body joints: \(controller.bodyJoints.count)",
                      on: !controller.bodyJoints.isEmpty)
            statusRow("Mock hands driven", on: controller.drivesMockHands)
            Text(String(format: "L (%.2f, %.2f, %.2f)  R (%.2f, %.2f, %.2f)",
                        mockHands.leftHandPosition.x,
                        mockHands.leftHandPosition.y,
                        mockHands.leftHandPosition.z,
                        mockHands.rightHandPosition.x,
                        mockHands.rightHandPosition.y,
                        mockHands.rightHandPosition.z))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var immersiveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scene").font(.headline)
            Button(immersiveSpaceOpen ? "Close Immersive Scene" : "Open Immersive Scene") {
                Task {
                    if immersiveSpaceOpen {
                        await dismissImmersiveSpace()
                        immersiveSpaceOpen = false
                    } else if await openImmersiveSpace(id: Self.immersiveSpaceID) == .opened {
                        immersiveSpaceOpen = true
                    }
                }
            }
            Text("Skeleton wireframe plus gloves on both hands, driven by the iPhone runner.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusRow(_ label: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(on ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(label)
        }
        .font(.callout)
    }
}
