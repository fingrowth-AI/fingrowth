import XCTest
import SwiftData
@testable import FinGrowth

final class AppShellTests: XCTestCase {

    // MARK: - SwiftData container (App launches without crash)

    func testAppContainerInitializesWithCustomStoreURL() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appending(path: "test.sqlite")

        let container = try AppContainer.makeContainer(storeURL: storeURL)
        XCTAssertNotNil(container)
    }

    func testSchemaIncludesAllPersistentModels() {
        let schema = AppContainer.makeSchema()
        let entityNames = Set(schema.entities.map(\.name))
        XCTAssertEqual(
            entityNames,
            ["PrivateLedger", "ShareableProfile", "AuditEntry", "ResearchHistoryEntry"]
        )
    }

    // MARK: - RootTab (Tabs switch correctly)

    func testRootTabsAreInExpectedOrder() {
        XCTAssertEqual(RootTab.allCases, [.research, .portfolio, .privacy, .settings])
    }

    func testEveryRootTabHasTitleAndIcon() {
        for tab in RootTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, "tab \(tab) has empty title")
            XCTAssertFalse(tab.systemImage.isEmpty, "tab \(tab) has empty system image")
        }
    }

    // MARK: - AppSettings (Backend URL persists across restarts)

    func testBackendURLDefaultsToLocalhost() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.backendURL, AppSettings.defaultBackendURL)
    }

    func testBackendURLPersistsAcrossRestarts() {
        let defaults = makeIsolatedDefaults()

        let first = AppSettings(defaults: defaults)
        first.backendURL = "https://strategist.example.com"

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.backendURL, "https://strategist.example.com")
    }

    func testResetBackendURLRestoresDefault() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.backendURL = "https://example.com"
        settings.resetBackendURL()
        XCTAssertEqual(settings.backendURL, AppSettings.defaultBackendURL)

        let next = AppSettings(defaults: defaults)
        XCTAssertEqual(next.backendURL, AppSettings.defaultBackendURL)
    }

    // MARK: - AppDataLocation

    func testSecureStoreURLCreatesDirectory() throws {
        let baseDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let storeURL = try AppDataLocation.secureStoreURL(in: baseDir)
        let parentDir = storeURL.deletingLastPathComponent()

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: parentDir.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists, "secure directory should exist at \(parentDir.path)")
        XCTAssertTrue(isDirectory.boolValue, "secure path should be a directory")
        XCTAssertEqual(storeURL.lastPathComponent, AppDataLocation.storeFileName)
    }

    func testStoreFileURLsCoversMainAndSidecars() {
        let storeURL = URL(fileURLWithPath: "/tmp/example/Foo.sqlite")
        let urls = AppDataLocation.storeFileURLs(for: storeURL).map(\.lastPathComponent)
        XCTAssertEqual(urls, ["Foo.sqlite", "Foo.sqlite-shm", "Foo.sqlite-wal"])
    }

    #if os(iOS)
    func testStoreFilesUseConfiguredProtectionClassAfterWrite() throws {
        let baseDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let storeURL = try AppDataLocation.secureStoreURL(in: baseDir)
        let container = try AppContainer.makeContainer(storeURL: storeURL)

        let context = ModelContext(container)
        context.insert(AuditEntry(endpoint: "test", direction: "outbound", payloadDigest: "deadbeef"))
        try context.save()

        // SwiftData creates -shm/-wal during save; reapply via a recorder so we can
        // verify the request even on simulators (which don't expose .protectionKey on read).
        let recorder = ProtectionRecordingFileManager()
        let touched = try AppDataLocation.applyStoreFileProtection(at: storeURL, fileManager: recorder)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL.path),
            "main .sqlite file must exist after save"
        )
        XCTAssertTrue(touched.contains(storeURL), "main .sqlite must be in the touched set")
        XCTAssertFalse(touched.isEmpty, "applyStoreFileProtection should touch at least one file")

        for url in touched {
            let recorded = recorder.setAttributesCalls.first { $0.path == url.path }
            XCTAssertNotNil(recorded, "no setAttributes call recorded for \(url.lastPathComponent)")
            XCTAssertEqual(
                recorded?.attributes[.protectionKey] as? FileProtectionType,
                AppDataLocation.storeFileProtection,
                "\(url.lastPathComponent) was not asked for the configured protection class"
            )
        }

        // Best-effort on-disk read: real devices expose .protectionKey, simulators return nil.
        for url in touched {
            if let onDisk = try FileManager.default
                .attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
            {
                XCTAssertEqual(
                    onDisk,
                    AppDataLocation.storeFileProtection,
                    "\(url.lastPathComponent) on-disk protection should match the configured class"
                )
            }
        }
    }
    #endif

    // MARK: - Helpers

    private func makeIsolatedDefaults(function: String = #function) -> UserDefaults {
        let suiteName = "AppShellTests.\(function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshell-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

#if os(iOS)
private final class ProtectionRecordingFileManager: FileManager {
    struct Call {
        let attributes: [FileAttributeKey: Any]
        let path: String
    }
    private(set) var setAttributesCalls: [Call] = []

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        setAttributesCalls.append(Call(attributes: attributes, path: path))
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
#endif
