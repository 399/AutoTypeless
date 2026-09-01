import Foundation

public enum UsageReader {
    public static func read(from appStorageURL: URL) throws -> AccountUsage {
        guard FileManager.default.fileExists(atPath: appStorageURL.path) else {
            throw AutoTypelessError.missingRequiredFile(appStorageURL.path)
        }

        let data = try Data(contentsOf: appStorageURL)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let userData = root["userData"] as? [String: Any]
        else {
            throw AutoTypelessError.malformedAppStorage
        }

        let role = userData["role"] as? [String: Any]
        return AccountUsage(
            roleName: stringValue(role?["name"]),
            subscriptionPlanName: stringValue(userData["subscription_plan_name"])
        )
    }

    public static func readAPIResponse(
        _ data: Data,
        base: AccountUsage? = nil,
        fetchedAt: Date = Date()
    ) throws -> AccountUsage {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let responseData = root["data"] as? [String: Any],
            let voice = responseData["voice_transcription"] as? [String: Any]
        else {
            throw AutoTypelessError.commandFailed("Typeless 用量响应格式无效")
        }

        return AccountUsage(
            roleName: base?.roleName,
            subscriptionPlanName: base?.subscriptionPlanName,
            totalWords: intValue(voice["total_words"]),
            weeklyWordLimit: intValue(voice["week_word_usage_limit"]),
            weeklyWordsUsed: intValue(voice["week_word_usage_value"]),
            fetchedAt: fetchedAt
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty {
            return value
        }
        return nil
    }
}

public struct UsageCacheStore: Sendable {
    public let directory: URL

    public init(stateDirectory: URL) {
        self.directory = stateDirectory.appendingPathComponent("Usage", isDirectory: true)
    }

    public func load(profileID: UUID) throws -> AccountUsage? {
        let url = fileURL(profileID: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AccountUsage.self, from: Data(contentsOf: url))
    }

    public func save(_ usage: AccountUsage, profileID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(profileID: profileID)
        try JSONEncoder().encode(usage).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func fileURL(profileID: UUID) -> URL {
        directory.appendingPathComponent("\(profileID.uuidString).json")
    }
}
