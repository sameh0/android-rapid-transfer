import AppKit
import Foundation
@testable import AndroidRapidTransfer
import AndroidRapidTransferCore
import MTPKit
import SwiftUI
import XCTest

// Offscreen renders of the file browser, for eyeballing light and dark mode
// without screen recording, plus a timing check on a 2,000-item folder.
// Skipped unless ART_RENDER_DIR names a folder for the PNGs:
//
//     ART_RENDER_DIR=/tmp/renders swift test --filter BrowserRender

@MainActor
enum BrowserRenderSupport {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["ART_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    static func render<V: View>(
        _ view: V,
        size: CGSize,
        dark: Bool,
        name: String,
        settle: TimeInterval = 1.0,
        before: (() -> Void)? = nil
    ) -> TimeInterval {
        guard let dir = outputDirectory else { return 0 }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        let start = Date()
        host.layoutSubtreeIfNeeded()
        let firstLayout = Date().timeIntervalSince(start)
        before?()
        pump(settle)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return firstLayout }
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = rep.representation(using: .png, properties: [:])
        try? data?.write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        window.contentView = nil
        return firstLayout
    }

    static func walkEntry(_ path: String, folder: Bool = false, size: Int64 = 0, day: Int = 1) -> WalkEntry {
        let url = URL(fileURLWithPath: path)
        return WalkEntry(
            size: size,
            isFolder: folder,
            modified: Date(timeIntervalSince1970: 1_780_000_000 + Double(day) * 86_400),
            name: url.lastPathComponent,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            extension: folder ? "" : url.pathExtension,
            parentId: 0,
            objectId: 0
        )
    }

    static func provider(cameraCount: Int = 14) -> MockMTPProvider {
        var entries = [
            walkEntry("/DCIM", folder: true),
            walkEntry("/DCIM/Camera", folder: true),
            walkEntry("/DCIM/Screenshots", folder: true),
            walkEntry("/Download", folder: true),
            walkEntry("/Music", folder: true),
            walkEntry("/Pictures", folder: true),
            walkEntry("/Documents", folder: true),
            walkEntry("/Empty", folder: true),
            walkEntry("/notes.txt", size: 2_300, day: 3),
            walkEntry("/boarding-pass.pdf", size: 284_119, day: 4)
        ]
        for index in 0..<cameraCount {
            let ext = index % 7 == 6 ? "mp4" : "jpg"
            entries.append(walkEntry(
                String(format: "/DCIM/Camera/IMG_202607%02d_%04d.\(ext)", index % 28 + 1, index),
                size: Int64(2_000_000 + index * 91_337),
                day: index
            ))
        }
        return MockMTPProvider(
            deviceInfo: DeviceInfo(manufacturer: "Google", model: "Pixel 8 Pro"),
            storages: [StorageInfo(
                id: 1,
                storageDescription: "Internal shared storage",
                maxCapacity: 128_000_000_000,
                freeSpaceInBytes: 23_400_000_000
            )],
            entries: entries
        )
    }

    static func settings() -> AppSettings {
        AppSettings(settingsURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("render-settings-\(UUID().uuidString).json"))
    }
}

@MainActor
final class BrowserRenderPaneTests: XCTestCase {
    private let size = CGSize(width: 620, height: 420)

    override func setUp() async throws {
        try XCTSkipIf(BrowserRenderSupport.outputDirectory == nil, "Set ART_RENDER_DIR to render.")
    }

    private func pane(_ model: DeviceBrowserViewModel) -> some View {
        BrowserPaneView(
            model: model,
            paneKind: .device,
            settings: BrowserRenderSupport.settings(),
            focusCoordinator: PaneFocusCoordinator()
        ) {
            Text("Internal shared storage").foregroundStyle(.secondary)
        }
    }

    func testRenderPanes() async throws {
        for dark in [false, true] {
            for mode in [BrowserViewMode.list, .grid] {
                let model = DeviceBrowserViewModel(provider: BrowserRenderSupport.provider(), viewMode: mode)
                await model.load()
                let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })
                await model.navigate(to: dcim)
                let camera = try XCTUnwrap(model.entries.first { $0.name == "Camera" })
                await model.navigate(to: camera)
                let ids = model.entries.prefix(3).map(\.id)
                model.selectEntry(id: ids[1], extending: false, toggling: false)
                model.selectEntry(id: ids[2], extending: false, toggling: true)
                BrowserRenderSupport.render(pane(model), size: size, dark: dark, name: "pane-\(mode)")
            }
            let empty = DeviceBrowserViewModel(provider: BrowserRenderSupport.provider(), viewMode: .grid)
            await empty.load()
            let folder = try XCTUnwrap(empty.entries.first { $0.name == "Empty" })
            await empty.navigate(to: folder)
            BrowserRenderSupport.render(pane(empty), size: size, dark: dark, name: "pane-empty")
        }
    }

    /// A 2,000-item Camera folder: how long the model takes to list it and
    /// the pane to lay it out, in both view modes.
    func testLargeFolderAppearsPromptly() async throws {
        for mode in [BrowserViewMode.list, .grid] {
            let model = DeviceBrowserViewModel(
                provider: BrowserRenderSupport.provider(cameraCount: 2_000),
                viewMode: mode
            )
            await model.load()
            let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })
            await model.navigate(to: dcim)
            let camera = try XCTUnwrap(model.entries.first { $0.name == "Camera" })
            let host = NSHostingView(rootView: pane(model).frame(width: size.width, height: size.height))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            BrowserRenderSupport.pump(0.5)
            let start = Date()
            await model.navigate(to: camera)
            let listed = Date().timeIntervalSince(start)
            host.layoutSubtreeIfNeeded()
            host.display()
            let shown = Date().timeIntervalSince(start)
            XCTAssertEqual(model.entries.count, 2_000)
            print("PERF \(mode): model \(String(format: "%.3f", listed)) s, listed+laid out+drawn \(String(format: "%.3f", shown)) s")
            BrowserRenderSupport.pump(0.6)
            window.contentView = nil
            BrowserRenderSupport.render(
                pane(model), size: size, dark: false, name: "pane-2000-\(mode)", settle: 0.6
            )
        }
    }
}

@MainActor
final class BrowserRenderComponentTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipIf(BrowserRenderSupport.outputDirectory == nil, "Set ART_RENDER_DIR to render.")
    }

    private func entry(_ name: String, folder: Bool = false) -> BrowserEntry {
        BrowserEntry(
            id: "/\(name)", name: name, size: folder ? nil : 3_914_078,
            modified: nil, isDirectory: folder, location: "/\(name)"
        )
    }

    func testRenderComponents() async throws {
        for dark in [false, true] {
            // Grid cell states: rest, hover, selected, mid-pop.
            let cells = HStack(spacing: 8) {
                BrowserGridCell(entry: entry("Camera", folder: true), isSelected: false, isHovered: false, popTrigger: nil, select: {})
                BrowserGridCell(entry: entry("IMG_0412.jpg"), isSelected: false, isHovered: true, popTrigger: nil, select: {})
                BrowserGridCell(entry: entry("IMG_0413.jpg"), isSelected: true, isHovered: false, popTrigger: nil, select: {})
                BrowserGridCell(entry: entry("New Folder", folder: true), isSelected: true, isHovered: false, popTrigger: nil, select: {})
                    .scaleEffect(1.12)
            }
            .padding()
            .background(.background)
            BrowserRenderSupport.render(cells, size: CGSize(width: 600, height: 170), dark: dark, name: "grid-cells-rest-hover-selected-pop")

            // Loading card, before and after the count is known.
            let loading = VStack(spacing: 16) {
                BrowserLoadingIndicator(progress: .init(path: "/DCIM/Camera"))
                BrowserLoadingIndicator(
                    progress: .init(path: "/DCIM/Camera", itemCount: 2_003, fractionCompleted: 0.6)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            BrowserRenderSupport.render(loading, size: CGSize(width: 360, height: 180), dark: dark, name: "loading-card")

            BrowserRenderSupport.render(
                BrowserSkeletonView(viewMode: .list),
                size: CGSize(width: 480, height: 260), dark: dark, name: "skeleton-list", settle: 0.2
            )
            BrowserRenderSupport.render(
                BrowserSkeletonView(viewMode: .grid),
                size: CGSize(width: 480, height: 300), dark: dark, name: "skeleton-grid", settle: 0.2
            )

            let empties = HStack(spacing: 0) {
                BrowserEmptyStateView(kind: .emptyFolder(.device)).frame(maxWidth: .infinity)
                Divider()
                BrowserEmptyStateView(kind: .emptyFolder(.local)).frame(maxWidth: .infinity)
                Divider()
                BrowserEmptyStateView(kind: .noResults("holiday")).frame(maxWidth: .infinity)
            }
            .background(.background)
            BrowserRenderSupport.render(empties, size: CGSize(width: 900, height: 240), dark: dark, name: "empty-states")

            let drop = ZStack {
                Color(nsColor: .textBackgroundColor)
                BrowserDropTargetHighlight(title: "Copy to Camera")
            }
            BrowserRenderSupport.render(drop, size: CGSize(width: 480, height: 280), dark: dark, name: "drop-target", settle: 0.3)
            let confirmation = ZStack {
                Color(nsColor: .textBackgroundColor)
                BrowserDropConfirmation(title: "Copying to Camera")
            }
            BrowserRenderSupport.render(confirmation, size: CGSize(width: 480, height: 160), dark: dark, name: "drop-confirmation")

            let model = DeviceBrowserViewModel(provider: BrowserRenderSupport.provider())
            await model.load()
            let dcim = try XCTUnwrap(model.entries.first { $0.name == "DCIM" })
            await model.navigate(to: dcim)
            let camera = try XCTUnwrap(model.entries.first { $0.name == "Camera" })
            await model.navigate(to: camera)
            model.selectAll()
            let chrome = VStack(spacing: 0) {
                BreadcrumbBarView(model: model, paneKind: .device, navigationDisabled: false)
                Divider()
                Spacer()
                Divider()
                BrowserStatusBarView(model: model)
            }
            BrowserRenderSupport.render(chrome, size: CGSize(width: 560, height: 110), dark: dark, name: "breadcrumb-and-status")

            // The navigation slide, sampled: entering, halfway, settled.
            let slideModel = DeviceBrowserViewModel(provider: BrowserRenderSupport.provider(), viewMode: .grid)
            await slideModel.load()
            let slideDCIM = try XCTUnwrap(slideModel.entries.first { $0.name == "DCIM" })
            await slideModel.navigate(to: slideDCIM)
            let frames = HStack(spacing: 6) {
                ForEach([0.0, 0.5, 1.0], id: \.self) { progress in
                    BrowserGridView(
                        model: slideModel, entries: slideModel.entries, location: "/DCIM",
                        animatesChanges: false, highlight: nil, navigationDisabled: false,
                        filePromiseExporter: nil, dragWriter: nil, copyAction: nil,
                        queueAction: nil, dateRangeAction: nil, paneFocus: {}, createFolder: {},
                        rename: { _ in }, delete: { _ in }, showInfo: { _ in }
                    )
                    .offset(x: 28 * (1 - progress))
                    .opacity(0.35 + 0.65 * progress)
                    .frame(width: 300, height: 180)
                    .clipped()
                    .border(.separator)
                }
            }
            .padding(6)
            .background(.background)
            BrowserRenderSupport.render(frames, size: CGSize(width: 930, height: 196), dark: dark, name: "navigation-slide-frames")
        }
    }
}
