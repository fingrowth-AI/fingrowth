import Foundation

enum AppDataLocation {
    static let storeFileName = "InvestmentStrategist.sqlite"
    static let secureDirectoryName = "secure"

    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    static let storeFileProtection: FileProtectionType = .completeUnlessOpen
    #endif

    static func secureStoreURL(
        in baseDirectory: URL = URL.documentsDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let secureDir = baseDirectory.appending(path: secureDirectoryName, directoryHint: .isDirectory)

        let attributes = secureAttributes()
        if !fileManager.fileExists(atPath: secureDir.path) {
            try fileManager.createDirectory(
                at: secureDir,
                withIntermediateDirectories: true,
                attributes: attributes
            )
        } else if let attributes {
            try fileManager.setAttributes(attributes, ofItemAtPath: secureDir.path)
        }

        return secureDir.appending(path: storeFileName)
    }

    /// All SQLite files SwiftData writes for a given store: the main file plus -shm/-wal sidecars.
    static func storeFileURLs(for storeURL: URL) -> [URL] {
        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        return [
            storeURL,
            directory.appending(path: "\(name)-shm"),
            directory.appending(path: "\(name)-wal"),
        ]
    }

    /// Applies the chosen file-protection class to every store file that currently exists.
    /// SwiftData (WAL mode) creates the -shm/-wal sidecars lazily, so call this after init and after writes.
    @discardableResult
    static func applyStoreFileProtection(
        at storeURL: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        var updated: [URL] = []
        for url in storeFileURLs(for: storeURL) where fileManager.fileExists(atPath: url.path) {
            try fileManager.setAttributes(
                [.protectionKey: storeFileProtection],
                ofItemAtPath: url.path
            )
            updated.append(url)
        }
        return updated
        #else
        return []
        #endif
    }

    private static func secureAttributes() -> [FileAttributeKey: Any]? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return [.protectionKey: storeFileProtection]
        #else
        return nil
        #endif
    }
}
