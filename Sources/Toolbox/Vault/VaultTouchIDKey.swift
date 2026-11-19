import CryptoKit
import Foundation
import LocalAuthentication

enum VaultKeyAnswer: Equatable {
    case password(String)
    case cancelled
    case failed(String)
}

/// Keeps the vault password so Download Video can open the vault with a fingerprint instead of the password.
@MainActor
protocol VaultPasswordKeeper: AnyObject {
    var isAvailable: Bool { get }
    var hasPassword: Bool { get }
    func save(_ password: String) throws
    func forget()
    func password(reason: String) async -> VaultKeyAnswer
}

/// The password is sealed with a key that lives in the Secure Enclave and only works after Touch ID.
/// The Keychain is not used: Toolbox is ad-hoc signed, and macOS would ask for the login password after every rebuild.
@MainActor
final class VaultTouchIDKey: VaultPasswordKeeper {
    static let fileName = "TouchID.key"
    static let attempts = 3

    private struct Sealed: Codable {
        let enclaveKey: Data
        let ephemeralPublicKey: Data
        let box: Data
    }

    enum KeyError: LocalizedError {
        case unreadable

        var errorDescription: String? { "The saved Touch ID key could not be read." }
    }

    private let file: URL

    init(file: URL) { self.file = file }

    convenience init(location: VaultLocation) {
        self.init(file: location.folder.appendingPathComponent(Self.fileName))
    }

    var isAvailable: Bool {
        SecureEnclave.isAvailable && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var hasPassword: Bool { FileManager.default.fileExists(atPath: file.path) }

    func save(_ password: String) throws {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], nil) else {
            throw KeyError.unreadable
        }
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
        let box = try AES.GCM.seal(Data(password.utf8), using: Self.boxKey(from: secret, ephemeral: ephemeral.publicKey))
        guard let combined = box.combined else { throw KeyError.unreadable }
        let sealed = Sealed(enclaveKey: enclaveKey.dataRepresentation, ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, box: combined)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(sealed).write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func forget() {
        try? FileManager.default.removeItem(at: file)
    }

    func password(reason: String) async -> VaultKeyAnswer {
        guard let data = try? Data(contentsOf: file), let sealed = try? JSONDecoder().decode(Sealed.self, from: data) else {
            return .failed("Touch ID isn't set up for the Vault yet. Unlock it once on the Vault page with \"Use Touch ID\" on.")
        }
        for attempt in 1...Self.attempts {
            let context = LAContext()
            context.localizedFallbackTitle = ""
            var unavailable: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &unavailable) else {
                return .failed("Touch ID isn't available right now.")
            }
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
                return open(sealed, with: context)
            } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                return .cancelled
            } catch let error as LAError where error.code == .authenticationFailed && attempt < Self.attempts {
                continue
            } catch {
                return .failed("Touch ID didn't recognize your finger.")
            }
        }
        return .failed("Touch ID didn't recognize your finger.")
    }

    private func open(_ sealed: Sealed, with context: LAContext) -> VaultKeyAnswer {
        do {
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: sealed.enclaveKey,
                                                                            authenticationContext: context)
            let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: sealed.ephemeralPublicKey)
            let secret = try enclaveKey.sharedSecretFromKeyAgreement(with: ephemeral)
            let box = try AES.GCM.SealedBox(combined: sealed.box)
            let password = try AES.GCM.open(box, using: Self.boxKey(from: secret, ephemeral: ephemeral))
            guard let text = String(data: password, encoding: .utf8) else { throw KeyError.unreadable }
            return .password(text)
        } catch {
            // A fingerprint added or removed since saving retires the enclave key for good.
            forget()
            Log.warning("Vault Touch ID key no longer opens", category: VaultLog.category, Log.details(error))
            return .failed("Your fingerprints changed since Touch ID was set up for the Vault. Unlock it once on the Vault page to set it up again.")
        }
    }

    private static func boxKey(from secret: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral.rawRepresentation,
                                       sharedInfo: Data("Toolbox vault password".utf8), outputByteCount: 32)
    }
}
