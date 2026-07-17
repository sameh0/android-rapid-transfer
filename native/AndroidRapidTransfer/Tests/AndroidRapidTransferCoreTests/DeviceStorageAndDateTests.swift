import Foundation
import MTPKit
import XCTest
@testable import AndroidRapidTransferCore

final class DeviceStorageTests: XCTestCase {
    private static let storages = [
        StorageInfo(
            id: 65537, storageDescription: "Internal shared storage",
            maxCapacity: 243_124_068_352, freeSpaceInBytes: 98_217_091_072, storageType: 3, filesystemType: 2
        ),
        StorageInfo(
            id: 131073, storageDescription: "",
            maxCapacity: 63_847_792_640, freeSpaceInBytes: 12_884_901_888, storageType: 4, filesystemType: 2
        ),
    ]

    func testNameAndCapacityComeFromTheStorageInfo() {
        let storage = DeviceStorage(storage: Self.storages[0], index: 0)

        XCTAssertEqual(storage.id, 65537)
        XCTAssertEqual(storage.name, "Internal shared storage")
        XCTAssertEqual(storage.totalBytes, 243_124_068_352)
        XCTAssertEqual(storage.freeBytes, 98_217_091_072)
        XCTAssertNotNil(storage.capacitySummary)
    }

    func testABlankDescriptionFallsBackToANumberedName() {
        let storage = DeviceStorage(storage: Self.storages[1], index: 1)
        XCTAssertEqual(storage.name, "Storage 2")
        XCTAssertEqual(DeviceStorage(storage: StorageInfo(id: 3, storageDescription: "  "), index: 2).name, "Storage 3")
    }

    func testAnUnreportedCapacityIsUnknownNotZero() {
        let storage = DeviceStorage(storage: StorageInfo(id: 1, storageDescription: "SD card"), index: 0)
        XCTAssertNil(storage.totalBytes)
        XCTAssertNil(storage.freeBytes)
        XCTAssertNil(storage.capacitySummary)

        let full = DeviceStorage(storage: StorageInfo(id: 1, maxCapacity: 100, freeSpaceInBytes: 0), index: 0)
        XCTAssertEqual(full.freeBytes, 0, "a full storage still reports its free space")
    }

    @MainActor
    func testBrowserListsStoragesByName() async throws {
        let provider = MockMTPProvider(storages: Self.storages)
        let model = DeviceBrowserViewModel(provider: provider)

        await model.load()

        XCTAssertEqual(model.storages.map(\.name), ["Internal shared storage", "Storage 2"])
        XCTAssertEqual(model.selectedStorageID, 65537)
        XCTAssertEqual(
            model.capacity,
            BrowserCapacity(freeBytes: 98_217_091_072, totalBytes: 243_124_068_352)
        )
    }
}

final class DeviceInfoDisplayNameTests: XCTestCase {
    func testTheModelWinsThenTheUSBProduct() {
        XCTAssertEqual(DeviceInfo(model: "Pixel 8", usb: USBDeviceInfo(product: "Pixel")).displayName, "Pixel 8")
        XCTAssertEqual(DeviceInfo(model: "", usb: USBDeviceInfo(product: "Pixel")).displayName, "Pixel")
        XCTAssertNil(DeviceInfo(model: " ").displayName)
    }
}

final class DeviceDateTests: XCTestCase {
    private static let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    func testBrowserEntryKeepsTheProvidersDate() {
        let modified = Date(timeIntervalSince1970: 1_784_293_496)
        let entry = WalkEntry(
            size: 10, isFolder: false, modified: modified, name: "a.jpg", path: "/DCIM/a.jpg",
            parentPath: "/DCIM", extension: "jpg", parentId: 0, objectId: 5
        )

        let browserEntry = BrowserEntry(walkEntry: entry)

        XCTAssertEqual(browserEntry.modified, modified)
        XCTAssertEqual(browserEntry.size, 10)
        XCTAssertEqual(browserEntry.objectId, 5)
    }

    func testAnUndatedEntryNeverMatchesADateRange() {
        let entry = BrowserEntry(walkEntry: WalkEntry(
            size: 1, isFolder: false, modified: nil, name: "x", path: "/x",
            parentPath: "/", extension: "", parentId: 0, objectId: 1
        ))
        XCTAssertFalse(DateRangeFilter(start: .distantPast).matches(entry))
    }

    func testDateRangeFilterUsesTheDevicesCalendarDay() {
        // A photo taken at 01:30 on July 4 in India is 20:00 UTC on July 3. A
        // filter for "July 4" in the same zone must include it.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.kolkata
        func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute, second: second))!
        }
        let filter = DateRangeFilter.calendarDays(from: date(4, 12, 0), through: date(4, 12, 0), in: calendar)

        XCTAssertTrue(filter.matches(date(4, 1, 30)))
        XCTAssertFalse(filter.matches(date(3, 23, 59, 59)))
        XCTAssertFalse(filter.matches(date(5, 0, 0)))
    }
}
