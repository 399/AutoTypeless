import Foundation

public struct AutoTypelessPaths: Sendable {
    public let typelessDataDirectory: URL
    public let stateDirectory: URL

    public init(typelessDataDirectory: URL, stateDirectory: URL) {
        self.typelessDataDirectory = typelessDataDirectory
        self.stateDirectory = stateDirectory
    }

    public static func live(fileManager: FileManager = .default) -> AutoTypelessPaths {
        let home = fileManager.homeDirectoryForCurrentUser
        return AutoTypelessPaths(
            typelessDataDirectory: home
                .appendingPathComponent("Library/Application Support/Typeless", isDirectory: true),
            stateDirectory: home
                .appendingPathComponent("Library/Application Support/AutoTypeless", isDirectory: true)
        )
    }

    public var profilesDirectory: URL {
        stateDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    public var recoveryDirectory: URL {
        stateDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    public var registryURL: URL {
        stateDirectory.appendingPathComponent("profiles.json")
    }

    public var authFileURL: URL {
        typelessDataDirectory.appendingPathComponent("user-data.json")
    }

    public var appStorageURL: URL {
        typelessDataDirectory.appendingPathComponent("app-storage.json")
    }
}

public struct AccountIdentity: Codable, Equatable, Sendable {
    public let userID: String
    public let email: String
    public let displayName: String?

    public init(userID: String, email: String, displayName: String?) {
        self.userID = userID
        self.email = email
        self.displayName = displayName
    }

    public var maskedEmail: String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "***" }
        let local = parts[0]
        let visible = local.prefix(min(2, local.count))
        return "\(visible)***@\(parts[1])"
    }
}

public struct AccountUsage: Codable, Equatable, Sendable {
    public let roleName: String?
    public let subscriptionPlanName: String?
    public let totalWords: Int?
    public let weeklyWordLimit: Int?
    public let weeklyWordsUsed: Int?
    public let fetchedAt: Date?

    public init(
        roleName: String?,
        subscriptionPlanName: String?,
        totalWords: Int? = nil,
        weeklyWordLimit: Int? = nil,
        weeklyWordsUsed: Int? = nil,
        fetchedAt: Date? = nil
    ) {
        self.roleName = roleName
        self.subscriptionPlanName = subscriptionPlanName
        self.totalWords = totalWords
        self.weeklyWordLimit = weeklyWordLimit
        self.weeklyWordsUsed = weeklyWordsUsed
        self.fetchedAt = fetchedAt
    }

    public var weeklyWordsRemaining: Int? {
        guard let weeklyWordLimit, let weeklyWordsUsed else { return nil }
        return max(0, weeklyWordLimit - weeklyWordsUsed)
    }
}

public enum ProfileValidationStatus: String, Codable, Equatable, Sendable {
    case valid
    case suspectedExpired
}

public struct ProfileRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public let identity: AccountIdentity
    public var capturedAt: Date
    public var typelessVersion: String?
    public var validationStatus: ProfileValidationStatus?

    public init(
        id: UUID = UUID(),
        label: String,
        identity: AccountIdentity,
        capturedAt: Date = Date(),
        typelessVersion: String? = nil,
        validationStatus: ProfileValidationStatus? = nil
    ) {
        self.id = id
        self.label = label
        self.identity = identity
        self.capturedAt = capturedAt
        self.typelessVersion = typelessVersion
        self.validationStatus = validationStatus
    }

    public var effectiveValidationStatus: ProfileValidationStatus {
        validationStatus ?? .valid
    }
}

public struct ProfileRegistry: Codable, Equatable, Sendable {
    public var profiles: [ProfileRecord]
    public var activeProfileID: UUID?

    public init(profiles: [ProfileRecord] = [], activeProfileID: UUID? = nil) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }
}

public struct SnapshotMetadata: Codable, Equatable, Sendable {
    public let identity: AccountIdentity
    public let capturedAt: Date
    public let authSHA256: String
    public let appStorageSHA256: String

    public init(
        identity: AccountIdentity,
        capturedAt: Date,
        authSHA256: String,
        appStorageSHA256: String
    ) {
        self.identity = identity
        self.capturedAt = capturedAt
        self.authSHA256 = authSHA256
        self.appStorageSHA256 = appStorageSHA256
    }
}

public enum AutoTypelessError: LocalizedError, Equatable {
    case missingRequiredFile(String)
    case malformedAppStorage
    case missingIdentity
    case profileNotFound
    case duplicateIdentity
    case cannotDeleteActiveProfile
    case typelessStillRunning
    case typelessDidNotTerminate
    case typelessDidNotLaunch
    case identityMismatch(expected: String, actual: String?)
    case profileSuspectedExpired(profileID: UUID, email: String)
    case checksumMismatch(String)
    case unsafeLabel
    case liveMutationRequiresConfirmation
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingRequiredFile(let path):
            return "缺少必要文件：\(path)"
        case .malformedAppStorage:
            return "app-storage.json 格式无效"
        case .missingIdentity:
            return "无法从 Typeless 账号缓存识别 user_id 和 email"
        case .profileNotFound:
            return "未找到指定账号快照"
        case .duplicateIdentity:
            return "该 Typeless 账号已存在"
        case .cannotDeleteActiveProfile:
            return "不能删除当前正在使用的账号，请先切换到其他账号"
        case .typelessStillRunning:
            return "Typeless 正在运行，捕获快照前必须先正常退出"
        case .typelessDidNotTerminate:
            return "Typeless 未能在限定时间内完全退出"
        case .typelessDidNotLaunch:
            return "Typeless 未能正常启动"
        case .identityMismatch(let expected, let actual):
            return "切换后账号验证失败，预期 \(expected)，实际 \(actual ?? "无法识别")"
        case .profileSuspectedExpired(_, let email):
            return "账号 \(email) 的登录状态可能已失效"
        case .checksumMismatch(let file):
            return "快照校验失败：\(file)"
        case .unsafeLabel:
            return "账号名称不能为空，且不能包含路径分隔符"
        case .liveMutationRequiresConfirmation:
            return "真实切换必须显式传入 --apply"
        case .commandFailed(let message):
            return message
        }
    }
}
