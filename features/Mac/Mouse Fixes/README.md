# Mouse Fixes

**Category:** Mac  
**SF Symbol:** `computermouse`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Mouse Fixes`)

Scroll your mouse and trackpad in different directions, and make the mouse wheel faster.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/MouseFixes/`:
- `MouseFixesView` / `MouseFixesModel` - reverse the mouse wheel's direction, change its speed (0.5x to 5x) and smooth scrolling (each click becomes a short glide), with a status card and a Try It scroll area. Settings are saved and switched back on when Toolbox starts.
- `ScrollEventTap` - a `CGEventTap` on scroll events that only rewrites wheel events; trackpad and Magic Mouse scrolls (continuous events) pass through untouched. Needs the **Accessibility** permission. It works only while Toolbox is open.
- `ScrollTransform` / `SmoothScroller` - the pure maths (a click is never rounded to nothing; the glide delivers the exact total).
- Tests: `MacInputTests.swift` (`ScrollMathTests`, `MouseFixesModelTests`).

## Implementation notes for an agent
- `defaults`/IOHID `com.apple.swipescrolldirection`; scroll acceleration via CGEventTap.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
