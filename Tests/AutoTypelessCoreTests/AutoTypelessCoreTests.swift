import Foundation
import Testing
@testable import AutoTypelessCore

@Suite("AutoTypelessCore")
struct AutoTypelessCoreTests {
    @Test("读取账号身份但不依赖其他个人字段")
    func readsIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha")

        let identity = try IdentityReader.read(from: fixture.paths.appStorageURL)
        #expect(identity.userID == "u-1")
        #expect(identity.email == "alpha@example.com")
        #expect(identity.maskedEmail == "al***@example.com")
    }

    @Test("只读取账号套餐，不把现金余额误认作字数额度")
    func readsUsage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha")

        let usage = try UsageReader.read(from: fixture.paths.appStorageURL)
        #expect(usage.roleName == "member")
        #expect(usage.subscriptionPlanName == nil)
    }

    @Test("解析 Typeless 真实每周用量响应")
    func readsLiveUsageResponse() throws {
        let data = Data("""
        {"status":"OK","data":{"voice_transcription":{"total_words":23,"week_word_usage_limit":8000,"week_word_usage_value":23}}}
        """.utf8)
        let fetchedAt = Date(timeIntervalSince1970: 100)
        let usage = try UsageReader.readAPIResponse(data, fetchedAt: fetchedAt)
        #expect(usage.totalWords == 23)
        #expect(usage.weeklyWordLimit == 8000)
        #expect(usage.weeklyWordsUsed == 23)
        #expect(usage.weeklyWordsRemaining == 7977)
        #expect(usage.fetchedAt == fetchedAt)
    }

    @Test("保存并读取联网用量缓存")
    func cachesLiveUsage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let profileID = UUID()
        let store = UsageCacheStore(stateDirectory: fixture.paths.stateDirectory)
        let usage = AccountUsage(roleName: "free", subscriptionPlanName: nil, totalWords: 23, weeklyWordLimit: 8000, weeklyWordsUsed: 23, fetchedAt: Date(timeIntervalSince1970: 100))
        try store.save(usage, profileID: profileID)
        #expect(try store.load(profileID: profileID) == usage)
    }

    @Test("捕获与恢复只影响两个会话文件")
    func capturesAndRestoresMinimalSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha")
        let protectedURL = fixture.paths.typelessDataDirectory.appendingPathComponent("typeless.db")
        try Data("history-must-stay".utf8).write(to: protectedURL)

        let service = fixture.service
        let profile = try service.captureCurrent(label: "Alpha")

        try fixture.writeLive(userID: "u-2", email: "beta@example.com", auth: "auth-beta")
        try service.snapshotStore.restore(profileID: profile.id)

        #expect(try String(contentsOf: fixture.paths.authFileURL, encoding: .utf8) == "auth-alpha")
        #expect(try IdentityReader.read(from: fixture.paths.appStorageURL).userID == "u-1")
        #expect(try String(contentsOf: protectedURL, encoding: .utf8) == "history-must-stay")
    }

    @Test("切换时保存离开账号最新状态")
    func switchRefreshesCurrentSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha-v1")
        let alpha = try fixture.service.captureCurrent(label: "Alpha")

        try fixture.writeLive(userID: "u-2", email: "beta@example.com", auth: "auth-beta-v1")
        let beta = try fixture.service.captureCurrent(label: "Beta")

        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha-v2")
        _ = try fixture.service.switchTo(profileID: beta.id)
        #expect(try String(contentsOf: fixture.paths.authFileURL, encoding: .utf8) == "auth-beta-v1")

        _ = try fixture.service.switchTo(profileID: alpha.id)
        #expect(try String(contentsOf: fixture.paths.authFileURL, encoding: .utf8) == "auth-alpha-v2")
    }

    @Test("目标快照损坏时拒绝切换且不改活动文件")
    func rejectsCorruptSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha")
        let profile = try fixture.service.captureCurrent(label: "Alpha")
        let authSnapshot = fixture.service.snapshotStore
            .profileDirectory(profile.id)
            .appendingPathComponent("user-data.json")
        try Data("tampered".utf8).write(to: authSnapshot)

        try fixture.writeLive(userID: "u-2", email: "beta@example.com", auth: "auth-beta")
        #expect(throws: AutoTypelessError.checksumMismatch("user-data.json")) {
            try fixture.service.switchTo(profileID: profile.id)
        }
        #expect(try String(contentsOf: fixture.paths.authFileURL, encoding: .utf8) == "auth-beta")
    }

    @Test("支持重命名并禁止删除当前账号")
    func managesProfilesSafely() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha")
        let alpha = try fixture.service.captureCurrent(label: "Alpha")

        try fixture.service.rename(profileID: alpha.id, label: "Main")
        #expect(try fixture.service.registryStore.load().profiles.first?.label == "Main")
        #expect(throws: AutoTypelessError.cannotDeleteActiveProfile) {
            try fixture.service.delete(profileID: alpha.id)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.service.snapshotStore.profileDirectory(alpha.id).path))
    }

    @Test("非当前账号可删除快照")
    func deletesInactiveProfile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha")
        let alpha = try fixture.service.captureCurrent(label: "Alpha")
        try fixture.writeLive(userID: "u-2", email: "beta@example.com", auth: "auth-beta")
        _ = try fixture.service.captureCurrent(label: "Beta")

        try fixture.service.delete(profileID: alpha.id)
        let registry = try fixture.service.registryStore.load()
        #expect(!registry.profiles.contains { $0.id == alpha.id })
        #expect(!FileManager.default.fileExists(atPath: fixture.service.snapshotStore.profileDirectory(alpha.id).path))
    }

    @Test("当前处于登录页时仍可切换到已保存账号")
    func switchesFromSignedOutState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha")
        let alpha = try fixture.service.captureCurrent(label: "Alpha")

        try Data("signed-out-auth".utf8).write(to: fixture.paths.authFileURL)
        try Data("{\"currentRoute\":null}".utf8).write(to: fixture.paths.appStorageURL)

        _ = try fixture.service.switchTo(profileID: alpha.id)
        #expect(fixture.controller.isRunning())
        #expect(try String(contentsOf: fixture.paths.authFileURL, encoding: .utf8) == "auth-alpha")
        #expect(try IdentityReader.read(from: fixture.paths.appStorageURL).userID == "u-1")
    }

    @Test("可标记疑似失效并在同账号重新登录后更新快照")
    func recoversSuspectedExpiredProfile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha-old")
        let alpha = try fixture.service.captureCurrent(label: "Alpha")

        let marked = try fixture.service.markSuspectedExpired(profileID: alpha.id)
        #expect(marked.effectiveValidationStatus == .suspectedExpired)

        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha-new")
        let updated = try fixture.service.refreshProfileSnapshot(profileID: alpha.id)
        #expect(updated.effectiveValidationStatus == .valid)
        let persisted = try fixture.service.registryStore.load().profiles.first { $0.id == alpha.id }
        #expect(persisted?.effectiveValidationStatus == .valid)
        #expect(try fixture.service.registryStore.load().activeProfileID == alpha.id)
        let snapshotAuth = fixture.service.snapshotStore.profileDirectory(alpha.id).appendingPathComponent("user-data.json")
        #expect(try String(contentsOf: snapshotAuth, encoding: .utf8) == "auth-alpha-new")
    }

    @Test("其他账号不能覆盖待恢复账号快照")
    func rejectsRecoveryWithDifferentIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha")
        let alpha = try fixture.service.captureCurrent(label: "Alpha")
        _ = try fixture.service.markSuspectedExpired(profileID: alpha.id)

        try fixture.writeLive(userID: "u-2", email: "beta@example.com", auth: "auth-beta")
        #expect(throws: AutoTypelessError.identityMismatch(expected: "alpha@example.com", actual: "beta@example.com")) {
            try fixture.service.refreshProfileSnapshot(profileID: alpha.id)
        }
        let snapshotAuth = fixture.service.snapshotStore.profileDirectory(alpha.id).appendingPathComponent("user-data.json")
        #expect(try String(contentsOf: snapshotAuth, encoding: .utf8) == "auth-alpha")
    }

    @Test("目标身份不匹配时自动回滚")
    func rollsBackOnIdentityMismatch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLive(userID: "u-1", email: "alpha@example.com", auth: "auth-alpha")
        let profile = try fixture.service.captureCurrent(label: "Alpha")

        let snapshotStorage = fixture.service.snapshotStore
            .profileDirectory(profile.id)
            .appendingPathComponent("app-storage.json")
        try fixture.writeStorage(to: snapshotStorage, userID: "wrong-user", email: "wrong@example.com")
        try fixture.rewriteMetadata(for: profile.id)

        try fixture.writeLive(userID: "u-2", email: "beta@example.com", auth: "auth-beta")
        #expect(throws: AutoTypelessError.identityMismatch(expected: "u-1", actual: "wrong-user")) {
            try fixture.service.switchTo(profileID: profile.id)
        }
        #expect(try String(contentsOf: fixture.paths.authFileURL, encoding: .utf8) == "auth-beta")
        #expect(try IdentityReader.read(from: fixture.paths.appStorageURL).userID == "u-2")
    }
}

private final class Fixture {
    let root: URL
    let paths: AutoTypelessPaths
    let controller = FakeController()
    lazy var service = AutoTypelessService(paths: paths, controller: controller)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoTypelessTests-\(UUID().uuidString)", isDirectory: true)
        paths = AutoTypelessPaths(
            typelessDataDirectory: root.appendingPathComponent("Typeless", isDirectory: true),
            stateDirectory: root.appendingPathComponent("AutoTypeless", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: paths.typelessDataDirectory,
            withIntermediateDirectories: true
        )
    }

    func writeLive(userID: String, email: String, auth: String) throws {
        try Data(auth.utf8).write(to: paths.authFileURL)
        try writeStorage(to: paths.appStorageURL, userID: userID, email: email)
    }

    func writeStorage(to url: URL, userID: String, email: String) throws {
        let object: [String: Any] = [
            "currentRoute": "/home",
            "userData": [
                "user_id": userID,
                "email": email,
                "name": "Fixture User",
                "cash_credit_balance": 123,
                "cash_credit_updated_at": "2026-08-25T08:09:09.869000+00:00",
                "role": ["name": "member"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    func rewriteMetadata(for profileID: UUID) throws {
        let directory = service.snapshotStore.profileDirectory(profileID)
        let identity = try IdentityReader.read(from: directory.appendingPathComponent("app-storage.json"))
        let metadata = SnapshotMetadata(
            identity: identity,
            capturedAt: Date(),
            authSHA256: try Checksum.sha256(of: directory.appendingPathComponent("user-data.json")),
            appStorageSHA256: try Checksum.sha256(of: directory.appendingPathComponent("app-storage.json"))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FakeController: @unchecked Sendable, TypelessControlling {
    private let lock = NSLock()
    private var running = false

    func isRunning() -> Bool {
        lock.withLock { running }
    }

    func terminate(timeout: TimeInterval) throws {
        lock.withLock { running = false }
    }

    func launch() throws {
        lock.withLock { running = true }
    }

    func waitUntilRunning(timeout: TimeInterval) -> Bool {
        isRunning()
    }
}
