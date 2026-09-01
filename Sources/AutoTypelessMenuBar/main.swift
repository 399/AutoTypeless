import AppKit
import AutoTypelessCore
import SwiftUI

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var keepInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(keepInMenuBar, forKey: "keepInMenuBar")
            NotificationCenter.default.post(name: .autoTypelessMenuBarPreferenceChanged, object: nil)
        }
    }
    @Published var profiles: [ProfileRecord] = []
    @Published var activeProfileID: UUID?
    @Published var currentIdentity: AccountIdentity?
    @Published var typelessRunning = false
    @Published var isLoading = false
    @Published var isWorking = false
    @Published var message: String?
    @Published var errorMessage: String?
    @Published var editorMode: AccountEditorMode?
    @Published var editingLabel = ""
    @Published var profilePendingDeletion: ProfileRecord?
    @Published var profilePendingRecovery: ProfileRecord?
    @Published var isRecoveryAlertPresented = false

    private let service = AutoTypelessService(
        paths: .live(),
        controller: TypelessController()
    )

    init() {
        keepInMenuBar = UserDefaults.standard.bool(forKey: "keepInMenuBar")
    }

    var activeProfile: ProfileRecord? {
        profiles.first { $0.id == activeProfileID }
    }

    var currentIdentityIsSaved: Bool {
        guard let currentIdentity else { return false }
        return profiles.contains { $0.identity.userID == currentIdentity.userID }
    }

    func refresh() {
        do {
            apply(try service.status())
            errorMessage = nil
        } catch {
            errorMessage = readable(error)
        }
    }

    func loadInitialStatus() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let status = try await Task.detached(priority: .userInitiated) {
                let service = AutoTypelessService(
                    paths: AutoTypelessPaths.live(),
                    controller: TypelessController()
                )
                return try service.status()
            }.value
            apply(status)
            errorMessage = nil
        } catch {
            errorMessage = readable(error)
        }
    }

    private func apply(_ status: (registry: ProfileRegistry, identity: AccountIdentity?, running: Bool)) {
        profiles = status.registry.profiles.sorted {
            $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        activeProfileID = status.registry.activeProfileID
        currentIdentity = status.identity
        typelessRunning = status.running
    }

    func beginAdd() {
        editingLabel = suggestedLabel()
        editorMode = currentIdentityIsSaved ? .refresh(activeProfile) : .add
    }

    func prepareNewAccount() {
        do {
            try TypelessController().launchNormally()
            message = "请在 Typeless 中退出当前账号并登录新账号，完成后回到这里点击“重新识别”"
        } catch {
            errorMessage = readable(error)
        }
    }

    func beginRename(_ profile: ProfileRecord) {
        editingLabel = profile.label
        editorMode = .rename(profile)
    }

    func submitEditor() {
        guard let mode = editorMode else { return }
        let label = editingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mode.requiresLabel || !label.isEmpty else {
            errorMessage = "账号名称不能为空"
            return
        }
        editorMode = nil
        switch mode {
        case .add:
            captureCurrent(label: label)
        case .refresh:
            refreshCurrentSnapshot()
        case .rename(let profile):
            rename(profile, label: label)
        }
    }

    func switchTo(_ profile: ProfileRecord) {
        guard !isWorking, profile.id != activeProfileID else { return }
        isWorking = true
        message = "正在切换到“\(profile.label)”…"
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            let backgroundService = AutoTypelessService(
                paths: AutoTypelessPaths.live(),
                controller: TypelessController()
            )
            do {
                let switched = try backgroundService.switchTo(profileID: profile.id)
                await MainActor.run {
                    self.message = "已切换到“\(switched.label)”"
                    self.isWorking = false
                    self.refresh()
                }
            } catch {
                let suspectedExpired: Bool
                if case AutoTypelessError.profileSuspectedExpired = error {
                    suspectedExpired = true
                } else {
                    suspectedExpired = false
                }
                await MainActor.run {
                    self.message = nil
                    self.isWorking = false
                    self.refresh()
                    if suspectedExpired {
                        self.profilePendingRecovery = profile
                        self.isRecoveryAlertPresented = true
                    } else {
                        self.errorMessage = self.readable(error)
                    }
                }
            }
        }
    }

    func prepareRecoveryLogin() {
        guard let profile = profilePendingRecovery else { return }
        isRecoveryAlertPresented = false
        do {
            try TypelessController().launchNormally()
            message = "请在 Typeless 中重新登录 \(profile.identity.maskedEmail)，完成后点击菜单中的“重新识别”"
        } catch {
            errorMessage = readable(error)
        }
    }

    func confirmRecoveredProfile() {
        guard let profile = profilePendingRecovery, !isWorking else { return }
        performBackground(message: "正在识别并更新“\(profile.label)”…") { service in
            let identity = try IdentityReader.read(from: AutoTypelessPaths.live().appStorageURL)
            guard identity.userID == profile.identity.userID else {
                throw AutoTypelessError.identityMismatch(expected: profile.identity.email, actual: identity.email)
            }
            let controller = TypelessController()
            try controller.terminate(timeout: 15)
            do {
                let updated = try service.refreshProfileSnapshot(profileID: profile.id)
                try controller.launch()
                return updated
            } catch {
                try? controller.launch()
                throw error
            }
        } success: { updated in
            self.profilePendingRecovery = nil
            self.isRecoveryAlertPresented = false
            return "恢复成功：“\(updated.label)”已更新登录状态并恢复正常"
        }
    }

    func postponeRecovery() {
        isRecoveryAlertPresented = false
        profilePendingRecovery = nil
        message = "已保留账号快照，账号仍标记为待验证；重新登录后点击“重新识别”即可恢复"
    }

    func requestDelete(_ profile: ProfileRecord) {
        guard profile.id != activeProfileID else {
            errorMessage = AutoTypelessError.cannotDeleteActiveProfile.localizedDescription
            return
        }
        profilePendingDeletion = profile
    }

    func confirmDelete() {
        guard let profile = profilePendingDeletion else { return }
        profilePendingDeletion = nil
        do {
            try service.delete(profileID: profile.id)
            message = "已删除“\(profile.label)”的本地快照"
            refresh()
        } catch {
            errorMessage = readable(error)
        }
    }

    func reidentifyCurrentAccount() {
        guard !isWorking else { return }
        refresh()
        guard let currentIdentity else {
            errorMessage = "未识别到已登录账号。请先在 Typeless 完成登录，再点击“重新识别”。"
            return
        }
        guard let profile = profiles.first(where: { $0.identity.userID == currentIdentity.userID }) else {
            message = "已识别到未保存账号 \(currentIdentity.maskedEmail)，可通过“添加”保存"
            return
        }
        guard profile.effectiveValidationStatus == .suspectedExpired else {
            message = "已识别当前账号“\(profile.label)”，登录状态正常"
            return
        }

        profilePendingRecovery = profile
        isRecoveryAlertPresented = false
        confirmRecoveredProfile()
    }

    func openTypeless() {
        do {
            try TypelessController().launchNormally()
            message = "已启动 Typeless"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
        } catch {
            errorMessage = readable(error)
        }
    }

    private func captureCurrent(label: String) {
        performBackground(message: "正在保存当前账号…") { service in
            let controller = TypelessController()
            try controller.terminate(timeout: 15)
            do {
                let profile = try service.captureCurrent(label: label)
                try controller.launch()
                return profile
            } catch {
                try? controller.launch()
                throw error
            }
        } success: { profile in
            "已添加“\(profile.label)”"
        }
    }

    private func refreshCurrentSnapshot() {
        performBackground(message: "正在重新获取当前账号…") { service in
            let controller = TypelessController()
            try controller.terminate(timeout: 15)
            do {
                guard let profile = try service.refreshActiveSnapshot() else {
                    throw AutoTypelessError.profileNotFound
                }
                try controller.launch()
                return profile
            } catch {
                try? controller.launch()
                throw error
            }
        } success: { profile in
            "已重新获取“\(profile.label)”"
        }
    }

    private func rename(_ profile: ProfileRecord, label: String) {
        do {
            try service.rename(profileID: profile.id, label: label)
            message = "已重命名为“\(label)”"
            refresh()
        } catch {
            errorMessage = readable(error)
        }
    }

    private func performBackground<Result: Sendable>(
        message workingMessage: String,
        operation: @escaping @Sendable (AutoTypelessService<TypelessController>) throws -> Result,
        success: @escaping @MainActor (Result) -> String
    ) {
        guard !isWorking else { return }
        isWorking = true
        message = workingMessage
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            let backgroundService = AutoTypelessService(
                paths: AutoTypelessPaths.live(),
                controller: TypelessController()
            )
            do {
                let result = try operation(backgroundService)
                await MainActor.run {
                    self.message = success(result)
                    self.isWorking = false
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.message = nil
                    self.errorMessage = self.readable(error)
                    self.isWorking = false
                    self.refresh()
                }
            }
        }
    }

    private func suggestedLabel() -> String {
        if let displayName = currentIdentity?.displayName, !displayName.isEmpty {
            return displayName
        }
        return "账号 \(profiles.count + 1)"
    }

    private func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

enum AccountEditorMode: Identifiable {
    case add
    case refresh(ProfileRecord?)
    case rename(ProfileRecord)

    var id: String {
        switch self {
        case .add: return "add"
        case .refresh: return "refresh"
        case .rename(let profile): return "rename-\(profile.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .add: return "添加当前登录账号"
        case .refresh: return "重新获取当前账号"
        case .rename: return "重命名账号"
        }
    }

    var actionTitle: String {
        switch self {
        case .add: return "保存账号"
        case .refresh: return "重新获取"
        case .rename: return "保存名称"
        }
    }

    var requiresLabel: Bool {
        switch self {
        case .add, .rename: return true
        case .refresh: return false
        }
    }
}

struct WindowCloseBehaviorConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureWindow(for: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func configureWindow(for view: NSView, coordinator: Coordinator) {
        guard let window = view.window, window.delegate !== coordinator else { return }
        coordinator.previousDelegate = window.delegate
        window.delegate = coordinator
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var previousDelegate: NSWindowDelegate?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard UserDefaults.standard.bool(forKey: "keepInMenuBar") else {
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }
            sender.orderOut(nil)
            return false
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: MenuBarModel

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "AutoTypeless v\(version) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            accountList
            Divider()
            controls
            Toggle("关闭窗口后常驻状态栏", isOn: $model.keepInMenuBar)
                .toggleStyle(.switch)
                .disabled(model.isWorking)
            Text(model.keepInMenuBar ? "关闭窗口后继续运行，可从状态栏重新打开。" : "默认关闭窗口即退出 AutoTypeless。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Text(versionText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(minWidth: 480, idealWidth: 520, alignment: .topLeading)
        .background(WindowCloseBehaviorConfigurator().frame(width: 0, height: 0))
        .sheet(item: $model.editorMode) { mode in
            AccountEditorSheet(model: model, mode: mode)
        }
        .alert("删除账号快照？", isPresented: Binding(
            get: { model.profilePendingDeletion != nil },
            set: { if !$0 { model.profilePendingDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { model.profilePendingDeletion = nil }
            Button("删除", role: .destructive) { model.confirmDelete() }
        } message: {
            Text("只删除 AutoTypeless 保存的本地会话快照，不会删除 Typeless 账号。删除后如需恢复，必须重新手动登录并添加。")
        }
        .alert("账号登录状态可能已失效", isPresented: $model.isRecoveryAlertPresented) {
            Button("重新登录") { model.prepareRecoveryLogin() }
            Button("立即重新识别") { model.confirmRecoveredProfile() }
            Button("稍后处理", role: .cancel) { model.postponeRecovery() }
        } message: {
            if let profile = model.profilePendingRecovery {
                Text("Typeless 未能验证“\(profile.label)”（\(profile.identity.maskedEmail)）的登录身份。原快照不会被自动覆盖或删除。选择“重新登录”后，在 Typeless 登录同一账号，再回到菜单点击“重新识别”；成功后会自动更新快照并清除待验证状态。")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.typelessRunning ? "waveform.circle.fill" : "waveform.circle")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeProfile?.label ?? "未识别账号")
                    .font(.headline)
                Text(model.currentIdentity?.maskedEmail ?? "无法识别当前登录账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading || model.isWorking {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("我的账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.beginAdd()
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(model.isWorking)
                .help(model.currentIdentityIsSaved ? "重新获取当前账号，或先去 Typeless 登录新账号" : "保存当前登录账号")
            }

            if model.profiles.isEmpty {
                Text("尚未保存账号")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.profiles, id: \.id) { profile in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            model.switchTo(profile)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: profile.id == model.activeProfileID ? "checkmark.circle.fill" : "circle")
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.label)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text(profile.identity.maskedEmail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if profile.effectiveValidationStatus == .suspectedExpired {
                                        Label("登录状态待验证", systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isWorking || profile.id == model.activeProfileID)

                        Menu {
                            Button("重命名") { model.beginRename(profile) }
                            Button("删除快照", role: .destructive) { model.requestDelete(profile) }
                                .disabled(profile.id == model.activeProfileID)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(model.isWorking)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("重新识别") { model.reidentifyCurrentAccount() }
                Button("打开 Typeless") { model.openTypeless() }
                Spacer()
                Button("退出工具") { NSApplication.shared.terminate(nil) }
            }
        }
        .disabled(model.isWorking)
    }
}

struct AccountEditorSheet: View {
    @ObservedObject var model: MenuBarModel
    let mode: AccountEditorMode
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.title).font(.headline)
            switch mode {
            case .add:
                Text("已识别到一个未保存的 Typeless 账号。确认名称后保存；保存时 Typeless 会短暂退出，完成后自动重新启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .refresh:
                Text("当前账号已经保存。你可以重新获取它的最新登录状态；如需添加新账号，请先打开 Typeless，退出当前账号并登录新账号，再回到菜单栏点击“重新识别”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开 Typeless，登录新账号") {
                    model.editorMode = nil
                    model.prepareNewAccount()
                }
            case .rename:
                EmptyView()
            }
            if case .refresh = mode {
                EmptyView()
            } else {
                TextField("账号名称", text: $model.editingLabel)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.submitEditor() }
            }
            HStack {
                Spacer()
                Button("取消") { model.editorMode = nil }
                Button(mode.actionTitle) { model.submitEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode.requiresLabel && model.editingLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}

extension Notification.Name {
    static let autoTypelessMenuBarPreferenceChanged = Notification.Name("AutoTypelessMenuBarPreferenceChanged")
}

@MainActor
final class AutoTypelessAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var model: MenuBarModel?

    func configure(model: MenuBarModel) {
        self.model = model
        rebuildStatusMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatusItem),
            name: .autoTypelessMenuBarPreferenceChanged,
            object: nil
        )
        updateStatusItem()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "keepInMenuBar")
    }

    @objc private func updateStatusItem() {
        let shouldShow = UserDefaults.standard.bool(forKey: "keepInMenuBar")
        if shouldShow, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "AutoTypeless")
            statusItem = item
            rebuildStatusMenu()
        } else if !shouldShow, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        model?.refresh()
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.delegate = self

        if let model {
            let identityTitle = model.activeProfile.map { "当前账号：\($0.label)" } ?? "当前账号：未识别"
            let identityItem = NSMenuItem(title: identityTitle, action: nil, keyEquivalent: "")
            identityItem.isEnabled = false
            menu.addItem(identityItem)

            if let email = model.currentIdentity?.maskedEmail {
                let emailItem = NSMenuItem(title: email, action: nil, keyEquivalent: "")
                emailItem.isEnabled = false
                menu.addItem(emailItem)
            }

            menu.addItem(.separator())
            if model.profiles.isEmpty {
                let emptyItem = NSMenuItem(title: "尚未保存账号", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                menu.addItem(emptyItem)
            } else {
                for profile in model.profiles {
                    let item = NSMenuItem(title: profile.label, action: #selector(switchAccount(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = profile.id.uuidString
                    item.state = profile.id == model.activeProfileID ? .on : .off
                    item.isEnabled = !model.isWorking && profile.id != model.activeProfileID
                    menu.addItem(item)
                }
            }
            menu.addItem(.separator())
        }

        addMenuItem("打开 AutoTypeless", action: #selector(openMainWindow), to: menu)
        addMenuItem("重新识别", action: #selector(reidentifyAccount), to: menu)
        addMenuItem("打开 Typeless", action: #selector(openTypeless), to: menu)
        menu.addItem(.separator())
        addMenuItem("退出 AutoTypeless", action: #selector(quitApplication), to: menu)
        statusItem.menu = menu
    }

    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID),
              let profile = model?.profiles.first(where: { $0.id == id }) else { return }
        model?.switchTo(profile)
    }

    @objc private func reidentifyAccount() {
        model?.reidentifyCurrentAccount()
    }

    @objc private func openTypeless() {
        model?.openTypeless()
    }

    @objc private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}

@main
struct AutoTypelessMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AutoTypelessAppDelegate.self) private var appDelegate
    @StateObject private var model = MenuBarModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MenuBarContent(model: model)
                .task {
                    appDelegate.configure(model: model)
                    await model.loadInitialStatus()
                    appDelegate.configure(model: model)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

    }
}
