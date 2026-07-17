import Foundation

public enum NewFolderNameSuggestion {
    public static func availableName(existingNames: [String]) -> String {
        let baseName = "untitled folder"
        guard contains(baseName, in: existingNames) else { return baseName }

        var suffix = 2
        while contains("\(baseName) \(suffix)", in: existingNames) {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private static func contains(_ candidate: String, in names: [String]) -> Bool {
        names.contains {
            candidate.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}
