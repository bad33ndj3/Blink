import ServiceManagement

enum LaunchAtLogin {
    static func register() {
        guard SMAppService.mainApp.status == .notRegistered else { return }
        try? SMAppService.mainApp.register()
    }
}
