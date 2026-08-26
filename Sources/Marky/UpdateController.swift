import AppKit
import Combine
import Sparkle

/// Owns Sparkle’s updater and keeps its UI visible for a menu-bar (LSUIElement) app.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    private(set) var updaterController: SPUStandardUpdaterController!

    @Published private(set) var canCheckForUpdates = false

    var updater: SPUUpdater { self.updaterController.updater }

    private var canCheckCancellable: AnyCancellable?
    private var sparkleSessionCount = 0

    override init() {
        super.init()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self)
        self.updaterController = controller
        self.canCheckCancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() {
        self.updaterController.checkForUpdates(nil)
    }

    private func beginSparkleUI(activate: Bool = true) {
        self.sparkleSessionCount += 1
        NSApp.setActivationPolicy(.regular)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func endSparkleUI() {
        self.sparkleSessionCount = max(0, self.sparkleSessionCount - 1)
        if self.sparkleSessionCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - SPUStandardUserDriverDelegate

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState)
    {
        let userInitiated = state.userInitiated
        Task { @MainActor in self.beginSparkleUI(activate: userInitiated) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.endSparkleUI() }
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in self.beginSparkleUI() }
    }

    nonisolated func standardUserDriverDidShowModalAlert() {
        Task { @MainActor in self.endSparkleUI() }
    }
}
