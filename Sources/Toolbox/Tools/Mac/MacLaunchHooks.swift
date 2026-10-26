import Foundation

/// Things the Mac tools put back when Toolbox starts, if the person asked for them.
@MainActor
enum MacLaunchHooks {
    private static var didRun = false

    /// Runs once per launch, however many windows open.
    static func run() {
        guard !didRun else { return }
        didRun = true
        MouseFixesModel.shared.restoreOnLaunch()
        DisplayControlModel.shared.restoreOnLaunch()
    }
}
