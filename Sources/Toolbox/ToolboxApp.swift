import SwiftUI

@main
struct ToolboxApp: App {
    @NSApplicationDelegateAdaptor(MainWindowReopener.self) private var reopener
    @State private var state = AppState()
    @State private var vault = VaultModel(location: .launch())

    init() {
        var sinks: [LogSink] = [ConsoleLogSink()]
        var storeProblem: Error?
        do {
            sinks.append(LogStoreSink(store: try LogStore(at: LogStoreLocation.launch())))
        } catch {
            storeProblem = error
        }
        Log.configure(sinks: sinks)
        Log.info("App launched", category: "app")
        if let storeProblem { Log.error("The log store could not be opened", category: "app", Log.details(storeProblem)) }
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
                    vault.quitGuard.showRefusal(on: state)
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
    }
}
