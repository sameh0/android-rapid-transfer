import Foundation

public struct FileDeletionConfirmation: Equatable, Sendable {
    public enum Destination: Equatable, Sendable {
        case trash
        case device
    }

    public let destination: Destination
    public let names: [String]

    public init(destination: Destination, names: [String]) {
        self.destination = destination
        self.names = names
    }

    public var title: String {
        switch destination {
        case .trash:
            names.count == 1 ? "Move Item to Trash?" : "Move \(names.count) Items to Trash?"
        case .device:
            names.count == 1 ? "Permanently Delete Item?" : "Permanently Delete \(names.count) Items?"
        }
    }

    public var message: String {
        let consequence = switch destination {
        case .trash:
            "The selected item\(names.count == 1 ? "" : "s") will be moved to the Trash."
        case .device:
            "Deleting from the phone is permanent and cannot be undone."
        }
        return consequence + "\n\n" + displayedNames.joined(separator: "\n")
    }

    private var displayedNames: [String] {
        let visibleNames = Array(names.prefix(5))
        let remainingCount = names.count - visibleNames.count
        guard remainingCount > 0 else { return visibleNames }
        return visibleNames + ["…and \(remainingCount) more"]
    }
}
