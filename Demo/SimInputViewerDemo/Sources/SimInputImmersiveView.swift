import SwiftUI
import RealityKit
import DicyaninSimulatorInput
import DicyaninHandGlove

/// Immersive scene: full integration of the package outputs.
/// - `BodySkeletonEntity`: ECS-driven wireframe of the iPhone-tracked body.
/// - `HandGloveView.addHands`: gloves following `MockHandTrackingController`,
///   which `SimulatorInputController` feeds from the received hand packets.
/// - A pinch-reactive target sphere driven by the mock hand joints, showing
///   gameplay logic consuming the same input path.
struct SimInputImmersiveView: View {
    var body: some View {
        RealityView { content in
            let skeleton = BodySkeletonEntity()
            skeleton.worldOffset = [0, 1.5, -1.5]
            content.add(skeleton)

            HandGloveView.addHands(to: content)

            content.add(PinchTargetEntity())

            let floor = ModelEntity(
                mesh: .generatePlane(width: 2, depth: 2),
                materials: [UnlitMaterial(color: .init(white: 0.2, alpha: 0.4))]
            )
            floor.position = [0, 0.02, -1.5]
            content.add(floor)
        }
    }
}
