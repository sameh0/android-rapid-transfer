import Foundation
@testable import AndroidRapidTransferCore
import XCTest

final class AcknowledgementsTests: XCTestCase {
    private func text(appName: String = "Portside") throws -> String {
        try XCTUnwrap(Acknowledgements.text(bundle: Bundle(for: Self.self), appName: appName))
    }

    /// The component list: everything before the first section.
    private func componentList(_ text: String) throws -> String {
        try XCTUnwrap(text.components(separatedBy: "=====").first)
    }

    private static let sparkleFragments = [
        "Permission is hereby granted, free of charge",
        "Redistribution and use in source and binary forms",
        "Copyright (c) 2006-2013 Andy Matuschak.",
        "Copyright 2003-2005 Colin Percival",
        "Copyright (c) 2008-2010 Yuta Mori",
        "Copyright (c) 2015 Orson Peters",
        "Copyright (c) 2011 Mark Hamlin.",
    ]

    func testTextLoadsWithTheAppNameFilledIn() throws {
        let text = try text()
        XCTAssertTrue(text.hasPrefix("ACKNOWLEDGEMENTS"))
        XCTAssertTrue(text.contains("Portside is built on open-source software."))
        XCTAssertFalse(text.contains(Acknowledgements.appNamePlaceholder))
    }

    func testListsExactlyWhatShipsWithItsLicense() throws {
        let text = try text()
        let list = try componentList(text)

        for component in Acknowledgements.components {
            let line = list.split(separator: "\n").first { $0.contains(component.name) }
            XCTAssertTrue(line?.contains(component.license) ?? false, "\(component.name) is not listed as \(component.license)")
        }
        for fragment in Self.sparkleFragments {
            XCTAssertTrue(text.contains(fragment), "Missing: \(fragment)")
        }
    }

    func testABundledCopyTakesPrecedenceOverTheSourceFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcknowledgementsTests-\(UUID().uuidString).bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "test.acknowledgements", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        try "Bundled notices for {{APP_NAME}}."
            .write(to: resources.appendingPathComponent("Acknowledgements.txt"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(url: root))

        XCTAssertEqual(Acknowledgements.text(bundle: bundle, appName: "Portside"), "Bundled notices for Portside.")
    }

    func testReachableFromTheHelpMenuThroughADeclaredWindow() {
        XCTAssertEqual(HelpMenuItem.acknowledgements.destination, .window(AppWindowID.acknowledgements))
        XCTAssertTrue(AppWindowID.all.contains(AppWindowID.acknowledgements))
    }
}
