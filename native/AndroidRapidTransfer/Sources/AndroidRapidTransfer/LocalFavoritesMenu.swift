import AndroidRapidTransferCore
import SwiftUI

/// The local pane's Favorites: a pull-down in the pane header rather than a
/// sidebar. Picking a favourite is choose-one-and-close, which a menu matches
/// exactly, and a sidebar would take width from a pane that already shares the
/// window with the device pane.
struct LocalFavoritesMenu: View {
    let model: LocalBrowserViewModel

    var body: some View {
        Menu {
            ForEach(model.favorites) { favorite in
                Button {
                    Task { await model.navigate(to: favorite) }
                } label: {
                    if model.isCurrent(favorite) {
                        Label(favorite.label, systemImage: "checkmark")
                    } else {
                        Label(favorite.label, systemImage: favorite.systemImage)
                    }
                }
                .disabled(model.isCurrent(favorite))
            }
        } label: {
            Label("Favorites", systemImage: "star")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isLoading)
        .help("Go to Home, Desktop, Downloads, removable disks or the filesystem root.")
    }
}
