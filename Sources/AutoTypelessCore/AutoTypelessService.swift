import Foundation

public struct SwitchPlan: Equatable, Sendable {
    public let target: ProfileRecord
    public let currentIdentity: AccountIdentity?
    public let operations: [String]

    public init(target: ProfileRecord, currentIdentity: AccountIdentity?, operations: [String]) {
        self.target = target
        self.currentIdentity = currentIdentity
        self.operations = operations
    }
}

public struct AutoTypelessService<Controller: TypelessControlling> {
    public let paths: AutoTypelessPaths
    public let controller: Controller
    public let registryStore: RegistryStore
    public let snapshotStore: SnapshotStore

    public init(paths: AutoTypelessPaths, controller: Controller) {
        self.paths = paths
        self.controller = controller
        self.registryStore = RegistryStore(url: paths.registryURL)
        self.snapshotStore = SnapshotStore(paths: paths)
    }

    public func status() throws -> (registry: ProfileRegistry, identity: AccountIdentity?, running: Bool) {
        let registry = try registryStore.load()
        let identity = try? IdentityReader.read(from: paths.appStorageURL)
        return (registry, identity, controller.isRunning())
    }

    public func captureCurrent(label: String, typelessVersion: String? = nil) throws -> ProfileRecord {
        try validateLabel(label)
        guard !controller.isRunning() else {
            throw AutoTypelessError.typelessStillRunning
        }
        let identity = try IdentityReader.read(from: paths.appStorageURL)
        var registry = try registryStore.load()
        guard !registry.profiles.contains(where: { $0.identity.userID == identity.userID }) else {
            throw AutoTypelessError.duplicateIdentity
        }

        var profile = ProfileRecord(label: label, identity: identity, typelessVersion: typelessVersion)
        let metadata = try snapshotStore.capture(profile: profile)
        profile.capturedAt = metadata.capturedAt
        registry.profiles.append(profile)
        registry.activeProfileID = profile.id
        try registryStore.save(registry)
        return profile
    }

    public func refreshActiveSnapshot() throws -> ProfileRecord? {
        guard !controller.isRunning() else {
            throw AutoTypelessError.typelessStillRunning
        }
        let identity = try IdentityReader.read(from: paths.appStorageURL)
        var registry = try registryStore.load()
        guard let index = registry.profiles.firstIndex(where: { $0.identity.userID == identity.userID }) else {
            return nil
        }
        var profile = registry.profiles[index]
        let metadata = try snapshotStore.capture(profile: profile)
        profile.capturedAt = metadata.capturedAt
        registry.profiles[index] = profile
        registry.activeProfileID = profile.id
        try registryStore.save(registry)
        return profile
    }

    public func planSwitch(profileID: UUID) throws -> SwitchPlan {
        let registry = try registryStore.load()
        guard let target = registry.profiles.first(where: { $0.id == profileID }) else {
            throw AutoTypelessError.profileNotFound
        }
        _ = try snapshotStore.validate(profileID: profileID)
        let currentIdentity = try? IdentityReader.read(from: paths.appStorageURL)
        return SwitchPlan(
            target: target,
            currentIdentity: currentIdentity,
            operations: [
                "请求 Typeless 正常退出并等待进程结束",
                "保存当前活动账号的最新会话快照（如已登记）",
                "创建切换前恢复点",
                "原子恢复目标账号的 user-data.json 与 app-storage.json",
                "重新启动 Typeless",
                "核对启动后的 user_id；失败时自动回滚"
            ]
        )
    }

    public func switchTo(profileID: UUID) throws -> ProfileRecord {
        var registry = try registryStore.load()
        guard let target = registry.profiles.first(where: { $0.id == profileID }) else {
            throw AutoTypelessError.profileNotFound
        }
        _ = try snapshotStore.validate(profileID: profileID)

        try controller.terminate(timeout: 15)
        var recovery: URL?

        do {
            recovery = try snapshotStore.createRecoveryPoint()
            // 登录页或损坏的当前缓存可能无法识别身份。此时不能让“保存离开账号”
            // 阻断目标账号恢复，更不能把刚退出的 Typeless 留在关闭状态。
            _ = try? refreshActiveSnapshot()
            try snapshotStore.restore(profileID: profileID)
            let restoredIdentity = try IdentityReader.read(from: paths.appStorageURL)
            guard restoredIdentity.userID == target.identity.userID else {
                throw AutoTypelessError.identityMismatch(
                    expected: target.identity.userID,
                    actual: restoredIdentity.userID
                )
            }
            try controller.launch()
            guard controller.waitUntilRunning(timeout: 15) else {
                throw AutoTypelessError.typelessDidNotLaunch
            }
            Thread.sleep(forTimeInterval: 2)
            guard let launchedIdentity = try? IdentityReader.read(from: paths.appStorageURL) else {
                registry.activeProfileID = target.id
                if let index = registry.profiles.firstIndex(where: { $0.id == target.id }) {
                    registry.profiles[index].validationStatus = .suspectedExpired
                }
                try registryStore.save(registry)
                throw AutoTypelessError.profileSuspectedExpired(profileID: target.id, email: target.identity.maskedEmail)
            }
            guard launchedIdentity.userID == target.identity.userID else {
                throw AutoTypelessError.identityMismatch(expected: target.identity.email, actual: launchedIdentity.email)
            }
            registry.activeProfileID = target.id
            if let index = registry.profiles.firstIndex(where: { $0.id == target.id }) {
                registry.profiles[index].validationStatus = .valid
            }
            try registryStore.save(registry)
            return registry.profiles.first(where: { $0.id == target.id }) ?? target
        } catch {
            try? controller.terminate(timeout: 10)
            if let recovery {
                try? snapshotStore.restoreRecoveryPoint(recovery)
            }
            try? controller.launch()
            throw error
        }
    }

    public func markSuspectedExpired(profileID: UUID) throws -> ProfileRecord {
        var registry = try registryStore.load()
        guard let index = registry.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AutoTypelessError.profileNotFound
        }
        registry.profiles[index].validationStatus = .suspectedExpired
        registry.activeProfileID = profileID
        try registryStore.save(registry)
        return registry.profiles[index]
    }

    public func refreshProfileSnapshot(profileID: UUID) throws -> ProfileRecord {
        guard !controller.isRunning() else {
            throw AutoTypelessError.typelessStillRunning
        }
        let identity = try IdentityReader.read(from: paths.appStorageURL)
        var registry = try registryStore.load()
        guard let index = registry.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AutoTypelessError.profileNotFound
        }
        let expected = registry.profiles[index].identity
        guard identity.userID == expected.userID else {
            throw AutoTypelessError.identityMismatch(expected: expected.email, actual: identity.email)
        }
        var profile = registry.profiles[index]
        let metadata = try snapshotStore.capture(profile: profile)
        profile.capturedAt = metadata.capturedAt
        profile.validationStatus = .valid
        registry.profiles[index] = profile
        registry.activeProfileID = profile.id
        try registryStore.save(registry)
        return profile
    }

    public func rename(profileID: UUID, label: String) throws {
        try validateLabel(label)
        var registry = try registryStore.load()
        guard let index = registry.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AutoTypelessError.profileNotFound
        }
        registry.profiles[index].label = label
        try registryStore.save(registry)
    }

    public func delete(profileID: UUID) throws {
        var registry = try registryStore.load()
        guard registry.profiles.contains(where: { $0.id == profileID }) else {
            throw AutoTypelessError.profileNotFound
        }
        if registry.activeProfileID == profileID {
            throw AutoTypelessError.cannotDeleteActiveProfile
        }
        registry.profiles.removeAll { $0.id == profileID }
        try snapshotStore.delete(profileID: profileID)
        try registryStore.save(registry)
    }

    private func validateLabel(_ label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else {
            throw AutoTypelessError.unsafeLabel
        }
    }
}
