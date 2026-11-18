import Foundation

/// The plain-words messages the vault shows, and which failures are worth a log entry.
enum VaultNotices {
    static let stillOpen = "The vault couldn't be locked because something is still using a file in it. Close it and press Lock again."
    static let finishedAsVaultClosed = "It finished moving just as the vault closed. Check it after you unlock."

    static func closedFromOutside(duringImport: Bool, unconfirmed: Int) -> String {
        var notice = "The vault was closed from outside Toolbox."
        if duringImport { notice += " Files that had not been moved yet are still where they were." }
        if unconfirmed > 0 {
            notice += " \(unconfirmed == 1 ? "1 file" : "\(unconfirmed) files") finished moving just as the vault closed; "
                + "check \(unconfirmed == 1 ? "it" : "them") after you unlock."
        }
        return notice + " Unlock to continue."
    }

    static let quitRefusedWhilePasswordChanges = "The vault's password is still being changed, so Toolbox didn't quit. "
        + "Wait for it to finish, then quit again. Quit again now to quit anyway; the change will still finish, "
        + "and the vault will stay open until you eject it or restart."

    /// For the log when quit or sleep could not wait for the lock.
    static func whyNotLocked(changingPassword: Bool, failure: String?) -> String {
        changingPassword ? "the password is still being changed" : failure ?? "the lock had not finished"
    }

    static func quitRefused(reason: String?) -> String {
        let said = (reason ?? "").lowercased()
        let why = reason == nil ? "It is taking too long to eject."
            : said.contains("busy") || said.contains("in use") ? "Something is still using a file in it, for example a file open in another app."
            : "macOS said: \(reason ?? "")"
        return "The vault couldn't be locked, so Toolbox didn't quit. \(why) Close what is using it, then press Lock or quit again. "
            + "Quit again to quit anyway; the vault will stay open until you eject it or restart."
    }

    static func isUnexpected(_ error: Error) -> Bool {
        guard let moveError = error as? VaultMoveError else { return true }
        switch moveError {
        case .copyDiffers, .unreadable, .vaultNotOpen, .notSaved, .originalKept: return true
        case .interrupted, .changedWhileMoving: return false
        case .unsupportedType, .insidePhotosLibrary, .notDownloaded, .alreadyInVault, .link: return false
        }
    }

    static func isUserMistake(_ error: Error) -> Bool {
        switch error as? VaultError {
        case .wrongPassword, .passwordTooShort, .passwordsDiffer: true
        default: false
        }
    }
}
