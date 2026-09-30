import Foundation
import XCTest
@testable import AndroidRapidTransferCore

/// The platform-neutral replacements Core uses where Apple's frameworks are
/// missing (Linux): the stored zip writer, the freedesktop trash, XDG user
/// folders and the in-memory log. They compile everywhere, so they are tested
/// everywhere.
final class PlatformServicesTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "PlatformServicesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Stored zip

    func testStoredZipHasEveryEntryWithMatchingCentralDirectory() throws {
        let folder = temporaryDirectory.appending(path: "Report", directoryHint: .isDirectory)
        let nested = folder.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appending(path: "README.txt"))
        try Data("line 1\nline 2\n".utf8).write(to: nested.appending(path: "app.log"))
        try Data().write(to: folder.appending(path: "empty.txt"))
        let zip = temporaryDirectory.appending(path: "out.zip")

        try StoredZipArchiver().archive(directory: folder, to: zip)

        let entries = try ZipReader(data: Data(contentsOf: zip)).entries()
        XCTAssertEqual(
            entries.map(\.name),
            ["Report/", "Report/README.txt", "Report/empty.txt", "Report/logs/", "Report/logs/app.log"]
        )
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["Report/README.txt"]?.data, Data("hello".utf8))
        XCTAssertEqual(byName["Report/logs/app.log"]?.data, Data("line 1\nline 2\n".utf8))
        XCTAssertEqual(byName["Report/empty.txt"]?.data, Data())
        XCTAssertEqual(byName["Report/logs/"]?.data, Data())
    }

    func testStoredZipCRCMatchesTheStandardCheckValue() {
        // The CRC-32 check value from the zip specification's polynomial.
        XCTAssertEqual(StoredZipArchiver.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(StoredZipArchiver.crc32(Data()), 0)
    }

    func testStoredZipRefusesAFile() throws {
        let file = temporaryDirectory.appending(path: "file.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(
            try StoredZipArchiver().archive(directory: file, to: temporaryDirectory.appending(path: "out.zip"))
        )
    }

    // MARK: - Freedesktop trash

    func testTrashMovesTheItemAndRecordsWhereItCameFrom() throws {
        let trash = temporaryDirectory.appending(path: "Trash", directoryHint: .isDirectory)
        let source = temporaryDirectory.appending(path: "My Photo #1.jpg")
        try Data("jpeg".utf8).write(to: source)
        let deletion = Date(timeIntervalSince1970: 1_790_000_000)

        let trashed = try FreedesktopTrash(homeTrash: trash).trashItem(at: source, now: deletion)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(trashed.path, trash.appending(path: "files/My Photo #1.jpg").path)
        XCTAssertEqual(try Data(contentsOf: trashed), Data("jpeg".utf8))
        let info = try String(
            contentsOf: trash.appending(path: "info/My Photo #1.jpg.trashinfo"),
            encoding: .utf8
        )
        let lines = info.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "[Trash Info]")
        XCTAssertEqual(
            lines.first { $0.hasPrefix("Path=") },
            "Path=" + FreedesktopTrash.encode(source.standardizedFileURL.path)
        )
        XCTAssertTrue(info.contains("%20Photo%20%231.jpg"), info)
        XCTAssertEqual(lines.first { $0.hasPrefix("DeletionDate=") }, "DeletionDate=\(FreedesktopTrash.deletionDate(deletion))")
    }

    func testTrashKeepsBothItemsWhenTheNameIsAlreadyTrashed() throws {
        let trash = temporaryDirectory.appending(path: "Trash", directoryHint: .isDirectory)
        let service = FreedesktopTrash(homeTrash: trash)
        let folder = temporaryDirectory.appending(path: "Album", directoryHint: .isDirectory)
        for content in ["first", "second"] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: folder.appending(path: "a.txt"))
            try service.trashItem(at: folder)
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: trash.appending(path: "files").path).sorted()
        let infos = try FileManager.default.contentsOfDirectory(atPath: trash.appending(path: "info").path).sorted()
        XCTAssertEqual(files, ["Album", "Album.2"])
        XCTAssertEqual(infos, ["Album.2.trashinfo", "Album.trashinfo"])
        XCTAssertEqual(
            try String(contentsOf: trash.appending(path: "files/Album.2/a.txt"), encoding: .utf8),
            "second"
        )
    }

    func testTrashNumbersNamesBeforeTheExtension() {
        XCTAssertEqual(FreedesktopTrash.numbered("photo.jpg", 1), "photo.2.jpg")
        XCTAssertEqual(FreedesktopTrash.numbered("Album", 2), "Album.3")
    }

    func testTrashReportsAMissingItem() {
        let service = FreedesktopTrash(homeTrash: temporaryDirectory.appending(path: "Trash"))
        XCTAssertThrowsError(try service.trashItem(at: temporaryDirectory.appending(path: "missing"))) { error in
            guard case FreedesktopTrashError.itemMissing = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testDefaultHomeTrashFollowsXDGDataHome() {
        XCTAssertEqual(
            FreedesktopTrash.defaultHomeTrash(environment: ["XDG_DATA_HOME": "/data", "HOME": "/home/u"]).path,
            "/data/Trash"
        )
        XCTAssertEqual(
            FreedesktopTrash.defaultHomeTrash(environment: ["HOME": "/home/u"]).path,
            "/home/u/.local/share/Trash"
        )
    }

    // MARK: - XDG user folders

    func testUserDirectoriesReadTheUserDirsFile() {
        let file = """
        # This file is written by xdg-user-dirs-update
        XDG_DESKTOP_DIR="$HOME/Schreibtisch"
        XDG_DOWNLOAD_DIR="/srv/downloads"
        """
        let directories = XDGUserDirectories(environment: ["HOME": "/home/u"]) { url in
            url.path == "/home/u/.config/user-dirs.dirs" ? file : nil
        }
        XCTAssertEqual(directories.home.path, "/home/u")
        XCTAssertEqual(directories.desktop.path, "/home/u/Schreibtisch")
        XCTAssertEqual(directories.downloads.path, "/srv/downloads")
    }

    func testUserDirectoriesFallBackToEnglishFolders() {
        let disabled = "XDG_DESKTOP_DIR=\"$HOME/\"\n"
        let directories = XDGUserDirectories(environment: ["HOME": "/home/u", "XDG_CONFIG_HOME": "/cfg"]) { url in
            url.path == "/cfg/user-dirs.dirs" ? disabled : nil
        }
        XCTAssertEqual(directories.desktop.path, "/home/u/Desktop")
        XCTAssertEqual(directories.downloads.path, "/home/u/Downloads")
    }

    func testRemovableMediaRootPrefersTheUserMountFolder() {
        XCTAssertEqual(
            XDGUserDirectories.removableMediaRoot(environment: ["USER": "u"]) { $0 == "/media/u" },
            "/media/u"
        )
        XCTAssertEqual(
            XDGUserDirectories.removableMediaRoot(environment: ["USER": "u"]) { $0 == "/run/media/u" },
            "/run/media/u"
        )
        XCTAssertEqual(XDGUserDirectories.removableMediaRoot(environment: [:]) { _ in true }, "/media")
    }

    // MARK: - Name order

    /// Table comparators order names as Finder does on every platform:
    /// case-insensitively and with numbers by value, in both directions.
    func testNameComparatorsUseFinderOrder() {
        let entries = ["file10.txt", "Zeta.txt", "alpha.txt", "file2.txt"].map { name in
            BrowserEntry(id: "/\(name)", name: name, size: 1, modified: nil, isDirectory: false, location: "/\(name)")
        }
        XCTAssertEqual(
            BrowserEntrySorter.sorted(entries, using: [KeyPathComparator(\BrowserEntry.name)]).map(\.name),
            ["alpha.txt", "file2.txt", "file10.txt", "Zeta.txt"]
        )
        XCTAssertEqual(
            BrowserEntrySorter.sorted(entries, using: [KeyPathComparator(\BrowserEntry.name, order: .reverse)])
                .map(\.name),
            ["Zeta.txt", "file10.txt", "file2.txt", "alpha.txt"]
        )
    }

    // MARK: - In-memory log

    func testLogBufferKeepsTheNewestEntriesInOrder() {
        let buffer = CoreLogBuffer(capacity: 3, echoesToStandardError: false)
        for index in 1...5 {
            buffer.append(.init(date: Date(), level: .info, subsystem: "s", category: "c", message: "m\(index)"))
        }
        XCTAssertEqual(buffer.entries().map(\.message), ["m3", "m4", "m5"])
        buffer.removeAll()
        XCTAssertEqual(buffer.entries(), [])
    }

    #if !canImport(OSLog)
    func testCoreLoggerFeedsTheBugReportLog() throws {
        let buffer = CoreLogBuffer.shared
        let echoed = buffer.echoesToStandardError
        buffer.echoesToStandardError = false
        defer { buffer.echoesToStandardError = echoed }
        let marker = UUID().uuidString
        Logger(subsystem: AppIdentity.bundleIdentifier, category: "Test")
            .error("Failed at \(marker, privacy: .public)")
        Logger(subsystem: "someone.else", category: "Test").info("other \(marker)")

        let text = try BugReportAppLog.collect()
        XCTAssertTrue(text.contains("[error] Test: Failed at \(marker)"), text)
        XCTAssertFalse(text.contains("other \(marker)"), text)
    }
    #endif
}

/// Reads a stored-only zip through its central directory, checking each local
/// header and CRC on the way — enough to prove another tool can list and
/// extract it.
private struct ZipReader {
    struct Entry {
        let name: String
        let data: Data
    }

    let data: Data

    func entries() throws -> [Entry] {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }

        let end = bytes.count - 22
        XCTAssertGreaterThanOrEqual(end, 0)
        XCTAssertEqual(u32(end), 0x0605_4B50, "No end of central directory record")
        let count = u16(end + 10)
        XCTAssertEqual(u16(end + 8), count)
        var offset = u32(end + 16)
        XCTAssertEqual(offset + u32(end + 12), end, "Central directory size and offset disagree")

        var result: [Entry] = []
        for _ in 0..<count {
            XCTAssertEqual(u32(offset), 0x0201_4B50, "Bad central directory header")
            XCTAssertEqual(u16(offset + 10), 0, "Entries must be stored")
            let crc = UInt32(u32(offset + 16))
            let size = u32(offset + 20)
            XCTAssertEqual(size, u32(offset + 24))
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)

            XCTAssertEqual(u32(local), 0x0403_4B50, "Bad local header for \(name)")
            XCTAssertEqual(UInt32(u32(local + 14)), crc)
            XCTAssertEqual(u16(local + 26), nameLength)
            let dataStart = local + 30 + nameLength + u16(local + 28)
            let content = Data(bytes[dataStart..<(dataStart + size)])
            XCTAssertEqual(StoredZipArchiver.crc32(content), crc, "CRC mismatch for \(name)")
            result.append(Entry(name: name, data: content))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return result
    }
}
