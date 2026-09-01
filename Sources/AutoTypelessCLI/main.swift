import AutoTypelessCore
import Foundation

@main
struct AutoTypelessCLI {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("错误：\(message)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        let paths = AutoTypelessPaths.live()
        let service = AutoTypelessService(paths: paths, controller: TypelessController())

        switch command {
        case "status":
            let status = try service.status()
            print("Typeless：\(status.running ? "运行中" : "未运行")")
            if let identity = status.identity {
                print("当前账号：\(identity.maskedEmail)")
            } else {
                print("当前账号：无法识别")
            }
            print("已保存账号：\(status.registry.profiles.count)")
            if let activeID = status.registry.activeProfileID,
               let active = status.registry.profiles.first(where: { $0.id == activeID }) {
                print("活动快照：\(active.label)")
            }

        case "list":
            let registry = try service.registryStore.load()
            if registry.profiles.isEmpty {
                print("尚未保存账号快照")
                return
            }
            for profile in registry.profiles {
                let active = registry.activeProfileID == profile.id ? " *" : ""
                print("\(profile.id.uuidString.lowercased())\t\(profile.label)\t\(profile.identity.maskedEmail)\(active)")
            }

        case "capture":
            let label = try requiredValue(after: "--label", in: arguments)
            guard arguments.contains("--apply") else {
                throw AutoTypelessError.liveMutationRequiresConfirmation
            }
            let profile = try service.captureCurrent(label: label)
            print("已保存账号：\(profile.label)（\(profile.identity.maskedEmail)）")
            print("快照 ID：\(profile.id.uuidString.lowercased())")

        case "switch":
            let id = try requiredUUID(after: "--id", in: arguments)
            let plan = try service.planSwitch(profileID: id)
            if !arguments.contains("--apply") {
                print("计划切换到：\(plan.target.label)（\(plan.target.identity.maskedEmail)）")
                if let current = plan.currentIdentity {
                    print("当前账号：\(current.maskedEmail)")
                }
                for (index, operation) in plan.operations.enumerated() {
                    print("\(index + 1). \(operation)")
                }
                print("这是预演，未修改任何文件。确认后追加 --apply。")
                return
            }
            let profile = try service.switchTo(profileID: id)
            print("已切换到：\(profile.label)（\(profile.identity.maskedEmail)）")

        case "usage":
            let data = try waitForAsync { try await LiveUsageFetcher.fetch(timeout: 30) }
            let usage = try UsageReader.readAPIResponse(data)
            if let used = usage.weeklyWordsUsed, let limit = usage.weeklyWordLimit, let remaining = usage.weeklyWordsRemaining {
                print("本周已用：\(used)/\(limit) 字")
                print("本周剩余：\(remaining)/\(limit) 字")
            } else {
                print("已获取用量，但响应中没有每周字数额度")
            }

        case "usage-json":
            let data = try waitForAsync { try await LiveUsageFetcher.fetch(timeout: 30) }
            FileHandle.standardOutput.write(data)

        case "rename":
            let id = try requiredUUID(after: "--id", in: arguments)
            let label = try requiredValue(after: "--label", in: arguments)
            guard arguments.contains("--apply") else {
                throw AutoTypelessError.liveMutationRequiresConfirmation
            }
            try service.rename(profileID: id, label: label)
            print("账号名称已更新")

        case "delete":
            let id = try requiredUUID(after: "--id", in: arguments)
            guard arguments.contains("--apply") else {
                throw AutoTypelessError.liveMutationRequiresConfirmation
            }
            try service.delete(profileID: id)
            print("账号快照已删除；未执行 Typeless 服务端退出登录")

        case "help", "--help", "-h":
            printHelp()

        default:
            throw AutoTypelessError.commandFailed("未知命令：\(command)")
        }
    }

    private static func waitForAsync<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResult<T>()
        Task {
            do {
                result.set(.success(try await operation()))
            } catch {
                result.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get().get()
    }

    private static func requiredValue(after option: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            throw AutoTypelessError.commandFailed("缺少参数 \(option)")
        }
        return arguments[index + 1]
    }

    private static func requiredUUID(after option: String, in arguments: [String]) throws -> UUID {
        let value = try requiredValue(after: option, in: arguments)
        guard let id = UUID(uuidString: value) else {
            throw AutoTypelessError.commandFailed("无效的快照 ID")
        }
        return id
    }

    private static func printHelp() {
        print("""
        AutoTypeless 阶段二命令行 PoC

        autotypeless status
        autotypeless list
        autotypeless capture --label <名称> --apply
        autotypeless switch --id <快照ID>              # 仅预演
        autotypeless switch --id <快照ID> --apply      # 真实切换
        autotypeless rename --id <快照ID> --label <名称> --apply
        autotypeless delete --id <快照ID> --apply

        安全约束：
        - capture 要求 Typeless 已完全退出。
        - switch 默认只显示计划，只有 --apply 才会修改真实会话文件。
        - 不读取或输出 token、Cookie、密码、录音及转写内容。
        """)
    }
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func set(_ value: Result<Value, Error>) {
        lock.withLock { self.value = value }
    }

    func get() -> Result<Value, Error> {
        lock.withLock { value! }
    }
}
