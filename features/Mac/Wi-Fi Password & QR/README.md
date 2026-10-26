# Wi-Fi Password & QR

**Category:** Mac  
**SF Symbol:** `wifi`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Wi-Fi Password & QR`)

Show the password of a saved Wi-Fi network and make a QR code guests can scan to join.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/WifiPassword/`:
- `WifiPasswordView` / `WifiPasswordModel` - saved networks list; pick one, press Show Password (macOS asks for approval in its own Keychain window), then copy it or use the QR code (security type and hidden-network options; copy or save as PNG).
- `WifiService` - `networksetup -listpreferredwirelessnetworks` for names and `security find-generic-password -D "AirPort network password" -a <name> -w` for the password; builds the `WIFI:` payload with proper escaping and a crisp QR with a quiet zone via Core Image. Nothing is stored or logged, and no network is used.
- Tests: `MacNetworkTests.swift` (`WifiServiceTests`).

## Implementation notes for an agent
- `security find-generic-password` (prompts Keychain auth) + CoreWLAN; QR via Core Image.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
