# Color Picker

**Category:** Images  
**SF Symbol:** `eyedropper`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Color Picker`)

Pick any color on screen and copy it as HEX, RGB, HSL or code.

## Design reference
`images/Images/Color Picker.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Images/ColorPicker/`, routed through `ToolInput.colorPicker`.
- `RGBAColor.swift` - the sRGB color every format is made from (HSL, OKLab/OKLCH, WCAG luminance, distance between two colors), `ColorFormat` (the eight copy formats) and the parser for typed colors (`#RGB`, `#RRGGBB`, `#RRGGBBAA`, `rgb()`/`rgba()`, `hsl()`/`hsla()`, comma or space separated).
- `TailwindColors.swift` - Tailwind v3's default palette (white, black and 22 families x 11 shades); the nearest one is found by distance in OKLab and is called exact when it is the same color.
- `ColorContrast.swift` - WCAG 2 ratio plus AA/AAA for normal and large text. A translucent color is judged as it looks (text over the background, background over white). The ratio is shown to two places but never rounded up across 3, 4.5 or 7.
- `PaletteExtractor.swift` - main colors of an image: pixels are grouped, clustered with weighted k-means in OKLab and near-twins merged, so the count is 5 to 8 (fewer for a flat image).
- `ColorHistory.swift` - last 20 picked or typed colors, saved in UserDefaults (`colorPicker.history`, as `#RRGGBBAA` text).
- `ColorPickerModel.swift` / `ColorPickerView.swift` - Pick, Palette from Image and Contrast tabs. Pick uses `NSColorSampler`, which needs no screen recording permission; Esc cancels. Command-Shift-C starts a pick on every tab (a hidden button holds the shortcut). Picked colors are clamped to sRGB. Include alpha adds opacity to every format (`#RRGGBBAA`, `rgba()`, `opacity:`, Tailwind `/50`); typing a translucent color turns it on.
- Palette: drop, choose or paste (Command-V) an image; click a color to copy its HEX, the eyedropper sends it to Pick, Copy All HEX copies one code per line.
- Contrast: two boxes (Text, Background) each fillable by typing, Pick or History; the box used last receives Command-Shift-C. Swap exchanges them.
- Nothing is written to disk but the history; no network.
- Tests: `Tests/ToolboxTests/ColorPickerTests.swift` (formats, parsing, OKLCH against reference values, Tailwind, WCAG boundary cases, history, palette on synthetic images, model).

## Sub-features / options
- Pick from anywhere on screen (any display)
- Copy as HEX, RGB, HSL, OKLCH, SwiftUI, NSColor, UIColor or Tailwind
- Include alpha / opacity
- History of the last 20 colors
- Palette from an image (5 to 8 colors)
- Contrast checker (WCAG 2 AA/AAA)

## Implementation notes for an agent
- `NSColorSampler` for on-screen sampling.
- Put the tool's logic in `Sources/Toolbox/Tools/Images/ColorPicker/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
