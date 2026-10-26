import SwiftUI

@main
struct ToolboxApp: App {
    @State private var state = AppState()

    init() {
        var sinks: [LogSink] = [ConsoleLogSink()]
        if let config = SupabaseLogConfig.load() { sinks.append(SupabaseLogSink(config: config)) }
        Log.configure(sinks: sinks)
        Log.info("App launched", category: "app")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(state.isDark ? .dark : .light)
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
