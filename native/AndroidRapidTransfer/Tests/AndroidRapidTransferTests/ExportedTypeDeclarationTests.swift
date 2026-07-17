import Foundation
@testable import AndroidRapidTransfer
import UniformTypeIdentifiers
import XCTest

/// The drag payloads use `UTType(exportedAs:)`, which Apple requires to be
/// declared in the bundle's Info.plist. Both packaging scripts embed the
/// declarations from `exported_type_declarations` in release-config.sh; this
/// keeps that list in step with the types the Swift code exports.
final class ExportedTypeDeclarationTests: XCTestCase {
    func testPackagingDeclaresEveryExportedDragType() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AndroidRapidTransferTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let config = packageRoot.appending(path: "Scripts/release-config.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \"$1\" && exported_type_declarations", "declare", config.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let fragment = try XCTUnwrap(String(data: data, encoding: .utf8))
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>\(fragment)</dict></plist>
        """
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        )
        let declarations = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declared = Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })

        XCTAssertEqual(declared, [UTType.artLocalItems.identifier, UTType.artDeviceItems.identifier])
        for declaration in declarations {
            XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.data"])
        }
    }
}
