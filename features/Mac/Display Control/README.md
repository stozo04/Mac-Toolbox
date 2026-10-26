# Display Control

**Category:** Mac  
**SF Symbol:** `display`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Display Control`)

Change the brightness, contrast and volume of external monitors, right from your Mac.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/DisplayControl/`:
- `DisplayControlView` / `DisplayControlModel` - lists external monitors; for ones that answer DDC/CI, sliders for brightness, contrast and volume (only the controls the monitor supports) and an option to restore the values when Toolbox opens.
- `DDC` (packet and checksum logic, tested against published examples) and `AVServiceBus` - DDC/CI over the Apple-silicon display connection using IOKit's private `IOAVService` calls, looked up at run time. Each monitor is matched to its connection by the vendor and product ID in the registry's EDID UUID; if that can't be done with certainty (for instance two identical monitors) the tool refuses to change anything rather than guess.
- Verified on real hardware: reads, and a write of the unchanged value. Replies are read from I2C offset 0. Apple silicon only. A monitor that rejects DDC (some adapters and docks) is shown with an explanation.
- Tests: `DisplayControlTests.swift` (plus read-only live probe and an opt-in live write: `TOOLBOX_DDC_WRITE_TEST=1`).

## Implementation notes for an agent
- DDC/CI over IOAVService (Apple silicon) or `m1ddc`-style implementation.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
