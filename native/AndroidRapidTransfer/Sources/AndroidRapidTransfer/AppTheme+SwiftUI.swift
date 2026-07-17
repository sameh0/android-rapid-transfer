import AndroidRapidTransferCore
import SwiftUI

extension AppTheme {
    var preferredColorScheme: ColorScheme? {
        switch appearanceOverride {
        case .light:
            .light
        case .dark:
            .dark
        case nil:
            nil
        }
    }
}
