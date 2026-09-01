import Foundation

public struct SnapshotStore {
    public let paths: AutoTypelessPaths
    private let fileManager: FileManager

    public init(paths: AutoTypelessPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func capture(profile: ProfileRecord) throws -> SnapshotMetadata {
        try validateRequiredLiveFiles()
        let directory = profileDirectory(profile.id)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let authDestination = directory.appendingPathComponent("user-data.json")
        let storageDestination = directory.appendingPathComponent("app-storage.json")
        try AtomicFileWriter.copy(from: paths.authFileURL, to: authDestination)
        try AtomicFileWriter.copy(from: paths.appStorageURL, to: storageDestination)

        let metadata = SnapshotMetadata(
            identity: profile.identity,
            capturedAt: Date(),
            authSHA256: try Checksum.sha256(of: authDestination),
            appStorageSHA256: try Checksum.sha256(of: storageDestination)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(
            try encoder.encode(metadata),
            to: directory.appendingPathComponent("metadata.json"),
            permissions: 0o600
        )
        return metadata
    }

    public func validate(profileID: UUID) throws -> SnapshotMetadata {
        let directory = profileDirectory(profileID)
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw AutoTypelessError.profileNotFound
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(SnapshotMetadata.self, from: Data(contentsOf: metadataURL))

        let authURL = directory.appendingPathComponent("user-data.json")
        let storageURL = directory.appendingPathComponent("app-storage.json")
        guard try Checksum.sha256(of: authURL) == metadata.authSHA256 else {
            throw AutoTypelessError.checksumMismatch("user-data.json")
        }
        guard try Checksum.sha256(of: storageURL) == metadata.appStorageSHA256 else {
            throw AutoTypelessError.checksumMismatch("app-storage.json")
        }
        return metadata
    }

    public func usage(profileID: UUID) throws -> AccountUsage {
        _ = try validate(profileID: profileID)
        return try UsageReader.read(
            from: profileDirectory(profileID).appendingPathComponent("app-storage.json")
        )
    }

    public func restore(profileID: UUID) throws {
        _ = try validate(profileID: profileID)
        let directory = profileDirectory(profileID)
        try AtomicFileWriter.copy(
            from: directory.appendingPathComponent("user-data.json"),
            to: paths.authFileURL
        )
        try AtomicFileWriter.copy(
            from: directory.appendingPathComponent("app-storage.json"),
            to: paths.appStorageURL
        )
    }

    public func createRecoveryPoint() throws -> URL {
        try validateRequiredLiveFiles()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let directory = paths.recoveryDirectory
            .appendingPathComponent(formatter.string(from: Date()) + "-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try AtomicFileWriter.copy(
            from: paths.authFileURL,
            to: directory.appendingPathComponent("user-data.json")
        )
        try AtomicFileWriter.copy(
            from: paths.appStorageURL,
            to: directory.appendingPathComponent("app-storage.json")
        )
        return directory
    }

    public func restoreRecoveryPoint(_ directory: URL) throws {
        try AtomicFileWriter.copy(
            from: directory.appendingPathComponent("user-data.json"),
            to: paths.authFileURL
        )
        try AtomicFileWriter.copy(
            from: directory.appendingPathComponent("app-storage.json"),
            to: paths.appStorageURL
        )
    }

    public func delete(profileID: UUID) throws {
        let directory = profileDirectory(profileID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    public func profileDirectory(_ profileID: UUID) -> URL {
        paths.profilesDirectory.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
    }

    private func validateRequiredLiveFiles() throws {
        for url in [paths.authFileURL, paths.appStorageURL] {
            guard fileManager.fileExists(atPath: url.path) else {
                throw AutoTypelessError.missingRequiredFile(url.path)
            }
        }
    }
}
