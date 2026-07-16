import Foundation
import simd
import DicyaninLabsMoCapRecording

#if os(visionOS)
import RealityKit

/// Debug wireframe body: one small sphere per received body joint plus thin
/// capsule bones, driven by ``SimulatorInputController``. Add it to an
/// immersive scene to see the iPhone-tracked body live in the simulator.
///
/// ECS-driven: a `BodySkeletonSystem` updates the joint entities each frame
/// from the controller's published joints, so there is no per-frame Combine
/// hop and entities are reused, never recreated.
public final class BodySkeletonEntity: Entity {
    /// Offset applied to the received head-relative joints so the skeleton is
    /// visible in front of the camera. Head-relative y=0 is eye level.
    public var worldOffset: SIMD3<Float> = [0, 1.5, -1.5]

    fileprivate var jointSpheres: [ARKitBodyJoint: ModelEntity] = [:]
    fileprivate var boneEntities: [(child: ARKitBodyJoint, parent: ARKitBodyJoint, entity: ModelEntity)] = []

    public required init() {
        super.init()
        BodySkeletonSystem.registerIfNeeded()
        components.set(BodySkeletonComponent())

        let jointMaterial = UnlitMaterial(color: .cyan)
        let boneMaterial = UnlitMaterial(color: .white)
        let sphereMesh = MeshResource.generateSphere(radius: 0.015)
        let boneMesh = MeshResource.generateBox(size: [0.008, 1, 0.008])

        for joint in ARKitBodyJoint.allCases {
            let sphere = ModelEntity(mesh: sphereMesh, materials: [jointMaterial])
            sphere.isEnabled = false
            jointSpheres[joint] = sphere
            addChild(sphere)

            if let parent = joint.parent {
                let bone = ModelEntity(mesh: boneMesh, materials: [boneMaterial])
                bone.isEnabled = false
                boneEntities.append((joint, parent, bone))
                addChild(bone)
            }
        }
    }
}

/// Marker component so the system can query skeleton roots.
public struct BodySkeletonComponent: Component {}

/// Updates every ``BodySkeletonEntity`` from the controller's latest joints.
public struct BodySkeletonSystem: System {
    @MainActor private static var registered = false

    @MainActor static func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        BodySkeletonComponent.registerComponent()
        BodySkeletonSystem.registerSystem()
    }

    private static let query = EntityQuery(where: .has(BodySkeletonComponent.self))

    public init(scene: RealityKit.Scene) {}

    public func update(context: SceneUpdateContext) {
        let joints = SimulatorInputController.shared.bodyJoints
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let skeleton = entity as? BodySkeletonEntity else { continue }
            apply(joints, to: skeleton)
        }
    }

    private func apply(_ joints: [ARKitBodyJoint: SIMD3<Float>],
                       to skeleton: BodySkeletonEntity) {
        let offset = skeleton.worldOffset
        for (joint, sphere) in skeleton.jointSpheres {
            if let p = joints[joint] {
                sphere.position = p + offset
                sphere.isEnabled = true
            } else {
                sphere.isEnabled = false
            }
        }
        for (child, parent, bone) in skeleton.boneEntities {
            guard let a = joints[child], let b = joints[parent] else {
                bone.isEnabled = false
                continue
            }
            let start = a + offset
            let end = b + offset
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.001 else {
                bone.isEnabled = false
                continue
            }
            bone.position = (start + end) * 0.5
            bone.scale = [1, length, 1]
            let up = SIMD3<Float>(0, 1, 0)
            let dir = delta / length
            let axis = simd_cross(up, dir)
            let axisLength = simd_length(axis)
            if axisLength > 0.0001 {
                bone.orientation = simd_quatf(angle: acos(simd_clamp(simd_dot(up, dir), -1, 1)),
                                              axis: axis / axisLength)
            } else {
                bone.orientation = simd_dot(up, dir) > 0
                    ? simd_quatf(angle: 0, axis: up)
                    : simd_quatf(angle: .pi, axis: [1, 0, 0])
            }
            bone.isEnabled = true
        }
    }
}
#endif
