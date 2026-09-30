import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#endif

public enum FreedesktopTrashError: Error, Equatable, Sendable {
    case itemMissing(String)
    case couldNotCreateTrash(String)
    case couldNotMove(path: String, errno: Int32)
}

/// Moves items to the trash as the freedesktop.org Trash specification
/// describes (the trash GNOME, KDE and every desktop file manager share):
/// the item goes into `<trash>/files/` next to a `<trash>/info/<name>.trashinfo`
/// that records where it came from, so the file manager can restore it.
///
/// Items on the home filesystem use the home trash (`$XDG_DATA_HOME/Trash`,
/// by default `~/.local/share/Trash`); items on another filesystem use that
/// filesystem's `$topdir/.Trash-$uid`, so nothing is copied across devices.
/// Apple platforms use `FileManager.trashItem` instead.
public struct FreedesktopTrash: Sendable {
    public let homeTrash: URL

    public init(homeTrash: URL = FreedesktopTrash.defaultHomeTrash()) {
        self.homeTrash = homeTrash
    }

    public static func defaultHomeTrash(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let dataHome = environment["XDG_DATA_HOME"], dataHome.hasPrefix("/") {
            return URL(fileURLWithPath: dataHome, isDirectory: true).appending(path: "Trash", directoryHint: .isDirectory)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appending(path: ".local/share/Trash", directoryHint: .isDirectory)
    }

    /// Moves `url` to the trash and returns its new location.
    @discardableResult
    public func trashItem(at url: URL, now: Date = Date()) throws -> URL {
        let path = url.standardizedFileURL.path
        guard let itemDevice = Self.device(ofPath: path, followLinks: false) else {
            throw FreedesktopTrashError.itemMissing(path)
        }
        let trash: URL
        let recordedPath: String
        if let homeDevice = Self.device(ofPath: Self.existingAncestor(of: homeTrash.path), followLinks: true),
           homeDevice == itemDevice {
            trash = homeTrash
            recordedPath = path
        } else {
            let topdir = Self.mountTop(of: path, device: itemDevice)
            trash = URL(fileURLWithPath: topdir, isDirectory: true)
                .appending(path: ".Trash-\(getuid())", directoryHint: .isDirectory)
            // Paths in a per-filesystem trash are relative to its top directory.
            let prefix = topdir.hasSuffix("/") ? topdir : topdir + "/"
            recordedPath = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        let files = trash.appending(path: "files", directoryHint: .isDirectory)
        let info = trash.appending(path: "info", directoryHint: .isDirectory)
        do {
            for directory in [trash, files, info] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            throw FreedesktopTrashError.couldNotCreateTrash(trash.path)
        }

        let infoText = """
        [Trash Info]
        Path=\(Self.encode(recordedPath))
        DeletionDate=\(Self.deletionDate(now))

        """
        let baseName = url.lastPathComponent
        for attempt in 0..<10_000 {
            let name = attempt == 0 ? baseName : Self.numbered(baseName, attempt)
            let infoURL = info.appending(path: name + ".trashinfo")
            // Creating the info file exclusively claims the name (the spec's lock).
            guard Self.createExclusively(infoURL.path, contents: Data(infoText.utf8)) else {
                if errno == EEXIST { continue }
                throw FreedesktopTrashError.couldNotCreateTrash(trash.path)
            }
            let target = files.appending(path: name)
            if rename(path, target.path) == 0 {
                return target
            }
            let failure = errno
            try? FileManager.default.removeItem(at: infoURL)
            throw FreedesktopTrashError.couldNotMove(path: path, errno: failure)
        }
        throw FreedesktopTrashError.couldNotCreateTrash(trash.path)
    }

    // MARK: - Helpers

    /// `name.2.ext`-style variant used when `name` is already in the trash.
    static func numbered(_ name: String, _ attempt: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        return ext.isEmpty ? "\(stem).\(attempt + 1)" : "\(stem).\(attempt + 1).\(ext)"
    }

    /// Percent-encodes a path as the spec requires (RFC 2396 path characters kept).
    static func encode(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-_.!~*'()")
        allowed = allowed.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// `YYYY-MM-DDThh:mm:ss` in local time.
    static func deletionDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Creates `path` only if it does not exist yet (`O_EXCL`) and writes
    /// `contents`; false when the name is taken.
    private static func createExclusively(_ path: String, contents: Data) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: contents)
            try handle.close()
            return true
        } catch {
            try? handle.close()
            unlink(path)
            return false
        }
    }

    private static func device(ofPath path: String, followLinks: Bool) -> UInt64? {
        var info = stat()
        let result = followLinks ? stat(path, &info) : lstat(path, &info)
        guard result == 0 else { return nil }
        return UInt64(truncatingIfNeeded: info.st_dev)
    }

    private static func existingAncestor(of path: String) -> String {
        var current = path
        while !FileManager.default.fileExists(atPath: current), current != "/" {
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { return "/" }
        }
        return current
    }

    /// The highest directory above `path` on the same device: its mount point.
    private static func mountTop(of path: String, device: UInt64) -> String {
        var top = (path as NSString).deletingLastPathComponent
        while top != "/" {
            let parent = (top as NSString).deletingLastPathComponent
            guard Self.device(ofPath: parent, followLinks: true) == device else { break }
            top = parent
        }
        return top.isEmpty ? "/" : top
    }
}
