import AutoTypelessCore
import Foundation

@main
struct AutoTypelessCLI {
    static func main() {
        do { try run(arguments: Array(CommandLine.arguments.dropFirst())) }
        catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("错误：\(message)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let command = arguments.first else { printHelp(); return }
        let service = AutoTypelessService(paths: .live(), controller: TypelessController())
        switch command {
        case "status":
            let status = try service.status()
            print("Typeless：\(status.running ? "运行中" : "未运行")")
            print("当前账号：\(status.identity?.maskedEmail ?? "无法识别")")
            print("已保存账号：\(status.registry.profiles.count)")
        case "list":
            let registry = try service.registryStore.load()
            for profile in registry.profiles {
                let active = registry.activeProfileID == profile.id ? " *" : ""
                print("\(profile.id.uuidString.lowercased())\t\(profile.label)\t\(profile.identity.maskedEmail)\(active)")
            }
        case "capture":
            let label = try requiredValue(after: "--label", in: arguments)
            guard arguments.contains("--apply") else { throw AutoTypelessError.liveMutationRequiresConfirmation }
            let profile = try service.captureCurrent(label: label)
            print("已保存账号：\(profile.label)（\(profile.identity.maskedEmail)）")
        case "switch":
            let id = try requiredUUID(after: "--id", in: arguments)
            if !arguments.contains("--apply") {
                let plan = try service.planSwitch(profileID: id)
                print("计划切换到：\(plan.target.label)（\(plan.target.identity.maskedEmail)）")
                for (index, operation) in plan.operations.enumerated() { print("\(index + 1). \(operation)") }
                print("这是预演，未修改任何文件。确认后追加 --apply。")
                return
            }
            let profile = try service.switchTo(profileID: id)
            print("已切换到：\(profile.label)（\(profile.identity.maskedEmail)）")
        case "rename":
            let id = try requiredUUID(after: "--id", in: arguments)
            let label = try requiredValue(after: "--label", in: arguments)
            guard arguments.contains("--apply") else { throw AutoTypelessError.liveMutationRequiresConfirmation }
            try service.rename(profileID: id, label: label)
        case "delete":
            let id = try requiredUUID(after: "--id", in: arguments)
            guard arguments.contains("--apply") else { throw AutoTypelessError.liveMutationRequiresConfirmation }
            try service.delete(profileID: id)
        case "help", "--help", "-h": printHelp()
        default: throw AutoTypelessError.commandFailed("未知命令：\(command)")
        }
    }

    private static func requiredValue(after option: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            throw AutoTypelessError.commandFailed("缺少参数 \(option)")
        }
        return arguments[index + 1]
    }

    private static func requiredUUID(after option: String, in arguments: [String]) throws -> UUID {
        guard let id = UUID(uuidString: try requiredValue(after: option, in: arguments)) else {
            throw AutoTypelessError.commandFailed("无效的快照 ID")
        }
        return id
    }

    private static func printHelp() {
        print("""
        AutoTypeless 命令行工具
        autotypeless status
        autotypeless list
        autotypeless capture --label <名称> --apply
        autotypeless switch --id <快照ID> [--apply]
        autotypeless rename --id <快照ID> --label <名称> --apply
        autotypeless delete --id <快照ID> --apply
        """)
    }
}
