#if os(Linux)
import Foundation

/// Finds which processes hold a USB device node open, so a busy phone can be
/// explained ("gvfsd-mtp is using the phone") instead of failing silently.
///
/// It scans `/proc/<pid>/fd/*` for links to `/dev/bus/usb/BBB/DDD`. The fd
/// directories of the same user's processes are readable without root, which
/// covers the desktop daemons (GVFS, KDE's kiod) that usually hold phones.
public enum USBDeviceHolder {
    public struct Process: Equatable, Sendable, CustomStringConvertible {
        public let pid: Int32
        /// `/proc/<pid>/comm`, for example "gvfsd-mtp".
        public let command: String

        public init(pid: Int32, command: String) {
            self.pid = pid
            self.command = command
        }

        /// A human name for well-known holders.
        public var displayName: String {
            switch command {
            case "gvfsd-mtp": return "GNOME Files (gvfsd-mtp)"
            case "gvfsd-gphoto2": return "GNOME Files (gvfsd-gphoto2)"
            case "kiod5", "kiod6": return "KDE's device service (\(command))"
            default: return command
            }
        }

        public var description: String { "\(command) (pid \(pid))" }
    }

    /// Processes other than `excludingPID` that have `/dev/bus/usb/BBB/DDD` open.
    public static func find(bus: Int, dev: Int, procRoot: String = "/proc",
                            excludingPID: Int32 = getpid()) -> [Process] {
        find(nodePath: LinuxUSBAddress.deviceNodePath(bus: bus, device: dev),
             procRoot: procRoot, excludingPID: excludingPID)
    }

    public static func find(nodePath: String, procRoot: String = "/proc",
                            excludingPID: Int32 = getpid()) -> [Process] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: procRoot) else { return [] }
        var result: [Process] = []
        for entry in entries {
            guard let pid = Int32(entry), pid != excludingPID else { continue }
            let fdDir = "\(procRoot)/\(entry)/fd"
            guard let fds = try? FileManager.default.contentsOfDirectory(atPath: fdDir) else { continue }
            let holds = fds.contains { fd in
                (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(fdDir)/\(fd)")) == nodePath
            }
            guard holds else { continue }
            let command = SysfsAttribute.string("\(procRoot)/\(entry)", "comm") ?? "pid \(pid)"
            result.append(Process(pid: pid, command: command))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// Programs that keep the node open for another interface of the phone
    /// (the ADB server claims only the ADB interface), so they are named only
    /// when nothing else holds the node.
    public static let otherInterfaceUsers: Set<String> = ["adb"]

    /// The holders most likely to have claimed the MTP interface.
    public static func likelyMTPHolders(_ holders: [Process]) -> [Process] {
        let filtered = holders.filter { !otherInterfaceUsers.contains($0.command) }
        return filtered.isEmpty ? holders : filtered
    }

    /// "gvfsd-mtp (pid 1234) is using the phone", or nil when no holder is visible.
    public static func busyMessage(_ all: [Process]) -> String? {
        let holders = likelyMTPHolders(all)
        guard !holders.isEmpty else { return nil }
        let names = holders.map { holder in
            holder.displayName == holder.command ? holder.description : "\(holder.displayName), pid \(holder.pid)"
        }
        return "\(names.joined(separator: ", ")) \(holders.count == 1 ? "is" : "are") using the phone"
    }
}

/// Explains why a usbfs node cannot be opened.
public enum USBDeviceNodeDiagnostics {
    /// Owner, group and mode of the node and whether this user may write it,
    /// for example "/dev/bus/usb/003/010 is owned by root:root with mode 0664;
    /// user sameh (uid 1000) has no write access".
    public static func permissionReport(path: String) -> String {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return "\(path): \(String(cString: strerror(errno)))"
        }
        let owner = userName(info.st_uid) ?? String(info.st_uid)
        let group = groupName(info.st_gid) ?? String(info.st_gid)
        let mode = String(format: "%04o", info.st_mode & 0o7777)
        let uid = getuid()
        let me = userName(uid) ?? "uid \(uid)"
        let writable = access(path, R_OK | W_OK) == 0
        var report = "\(path) is owned by \(owner):\(group) with mode \(mode); user \(me) (uid \(uid)) "
        report += writable ? "has read-write access" : "has no read-write access"
        if !writable {
            report += " (no udev \"uaccess\" or group rule grants it to this login session)"
        }
        return report
    }

    static func userName(_ uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }

    static func groupName(_ gid: gid_t) -> String? {
        guard let entry = getgrgid(gid), let name = entry.pointee.gr_name else { return nil }
        return String(cString: name)
    }
}
#endif
