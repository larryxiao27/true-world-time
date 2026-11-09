import Combine
import ServiceManagement

@MainActor protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

@MainActor private struct SystemLoginItemService: LoginItemServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemServicing

    init() { service = SystemLoginItemService() }
    init(service: any LoginItemServicing) { self.service = service }

    var requested: Bool { status == .enabled || status == .requiresApproval }
    var statusText: String {
        switch status {
        case .enabled: return "登录后静默运行，手动打开才显示设置"
        case .requiresApproval: return "等待系统允许，登录启动尚未生效"
        case .notFound: return "请将 App 安装到「应用程序」后再开启"
        case .notRegistered: return "开启后，登录 Mac 时自动在后台运行"
        @unknown default: return "暂时无法读取登录启动状态"
        }
    }
    func refresh() { status = service.status }
    func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false; refresh() }
        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound { try service.register() }
            } else if service.status != .notRegistered {
                try await service.unregister()
            }
        } catch { errorMessage = "未能更改登录启动：" + error.localizedDescription }
    }
    func openSettings() { service.openSettings() }
}
