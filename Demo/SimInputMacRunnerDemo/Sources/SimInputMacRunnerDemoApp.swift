import SwiftUI
import DicyaninSimInputMacRunner

/// Mac webcam runner: estimates your full 3D body pose + hand poses from the
/// webcam with Vision and broadcasts head-relative SimInputPackets to the
/// visionOS simulator over localhost.
@main
struct SimInputMacRunnerDemoApp: App {
    @StateObject private var broadcaster = MacSimInputBroadcaster()

    var body: some Scene {
        WindowGroup {
            SimInputMacRunnerView(broadcaster: broadcaster)
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}
