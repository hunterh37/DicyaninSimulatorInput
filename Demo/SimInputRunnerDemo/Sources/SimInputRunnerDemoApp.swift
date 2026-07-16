import SwiftUI
import DicyaninSimInputRunner

/// iPhone runner app: place the phone on the desk facing you and it streams
/// body + hand poses to the visionOS simulator.
///
/// Create an iOS App target in Xcode, add the local DicyaninSimulatorInput
/// package with the DicyaninSimInputRunner product, drop these files in, and
/// set Info.plist keys:
/// - NSCameraUsageDescription: "Tracks your body and hands to drive the visionOS simulator."
/// - NSLocalNetworkUsageDescription: "Streams poses to the visionOS simulator on your Mac."
/// - NSBonjourServices: ["_dicyaninsiminput._tcp"]
@main
struct SimInputRunnerDemoApp: App {
    @StateObject private var broadcaster = SimInputBroadcaster()

    var body: some Scene {
        WindowGroup {
            SimInputRunnerView(broadcaster: broadcaster)
                .persistentSystemOverlays(.hidden)
        }
    }
}
