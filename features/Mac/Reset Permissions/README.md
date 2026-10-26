# Reset Permissions

**Category:** Mac  
**SF Symbol:** `lock.rotation`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Reset Permissions`)

Unstick an app's Screen Recording, Microphone, Camera or other privacy access.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/ResetPermissions/`:
- `ResetPermissionsView` / `ResetPermissionsModel` - pick an installed app (searchable, or choose another), then Reset next to Screen Recording, Microphone, Camera, Accessibility, Input Monitoring, Full Disk Access, Automation, Photos, Contacts, Calendars, Reminders, the Desktop / Documents / Downloads folders, Bluetooth or Speech Recognition, or reset all for that app. Each row can open its System Settings page.
- `PermissionResetter` - `tccutil reset <Service> <bundle id>`. The bundle id is validated and the command always names an app (never resets every app). tccutil only knows installed apps, so others get a friendly message.
- Tests: `MacAppToolsTests.swift` (`ResetPermissionsTests`, including a harmless real tccutil call).

## Implementation notes for an agent
- `tccutil reset <Service> <bundle id>`.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
