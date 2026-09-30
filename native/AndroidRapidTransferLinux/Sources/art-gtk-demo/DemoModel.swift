import ARTGtk
import CGtk
import Observation

/// One row of the demo file table.
struct FileRow: Sendable {
    let id: Int
    let name: String
    let lowercasedName: String
    let isFolder: Bool
    let size: Int64
    let modified: Int64
    let sizeText: String
    let modifiedText: String

    var iconName: String {
        if isFolder { return "folder-symbolic" }
        if name.hasSuffix(".jpg") { return "image-x-generic-symbolic" }
        if name.hasSuffix(".mp4") { return "video-x-generic-symbolic" }
        return "text-x-generic-symbolic"
    }

    init(id: Int, name: String, isFolder: Bool, size: Int64, modified: Int64) {
        self.id = id
        self.name = name
        lowercasedName = name.lowercased()
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        sizeText = isFolder ? "—" : formatBytes(size)
        modifiedText = formatDate(modified)
    }

    /// Deterministic sample data.
    static func sample(count: Int) -> [FileRow] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }
        let base: Int64 = 1_780_000_000
        return (0..<count).map { i in
            let kind = next() % 10
            let modified = base - Int64(next() % 40_000_000)
            if i % 50 == 0 {
                return FileRow(id: i, name: "Folder \(i / 50 + 1)", isFolder: true, size: 0, modified: modified)
            }
            switch kind {
            case 0...5: return FileRow(id: i, name: "IMG_\(20_260_000 + i).jpg", isFolder: false, size: Int64(next() % 8_000_000 + 400_000), modified: modified)
            case 6...7: return FileRow(id: i, name: "VID_\(20_260_000 + i).mp4", isFolder: false, size: Int64(next() % 900_000_000 + 5_000_000), modified: modified)
            default: return FileRow(id: i, name: "Document \(i).pdf", isFolder: false, size: Int64(next() % 3_000_000 + 20_000), modified: modified)
            }
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var unit = 0
    var scaled = Double(bytes)
    while scaled >= 1000, unit < units.count - 1 {
        scaled /= 1000
        unit += 1
    }
    if unit == 0 { return "\(bytes) B" }
    let tenths = Int((scaled * 10).rounded())
    return "\(tenths / 10).\(tenths % 10) \(units[unit])"
}

func formatDate(_ unixSeconds: Int64) -> String {
    guard let dateTime = g_date_time_new_from_unix_local(gint64(unixSeconds)) else { return "" }
    defer { g_date_time_unref(dateTime) }
    guard let text = g_date_time_format(dateTime, "%Y-%m-%d %H:%M") else { return "" }
    defer { g_free(text) }
    return String(cString: text)
}

/// The observable state the gallery binds its widgets to.
@MainActor
@Observable
final class GalleryModel {
    var progress = 0.0
    var status = "Idle"
    var isRunning = false
    var copiedFiles = 0
    var itemCount = 0
    var visibleCount = 0
    var selectedCount = 0
    var droppedPaths: [String] = []
    var showHidden = false
    var chosenFolder: String?

    var summary: String {
        var text = "\(visibleCount) of \(itemCount) items"
        if selectedCount > 0 { text += " · \(selectedCount) selected" }
        return text
    }
}
