import Foundation

public struct SnapshotStore {
    public let paths: AutoTypelessPaths
    private let fileManager: FileManager

    public init(paths: AutoTypelessPaths, fileManager: FileManager = .default) { self.paths = paths; self.fileManager = fileManager }

    public func capture(profile: ProfileRecord) throws -> SnapshotMetadata {
        try validateRequiredLiveFiles()
        let directory = profileDirectory(profile.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let auth = directory.appendingPathComponent("user-data.json")
        let storage = directory.appendingPathComponent("app-storage.json")
        try AtomicFileWriter.copy(from: paths.authFileURL, to: auth)
        try AtomicFileWriter.copy(from: paths.appStorageURL, to: storage)
        let metadata = SnapshotMetadata(identity: profile.identity, capturedAt: Date(), authSHA256: try Checksum.sha256(of: auth), appStorageSHA256: try Checksum.sha256(of: storage))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(try encoder.encode(metadata), to: directory.appendingPathComponent("metadata.json"), permissions: 0o600)
        return metadata
    }

    public func validate(profileID: UUID) throws -> SnapshotMetadata {
        let directory = profileDirectory(profileID)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(SnapshotMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        guard try Checksum.sha256(of: directory.appendingPathComponent("user-data.json")) == metadata.authSHA256 else { throw AutoTypelessError.checksumMismatch("user-data.json") }
        guard try Checksum.sha256(of: directory.appendingPathComponent("app-storage.json")) == metadata.appStorageSHA256 else { throw AutoTypelessError.checksumMismatch("app-storage.json") }
        return metadata
    }

    public func restore(profileID: UUID) throws {
        _ = try validate(profileID: profileID)
        let directory = profileDirectory(profileID)
        try AtomicFileWriter.copy(from: directory.appendingPathComponent("user-data.json"), to: paths.authFileURL)
        try AtomicFileWriter.copy(from: directory.appendingPathComponent("app-storage.json"), to: paths.appStorageURL)
    }

    public func createRecoveryPoint() throws -> URL {
        try validateRequiredLiveFiles()
        let directory = paths.recoveryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try AtomicFileWriter.copy(from: paths.authFileURL, to: directory.appendingPathComponent("user-data.json"))
        try AtomicFileWriter.copy(from: paths.appStorageURL, to: directory.appendingPathComponent("app-storage.json"))
        return directory
    }

    public func restoreRecoveryPoint(_ directory: URL) throws {
        try AtomicFileWriter.copy(from: directory.appendingPathComponent("user-data.json"), to: paths.authFileURL)
        try AtomicFileWriter.copy(from: directory.appendingPathComponent("app-storage.json"), to: paths.appStorageURL)
    }

    public func delete(profileID: UUID) throws { let directory = profileDirectory(profileID); if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) } }
    public func profileDirectory(_ profileID: UUID) -> URL { paths.profilesDirectory.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true) }

    private func validateRequiredLiveFiles() throws {
        for url in [paths.authFileURL, paths.appStorageURL] where !fileManager.fileExists(atPath: url.path) { throw AutoTypelessError.missingRequiredFile(url.path) }
    }
}
