import Foundation
import Combine
import ServiceManagement

final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var indicator: String { didSet { defaults.set(indicator, forKey: "indicator") } }
    @Published var interval: Double { didSet { defaults.set(interval, forKey: "interval") } }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    @Published var compact: Bool { didSet { defaults.set(compact, forKey: "compact") } }
    @Published var scale: Double { didSet { defaults.set(scale, forKey: "scale"); Scale.value = CGFloat(scale) } }
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var loginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedIndicator = defaults.string(forKey: "indicator") ?? "icon"
        indicator = ["icon", "cpu", "memory"].contains(storedIndicator) ? storedIndicator : "icon"
        let storedInterval = defaults.double(forKey: "interval")
        interval = [2.0, 5.0, 10.0].contains(storedInterval) ? storedInterval : 2
        let storedAppearance = defaults.string(forKey: "appearance") ?? "system"
        appearance = ["system", "light", "dark"].contains(storedAppearance) ? storedAppearance : "system"
        compact = defaults.bool(forKey: "compact")
        let storedScale = defaults.double(forKey: "scale")
        scale = Scale.choices.contains(storedScale) ? storedScale : 1.2
        Scale.value = CGFloat(scale)
        refreshLogin()
    }

    func refreshLogin() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "未能修改登录项：\(error.localizedDescription)"
        }
        refreshLogin()
    }
}
