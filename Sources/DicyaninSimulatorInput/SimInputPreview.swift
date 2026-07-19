//
//  SimInputPreview.swift
//  DicyaninSimulatorInput
//
//  Cross-platform, representative full-body skeleton. The live debug bodies
//  (BodySkeletonEntity, HumanoidBodyEntity) are gated behind #if os(visionOS)
//  because they depend on ARKit-driven joint streams. This file has no ARKit
//  dependency: it builds a static stick figure in a natural standing A-pose with
//  plain RealityKit so macOS (and any platform) can show a representative
//  skeleton. Proportions mirror the visionOS visuals: sphere joints radius 0.015,
//  thin white box bones (0.008), cyan joints, white bones.
//

import Foundation
import simd
import RealityKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Builds a representative full-body stick skeleton as a plain RealityKit
/// `Entity` hierarchy, usable on any platform (macOS included) with no ARKit
/// dependency.
public enum SimInputPreview {

    private static let jointRadius: Float = 0.015
    private static let boneRadius: Float = 0.008

    // Named joints in a natural standing A-pose (meters, y up), roughly 1.7m tall.
    private static let joints: [String: SIMD3<Float>] = [
        "head":          [0.00, 1.62, 0.0],
        "neck":          [0.00, 1.45, 0.0],
        "spineUpper":    [0.00, 1.38, 0.0],
        "spineMid":      [0.00, 1.20, 0.0],
        "hipsCenter":    [0.00, 1.00, 0.0],

        "leftShoulder":  [-0.18, 1.42, 0.0],
        "leftElbow":     [-0.34, 1.12, 0.0],
        "leftWrist":     [-0.46, 0.86, 0.0],

        "rightShoulder": [0.18, 1.42, 0.0],
        "rightElbow":    [0.34, 1.12, 0.0],
        "rightWrist":    [0.46, 0.86, 0.0],

        "leftHip":       [-0.10, 0.98, 0.0],
        "leftKnee":      [-0.12, 0.55, 0.0],
        "leftAnkle":     [-0.12, 0.10, 0.0],

        "rightHip":      [0.10, 0.98, 0.0],
        "rightKnee":     [0.12, 0.55, 0.0],
        "rightAnkle":    [0.12, 0.10, 0.0]
    ]

    // Bones as (child, parent) pairs, mirroring the ARKit body hierarchy.
    private static let bones: [(String, String)] = [
        ("head", "neck"),
        ("neck", "spineUpper"),
        ("spineUpper", "spineMid"),
        ("spineMid", "hipsCenter"),

        ("leftShoulder", "spineUpper"),
        ("leftElbow", "leftShoulder"),
        ("leftWrist", "leftElbow"),

        ("rightShoulder", "spineUpper"),
        ("rightElbow", "rightShoulder"),
        ("rightWrist", "rightElbow"),

        ("leftHip", "hipsCenter"),
        ("leftKnee", "leftHip"),
        ("leftAnkle", "leftKnee"),

        ("rightHip", "hipsCenter"),
        ("rightKnee", "rightHip"),
        ("rightAnkle", "rightKnee")
    ]

    /// Builds a representative full-body skeleton: a sphere per joint (head,
    /// shoulders, elbows, wrists, hips, knees, ankles, spine) connected by thin
    /// white box bones in a natural standing A-pose. Returns a single root
    /// `Entity`.
    @MainActor
    public static func makeSkeleton() -> Entity {
        let root = Entity()
        root.name = "SimInputPreviewSkeleton"

        let jointMaterial = UnlitMaterial(color: .cyan)
        let boneMaterial = UnlitMaterial(color: .white)

        for (name, position) in joints {
            let sphere = ModelEntity(mesh: .generateSphere(radius: jointRadius), materials: [jointMaterial])
            sphere.name = name
            sphere.position = position
            root.addChild(sphere)
        }

        let boneMesh = MeshResource.generateBox(size: [boneRadius * 2, 1, boneRadius * 2])
        for (child, parent) in bones {
            guard let a = joints[child], let b = joints[parent] else { continue }
            root.addChild(bone(from: a, to: b, mesh: boneMesh, material: boneMaterial))
        }

        return root
    }

    @MainActor
    private static func bone(from start: SIMD3<Float>, to end: SIMD3<Float>,
                             mesh: MeshResource, material: UnlitMaterial) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh, materials: [material])
        let delta = end - start
        let length = simd_length(delta)
        entity.position = (start + end) * 0.5
        if length > 0.0001 {
            entity.scale = [1, length, 1]
            let up = SIMD3<Float>(0, 1, 0)
            let dir = delta / length
            let axis = simd_cross(up, dir)
            let axisLength = simd_length(axis)
            if axisLength > 0.0001 {
                entity.orientation = simd_quatf(angle: acos(simd_clamp(simd_dot(up, dir), -1, 1)),
                                                axis: axis / axisLength)
            } else if simd_dot(up, dir) < 0 {
                entity.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
            }
        }
        return entity
    }
}
