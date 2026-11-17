import SwiftUI

@main
struct ToolboxApp: App {
    @NSApplicationDelegateAdaptor(MainWindowReopener.self) private var reopener
    @State private var state = AppState()
    @State private var vault = VaultModel(location: .launch())

    init() {
        var sinks: [LogSink] = [ConsoleLogSink()]
        if AppInfo.sendsRemoteLogs(), let config = SupabaseLogConfig.load() { sinks.append(SupabaseLogSink(config: config)) }
        Log.configure(sinks: sinks)
        Log.info("App launched", category: "app")
    }

    var body: some Scene {
        WindowGroup(id: MainWindowReopener.windowID) {
            RootView()
                .environment(state)
                .environment(vault)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(state.isDark ? .dark : .light)
                .registersMainWindowOpener(reopener)
                .onAppear {
                    MacLaunchHooks.run()
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
    }
}
