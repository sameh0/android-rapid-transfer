import AndroidRapidTransferCore
import SwiftUI

struct ContentView: View {
    let localModel: LocalBrowserViewModel
    let connectionController: DeviceConnectionController
    @Bindable var transferModel: TransferViewModel
    @Bindable var settings: AppSettings
    let focusCoordinator: PaneFocusCoordinator
    @Bindable var onboarding: OnboardingCoordinator

    var body: some View {
        VStack(spacing: 0) {
            PaneLayoutView(
                localModel: localModel,
                connectionController: connectionController,
                transferModel: transferModel,
                settings: settings,
                focusCoordinator: focusCoordinator,
                onboarding: onboarding
            )
            if transferModel.isPanelVisible {
                VStack(spacing: 0) {
                    Divider()
                    TransferPanelView(model: transferModel)
                }
                // Slides up from the window's bottom edge when the first copy
                // starts and back down when it is dismissed.
                .motionTransition(Motion.panelSlide)
            }
        }
        .motion(Motion.gentle, value: transferModel.isPanelVisible)
        .motionLiveness()
        .task(id: connectionController.transferSessionID) {
            guard let queue = connectionController.transferQueue,
                  let deviceModel = connectionController.deviceModel else {
                transferModel.detach()
                return
            }
            transferModel.attach(queue: queue, deviceModel: deviceModel)
        }
        .task {
            presentOnboardingIfNeeded()
            focusCoordinator.ensureValidFocus(showLocalPane: settings.showLocalPane)
            await connectionController.paneAppeared(hotplugEnabled: settings.enableUsbHotplug)
        }
        .onDisappear {
            // Closing the last window releases the phone; open transfers keep it.
            connectionController.paneDisappeared(
                hasActiveTransfers: transferModel.hasActiveTransfers
            )
        }
        .onAppear {
            updateDockProgress(transferModel.overallProgress)
        }
        /// Key off rows because overallProgress can short-circuit on @ObservationIgnored
        /// state and register no observation dependency.
        .onChange(of: transferModel.rows) { _, _ in
            updateDockProgress(transferModel.overallProgress)
        }
        .onChange(of: settings.enableUsbHotplug) { _, enabled in
            Task { await connectionController.setUsbHotplugEnabled(enabled) }
        }
        .onChange(of: settings.localViewMode) { _, viewMode in
            localModel.viewMode = viewMode
        }
        .onChange(of: settings.localShowsHiddenFiles) { _, showsHiddenFiles in
            Task { await localModel.setShowsHiddenFiles(showsHiddenFiles) }
        }
        .onChange(of: settings.deviceViewMode) { _, _ in
            updateDevicePreferences()
        }
        .onChange(of: settings.deviceShowsHiddenFiles) { _, _ in
            updateDevicePreferences()
        }
        .onChange(of: settings.showDirectoriesFirst) { _, directoriesFirst in
            localModel.setDirectoriesFirst(directoriesFirst)
            updateDevicePreferences()
        }
        .onChange(of: settings.showLocalPane) { _, showLocalPane in
            focusCoordinator.ensureValidFocus(showLocalPane: showLocalPane)
        }
        .sheet(item: $transferModel.conflictPrompt) { prompt in
            FileConflictDialogView(
                prompt: prompt,
                resolve: transferModel.resolveConflict
            )
        }
        .sheet(isPresented: $onboarding.isPresented, onDismiss: onboardingDidDismiss) {
            OnboardingView(coordinator: onboarding)
        }
        .alert("Couldn’t Complete the Operation", isPresented: $transferModel.isShowingOperationError) {
            Button("OK", action: dismissOperationError)
        } message: {
            Text(transferModel.operationErrorMessage ?? "The operation could not be completed.")
        }
    }

    private func dismissOperationError() {
        transferModel.operationErrorMessage = nil
    }

    private func presentOnboardingIfNeeded() {
        guard settings.needsOnboarding() else { return }
        onboarding.show()
    }

    private func updateDockProgress(_ progress: TransferOverallProgress?) {
        DockProgressPresenter.shared.apply(DockProgressState(progress))
    }

    private func onboardingDidDismiss() {
        settings.markOnboardingShown()
    }

    private func updateDevicePreferences() {
        let viewMode = settings.deviceViewMode
        let showsHiddenFiles = settings.deviceShowsHiddenFiles
        let directoriesFirst = settings.showDirectoriesFirst
        Task {
            await connectionController.updateDevicePreferences(
                viewMode: viewMode,
                showsHiddenFiles: showsHiddenFiles,
                directoriesFirst: directoriesFirst
            )
        }
    }
}
