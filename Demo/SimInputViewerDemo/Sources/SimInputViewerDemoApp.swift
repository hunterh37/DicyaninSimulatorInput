import SwiftUI
import RealityKit
import DicyaninSimulatorInput

/// visionOS viewer app: receives body + hand poses from the iPhone runner
/// (Demo/SimInputRunnerDemo) and shows them live in the simulator.
///
/// Create a visionOS App target in Xcode, add the local DicyaninSimulatorInput
/// package with the DicyaninSimulatorInput product plus the DicyaninHandGlove
/// product from DicyaninMockHandTracking, and drop these files in.
///
/// Info.plist: NSLocalNetworkUsageDescription, NSBonjourServices =
/// ["_dicyaninsiminput._tcp"].
///
/// Run the runner app on an iPhone on the same Wi-Fi, then press Connect.
@main
struct SimInputViewerDemoApp: App {
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup {
            SimInputViewerControlView()
        }
        .defaultSize(width: 420, height: 560)

        ImmersiveSpace(id: SimInputViewerControlView.immersiveSpaceID) {
            SimInputImmersiveView()
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
