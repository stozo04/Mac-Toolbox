import Foundation
import Security

/// Who signed a program or app, read from its code signature.
struct CodeSignInfo: Equatable {
    var isSigned = false
    /// False when the signature no longer matches the files (the app was changed after it was signed).
    var isValid = false
    var isAdHoc = false
    var developer: String?
    var teamID: String?
    var isApple: Bool { developer == "Apple" }

    static let unsigned = CodeSignInfo()

    /// "Developer ID Application: Google LLC (EQHXZ8M8AV)" becomes "Google LLC".
    static func developerName(fromCertificateSummary summary: String) -> String {
        let appleSigners = ["Software Signing", "Apple Mac OS Application Signing", "Apple Code Signing Certification Authority", "Apple Development Signing"]
        if appleSigners.contains(summary) || summary.hasSuffix(" Software Signing") { return "Apple" }
        var name = summary
        if let colon = summary.firstIndex(of: ":"), summary.hasPrefix("Developer ID") || summary.hasPrefix("Apple Development")
            || summary.hasPrefix("Mac Developer") || summary.hasPrefix("3rd Party Mac Developer") || summary.hasPrefix("Apple Distribution") {
            name = String(summary[summary.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if name.hasSuffix(")"), let open = name.lastIndex(of: "("), name.distance(from: open, to: name.endIndex) <= 13 {
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    static func inspect(_ url: URL) -> CodeSignInfo {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else { return .unsigned }

        var info = CodeSignInfo()
        var infoDict: CFDictionary?
        let copied = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoDict)
        guard copied == errSecSuccess, let dict = infoDict as? [String: Any] else { return .unsigned }

        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        info.isAdHoc = flags & 0x2 != 0 // kSecCodeSignatureAdhoc
        info.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        info.isSigned = !certificates.isEmpty || info.isAdHoc || dict[kSecCodeInfoIdentifier as String] != nil
        if let leaf = certificates.first, let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            info.developer = developerName(fromCertificateSummary: summary)
        }
        info.isValid = SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        return info
    }
}
