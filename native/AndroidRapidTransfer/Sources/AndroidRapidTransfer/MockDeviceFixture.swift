import AndroidRapidTransferCore
import Foundation
import MTPKit

enum MockDeviceFixture {
    /// With `--mock --mock-copy-on-launch`, copies a mock photo as soon as the
    /// mock phone's files are listed, so a finished copy can be looked at (or
    /// its idle cost measured) without driving the UI. Mock downloads write
    /// nothing to disk.
    static let copyOnLaunchArgument = "--mock-copy-on-launch"

    @MainActor
    static func copyOnLaunch(controller: DeviceConnectionController, transferModel: TransferViewModel) {
        Task { @MainActor in
            for _ in 0 ..< 100 {
                if let model = controller.deviceModel, model.hasLoaded, let storageID = model.selectedStorageID {
                    await transferModel.enqueueDroppedDeviceItems(
                        sources: ["/DCIM/Camera/IMG_20260716_174201.jpg"],
                        storageID: storageID
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static func makeProvider() -> MockMTPProvider {
        MockMTPProvider(
            deviceInfo: DeviceInfo(
                manufacturer: "Google",
                model: "Pixel 8 Pro",
                usb: USBDeviceInfo(serialNumber: "FAKE-P8P-2026")
            ),
            storages: [
                storage(
                    id: 65537,
                    description: "Internal shared storage",
                    capacity: 128_000_000_000,
                    free: 73_400_000_000
                ),
                storage(
                    id: 131073,
                    description: "SD card",
                    capacity: 64_000_000_000,
                    free: 41_800_000_000
                )
            ],
            entries: entries,
            transferScripts: Array(repeating: transferScript, count: 20)
        )
    }

    private static func storage(
        id: UInt32,
        description: String,
        capacity: UInt64,
        free: UInt64
    ) -> StorageInfo {
        StorageInfo(
            id: id,
            storageDescription: description,
            maxCapacity: capacity,
            freeSpaceInBytes: free,
            storageType: 3,
            filesystemType: 2
        )
    }

    private static let transferScript = MockTransferScript(
        events: [
            .progress(progress(percent: 12, sentBytes: 6_000_000)),
            .progress(progress(percent: 48, sentBytes: 24_000_000)),
            .progress(progress(percent: 83, sentBytes: 41_500_000)),
            .progress(progress(percent: 100, sentBytes: 50_000_000))
        ],
        eventInterval: .milliseconds(180),
        completionDelay: .milliseconds(250)
    )

    private static func progress(percent: Float, sentBytes: Int64) -> TransferProgressInfo {
        TransferProgressInfo(
            fullPath: "/selected-items",
            name: "selected-items",
            elapsedTime: 1_000,
            speed: 18.5,
            totalFiles: 1,
            totalDirectories: 0,
            filesSent: percent == 100 ? 1 : 0,
            filesSentProgress: percent,
            activeFileSize: TransferSizeInfo(
                total: 50_000_000,
                sent: sentBytes,
                progress: percent
            ),
            bulkFileSize: TransferSizeInfo(
                total: 50_000_000,
                sent: sentBytes,
                progress: percent
            )
        )
    }

    private static let entries: [WalkEntry] = [
        entry(path: "/DCIM", folder: true, objectID: 1, date: "2026-07-12T09:15:00Z"),
        entry(path: "/DCIM/Camera", folder: true, objectID: 2, date: "2026-07-16T17:42:00Z"),
        entry(path: "/DCIM/Camera/IMG_20260716_174201.jpg", objectID: 3, size: 4_832_411, date: "2026-07-16T17:42:01Z"),
        entry(path: "/DCIM/Camera/IMG_20260714_101522.jpg", objectID: 4, size: 3_914_078, date: "2026-07-14T10:15:22Z"),
        entry(path: "/DCIM/Camera/PXL_20260712_091501.jpg", objectID: 5, size: 5_204_991, date: "2026-07-12T09:15:01Z"),
        entry(path: "/Download", folder: true, objectID: 6, date: "2026-07-15T13:10:00Z"),
        entry(path: "/Download/boarding-pass.pdf", objectID: 7, size: 284_119, date: "2026-07-15T13:10:12Z"),
        entry(path: "/Download/Android-Rapid-Transfer-1.0.0.dmg", objectID: 8, size: 43_872_002, date: "2026-06-30T08:00:00Z"),
        entry(path: "/Music", folder: true, objectID: 9, date: "2026-05-20T19:21:00Z"),
        entry(path: "/Music/Favorites", folder: true, objectID: 10, date: "2026-05-20T19:22:00Z"),
        entry(path: "/Music/Favorites/Coastal Drive.mp3", objectID: 11, size: 8_441_120, date: "2026-05-20T19:22:10Z"),
        entry(path: "/Pictures", folder: true, objectID: 12, date: "2026-07-01T12:00:00Z"),
        entry(path: "/Pictures/Screenshots", folder: true, objectID: 13, date: "2026-07-10T11:40:00Z"),
        entry(path: "/Pictures/Screenshots/Screenshot_20260710.png", objectID: 14, size: 1_191_042, date: "2026-07-10T11:40:18Z"),
        entry(path: "/WhatsApp", folder: true, objectID: 15, date: "2026-07-11T07:35:00Z"),
        entry(path: "/WhatsApp/Media", folder: true, objectID: 16, date: "2026-07-11T07:36:00Z"),
        entry(path: "/WhatsApp/Media/WhatsApp Images", folder: true, objectID: 17, date: "2026-07-11T07:37:00Z"),
        entry(path: "/WhatsApp/Media/WhatsApp Images/IMG-20260711-WA0001.jpg", objectID: 18, size: 622_104, date: "2026-07-11T07:37:20Z"),
        entry(path: "/Android", folder: true, objectID: 19, date: "2026-04-01T08:00:00Z"),
        entry(path: "/Documents", folder: true, objectID: 20, date: "2026-06-18T16:25:00Z")
    ]

    private static func entry(
        path: String,
        folder: Bool = false,
        objectID: UInt32,
        size: Int64 = 0,
        date: String
    ) -> WalkEntry {
        let url = URL(fileURLWithPath: path)
        return WalkEntry(
            size: size,
            isFolder: folder,
            modified: wallClock.date(from: date),
            name: url.lastPathComponent,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            extension: folder ? "" : url.pathExtension,
            parentId: 0,
            objectId: objectID
        )
    }

    /// Fixture dates are device wall-clock times, read in the Mac's zone the
    /// way the MTP engine reads a phone's dates.
    private static let wallClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()
}
