import Foundation
import Combine

/// Shared scene settings: which body representation the immersive scene shows.
@MainActor
final class ViewerSceneSettings: ObservableObject {
    static let shared = ViewerSceneSettings()

    /// False: stick-figure wireframe (`BodySkeletonEntity`).
    /// True: 3D humanoid (`HumanoidBodyEntity`, DicyaninHumanoidMesh).
    @Published var useHumanoid = false

    private init() {}
}
