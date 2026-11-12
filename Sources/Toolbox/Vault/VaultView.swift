import SwiftUI

struct VaultView: View {
    @Environment(VaultModel.self) private var vault

    var body: some View {
        ZStack {
            if vault.phase == .open || vault.phase == .opening {
                VaultLibraryView()
                    .opacity(vault.phase == .open ? 1 : 0)
                    .animation(.easeOut(duration: 0.35), value: vault.phase)
            }
            if vault.phase != .open {
                VaultDoorView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
