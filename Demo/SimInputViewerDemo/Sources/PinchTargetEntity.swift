import RealityKit
import UIKit
import simd
import ARKit
import DicyaninMockHandTracking

/// Gameplay-style consumer of the mock hand pipeline: a floating sphere that
/// highlights when the right index fingertip is near it and snaps to the
/// fingertip while pinching. ECS-driven, entities reused every frame.
final class PinchTargetEntity: Entity {
    fileprivate static let restPosition = SIMD3<Float>(0.25, 1.3, -0.7)
    fileprivate let sphere: ModelEntity
    fileprivate let idleMaterial = UnlitMaterial(color: .orange)
    fileprivate let hotMaterial = UnlitMaterial(color: .green)
    fileprivate var isHot = false

    required init() {
        sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.04),
            materials: [UnlitMaterial(color: .orange)]
        )
        super.init()
        PinchTargetSystem.registerIfNeeded()
        components.set(PinchTargetComponent())
        sphere.position = Self.restPosition
        addChild(sphere)
    }
}

struct PinchTargetComponent: Component {}

struct PinchTargetSystem: System {
    @MainActor private static var registered = false

    @MainActor static func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        PinchTargetComponent.registerComponent()
        PinchTargetSystem.registerSystem()
    }

    private static let query = EntityQuery(where: .has(PinchTargetComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let controller = MockHandTrackingController.shared
        guard let tip = controller.rightHandJoints[.indexFingerTip] else { return }
        let tipPosition = SIMD3<Float>(tip.columns.3.x, tip.columns.3.y, tip.columns.3.z)
        let pinching = controller.isPinching

        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let target = entity as? PinchTargetEntity else { continue }
            let near = simd_distance(tipPosition, target.sphere.position) < 0.12
            let hot = near || pinching
            if hot != target.isHot {
                target.isHot = hot
                target.sphere.model?.materials = [hot ? target.hotMaterial : target.idleMaterial]
            }
            target.sphere.position = pinching && near
                ? tipPosition
                : PinchTargetEntity.restPosition
        }
    }
}
