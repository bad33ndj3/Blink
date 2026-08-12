import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    static func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}
