import AppKit
import Foundation

public protocol TypelessControlling: Sendable {
    func isRunning() -> Bool
    func terminate(timeout: TimeInterval) throws
    func launch() throws
    func waitUntilRunning(timeout: TimeInterval) -> Bool
}

private final class LockedLaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var application: NSRunningApplication?
    private var error: Error?
    func store(application: NSRunningApplication?, error: Error?) { lock.withLock { self.application = application; self.error = error } }
    func load() -> (application: NSRunningApplication?, error: Error?) { lock.withLock { (application, error) } }
}

public struct TypelessController: TypelessControlling {
    public let bundleIdentifier: String
    public let applicationURL: URL
    public init(bundleIdentifier: String = "now.typeless.desktop", applicationURL: URL = URL(fileURLWithPath: "/Applications/Typeless.app", isDirectory: true)) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL
    }
    public func isRunning() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty }
    public func terminate(timeout: TimeInterval = 15) throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !applications.isEmpty else { return }
        for application in applications { application.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw AutoTypelessError.typelessDidNotTerminate
    }
    public func launch() throws { try launchNormally() }
    public func launchNormally() throws { try launch(arguments: []) }
    private func launch(arguments: [String]) throws {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else { throw AutoTypelessError.commandFailed("未找到 Typeless 应用：\(applicationURL.path)") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true
        configuration.addsToRecentItems = false
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedLaunchResult()
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in result.store(application: application, error: error); semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 15) == .success else { throw AutoTypelessError.commandFailed("启动 Typeless 超时") }
        let launchResult = result.load()
        if let error = launchResult.error { throw AutoTypelessError.commandFailed("无法启动 Typeless：\(error.localizedDescription)") }
        guard launchResult.application != nil else { throw AutoTypelessError.commandFailed("无法启动 Typeless") }
    }
    public func waitUntilRunning(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
