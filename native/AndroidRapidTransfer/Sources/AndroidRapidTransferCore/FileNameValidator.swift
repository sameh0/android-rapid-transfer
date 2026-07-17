import Foundation

public enum FileNameValidator {
    /// Characters rejected in new-folder and rename names. Several are legal
    /// on APFS but not on the FAT/exFAT storage phones commonly use, so
    /// refusing them up front beats a device-side failure halfway through an
    /// operation.
    public static let forbiddenCharacters: Set<Character> = [
        "/", "\\", "?", "%", "*", ":", "|", "\"", "<", ">",
    ]

    public static func validationMessage(
        for name: String,
        existingNames: [String],
        originalName: String? = nil
    ) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The name cannot be empty."
        }
        if name.contains("/") {
            return "The name cannot contain a slash (/)."
        }
        if name.contains(where: forbiddenCharacters.contains) {
            return "The name cannot contain any of these characters: / \\ ? % * : | \" < >"
        }
        if name == "." || name == ".." {
            return "Choose a different name."
        }

        let isUnchanged = originalName.map {
            name.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        } ?? false
        if !isUnchanged,
           existingNames.contains(where: {
               name.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
           }) {
            return "An item named “\(name)” already exists."
        }
        return nil
    }
}

/// Every resulting destination path is checked for a backslash or colon before
/// any transfer starts, so the whole operation is refused rather than failing
/// part-way.
public enum TransferPathValidator {
    public static let invalidPathMessage =
        "Invalid file name in the path. The \\ and : characters are not allowed."

    /// `destinationDirectory` joined with the last path component of each
    /// source — the top-level items the transfer will create.
    public static func validationMessage(
        destinationDirectory: String,
        sources: [String]
    ) -> String? {
        let names = sources.map { URL(fileURLWithPath: $0).lastPathComponent }
        return validationMessage(destinationDirectory: destinationDirectory, names: names)
    }

    public static func validationMessage(
        destinationDirectory: String,
        names: [String]
    ) -> String? {
        for name in names {
            let path = destinationDirectory.hasSuffix("/")
                ? destinationDirectory + name
                : destinationDirectory + "/" + name
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || path.contains("\\")
                || path.contains(":") {
                return invalidPathMessage
            }
        }
        return nil
    }
}
