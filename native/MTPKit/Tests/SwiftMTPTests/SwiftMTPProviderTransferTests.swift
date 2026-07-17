import Foundation
import MTPKit
import XCTest
@testable import SwiftMTP

/// Uploads, downloads, progress, cancellation and failure cleanup of
/// ``SwiftMTPProvider`` against ``FakeMTPDevice`` (contract §2).
final class SwiftMTPProviderTransferTests: ProviderTestCase {
    // MARK: - Upload (§2.3)

    func testUploadCreatesTheDestinationStreamsTheFileAndSetsItsDate() async throws {
        let device = FakeMTPDevice()
        let (provider, _) = makeProvider(device)
        let local = try temporaryDirectory()
        let file = local.appendingPathComponent("photo.jpg")
        let data = patternedData(10_000)
        try writeFile(file, data, modified: localDate(2023, 7, 8, 9, 10, 11))

        let operation = try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [file.path], destination: "/New/Dir", preprocessFiles: true))
        let events = try await run(operation)

        let uploaded = try XCTUnwrap(device.object(at: "New/Dir/photo.jpg"))
        XCTAssertEqual(uploaded.data, data)
        XCTAssertEqual(uploaded.format, PTPObjectFormat.undefined, "the device infers the type")
        XCTAssertEqual(uploaded.modified, "20230708T091011", "local wall-clock time")
        XCTAssertEqual(uploaded.created, "20230708T091011")

        let preprocess = preprocessEvents(events)
        XCTAssertEqual(preprocess, [TransferPreprocessData(fullPath: file.path, name: "photo.jpg", size: 10_000)])
        let progress = progressEvents(events)
        XCTAssertGreaterThan(progress.count, 2)
        let last = try XCTUnwrap(progress.last)
        XCTAssertEqual(last.name, "photo.jpg")
        XCTAssertEqual(last.fullPath, "/New/Dir/photo.jpg", "uploads report the device path")
        XCTAssertEqual(last.totalFiles, 1)
        XCTAssertEqual(last.totalDirectories, 0)
        XCTAssertEqual(last.filesSent, 1)
        XCTAssertEqual(last.filesSentProgress, 100)
        XCTAssertEqual(last.bulkFileSize, TransferSizeInfo(total: 10_000, sent: 10_000, progress: 100))
        XCTAssertEqual(last.activeFileSize, TransferSizeInfo(total: 10_000, sent: 10_000, progress: 100))
        XCTAssertEqual(progress.map(\.bulkFileSize.sent), progress.map(\.bulkFileSize.sent).sorted(), "monotone")
        XCTAssertTrue(progress.allSatisfy { $0.speed >= 0 && $0.elapsedTime >= 0 })
    }

    func testUploadReplacesASameNameFileCaseInsensitively() async throws {
        let device = FakeMTPDevice()
        device.addFile("Download/Report.PDF", data: Data([1, 2, 3]))
        let (provider, _) = makeProvider(device)
        let local = try temporaryDirectory()
        let file = local.appendingPathComponent("report.pdf")
        try writeFile(file, Data([4, 5]))
        _ = try await run(try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [file.path], destination: "/Download", preprocessFiles: false)))
        XCTAssertEqual(device.childNames("/Download"), ["report.pdf"])
        XCTAssertEqual(device.object(at: "Download/report.pdf")?.data, Data([4, 5]))
        XCTAssertEqual(device.calls(PTPOperation.deleteObject).count, 1)
    }

    func testUploadNeverDeletesADirectoryToMakeRoomForAFile() async throws {
        let device = FakeMTPDevice()
        device.addFile("Download/thing/inside.txt", data: Data([1]))
        let (provider, _) = makeProvider(device)
        let local = try temporaryDirectory()
        let file = local.appendingPathComponent("Thing")
        try writeFile(file, Data([2]))
        let error = await failure(of: try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [file.path], destination: "/Download", preprocessFiles: true)))
        XCTAssertEqual(callError(error)?.type, .invalidPath)
        XCTAssertNotNil(device.object(at: "Download/thing/inside.txt"))
        XCTAssertTrue(device.calls(PTPOperation.deleteObject).isEmpty)
    }

    func testFolderUploadIsRecursiveLexicalAndSkipsSymlinksAndDisallowedNames() async throws {
        let device = FakeMTPDevice()
        let (provider, _) = makeProvider(device)
        let local = try temporaryDirectory()
        let top = local.appendingPathComponent("top")
        try writeFile(top.appendingPathComponent("b.txt"), Data([2]))
        try writeFile(top.appendingPathComponent("a.txt"), Data([1]))
        try writeFile(top.appendingPathComponent(".hidden"), Data([3]))
        try writeFile(top.appendingPathComponent(".DS_Store"), Data([4]))
        try writeFile(top.appendingPathComponent("sub/c.txt"), Data([5]))
        try FileManager.default.createDirectory(at: top.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: top.appendingPathComponent("link"),
                                                   withDestinationURL: top.appendingPathComponent("a.txt"))

        let events = try await run(try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [top.path], destination: "/", preprocessFiles: true)))

        XCTAssertEqual(device.childNames("/top"), [".hidden", "a.txt", "b.txt", "empty", "sub"])
        XCTAssertEqual(device.childNames("/top/sub"), ["c.txt"])
        XCTAssertEqual(device.childNames("/top/empty"), [])
        XCTAssertEqual(device.object(at: "top/sub/c.txt")?.data, Data([5]))
        XCTAssertEqual(preprocessEvents(events).map(\.name), [".hidden", "a.txt", "b.txt", "c.txt"],
                       "one per file (unthrottled in tests)")
        let last = try XCTUnwrap(progressEvents(events).last)
        XCTAssertEqual(last.totalFiles, 4)
        XCTAssertEqual(last.totalDirectories, 3, "uploads count the source root")
        XCTAssertEqual(last.filesSent, 4)
        XCTAssertEqual(last.bulkFileSize.total, 4)
    }

    func testAMissingUploadSourceFailsThroughTheResult() async throws {
        let device = FakeMTPDevice()
        let (provider, _) = makeProvider(device)
        let missing = try temporaryDirectory().appendingPathComponent("nope").path
        let withPreprocess = await failure(of: try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [missing], destination: "/", preprocessFiles: true)))
        XCTAssertEqual(callError(withPreprocess)?.type, .localFileRead)
        let without = await failure(of: try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [missing], destination: "/", preprocessFiles: false)))
        XCTAssertEqual(callError(without)?.type, .invalidPath)
        XCTAssertTrue(callError(without)?.message.contains("no such file or directory") == true)
    }

    func testASymlinkedUploadSourceUploadsNothing() async throws {
        let device = FakeMTPDevice()
        let (provider, _) = makeProvider(device)
        let local = try temporaryDirectory()
        try writeFile(local.appendingPathComponent("real.txt"), Data([1]))
        let link = local.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local.appendingPathComponent("real.txt"))
        _ = try await run(try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [link.path], destination: "/Dest", preprocessFiles: true)))
        XCTAssertEqual(device.childNames("/Dest"), [])
    }

    func testUploadSizesAroundPacketBoundariesUseTheSpecZLPRule() async throws {
        let device = FakeMTPDevice(maxPacketSize: 512)
        let (provider, _) = makeProvider(device)
        let local = try temporaryDirectory()
        // Container length = 12 + size: 512 needs a ZLP; 12 + 1536 does not.
        for (name, size, zlps) in [("zero.bin", 0, 0), ("fivehundred.bin", 500, 1), ("aligned.bin", 1536, 0)] {
            let file = local.appendingPathComponent(name)
            try writeFile(file, patternedData(size))
            let before = device.zeroLengthWrites
            _ = try await run(try await provider.uploadFiles(input: UploadFilesInput(
                storageId: sid, sources: [file.path], destination: "/Z", preprocessFiles: false)))
            XCTAssertEqual(device.object(at: "Z/\(name)")?.data, patternedData(size), name)
            XCTAssertEqual(device.zeroLengthWrites - before, zlps, name)
        }
    }

    func testDeviceLossDuringUploadIsDeviceChanged() async throws {
        let device = FakeMTPDevice()
        let (provider, factory) = makeProvider(device)
        let local = try temporaryDirectory()
        let file = local.appendingPathComponent("big.bin")
        try writeFile(file, patternedData(50_000))
        device.vanishAfterSendObjectBytes = 10_000
        let error = await failure(of: try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [file.path], destination: "/", preprocessFiles: true)))
        XCTAssertEqual(callError(error)?.type, .deviceChanged)
        XCTAssertTrue(callError(error)?.message.contains("LIBUSB_ERROR_NO_DEVICE") == true)
        device.reattach()
        _ = try await provider.walk(input: walkInput("/"))
        XCTAssertEqual(factory.opens, 2)
    }

    func testCancellingAnUploadAbortsItAndTheSessionSurvives() async throws {
        let device = FakeMTPDevice()
        device.objectWriteDelay = 0.002
        let (provider, factory) = makeProvider(device) { $0.transferChunkSize = 1024 }
        let local = try temporaryDirectory()
        let file = local.appendingPathComponent("big.bin")
        try writeFile(file, patternedData(400_000))
        let operation = try await provider.uploadFiles(input: UploadFilesInput(
            storageId: sid, sources: [file.path], destination: "/", preprocessFiles: false))
        for await event in operation.progress {
            if case let .progress(info) = event, info.activeFileSize.sent > 0 { break }
        }
        operation.result.cancel()
        do {
            _ = try await operation.result.value
            XCTFail("the upload was cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(device.cancelRequests.count, 1)
        XCTAssertNil(device.object(at: "big.bin"), "no partial object is left behind")
        let entries = try await provider.walk(input: walkInput("/"))
        XCTAssertEqual(entries, [])
        XCTAssertEqual(factory.opens, 1, "the session survived the abort")
    }

    // MARK: - Download (§2.2)

    func testDownloadOverwritesAtomicallyAndRestoresTheLocalMtime() async throws {
        let device = FakeMTPDevice()
        let data = patternedData(10_000)
        device.addFile("DCIM/Camera/IMG_1.jpg", data: data, modified: "20240102T030405")
        let (provider, _) = makeProvider(device)
        let destination = try temporaryDirectory()
        try writeFile(destination.appendingPathComponent("IMG_1.jpg"), Data("old".utf8))

        let events = try await run(try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/DCIM/Camera/IMG_1.jpg"], destination: destination.path, preprocessFiles: true)))

        let local = destination.appendingPathComponent("IMG_1.jpg")
        XCTAssertEqual(try Data(contentsOf: local), data)
        let mtime = try FileManager.default.attributesOfItem(atPath: local.path)[.modificationDate] as? Date
        XCTAssertEqual(mtime, localDate(2024, 1, 2, 3, 4, 5), "the device's wall clock read in the Mac's zone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["IMG_1.jpg"],
                       "no temporary file is left")
        XCTAssertEqual(preprocessEvents(events),
                       [TransferPreprocessData(fullPath: "/DCIM/Camera/IMG_1.jpg", name: "IMG_1.jpg", size: 10_000)])
        let last = try XCTUnwrap(progressEvents(events).last)
        XCTAssertEqual(last.name, "IMG_1.jpg")
        XCTAssertEqual(last.fullPath, "/DCIM/Camera/IMG_1.jpg")
        XCTAssertEqual(last.totalFiles, 1)
        XCTAssertEqual(last.filesSent, 1)
        XCTAssertEqual(last.filesSentProgress, 100)
        XCTAssertEqual(last.bulkFileSize.total, 10_000)
        XCTAssertEqual(last.bulkFileSize.sent, 10_000)
    }

    func testDownloadWithoutPreprocessingReportsNoTotals() async throws {
        let device = FakeMTPDevice()
        device.addFile("a.bin", data: patternedData(5000))
        let (provider, _) = makeProvider(device)
        let destination = try temporaryDirectory()
        let events = try await run(try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/a.bin"], destination: destination.path, preprocessFiles: false)))
        XCTAssertTrue(preprocessEvents(events).isEmpty)
        let last = try XCTUnwrap(progressEvents(events).last)
        XCTAssertEqual(last.totalFiles, 0)
        XCTAssertEqual(last.filesSentProgress, 0)
        XCTAssertEqual(last.bulkFileSize.total, 0)
        XCTAssertEqual(last.bulkFileSize.sent, 5000)
        XCTAssertEqual(last.filesSent, 1)
    }

    func testDirectoryDownloadIsRecursive() async throws {
        let device = FakeMTPDevice()
        device.addFile("Trip/a.jpg", data: Data([1]))
        device.addFile("Trip/.hidden", data: Data([2]))
        device.addFile("Trip/.DS_Store", data: Data([3]))
        device.addFolder("Trip/Empty")
        device.addFile("Trip/Sub/b.jpg", data: Data([4]))
        let (provider, _) = makeProvider(device)
        let destination = try temporaryDirectory()
        let events = try await run(try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/trip"], destination: destination.path, preprocessFiles: true)))
        let trip = destination.appendingPathComponent("trip")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trip.path).sorted(),
                       [".hidden", "Empty", "Sub", "a.jpg"], "hidden files are downloaded, disallowed ones are not")
        XCTAssertEqual(try Data(contentsOf: trip.appendingPathComponent("Sub/b.jpg")), Data([4]))
        let last = try XCTUnwrap(progressEvents(events).last)
        XCTAssertEqual(last.totalFiles, 3)
        XCTAssertEqual(last.totalDirectories, 2, "downloads do not count the source directory")
    }

    func testAnEmptyTopLevelSourceDirectoryCreatesNothing() async throws {
        let device = FakeMTPDevice()
        device.addFolder("EmptyTop")
        let (provider, _) = makeProvider(device)
        let destination = try temporaryDirectory()
        _ = try await run(try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/EmptyTop"], destination: destination.path, preprocessFiles: true)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testDownloadingOntoALocalDirectoryIsLocalFileRead() async throws {
        let device = FakeMTPDevice()
        device.addFile("clash", data: Data([1]))
        let (provider, _) = makeProvider(device)
        let destination = try temporaryDirectory()
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("clash"), withIntermediateDirectories: true)
        let error = await failure(of: try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/clash"], destination: destination.path, preprocessFiles: false)))
        XCTAssertEqual(callError(error)?.type, .localFileRead)
    }

    func testDownloadFallsBackToThePathWhenTheHintIsStale() async throws {
        let device = FakeMTPDevice()
        device.addFile("a.bin", data: Data([7]))
        let (provider, _) = makeProvider(device)
        let destination = try temporaryDirectory()
        _ = try await run(try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/a.bin"], sourceProps: [SourceProp(fullPath: "/a.bin", objectId: 4242)],
            destination: destination.path, preprocessFiles: true)))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.bin")), Data([7]))
    }

    func testDeviceLossDuringDownloadLeavesNoPartialFile() async throws {
        let device = FakeMTPDevice()
        device.addFile("big.bin", data: patternedData(20_000))
        let (provider, factory) = makeProvider(device)
        let destination = try temporaryDirectory()
        device.vanishAfterObjectBytes = 5000
        let error = await failure(of: try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/big.bin"], destination: destination.path, preprocessFiles: true)))
        XCTAssertEqual(callError(error)?.type, .deviceChanged)
        XCTAssertTrue(callError(error)?.message.contains("LIBUSB_ERROR_NO_DEVICE") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [],
                       "neither the file nor its temporary copy remains")
        device.reattach()
        _ = try await provider.walk(input: walkInput("/"))
        XCTAssertEqual(factory.opens, 2)
    }

    func testCancellingADownloadAbortsItAndTheNextOperationSucceeds() async throws {
        let device = FakeMTPDevice()
        let data = patternedData(400_000)
        device.addFile("big.bin", data: data)
        device.objectReadDelay = 0.002
        let (provider, factory) = makeProvider(device)
        let destination = try temporaryDirectory()
        let operation = try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/big.bin"], destination: destination.path, preprocessFiles: false))
        for await event in operation.progress {
            if case let .progress(info) = event, info.activeFileSize.sent > 0 { break }
        }
        operation.result.cancel()
        do {
            _ = try await operation.result.value
            XCTFail("the download was cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let getObject = try XCTUnwrap(device.calls(PTPOperation.getObject).last)
        XCTAssertEqual(device.cancelRequests, [getObject.transactionID], "class Cancel for that transaction")
        XCTAssertGreaterThanOrEqual(device.statusRequests, 2, "Get Device Status polled until OK")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])

        device.objectReadDelay = 0
        let entries = try await provider.walk(input: walkInput("/"))
        XCTAssertEqual(entries.map(\.name), ["big.bin"])
        _ = try await run(try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/big.bin"], destination: destination.path, preprocessFiles: false)))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("big.bin")), data)
        XCTAssertEqual(factory.opens, 1, "no reconnect was needed")
    }

    func testTransfersRunInCallOrderBehindEachOther() async throws {
        let device = FakeMTPDevice()
        device.addFile("one.bin", data: patternedData(30_000))
        let (provider, _) = makeProvider(device)
        let destination = try temporaryDirectory()
        let download = try await provider.downloadFiles(input: DownloadFilesInput(
            storageId: sid, sources: ["/one.bin"], destination: destination.path, preprocessFiles: false))
        // Queued behind the transfer, so it sees the downloaded object untouched.
        let deleted = try await provider.deleteFiles(input: DeleteFileInput(storageId: sid, files: ["/one.bin"]))
        XCTAssertTrue(deleted)
        _ = try await run(download)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("one.bin")).count, 30_000)
    }
}
