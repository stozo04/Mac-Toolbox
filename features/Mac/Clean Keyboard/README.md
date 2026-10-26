# Clean Keyboard

**Category:** Mac  
**SF Symbol:** `keyboard`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Clean Keyboard`)

Pause the keyboard for a minute so you can wipe the keys without typing gibberish.

## Design reference
`images/Mac/Clean Keyboard.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/CleanKeyboard/`:
- `CleanKeyboardView` / `CleanKeyboardModel` - pause for 30 seconds, 1 or 2 minutes. The screens dim and the main one shows a countdown and a Done button; the countdown ends on its own.
- `EventTapKeyboardBlocker` - a `CGEventTap` that swallows key down/up, modifier and media-key events. It needs the **Accessibility** permission; without it the screen is never dimmed and the tool shows how to grant it. The mouse, trackpad, power button and Touch ID are not affected.
- Tests: `MacInputTests.swift` (with a fake blocker; a real tap is created and removed in one synchronous step).

## Implementation notes for an agent
- CGEventTap swallowing key events (needs Accessibility/Input Monitoring).
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
