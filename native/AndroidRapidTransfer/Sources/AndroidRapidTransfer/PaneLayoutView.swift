import AndroidRapidTransferCore
import SwiftUI

struct PaneLayoutView: View {
    let localModel: LocalBrowserViewModel
    let connectionController: DeviceConnectionController
    let transferModel: TransferViewModel
    let settings: AppSettings
    let focusCoordinator: PaneFocusCoordinator
    let onboarding: OnboardingCoordinator

    var body: some View {
        if settings.showLocalPane {
            HSplitView {
                if settings.localPaneOnLeft {
                    LocalPaneView(
                        model: localModel,
                        transferModel: transferModel,
                        settings: settings,
                        focusCoordinator: focusCoordinator
                    )
                    .frame(minWidth: 400)
                    DevicePaneView(
                        controller: connectionController,
                        transferModel: transferModel,
                        settings: settings,
                        focusCoordinator: focusCoordinator,
                        onboarding: onboarding
                    )
                    .frame(minWidth: 400)
                } else {
                    DevicePaneView(
                        controller: connectionController,
                        transferModel: transferModel,
                        settings: settings,
                        focusCoordinator: focusCoordinator,
                        onboarding: onboarding
                    )
                    .frame(minWidth: 400)
                    LocalPaneView(
                        model: localModel,
                        transferModel: transferModel,
                        settings: settings,
                        focusCoordinator: focusCoordinator
                    )
                    .frame(minWidth: 400)
                }
            }
        } else {
            DevicePaneView(
                controller: connectionController,
                transferModel: transferModel,
                settings: settings,
                focusCoordinator: focusCoordinator,
                onboarding: onboarding
            )
        }
    }
}
