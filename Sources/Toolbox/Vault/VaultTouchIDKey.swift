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
    static let notSetUp = "Touch ID isn't set up for the Vault yet. Unlock it once on the Vault page with \"Use Touch ID\" on."
    static let notRecognized = "Touch ID didn't recognize your finger."
    static let lockedOut = "Touch ID is locked after too many tries. Unlock your Mac with its password to turn it back on."
    static let fingerprintsChanged = "Your fingerprints changed since Touch ID was set up for the Vault. Unlock it once on the Vault page to set it up again."

    struct Sealed: Codable, Equatable {
        let enclaveKey: Data
        let ephemeralPublicKey: Data
        let box: Data
        var fingerprints: Data?
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
        var sealed = try Self.seal(password, to: enclaveKey.publicKey, enclaveKey: enclaveKey.dataRepresentation)
        sealed.fingerprints = Self.currentFingerprints()
        try write(JSONEncoder().encode(sealed))
    }

    func forget() {
        try? FileManager.default.removeItem(at: file)
    }

    func password(reason: String) async -> VaultKeyAnswer {
        guard let data = try? Data(contentsOf: file), let sealed = try? JSONDecoder().decode(Sealed.self, from: data) else {
            return .failed(Self.notSetUp)
        }
        // One prompt: it already lets you try your finger several times, and a second one is what reaches the misses
        // after which macOS locks Touch ID for the whole Mac until the login password is typed.
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &unavailable) else {
            return .failed(Self.message(for: (unavailable as? LAError)?.code))
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return open(sealed, with: context)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return .cancelled
        } catch {
            return .failed(Self.message(for: (error as? LAError)?.code))
        }
    }

    private static func message(for code: LAError.Code?) -> String {
        switch code {
        case .biometryLockout?: lockedOut
        case .biometryNotEnrolled?: "No fingerprints are set up on this Mac. Add one in System Settings > Touch ID & Password."
        case .biometryNotAvailable?, .biometryDisconnected?: "Touch ID isn't available right now."
        default: notRecognized
        }
    }

    private func open(_ sealed: Sealed, with context: LAContext) -> VaultKeyAnswer {
        do {
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: sealed.enclaveKey,
                                                                            authenticationContext: context)
            return .password(try Self.unseal(sealed) { try enclaveKey.sharedSecretFromKeyAgreement(with: $0) })
        } catch {
            // Only a changed set of fingerprints retires the enclave key for good; anything else may pass, so the key stays.
            let changed = sealed.fingerprints != nil && sealed.fingerprints != context.evaluatedPolicyDomainState
            if changed { forget() }
            Log.warning("Vault Touch ID key did not open", category: VaultLog.category,
                        Log.details(error, ["fingerprints_changed": String(changed)]))
            return .failed(changed ? Self.fingerprintsChanged : "Touch ID couldn't open the saved key. Try again.")
        }
    }

    private func write(_ data: Data) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fresh = folder.appendingPathComponent(".\(Self.fileName)-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: fresh.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw KeyError.unreadable
        }
        guard rename(fresh.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: fresh)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func currentFingerprints() -> Data? {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.evaluatedPolicyDomainState
    }

    static func seal(_ password: String, to publicKey: P256.KeyAgreement.PublicKey, enclaveKey: Data) throws -> Sealed {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        let box = try AES.GCM.seal(Data(password.utf8), using: boxKey(from: secret, ephemeral: ephemeral.publicKey))
        guard let combined = box.combined else { throw KeyError.unreadable }
        return Sealed(enclaveKey: enclaveKey, ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, box: combined)
    }

    static func unseal(_ sealed: Sealed, agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> String {
        let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: sealed.ephemeralPublicKey)
        let box = try AES.GCM.SealedBox(combined: sealed.box)
        let password = try AES.GCM.open(box, using: boxKey(from: try agree(ephemeral), ephemeral: ephemeral))
        guard let text = String(data: password, encoding: .utf8) else { throw KeyError.unreadable }
        return text
    }

    private static func boxKey(from secret: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral.rawRepresentation,
                                       sharedInfo: Data("Toolbox vault password".utf8), outputByteCount: 32)
    }
}
