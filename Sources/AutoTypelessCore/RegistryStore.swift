import Foundation

public struct RegistryStore {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load() throws -> ProfileRegistry {
        guard fileManager.fileExists(atPath: url.path) else {
            return ProfileRegistry()
        }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(ProfileRegistry.self, from: data)
    }

    public func save(_ registry: ProfileRegistry) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try Self.encoder.encode(registry)
        try AtomicFileWriter.write(data, to: url, permissions: 0o600)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum AtomicFileWriter {
    public static func write(_ data: Data, to destination: URL, permissions: Int) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    public static func copy(from source: URL, to destination: URL, permissions: Int = 0o600) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AutoTypelessError.missingRequiredFile(source.path)
        }
        let data = try Data(contentsOf: source)
        try write(data, to: destination, permissions: permissions)
    }
}
