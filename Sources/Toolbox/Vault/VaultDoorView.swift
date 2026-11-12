import SwiftUI

struct VaultDoor: View {
    var wheelTurn: Angle = .zero
    private static let boltCount = 16
    private static let spokeCount = 4

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(AngularGradient(colors: Steel.frame, center: .center))
                Circle().strokeBorder(Steel.edge, lineWidth: size * 0.012)
                bolts(size: size)
                Circle()
                    .fill(RadialGradient(colors: Steel.face, center: .init(x: 0.38, y: 0.32), startRadius: 0, endRadius: size * 0.55))
                    .overlay(Circle().strokeBorder(Steel.edge, lineWidth: size * 0.008))
                    .padding(size * 0.1)
                Circle().strokeBorder(Steel.groove, lineWidth: size * 0.006).padding(size * 0.2)
                Circle().strokeBorder(Steel.groove.opacity(0.6), lineWidth: size * 0.004).padding(size * 0.24)
                wheel(size: size).rotationEffect(wheelTurn)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Vault door")
    }

    private func bolts(size: CGFloat) -> some View {
        ForEach(0..<Self.boltCount, id: \.self) { index in
            Circle()
                .fill(RadialGradient(colors: Steel.bolt, center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.02))
                .frame(width: size * 0.034, height: size * 0.034)
                .offset(y: -size * 0.452)
                .rotationEffect(.degrees(Double(index) / Double(Self.boltCount) * 360))
        }
    }

    private func wheel(size: CGFloat) -> some View {
        ZStack {
            ForEach(0..<Self.spokeCount, id: \.self) { index in
                Capsule()
                    .fill(LinearGradient(colors: Steel.spoke, startPoint: .leading, endPoint: .trailing))
                    .frame(width: size * 0.045, height: size * 0.56)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
            ForEach(0..<(Self.spokeCount * 2), id: \.self) { index in
                Circle()
                    .fill(RadialGradient(colors: Steel.bolt, center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.03))
                    .frame(width: size * 0.06, height: size * 0.06)
                    .offset(y: -size * 0.28)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
            Circle()
                .fill(RadialGradient(colors: Steel.hub, center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.09))
                .frame(width: size * 0.17, height: size * 0.17)
                .overlay(Circle().strokeBorder(Steel.edge, lineWidth: size * 0.008))
            Circle().fill(Steel.edge).frame(width: size * 0.05, height: size * 0.05)
        }
    }

    private enum Steel {
        static let frame = [gray(0.42), gray(0.62), gray(0.36), gray(0.58), gray(0.4), gray(0.66), gray(0.42)]
        static let face = [gray(0.74), gray(0.55), gray(0.38)]
        static let edge = gray(0.18)
        static let groove = gray(0.28)
        static let bolt = [gray(0.85), gray(0.45), gray(0.25)]
        static let spoke = [gray(0.3), gray(0.62), gray(0.3)]
        static let hub = [gray(0.88), gray(0.55), gray(0.3)]

        static func gray(_ white: Double) -> Color { Color(white: white) }
    }
}

struct Shake: GeometryEffect {
    var attempts: CGFloat
    private static let distance: CGFloat = 12
    private static let swings: CGFloat = 3

    var animatableData: CGFloat {
        get { attempts }
        set { attempts = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: Self.distance * sin(attempts * .pi * Self.swings * 2), y: 0))
    }
}

struct VaultDoorView: View {
    @Environment(VaultModel.self) private var vault
    @State private var password = ""
    @State private var confirmation = ""
    @State private var wheelTurn: Angle = .zero
    @State private var swing: Double = 0
    @State private var fade: Double = 1
    @FocusState private var focused: Bool

    static let doorSize: CGFloat = 300
    static let formWidth: CGFloat = 280
    private static let wheelSeconds = 0.9
    private static let swingSeconds = 0.8

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle().fill(Color.black.opacity(0.85))
                    .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 2))
                VaultDoor(wheelTurn: wheelTurn)
                    .rotation3DEffect(.degrees(swing), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.45)
                    .modifier(Shake(attempts: CGFloat(vault.wrongPasswordAttempts)))
                    .animation(.linear(duration: 0.45), value: vault.wrongPasswordAttempts)
            }
            .frame(width: Self.doorSize, height: Self.doorSize)
            form.frame(width: Self.formWidth).opacity(vault.phase == .opening ? 0 : 1)
        }
        .opacity(fade)
        .onChange(of: vault.phase) { _, phase in
            if phase == .opening { playOpening() } else if phase != .open { closeDoor() }
        }
        .onAppear {
            focused = true
            prefillDebugPassword()
        }
    }

    private func prefillDebugPassword() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--vault-debug-password"), flag + 1 < arguments.count else { return }
        password = arguments[flag + 1]
        confirmation = arguments[flag + 1]
        #endif
    }

    @ViewBuilder private var form: some View {
        VStack(spacing: 10) {
            if vault.phase == .setup {
                Text("Create your vault").font(.title3.weight(.semibold))
                Text("Choose a password. You'll need it here and in Finder.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                SecureField("Password", text: $password).focused($focused)
                SecureField("Password again", text: $confirmation).onSubmit(submit)
                Label("There's no way to recover a forgotten password. Forget it and everything inside is gone.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SecureField("Vault password", text: $password).focused($focused).onSubmit(submit)
            }
            if let message = vault.message {
                Text(message).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button(action: submit) {
                Group {
                    if vault.isWorking { ProgressView().controlSize(.small) } else {
                        Text(vault.phase == .setup ? "Create vault" : "Unlock")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vault.isWorking)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func submit() {
        guard !vault.isWorking else { return }
        let entered = password
        let again = confirmation
        Task {
            if vault.phase == .setup {
                await vault.create(password: entered, confirmation: again)
            } else {
                await vault.unlock(password: entered)
            }
            if vault.phase != .setup {
                password = ""
                confirmation = ""
            }
            focused = true
        }
    }

    private func closeDoor() {
        wheelTurn = .zero
        swing = 0
        fade = 1
    }

    private func playOpening() {
        withAnimation(.easeInOut(duration: Self.wheelSeconds)) { wheelTurn = .degrees(300) }
        Task {
            try? await Task.sleep(for: .seconds(Self.wheelSeconds))
            guard vault.phase == .opening else { return closeDoor() }
            withAnimation(.easeIn(duration: Self.swingSeconds)) { swing = -105 }
            withAnimation(.easeIn(duration: Self.swingSeconds / 2).delay(Self.swingSeconds / 2)) { fade = 0 }
            try? await Task.sleep(for: .seconds(Self.swingSeconds))
            vault.finishOpening()
        }
    }
}
