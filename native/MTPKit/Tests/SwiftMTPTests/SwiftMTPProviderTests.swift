import Foundation
import MTPKit
import XCTest
@testable import SwiftMTP

/// Lifecycle, device info, listing, path resolution and the mutating calls
/// of ``SwiftMTPProvider`` against ``FakeMTPDevice`` (contract §0, §1, §3–§6).
final class SwiftMTPProviderTests: ProviderTestCase {
    // MARK: - Lifecycle (§0.3)

    func testConcurrentFirstCallsOpenTheDeviceOnce() async throws {
        let device = FakeMTPDevice()
        let (provider, factory) = makeProvider(device)
        factory.openDelay = 0.05
        let rootInput = walkInput("/")
        async let info = provider.deviceInfo()
        async let storages = provider.storages()
        async let listing = provider.walk(input: rootInput)
        _ = try await (info, storages, listing)
        XCTAssertEqual(factory.opens, 1)
        XCTAssertEqual(device.calls(PTPOperation.openSession).count, 1)
        let opened = await provider.sessionsOpened
        XCTAssertEqual(opened, 1)
    }

    func testFailedOpenIsRetriedByTheNextCall() async throws {
        let device = FakeMTPDevice()
        let (provider, factory) = makeProvider(device)
        factory.failNextOpen = MTPTransportError(.exclusiveAccess, status: IOReturnCode.exclusiveAccess, "busy")
        await assertThrowsCall(.deviceSetup) { try await provider.deviceInfo() }
        _ = try await provider.deviceInfo()
        XCTAssertEqual(factory.opens, 1)
    }

    func testDisposeClosesTheSessionAndTheNextCallReopens() async throws {
        let device = FakeMTPDevice()
        let (provider, factory) = makeProvider(device)
        let nothingOpen = try await provider.dispose()
        XCTAssertTrue(nothingOpen)
        _ = try await provider.deviceInfo()
        let disposed = try await provider.dispose()
        XCTAssertTrue(disposed)
        XCTAssertEqual(device.closeCount, 1)
        XCTAssertEqual(device.calls(PTPOperation.closeSession).count, 1)
        XCTAssertFalse(device.sessionOpen)
        _ = try await provider.storages()
        XCTAssertEqual(factory.opens, 2)
    }

    func testNoDeviceIsDetectFailed() async {
        let device = FakeMTPDevice()
        device.vanish()
        let (provider, _) = makeProvider(device)
        await assertThrowsCall(.mtpDetectFailed) { try await provider.deviceInfo() }
    }

    func testOpenSessionFailureIsDeviceSetupAndNeverResets() async {
        let device = FakeMTPDevice()
        device.openSessionFailure = PTPResponseCode.deviceBusy
        let (provider, _) = makeProvider(device)
        await assertThrowsCall(.deviceSetup, contains: "DeviceBusy") { try await provider.storages() }
        XCTAssertEqual(device.closeCount, 1, "the interface is released, not reset")
    }

    func testOpenAfterAHostDiedMidUploadRetriesGetDeviceInfoOnce() async throws {
        let device = FakeMTPDevice()
        device.addFolder("DCIM")
        device.abandonedSendObject = 57
        let (provider, factory) = makeProvider(device)
        let entries = try await provider.walk(input: walkInput("/"))
        XCTAssertEqual(entries.map(\.name), ["DCIM"])
        XCTAssertEqual(factory.opens, 1, "recovered within one open")
        XCTAssertEqual(device.cancelRequests, [], "no class Cancel to an idle phone")
        XCTAssertEqual(device.closeCount, 0, "never released or reset")
    }

    func testOrdinaryOpenSendsNoCancel() async throws {
        let device = FakeMTPDevice()
        let (provider, _) = makeProvider(device)
        _ = try await provider.deviceInfo()
        XCTAssertEqual(device.cancelRequests, [])
    }

    func testSessionLossIsDeviceChangedWithTheNoDeviceMarkerAndReconnects() async throws {
        let device = FakeMTPDevice()
        device.addFolder("DCIM")
        let (provider, factory) = makeProvider(device)
        _ = try await provider.walk(input: walkInput("/"))
        device.vanish()
        await assertThrowsCall(.deviceChanged, contains: "LIBUSB_ERROR_NO_DEVICE") {
            try await provider.walk(input: walkInput("/DCIM"))
        }
        // Still gone: the next call tries to reopen and finds nothing.
        await assertThrowsCall(.mtpDetectFailed) { try await provider.walk(input: walkInput("/")) }
        device.reattach()
        let entries = try await provider.walk(input: walkInput("/"))
        XCTAssertEqual(entries.map(\.name), ["DCIM"])
        XCTAssertEqual(factory.opens, 2)
    }

    func testFileExistsOnADeadSessionThrowsInsteadOfReportingFalse() async throws {
        let device = FakeMTPDevice()
        device.addFile("a.txt", data: Data([1]))
        let (provider, _) = makeProvider(device)
        _ = try await provider.storages()
        device.vanish()
        await assertThrowsCall(.deviceChanged, contains: "LIBUSB_ERROR_NO_DEVICE") {
            try await provider.fileExists(input: FileExistsInput(storageId: self.sid, files: ["/a.txt"]))
        }
    }

    // MARK: - Device info and storages (§1.1, §1.2, §3)

    func testDeviceInfoCarriesTheDatasetAndUSBIdentity() async throws {
        let device = FakeMTPDevice()
        let (provider, _) = makeProvider(device)
        let info = try await provider.deviceInfo()
        XCTAssertEqual(info.model, "Fake Phone 5G")
        XCTAssertEqual(info.serialNumber, "FAKE0001")
        XCTAssertEqual(info.vendorExtensionDescription, "microsoft.com: 1.0; android.com: 1.0;")
        XCTAssertFalse(info.operationsSupported.isEmpty)
        XCTAssertEqual(info.usb, USBDeviceInfo(
            vendorID: 0x2717, productID: 0xFF48, deviceRelease: 0x0606,
            manufacturer: "FakeCo", product: "Fake Phone 5G", serialNumber: "FAKE0001"
        ))
    }

    func testStoragesCarryTheirInfo() async throws {
        let device = FakeMTPDevice()
        let (provider, _) = makeProvider(device)
        let storages = try await provider.storages()
        XCTAssertEqual(storages.map(\.id), [65537, 0x20001])
        XCTAssertEqual(storages[0].storageDescription, "Internal shared storage")
        XCTAssertEqual(storages[0].maxCapacity, 128_000_000_000)
        XCTAssertEqual(storages[0].freeSpaceInBytes, 64_000_000_000)
    }

    func testNoStorageIsReported() async {
        let device = FakeMTPDevice()
        device.storages = []
        let (provider, _) = makeProvider(device)
        await assertThrowsCall(.noStorage, message: "no storage found") { try await provider.storages() }
    }

    func testEmptyStorageDatasetIsAllowStorageAccessAndReopens() async throws {
        let device = FakeMTPDevice()
        device.emptyStorageIDsPayload = true
        let (provider, factory) = makeProvider(device)
        await assertThrowsCall(.allowStorageAccess, contains: "error allow storage access") {
            try await provider.storages()
        }
        device.emptyStorageIDsPayload = false
        let storages = try await provider.storages()
        XCTAssertEqual(storages.count, 2)
        XCTAssertEqual(factory.opens, 2, "the device is reopened after this error")
    }

    // MARK: - Walk (§1.3)

    func testRootWalkListsOnlyDirectChildrenOfTheRequestedStorage() async throws {
        let device = FakeMTPDevice()
        let dcim = device.addFolder("DCIM")
        device.addFolder("Download")
        let file = device.addFile("a.txt", data: Data(count: 42))
        device.addFile("sd.jpg", data: Data(count: 1), storage: 0x20001)
        let (provider, _) = makeProvider(device)
        let entries = try await provider.walk(input: walkInput("/"))
        XCTAssertEqual(entries.map(\.name), ["DCIM", "Download", "a.txt"], "device order, other storage excluded")
        XCTAssertEqual(entries.map(\.path), ["/DCIM", "/Download", "/a.txt"])
        XCTAssertEqual(entries.map(\.parentPath), ["/", "/", "/"])
        XCTAssertEqual(entries.map(\.isFolder), [true, true, false])
        XCTAssertEqual(entries.map(\.size), [0, 0, 42])
        XCTAssertEqual(entries.map(\.objectId), [dcim, dcim + 1, file])
        XCTAssertTrue(entries.allSatisfy { $0.parentId == PTPHandle.root })
        // Root children are listed through handle 0 at depth 1.
        let propLists = device.calls(PTPOperation.getObjectPropList)
        XCTAssertFalse(propLists.isEmpty)
        XCTAssertTrue(propLists.allSatisfy { $0.parameters[0] == 0 && $0.parameters[4] == 1 })
    }

    func testWalkBuildsPathsFromTheInputSpellingAndDropsTheDirectoryItself() async throws {
        let device = FakeMTPDevice()
        let dcim = device.addFolder("DCIM")
        device.addFolder("DCIM/Camera")
        device.addFile("DCIM/x.jpg", data: Data(count: 3))
        let (provider, _) = makeProvider(device)
        let entries = try await provider.walk(input: walkInput("dcim/"))
        XCTAssertEqual(entries.map(\.path), ["/dcim/Camera", "/dcim/x.jpg"])
        XCTAssertEqual(entries.map(\.parentPath), ["/dcim", "/dcim"])
        XCTAssertEqual(entries.map(\.parentId), [dcim, dcim])
    }

    func testWalkEntryDatesAndExtensions() async throws {
        let device = FakeMTPDevice()
        device.addFolder("F.d")
        for name in ["a.JPG", "x.tar.gz", ".bashrc", "file.", "noext"] {
            device.addFile("Stuff/\(name)", data: Data([1]), modified: "20240102T030405")
        }
        device.addFile("Stuff/folder.d", data: Data([1]))
        let (provider, _) = makeProvider(device)
        let entries = try await provider.walk(input: walkInput("/Stuff"))
        XCTAssertEqual(entries.map(\.extension), ["JPG", "tar.gz", "bashrc", "", "", "d"])
        XCTAssertEqual(entries.first?.modified, localDate(2024, 1, 2, 3, 4, 5), "device wall clock in the Mac's zone")
        let root = try await provider.walk(input: walkInput("/"))
        XCTAssertEqual(root.first { $0.name == "F.d" }?.extension, "", "folders have no extension")
    }

    func testHiddenAndDisallowedFilters() async throws {
        let device = FakeMTPDevice()
        for name in [".hidden", ".DS_Store", "[-----DS_Store.mtp.test----].txt", "ok.txt"] {
            device.addFile("Dir/\(name)", data: Data([1]))
        }
        let (provider, _) = makeProvider(device)
        func names(_ disallowed: Bool, _ hidden: Bool) async throws -> [String] {
            try await provider.walk(input: walkInput("/Dir", skipDisallowed: disallowed, skipHidden: hidden)).map(\.name)
        }
        let both = try await names(true, true)
        XCTAssertEqual(both, ["ok.txt"])
        let hiddenOnly = try await names(false, true)
        XCTAssertEqual(hiddenOnly, ["[-----DS_Store.mtp.test----].txt", "ok.txt"])
        let disallowedOnly = try await names(true, false)
        XCTAssertEqual(disallowedOnly, [".hidden", "ok.txt"])
        let neither = try await names(false, false)
        XCTAssertEqual(neither.count, 4)
    }

    func testWalkingADisallowedTargetIsInvalidPath() async {
        let device = FakeMTPDevice()
        device.addFile("Dir/.DS_Store", data: Data([1]))
        let (provider, _) = makeProvider(device)
        await assertThrowsCall(.invalidPath, message: "disallowed file .DS_Store") {
            try await provider.walk(input: self.walkInput("/Dir/.DS_Store", skipDisallowed: true))
        }
    }

    func testWalkingAFileReturnsThatFile() async throws {
        let device = FakeMTPDevice()
        device.addFile("Dir/Sub/f.bin", data: Data(count: 9))
        let (provider, _) = makeProvider(device)
        let entries = try await provider.walk(input: walkInput("/dir/sub/F.BIN"))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "f.bin")
        XCTAssertEqual(entries.first?.path, "/dir/sub/F.BIN")
        XCTAssertEqual(entries.first?.parentPath, "/", "path mode")
        XCTAssertEqual(entries.first?.size, 9)
    }

    func testEmptyDirectoryIsAnEmptyListWithOneProgressEvent() async throws {
        let device = FakeMTPDevice()
        device.addFolder("Empty")
        let (provider, _) = makeProvider(device)
        let log = ProgressLog()
        let entries = try await provider.walk(input: walkInput("/Empty/"), onProgress: { log.append($0) })
        XCTAssertEqual(entries, [])
        XCTAssertEqual(log.all, [WalkProgress(fullPath: "/Empty/", itemCount: 0, fractionCompleted: 0)])
    }

    func testPerPropertyProgressAndTheWildcardSizeGate() async throws {
        let device = FakeMTPDevice()
        for index in 0..<5 { device.addFile("Big/f\(index).jpg", data: Data([UInt8(index)])) }
        device.addFile("Small/a.jpg", data: Data([1]))
        device.addFile("Small/b.jpg", data: Data([2]))
        let (provider, _) = makeProvider(device) { $0.wildcardMaxChildren = 3 }
        let log = ProgressLog()
        let big = try await provider.walk(input: walkInput("/Big"), onProgress: { log.append($0) })
        XCTAssertEqual(big.map(\.name), ["f0.jpg", "f1.jpg", "f2.jpg", "f3.jpg", "f4.jpg"])
        XCTAssertEqual(device.propListCalls(property: MTPObjectProperty.all), 0, "gated: no wildcard")
        XCTAssertEqual(device.propListCalls(property: UInt32(MTPObjectProperty.dateCreated)), 0)
        XCTAssertEqual(log.all.map(\.fractionCompleted), [0, 0.25, 0.5, 0.75, 1])
        XCTAssertTrue(log.all.allSatisfy { $0.fullPath == "/Big" && $0.itemCount == 5 })
        XCTAssertEqual(device.calls(PTPOperation.getObjectInfo).count, 0, "no per-object fallback")

        _ = try await provider.walk(input: walkInput("/Small"))
        XCTAssertEqual(device.propListCalls(property: MTPObjectProperty.all), 1, "small folders use the wildcard")
    }

    func testWildcardRefusalDemotesToPerPropertyForTheSession() async throws {
        let device = FakeMTPDevice()
        device.wildcardRefuseAbove = 0
        device.addFile("A/one.jpg", data: Data([1]))
        device.addFile("B/two.jpg", data: Data([2]))
        let (provider, _) = makeProvider(device)
        let a = try await provider.walk(input: walkInput("/A"))
        XCTAssertEqual(a.map(\.name), ["one.jpg"])
        let b = try await provider.walk(input: walkInput("/B"))
        XCTAssertEqual(b.map(\.name), ["two.jpg"])
        XCTAssertEqual(device.propListCalls(property: MTPObjectProperty.all), 1, "refused once, never asked again")
        XCTAssertEqual(device.calls(PTPOperation.getObjectInfo).count, 0)
    }

    func testOtherWildcardFailuresFallBackPerObjectForThatDirectoryOnly() async throws {
        let device = FakeMTPDevice()
        device.wildcardRefuseAbove = 1
        device.wildcardRefusalCode = PTPResponseCode.generalError
        device.addFile("Two/a.jpg", data: Data([1]))
        device.addFile("Two/b.jpg", data: Data([2]))
        device.addFile("One/c.jpg", data: Data([3]))
        let (provider, _) = makeProvider(device)
        let two = try await provider.walk(input: walkInput("/Two"))
        XCTAssertEqual(two.map(\.name), ["a.jpg", "b.jpg"])
        XCTAssertEqual(device.calls(PTPOperation.getObjectInfo).count, 2)
        let one = try await provider.walk(input: walkInput("/One"))
        XCTAssertEqual(one.map(\.name), ["c.jpg"])
        XCTAssertEqual(device.propListCalls(property: MTPObjectProperty.all), 2, "the strategy was kept")
    }

    func testUnusablePerPropertyDemotesToObjectInfo() async throws {
        let device = FakeMTPDevice()
        device.wildcardRefuseAbove = 0
        device.failingProperties = [MTPObjectProperty.objectFileName, MTPObjectProperty.objectFormat,
                                    MTPObjectProperty.objectSize, MTPObjectProperty.dateModified,
                                    MTPObjectProperty.dateCreated]
        device.addFile("A/one.jpg", data: Data(count: 7))
        device.addFile("B/two.jpg", data: Data(count: 8))
        let (provider, _) = makeProvider(device)
        let a = try await provider.walk(input: walkInput("/A"))
        XCTAssertEqual(a.map(\.size), [7])
        device.resetRecording()
        let b = try await provider.walk(input: walkInput("/B"))
        XCTAssertEqual(b.map(\.size), [8])
        XCTAssertTrue(device.calls(PTPOperation.getObjectPropList).isEmpty, "demoted to per-object for the session")
    }

    func testDateCreatedIsFetchedOnlyWhenDateModifiedIsMissing() async throws {
        let device = FakeMTPDevice()
        let handle = device.addFile("Big/a.jpg", data: Data([1]))
        device.setModified(handle, modified: "", created: "20200304T050607")
        device.addFile("Big/b.jpg", data: Data([1]))
        let (provider, _) = makeProvider(device) { $0.wildcardMaxChildren = 1 }
        let entries = try await provider.walk(input: walkInput("/Big"))
        XCTAssertEqual(entries.map(\.modified), [localDate(2020, 3, 4, 5, 6, 7), localDate(2024, 1, 2, 3, 4, 5)])
        XCTAssertEqual(device.propListCalls(property: UInt32(MTPObjectProperty.dateCreated)), 1)
    }

    func testChildrenWithUnparseableDatesAreKept() async throws {
        for propList in [true, false] {
            let device = FakeMTPDevice()
            device.supportsPropList = propList
            let handle = device.addFile("D/odd.jpg", data: Data([1]))
            device.setModified(handle, modified: "not a date", created: "")
            device.addFile("D/fine.jpg", data: Data([1]))
            let (provider, _) = makeProvider(device)
            let entries = try await provider.walk(input: walkInput("/D"))
            XCTAssertEqual(entries.map(\.name), ["odd.jpg", "fine.jpg"], "proplist \(propList)")
            XCTAssertNil(entries.first?.modified)
        }
    }

    func testDevicesWithoutGetObjectPropListListPerObject() async throws {
        let device = FakeMTPDevice()
        device.supportsPropList = false
        device.deviceInfo.operationsSupported.removeAll { $0 == PTPOperation.getObjectPropList }
        device.addFile("DCIM/a.jpg", data: Data(count: 5))
        let (provider, _) = makeProvider(device)
        let entries = try await provider.walk(input: walkInput("/DCIM"))
        XCTAssertEqual(entries.map(\.size), [5])
        XCTAssertTrue(device.calls(PTPOperation.getObjectPropList).isEmpty)
    }

    func testSurrogatePairNamesSurviveTheRoundTrip() async throws {
        let device = FakeMTPDevice()
        device.addFile("Pics/📷 café.jpg", data: Data([1]))
        let (provider, _) = makeProvider(device)
        let entries = try await provider.walk(input: walkInput("/Pics"))
        XCTAssertEqual(entries.map(\.name), ["📷 café.jpg"])
        XCTAssertEqual(entries.map(\.path), ["/Pics/📷 café.jpg"])
        let exists = try await provider.fileExists(input: FileExistsInput(storageId: sid, files: ["/pics/📷 CAFÉ.JPG"]))
        XCTAssertEqual(exists.map(\.exists), [true])
    }

    // MARK: - Path resolution (§0.4)

    func testFileExistsIsCaseInsensitiveNormalizedAndEchoesTheInput() async throws {
        let device = FakeMTPDevice()
        device.addFile("DCIM/Camera/IMG.JPG", data: Data([1]))
        let (provider, _) = makeProvider(device)
        let files = ["/dcim/camera/img.jpg", "DCIM/Camera/IMG.JPG", "/DCIM//Camera/../Camera/img.jpg/",
                     "/DCIM/Nope", "", "/", "/DCIM/Camera/IMG.JPG/deeper"]
        let result = try await provider.fileExists(input: FileExistsInput(storageId: sid, files: files))
        XCTAssertEqual(result.map(\.fullpath), files)
        XCTAssertEqual(result.map(\.exists), [true, true, true, false, false, true, false])
        let empty = try await provider.fileExists(input: FileExistsInput(storageId: sid, files: []))
        XCTAssertEqual(empty, [])
    }

    func testTheFirstCaseInsensitiveMatchInDeviceOrderWins() async throws {
        let device = FakeMTPDevice()
        let first = device.insert(name: "Photo.jpg", parent: 0, storage: sid, format: PTPObjectFormat.exifJPEG)
        let second = device.insert(name: "photo.JPG", parent: 0, storage: sid, format: PTPObjectFormat.exifJPEG)
        let (provider, _) = makeProvider(device)
        _ = try await provider.deleteFiles(input: DeleteFileInput(storageId: sid, files: ["/PHOTO.jpg"]))
        XCTAssertNil(device.objects[first])
        XCTAssertNotNil(device.objects[second])
    }

    func testResolutionErrorsMatchGoMessages() async {
        let device = FakeMTPDevice()
        device.addFile("a.txt", data: Data([1]))
        let (provider, _) = makeProvider(device)
        await assertThrowsCall(.invalidPath, message: "path not found: /Missing/x\nreason: file not found: Missing") {
            try await provider.walk(input: self.walkInput("/Missing/x"))
        }
        await assertThrowsCall(.invalidPath, message: "path not found: /a.txt/x") {
            try await provider.walk(input: self.walkInput("/a.txt/x"))
        }
    }

    func testAValidObjectIdHintSkipsPathResolution() async throws {
        let device = FakeMTPDevice()
        let dcim = device.addFolder("DCIM")
        device.addFile("DCIM/a.jpg", data: Data([1]))
        let (provider, _) = makeProvider(device)
        _ = try await provider.storages()
        device.resetRecording()
        let entries = try await provider.walk(input: walkInput("/DCIM", objectId: dcim))
        XCTAssertEqual(entries.map(\.path), ["/DCIM/a.jpg"])
        let rootListings = device.calls(PTPOperation.getObjectHandles).filter { $0.parameters[2] == PTPHandle.root }
        XCTAssertTrue(rootListings.isEmpty)
    }

    func testStaleOrMismatchedObjectIdHintsFallBackToThePath() async throws {
        let device = FakeMTPDevice()
        device.addFile("DCIM/a.jpg", data: Data([1]))
        let other = device.addFolder("Other")
        device.addFile("Other/b.jpg", data: Data([1]))
        let (provider, _) = makeProvider(device)
        let stale = try await provider.walk(input: walkInput("/DCIM", objectId: 9999))
        XCTAssertEqual(stale.map(\.name), ["a.jpg"])
        let mismatched = try await provider.walk(input: walkInput("/DCIM", objectId: other))
        XCTAssertEqual(mismatched.map(\.name), ["a.jpg"], "a hint naming another object is not trusted")
    }

    func testACachedHandleThatWentStaleIsResolvedAgain() async throws {
        let device = FakeMTPDevice()
        let camera = device.addFolder("DCIM/Camera")
        device.addFile("DCIM/Camera/old.jpg", data: Data([1]))
        let (provider, _) = makeProvider(device) { $0.directoryCacheLifetime = 3600 }
        let before = try await provider.walk(input: walkInput("/DCIM/Camera"))
        XCTAssertEqual(before.map(\.name), ["old.jpg"])
        // Changed on the phone: Camera deleted and recreated with a new handle.
        device.removeExternally(camera)
        device.addFile("DCIM/Camera/new.jpg", data: Data([2]))
        let after = try await provider.walk(input: walkInput("/DCIM/Camera"))
        XCTAssertEqual(after.map(\.name), ["new.jpg"])
    }

    // MARK: - deleteFiles (§1.5)

    func testDeleteContinuesPastMissingPathsAndRecursesOnTheDevice() async throws {
        let device = FakeMTPDevice()
        device.addFile("a.txt", data: Data([1]))
        device.addFile("Folder/inner/b.txt", data: Data([1]))
        device.addFile("keep.txt", data: Data([1]))
        let (provider, _) = makeProvider(device)
        let deleted = try await provider.deleteFiles(input: DeleteFileInput(
            storageId: sid, files: ["/missing", "/A.TXT", "", "/folder"]))
        XCTAssertTrue(deleted)
        XCTAssertEqual(device.childNames("/"), ["keep.txt"])
        XCTAssertEqual(device.calls(PTPOperation.deleteObject).count, 2, "one DeleteObject per existing path")
        let exists = try await provider.fileExists(input: FileExistsInput(storageId: sid, files: ["/a.txt", "/Folder"]))
        XCTAssertEqual(exists.map(\.exists), [false, false], "the cache follows our own deletes")
    }

    func testDeletingTheRootIsRejectedBeforeAnythingIsDeleted() async throws {
        let device = FakeMTPDevice()
        device.addFile("a.txt", data: Data([1]))
        let (provider, _) = makeProvider(device)
        for root in ["/", "", "/.", "//"] where !root.isEmpty {
            await assertThrowsCall(.invalidPath) {
                try await provider.deleteFiles(input: DeleteFileInput(storageId: self.sid, files: ["/a.txt", root]))
            }
        }
        XCTAssertTrue(device.calls(PTPOperation.deleteObject).isEmpty)
        XCTAssertEqual(device.childNames("/"), ["a.txt"])
    }

    func testDeleteFailureIsFileObjectReadWithTheResponseName() async {
        let device = FakeMTPDevice()
        device.addFile("a.txt", data: Data([1]))
        device.deleteFailure = PTPResponseCode.partialDeletion
        let (provider, _) = makeProvider(device)
        await assertThrowsCall(.fileObjectRead, message: "PartialDeletion") {
            try await provider.deleteFiles(input: DeleteFileInput(storageId: self.sid, files: ["/a.txt"]))
        }
    }

    // MARK: - makeDirectory (§1.6)

    func testMakeDirectoryCreatesMissingParentsWithLocalDates() async throws {
        let device = FakeMTPDevice()
        device.addFolder("A")
        let (provider, _) = makeProvider(device)
        let made = try await provider.makeDirectory(input: MakeDirectoryInput(storageId: sid, fullPath: "a/B/C"))
        XCTAssertTrue(made)
        let c = try XCTUnwrap(device.object(at: "A/B/C"))
        XCTAssertTrue(c.isFolder)
        // 2024-05-06T07:08:09Z is 03:08:09 in New York.
        XCTAssertEqual(c.modified, "20240506T030809")
        XCTAssertEqual(device.calls(PTPOperation.sendObjectInfo).count, 2, "A existed (case-insensitively)")
        XCTAssertTrue(device.calls(PTPOperation.sendObject).isEmpty)
    }

    func testMakeDirectoryOnAnExistingDirectoryOrTheRootIsSuccess() async throws {
        let device = FakeMTPDevice()
        device.addFolder("DCIM/Camera")
        let (provider, _) = makeProvider(device)
        let existing = try await provider.makeDirectory(input: MakeDirectoryInput(storageId: sid, fullPath: "/dcim/CAMERA/"))
        let root = try await provider.makeDirectory(input: MakeDirectoryInput(storageId: sid, fullPath: "/"))
        XCTAssertTrue(existing)
        XCTAssertTrue(root)
        XCTAssertTrue(device.calls(PTPOperation.sendObjectInfo).isEmpty)
    }

    func testMakeDirectoryThroughAFileIsInvalidPath() async {
        let device = FakeMTPDevice()
        device.addFile("a.txt", data: Data([1]))
        let (provider, _) = makeProvider(device)
        await assertThrowsCall(.invalidPath, message: "invalid path: a.txt. The object is not a directory") {
            try await provider.makeDirectory(input: MakeDirectoryInput(storageId: self.sid, fullPath: "/a.txt/x"))
        }
    }

    func testStoreFullIsStorageFull() async {
        let device = FakeMTPDevice()
        device.storeFull = true
        let (provider, _) = makeProvider(device)
        await assertThrowsCall(.storageFull, message: "StoreFull") {
            try await provider.makeDirectory(input: MakeDirectoryInput(storageId: self.sid, fullPath: "/New"))
        }
    }

    // MARK: - renameFile (§1.7)

    func testRenameByPathUpdatesTheCache() async throws {
        let device = FakeMTPDevice()
        let handle = device.addFile("Docs/a.txt", data: Data([1]))
        let (provider, _) = makeProvider(device)
        _ = try await provider.walk(input: walkInput("/Docs"))
        let renamed = try await provider.renameFile(input: RenameFileInput(storageId: sid, fullPath: "/docs/A.txt",
                                                                            newFileName: "b.txt"))
        XCTAssertTrue(renamed)
        XCTAssertEqual(device.objects[handle]?.name, "b.txt", "renamed in place, handle kept")
        let exists = try await provider.fileExists(input: FileExistsInput(storageId: sid, files: ["/Docs/a.txt", "/Docs/b.txt"]))
        XCTAssertEqual(exists.map(\.exists), [false, true])
    }

    func testRenameErrors() async {
        let device = FakeMTPDevice()
        let (provider, _) = makeProvider(device)
        await assertThrowsCall(.invalidPath, message: "file not found: /nope") {
            try await provider.renameFile(input: RenameFileInput(storageId: self.sid, fullPath: "/nope", newFileName: "x"))
        }
        await assertThrowsCall(.invalidPath) {
            try await provider.renameFile(input: RenameFileInput(storageId: self.sid, fullPath: "/", newFileName: "x"))
        }
        XCTAssertTrue(device.calls(PTPOperation.setObjectPropValue).isEmpty)
    }

    func testRenameGeneralErrorCountsAsSuccess() async throws {
        let device = FakeMTPDevice()
        device.addFile("a.txt", data: Data([1]))
        device.renameAnswersGeneralError = true
        let (provider, _) = makeProvider(device)
        let renamed = try await provider.renameFile(input: RenameFileInput(storageId: sid, fullPath: "/a.txt", newFileName: "b.txt"))
        XCTAssertTrue(renamed)
    }

    // MARK: - Device selection (§4)

    private func candidate(_ serial: String, product: String = "Phone", name: String? = "MTP", interface: Int = 0,
                           registry: UInt64 = 1) -> MTPInterfaceCandidate {
        MTPInterfaceCandidate(registryEntryID: registry, vendorID: 0x2717, productID: 0xFF48, manufacturer: "Xiaomi",
                              productName: product, serialNumber: serial, locationID: 0x100,
                              interfaceNumber: interface, interfaceClass: 0xFF, interfaceSubClass: 0xFF,
                              interfaceProtocol: 0, interfaceName: name, endpointCount: 3)
    }

    func testDeviceSelection() throws {
        XCTAssertThrowsError(try MTPDeviceOpener.choose([])) {
            XCTAssertEqual(($0 as? MTPCallError)?.type, .mtpDetectFailed)
        }
        let a = candidate("A", product: "Phone A", registry: 1)
        XCTAssertEqual(try MTPDeviceOpener.choose([a, candidate("A", interface: 1, registry: 2)]), a,
                       "two interfaces of one device are one device")
        XCTAssertEqual(try MTPDeviceOpener.choose([a, candidate("C", name: nil, registry: 3)]), a,
                       "a named MTP interface wins over a string-less one")
        XCTAssertThrowsError(try MTPDeviceOpener.choose([a, candidate("B", product: "Phone B", registry: 4)])) {
            let error = $0 as? MTPCallError
            XCTAssertEqual(error?.type, .multipleDevice)
            XCTAssertEqual(error?.message, "mtp: more than 1 device: Xiaomi Phone A A,Xiaomi Phone B B")
        }
    }

    // MARK: - Dates

    func testDateParsingLeniencyAndFormatting() {
        let wallClock = MTPDateTime(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5,
                                    millisecond: 0, offsetSeconds: nil)
        XCTAssertEqual(MTPDateTime.parse("20240102T030405"), wallClock)
        XCTAssertEqual(MTPDateTime.parse("20240102T030405."), wallClock, "Samsung")
        XCTAssertEqual(MTPDateTime.parse("20240102T030405Z"), wallClock, "Jolla")
        var lumia = wallClock
        lumia.offsetSeconds = -7 * 3600
        XCTAssertEqual(MTPDateTime.parse("20240102T030405-0700"), lumia, "Lumia")
        XCTAssertEqual(MTPDateTime.parse("20240102T030405.5")?.millisecond, 500)
        XCTAssertNil(MTPDateTime.parse(""))
        XCTAssertNil(MTPDateTime.parse("20241302T030405"))
        XCTAssertNil(MTPDateTime.parse("20240230T030405"))
        XCTAssertNil(MTPDateTime.parse("garbage"))
        // A zone-less date is local wall-clock time; a numeric zone is honoured.
        XCTAssertEqual(MTPDateTime.parse("20240102T030405")?.date(in: zone), localDate(2024, 1, 2, 3, 4, 5))
        XCTAssertEqual(MTPDateTime.parse("20240102T030405-0700")?.date(in: zone),
                       Date(timeIntervalSince1970: 1_704_189_845))
        XCTAssertEqual(MTPDateTime.format(localDate(2024, 7, 8, 9, 10, 11), in: zone), "20240708T091011")
    }

    func testDevicePathHelpers() {
        XCTAssertEqual(DevicePath.normalize("DCIM"), "/DCIM")
        XCTAssertEqual(DevicePath.normalize("/DCIM/"), "/DCIM")
        XCTAssertEqual(DevicePath.normalize("/a/../b"), "/b")
        XCTAssertEqual(DevicePath.normalize("/."), "/")
        XCTAssertEqual(DevicePath.normalize("/../x"), "/x")
        XCTAssertEqual(DevicePath.normalize(""), "/")
        XCTAssertEqual(DevicePath.dir("/a/b"), "/a")
        XCTAssertEqual(DevicePath.dir("/a"), "/")
        XCTAssertEqual(DevicePath.join("/", "x"), "/x")
    }

    // MARK: - The protocol surface through an existential

    func testProtocolSurfaceDispatchesThroughTheExistential() async throws {
        let device = FakeMTPDevice()
        device.addFile("a", data: Data([9, 8, 7]))
        let (concrete, _) = makeProvider(device)
        let provider: any MTPDeviceProvider = concrete
        let local = try temporaryDirectory()
        try writeFile(local.appendingPathComponent("a"), Data([1, 2]))

        let info = try await provider.deviceInfo()
        let storages = try await provider.storages()
        let root = try await provider.walk(input: walkInput("/"))
        let existence = try await provider.fileExists(input: FileExistsInput(storageId: sid, files: ["/x"]))
        XCTAssertFalse(info.model.isEmpty)
        XCTAssertEqual(storages.count, 2)
        XCTAssertEqual(root.map(\.name), ["a"])
        XCTAssertEqual(existence, [FileExistsData(fullpath: "/x", exists: false)])

        let madeDirectory = try await provider.makeDirectory(input: MakeDirectoryInput(storageId: sid, fullPath: "/Folder"))
        XCTAssertTrue(madeDirectory)
        // Go semantics, unlike MockMTPProvider: an existing directory is success.
        let again = try await provider.makeDirectory(input: MakeDirectoryInput(storageId: sid, fullPath: "/folder"))
        XCTAssertTrue(again)
        let renamed = try await provider.renameFile(input: RenameFileInput(storageId: sid, fullPath: "/Folder",
                                                                          newFileName: "Renamed"))
        XCTAssertTrue(renamed)
        let deleted = try await provider.deleteFiles(input: DeleteFileInput(storageId: sid, files: ["/Renamed", "/missing"]))
        XCTAssertTrue(deleted)

        let upload = try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [local.appendingPathComponent("a").path], destination: "/Up", preprocessFiles: false))
        _ = try await run(upload)
        let download = try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/a"], destination: local.appendingPathComponent("down").path, preprocessFiles: false))
        _ = try await run(download)
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("down/a")), Data([9, 8, 7]))
        let disposed = try await provider.dispose()
        XCTAssertTrue(disposed)
    }
}
