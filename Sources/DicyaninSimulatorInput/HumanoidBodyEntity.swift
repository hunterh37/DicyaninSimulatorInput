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

    /// Turn the figure to match the tracked person's body yaw (from
    /// ``SimulatorInputController/bodyYaw``). Off keeps it facing the viewer.
    public var tracksFacing = true

    /// Sign of the applied yaw. Flip if the figure turns opposite the person.
    public var facingSign: Float = 1

    fileprivate let humanoid: Entity
    fileprivate var handRigs: [HumanoidHandRig] = []

    public required init() {
        humanoid = HumanoidEntity.create(pose: .aPose)
        // The mesh is authored facing -z (its left arm at local -x). The
        // received person frame faces +z (toward the viewer), so turn the
        // figure around to face the viewer like a mirror. The retarget system
        // folds this root rotation into every bone alignment.
        humanoid.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
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
        // Offsets stay in the received (mirror) space so the hand keeps its
        // real-world orientation; rotating into the wrist frame would render
        // every hand in one canonical pose regardless of how it is turned.
        let wristPosition = SIMD3(wrist.columns.3.x, wrist.columns.3.y, wrist.columns.3.z)
        for (name, transform) in joints {
            let sphere = jointSpheres[name] ?? {
                let s = ModelEntity(mesh: Self.sphereMesh, materials: [Self.material])
                jointSpheres[name] = s
                container.addChild(s)
                return s
            }()
            let p = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            sphere.position = (p - wristPosition) * scale
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

        // Body yaw: base flip (mesh authored facing -z, turned to face the
        // viewer) plus the tracked person's turn. Mirroring reflects the turn,
        // so the yaw negates when the figure is mirrored. Slerp-smoothed on top
        // of the estimator's own smoothing so heading never snaps.
        let yaw = root.tracksFacing
            ? SimulatorInputController.shared.bodyYaw * root.facingSign * (root.mirrored ? -1 : 1)
            : 0
        let targetOrientation = simd_quatf(angle: .pi + yaw, axis: [0, 1, 0])
        humanoid.orientation = simd_slerp(humanoid.orientation, targetOrientation, Self.smoothing)

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

        // Root of every chain is the humanoid's own rotation (it faces the
        // viewer), so received directions get expressed in mesh space.
        let rootWorld = humanoid.orientation

        // Torso: hips up to the base of the neck. Rest direction is +Y.
        let torsoWorld = orient(joint: "joint_torso", in: humanoid,
                                from: joints[.hips], to: joints[.neck1] ?? joints[.head],
                                rest: [0, 1, 0], parentWorld: rootWorld)

        // Arms: two-bone IK per arm. The chain starts at the mesh's own
        // shoulder pivot and reaches for the received wrist offset scaled to
        // the mesh arm length, with the bend plane taken from the received
        // elbow. Direction-only retargeting let proportion mismatches between
        // the tracked person and the mesh push the elbow into the torso; IK
        // keeps the elbow on the mesh's own reachable sphere. Falls back to
        // direction alignment when the wrist is untracked.
        for (upper, lower, armData, forearmData) in [
            ("joint_upperArm_L", "joint_forearm_L", leftArmData, leftForearmData),
            ("joint_upperArm_R", "joint_forearm_R", rightArmData, rightForearmData)
        ] {
            if solveArmIK(upper: upper, lower: lower, in: humanoid,
                          shoulder: joints[armData.0], elbow: joints[armData.1],
                          wrist: joints[forearmData.1], parentWorld: torsoWorld) {
                continue
            }
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
                                    rest: [0, -1, 0], parentWorld: rootWorld)
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

    /// Analytic two-bone IK for one arm, solved in the torso joint's frame.
    /// Shoulder/elbow/wrist are received head-relative positions; only their
    /// relative offsets are used, scaled so the received arm span matches the
    /// mesh arm span. Returns false when inputs are missing or degenerate so
    /// the caller can fall back to direction alignment.
    @MainActor
    private func solveArmIK(upper upperName: String, lower lowerName: String,
                            in humanoid: Entity,
                            shoulder: SIMD3<Float>?, elbow: SIMD3<Float>?,
                            wrist: SIMD3<Float>?,
                            parentWorld: simd_quatf) -> Bool {
        guard let shoulder, let elbow, let wrist,
              Self.isValid(shoulder), Self.isValid(elbow), Self.isValid(wrist),
              let upperJoint = humanoid.findEntity(named: upperName),
              let lowerJoint = humanoid.findEntity(named: lowerName) else { return false }

        let l1 = simd_length(lowerJoint.position)       // shoulder pivot -> elbow pivot
        let l2 = Self.forearmLength                     // elbow pivot -> wrist
        let dataUpper = simd_length(elbow - shoulder)
        let dataLower = simd_length(wrist - elbow)
        guard l1 > 0.01, dataUpper > 0.02, dataLower > 0.02 else { return false }
        let scale = (l1 + l2) / (dataUpper + dataLower)

        // Wrist target and elbow hint in the torso frame, shoulder-relative.
        let target = parentWorld.inverse.act((wrist - shoulder) * scale)
        let elbowHint = parentWorld.inverse.act((elbow - shoulder) * scale)
        let rawDistance = simd_length(target)
        guard rawDistance > 0.001 else { return false }
        let targetDir = target / rawDistance
        let distance = simd_clamp(rawDistance, abs(l1 - l2) + 0.001, l1 + l2 - 0.001)

        // Bend plane: component of the received elbow off the shoulder-wrist
        // line. Near-straight arms fall back to bending backward (mesh faces
        // -z, so the elbow points toward +z in the torso frame).
        var bend = elbowHint - simd_dot(elbowHint, targetDir) * targetDir
        if simd_length_squared(bend) < 1e-6 {
            let fallback = SIMD3<Float>(0, 0, 1)
            bend = fallback - simd_dot(fallback, targetDir) * targetDir
        }
        guard simd_length_squared(bend) > 1e-8 else { return false }
        let bendDir = simd_normalize(bend)

        // Law of cosines: elbow at distance `along` toward the target, lifted
        // `lift` into the bend plane.
        let along = simd_clamp((distance * distance + l1 * l1 - l2 * l2) / (2 * distance), -l1, l1)
        let lift = max(0, l1 * l1 - along * along).squareRoot()
        let elbowPos = targetDir * along + bendDir * lift

        let upperDir = simd_normalize(elbowPos)
        let lowerDirInTorso = simd_normalize(targetDir * distance - elbowPos)

        let upperTarget = Self.quatAligning([0, -1, 0], upperDir)
        upperJoint.orientation = simd_slerp(upperJoint.orientation, upperTarget, Self.smoothing)

        let upperWorld = parentWorld * upperJoint.orientation
        let lowerDirInUpper = upperWorld.inverse.act(parentWorld.act(lowerDirInTorso))
        let lowerTarget = Self.quatAligning([0, -1, 0], lowerDirInUpper)
        lowerJoint.orientation = simd_slerp(lowerJoint.orientation, lowerTarget, Self.smoothing)
        return true
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
