import SwiftUI

/// The Mac category's tools. Each has its own folder under `Tools/Mac/`.
enum MacTool: Hashable {
    case networkSpeedTest, storageExplorer, wifiPassword, keepAwake, uninstallApp, presentationMode
    case cleanKeyboard, ejectAllDisks, loginItems, fixDamagedApp, resetPermissions, hiddenSettings
    case displayControl, mouseFixes
}

struct MacToolView: View {
    let tool: MacTool

    var body: some View {
        switch tool {
        case .networkSpeedTest: NetworkSpeedTestView()
        case .storageExplorer: StorageExplorerView()
        case .wifiPassword: WifiPasswordView()
        case .keepAwake: KeepAwakeView()
        case .uninstallApp: UninstallAppView()
        case .presentationMode: PresentationModeView()
        case .cleanKeyboard: CleanKeyboardView()
        case .ejectAllDisks: EjectAllDisksView()
        case .loginItems: LoginItemsView()
        case .fixDamagedApp: FixDamagedAppView()
        case .resetPermissions: ResetPermissionsView()
        case .hiddenSettings: HiddenSettingsView()
        case .displayControl: DisplayControlView()
        case .mouseFixes: MouseFixesView()
        }
    }
}
