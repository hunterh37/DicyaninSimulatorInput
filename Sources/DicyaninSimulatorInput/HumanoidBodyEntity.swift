import Foundation
import simd
import DicyaninLabsMoCapRecording

#if os(visionOS)
import ARKit
import RealityKit
import DicyaninHumanoidMesh
import DicyaninMockHandTracking

/// 3D humanoid body driven by ``SimulatorInputController``: the procedural
/// DicyaninHumanoidMesh figure posed each frame from the received body joints,
/// plus full 21-joint hands (from `MockHandTrackingController`) attached at the
/// figure's wrists, mirroring the tracked person's movement.
///
/// ECS-driven like ``BodySkeletonEntity``: a `HumanoidBodySystem` retargets the
/// head-relative joint positions onto the humanoid's joint pivots per frame.
/// Entities are reused, never recreated.
public final class HumanoidBodyEntity: Entity {
    /// Offset applied to the received head-relative joints. Head-relative y=0
    /// is eye level; same default as ``BodySkeletonEntity``.
    public var worldOffset: SIMD3<Float> = [0, 1.5, -1.5]

    /// Swap left/right so the figure moves like a mirror image of the tracked
    /// person (the natural reading when facing the capture camera).
    public var mirrored = true

    /// Scale applied to the wrist-relative finger joint offsets.
    public var handScale: Float = 1.0

    fileprivate let humanoid: Entity
    fileprivate var handRigs: [HumanoidHandRig] = []

    public required init() {
        humanoid = HumanoidEntity.create(pose: .aPose)
        super.init()
        HumanoidBodySystem.registerIfNeeded()
        components.set(HumanoidBodyComponent())
        addChild(humanoid)

        for chirality in [HumanoidHandRig.Chirality.left, .right] {
            let rig = HumanoidHandRig(chirality: chirality)
            handRigs.append(rig)
            addChild(rig.container)
        }
    }
}

/// Marker component so the system can query humanoid roots.
public struct HumanoidBodyComponent: Component {}

/// One mini hand skeleton (joint spheres) placed at a humanoid wrist,
/// articulated wrist-relative from the mock hand-tracking joints.
@MainActor
final class HumanoidHandRig {
    enum Chirality { case left, right }

    let chirality: Chirality
    let container = Entity()
    private var jointSpheres: [HandSkeleton.JointName: ModelEntity] = [:]

    private static let sphereMesh = MeshResource.generateSphere(radius: 0.007)
    private static let material = UnlitMaterial(color: .cyan)

    init(chirality: Chirality) {
        self.chirality = chirality
        container.isEnabled = false
    }

    /// Position the container at the given point (in humanoid-root space) and
    /// lay out the finger joints wrist-relative from the received transforms,
    /// preserving the hand's real-world orientation and articulation.
    func apply(_ joints: [HandSkeleton.JointName: simd_float4x4],
               wristAt position: SIMD3<Float>,
               scale: Float) {
        guard let wrist = joints[.wrist] else {
            container.isEnabled = false
            return
        }
        container.isEnabled = true
        container.position = position
        let wristInverse = wrist.inverse
        for (name, transform) in joints {
            let sphere = jointSpheres[name] ?? {
                let s = ModelEntity(mesh: Self.sphereMesh, materials: [Self.material])
                jointSpheres[name] = s
                container.addChild(s)
                return s
            }()
            let local = wristInverse * transform
            sphere.position = SIMD3(local.columns.3.x, local.columns.3.y, local.columns.3.z) * scale
        }
    }

    func hide() {
        container.isEnabled = false
    }
}

/// Retargets every ``HumanoidBodyEntity`` each frame: root placed at the hips,
/// torso/arm/leg joint pivots rotated so each bone points along the received
/// bone direction, hands articulated from the mock controller's joints.
public struct HumanoidBodySystem: System {
    @MainActor private static var registered = false

    @MainActor static func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        HumanoidBodyComponent.registerComponent()
        HumanoidBodySystem.registerSystem()
    }

    private static let query = EntityQuery(where: .has(HumanoidBodyComponent.self))

    // Rest-pose geometry of the humanoid (see HumanoidEntity/HumanoidMesh):
    // hips (thigh pivots) sit at y = 0.676 + 0.224.
    private static let hipHeight: Float = 0.9
    // Forearm pivot to wrist: segment length below the elbow joint.
    private static let forearmLength: Float = 0.372

    public init(scene: RealityKit.Scene) {}

    public func update(context: SceneUpdateContext) {
        let controller = SimulatorInputController.shared
        let joints = controller.bodyJoints
        let hands = MockHandTrackingController.shared
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let root = entity as? HumanoidBodyEntity, root.isEnabled else { continue }
            apply(joints, hands: hands, to: root)
        }
    }

    @MainActor
    private func apply(_ joints: [ARKitBodyJoint: SIMD3<Float>],
                       hands: MockHandTrackingController,
                       to root: HumanoidBodyEntity) {
        guard let hips = joints[.hips], Self.isValid(hips) else {
            for rig in root.handRigs { rig.hide() }
            return
        }
        let humanoid = root.humanoid
        let targetPosition = hips + root.worldOffset - [0, Self.hipHeight, 0]
            + SimulatorInputController.shared.bodyRootOffset
        humanoid.position = simd_mix(humanoid.position, targetPosition,
                                     SIMD3<Float>(repeating: Self.smoothing))

        // Data joints per geometry side. mirrored swaps the person's sides.
        let leftArmData: (ARKitBodyJoint, ARKitBodyJoint) =
            root.mirrored ? (.rightArm, .rightForearm) : (.leftArm, .leftForearm)
        let leftForearmData: (ARKitBodyJoint, ARKitBodyJoint) =
            root.mirrored ? (.rightForearm, .rightHand) : (.leftForearm, .leftHand)
        let rightArmData: (ARKitBodyJoint, ARKitBodyJoint) =
            root.mirrored ? (.leftArm, .leftForearm) : (.rightArm, .rightForearm)
        let rightForearmData: (ARKitBodyJoint, ARKitBodyJoint) =
            root.mirrored ? (.leftForearm, .leftHand) : (.rightForearm, .rightHand)
        let leftThighData: (ARKitBodyJoint, ARKitBodyJoint) =
            root.mirrored ? (.rightUpLeg, .rightLeg) : (.leftUpLeg, .leftLeg)
        let leftShinData: (ARKitBodyJoint, ARKitBodyJoint) =
            root.mirrored ? (.rightLeg, .rightFoot) : (.leftLeg, .leftFoot)
        let rightThighData: (ARKitBodyJoint, ARKitBodyJoint) =
            root.mirrored ? (.leftUpLeg, .leftLeg) : (.rightUpLeg, .rightLeg)
        let rightShinData: (ARKitBodyJoint, ARKitBodyJoint) =
            root.mirrored ? (.leftLeg, .leftFoot) : (.rightLeg, .rightFoot)

        // Torso: hips up to the base of the neck. Rest direction is +Y.
        let torsoWorld = orient(joint: "joint_torso", in: humanoid,
                                from: joints[.hips], to: joints[.neck1] ?? joints[.head],
                                rest: [0, 1, 0], parentWorld: simd_quatf())

        // Arms: two-segment chains under the torso pivot. Rest direction -Y.
        for (upper, lower, armData, forearmData) in [
            ("joint_upperArm_L", "joint_forearm_L", leftArmData, leftForearmData),
            ("joint_upperArm_R", "joint_forearm_R", rightArmData, rightForearmData)
        ] {
            let upperWorld = orient(joint: upper, in: humanoid,
                                    from: joints[armData.0], to: joints[armData.1],
                                    rest: [0, -1, 0], parentWorld: torsoWorld)
            _ = orient(joint: lower, in: humanoid,
                       from: joints[forearmData.0], to: joints[forearmData.1],
                       rest: [0, -1, 0], parentWorld: upperWorld)
        }

        // Legs: two-segment chains under the root. Rest direction -Y.
        for (upper, lower, thighData, shinData) in [
            ("joint_thigh_L", "joint_shin_L", leftThighData, leftShinData),
            ("joint_thigh_R", "joint_shin_R", rightThighData, rightShinData)
        ] {
            let thighWorld = orient(joint: upper, in: humanoid,
                                    from: joints[thighData.0], to: joints[thighData.1],
                                    rest: [0, -1, 0], parentWorld: simd_quatf())
            _ = orient(joint: lower, in: humanoid,
                       from: joints[shinData.0], to: joints[shinData.1],
                       rest: [0, -1, 0], parentWorld: thighWorld)
        }

        // Hands: full received joint skeletons pinned to the humanoid wrists.
        for rig in root.handRigs {
            let forearmName = rig.chirality == .left ? "joint_forearm_L" : "joint_forearm_R"
            let dataIsLeft = root.mirrored ? (rig.chirality == .right) : (rig.chirality == .left)
            let handJoints = dataIsLeft ? hands.leftHandJoints : hands.rightHandJoints
            guard let forearm = humanoid.findEntity(named: forearmName) else {
                rig.hide()
                continue
            }
            let wrist = forearm.convert(position: [0, -Self.forearmLength, 0], to: root)
            rig.apply(handJoints, wristAt: wrist, scale: root.handScale)
        }
    }

    /// Per-frame slerp/lerp factor toward the target pose.
    private static let smoothing: Float = 0.35

    /// A body joint is considered tracked when it isn't the zero vector the
    /// mappers emit for undetected joints. (The head is the frame origin, but
    /// it is never used as a bone endpoint here.)
    private static func isValid(_ p: SIMD3<Float>) -> Bool {
        simd_length_squared(p) > 1e-6
    }

    /// Rotates one joint pivot so its bone (rest direction `rest`, expressed in
    /// the parent joint's frame) points along the received `from -> to`
    /// direction. The target is computed as a minimal-twist rotation inside the
    /// parent frame, so a bent elbow or knee hinges naturally instead of
    /// twisting the segment. Missing or untracked endpoints ease the joint back
    /// to its rest orientation (straight down for limbs), and every update is
    /// slerp-smoothed so tracking dropouts never snap the figure.
    /// Returns the joint's accumulated world rotation for child pivots.
    @MainActor
    @discardableResult
    private func orient(joint name: String,
                        in humanoid: Entity,
                        from: SIMD3<Float>?,
                        to: SIMD3<Float>?,
                        rest: SIMD3<Float>,
                        parentWorld: simd_quatf) -> simd_quatf {
        guard let joint = humanoid.findEntity(named: name) else { return parentWorld }

        var targetLocal = simd_quatf(angle: 0, axis: [0, 1, 0])  // rest pose
        if let from, let to, Self.isValid(from), Self.isValid(to) {
            let delta = to - from
            let length = simd_length(delta)
            if length > 0.001 {
                // Express the bone direction in the parent joint's frame and
                // align with a minimal arc there: no world-space twist leaks
                // into the segment when the chain above it rotates.
                let dirInParent = parentWorld.inverse.act(delta / length)
                targetLocal = Self.quatAligning(rest, dirInParent)
            }
        }
        joint.orientation = simd_slerp(joint.orientation, targetLocal, Self.smoothing)
        return parentWorld * joint.orientation
    }

    /// Minimal-arc quaternion rotating unit vector `a` onto unit vector `b`.
    private static func quatAligning(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> simd_quatf {
        let dot = simd_clamp(simd_dot(a, b), -1, 1)
        let axis = simd_cross(a, b)
        let axisLength = simd_length(axis)
        if axisLength > 0.0001 {
            return simd_quatf(angle: acos(dot), axis: axis / axisLength)
        }
        return dot > 0
            ? simd_quatf(angle: 0, axis: [0, 1, 0])
            : simd_quatf(angle: .pi, axis: [1, 0, 0])
    }
}
#endif
