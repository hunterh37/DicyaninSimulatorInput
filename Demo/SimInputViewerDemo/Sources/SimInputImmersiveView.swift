import SwiftUI
import RealityKit
import DicyaninSimulatorInput
import DicyaninHandGlove

/// Immersive scene: full integration of the package outputs.
/// - Body representation, toggled from the control window:
///   `BodySkeletonEntity` (stick-figure wireframe) or `HumanoidBodyEntity`
///   (3D humanoid with full body + hand retargeting).
/// - `HandGloveView.addHands`: gloves following `MockHandTrackingController`,
///   which `SimulatorInputController` feeds from the received hand packets.
/// - A pinch-reactive target sphere driven by the mock hand joints, showing
///   gameplay logic consuming the same input path.
struct SimInputImmersiveView: View {
    @ObservedObject private var settings = ViewerSceneSettings.shared

    @State private var skeleton = BodySkeletonEntity()
    @State private var humanoid = HumanoidBodyEntity()

    var body: some View {
        RealityView { content in
            skeleton.worldOffset = [0, 1.5, -1.5]
            content.add(skeleton)

            humanoid.worldOffset = [0, 1.5, -1.5]
            content.add(humanoid)

            HandGloveView.addHands(to: content)

            content.add(PinchTargetEntity())

            let floor = ModelEntity(
                mesh: .generatePlane(width: 2, depth: 2),
                materials: [UnlitMaterial(color: .init(white: 0.2, alpha: 0.4))]
            )
            floor.position = [0, 0.02, -1.5]
            content.add(floor)

            applyRepresentation()
        } update: { _ in
            applyRepresentation()
        }
    }

    private func applyRepresentation() {
        skeleton.isEnabled = !settings.useHumanoid
        humanoid.isEnabled = settings.useHumanoid
    }
}
