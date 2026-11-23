# Scarlet

**Category:** Video
**Tagline:** Edit video by talking to Claude Code or Codex. Opens Scarlet, a free AI video editor.

## What it is
A card that opens [Scarlet](https://github.com/Forward-Future/scarlet), Forward Future's free, open-source AI video editor: you tell Claude Code or Codex what to change, by voice, in writing or by drawing on a frame. It sits beside the Video tools; it does not replace any of them.

## Behavior
- Clicking the card opens Scarlet when it is installed (bundle ID `com.forwardfuture.scarlet`, found through Launch Services). Toolbox stays on the page you were on.
- When Scarlet is not installed, the card opens its page: what Scarlet does, a **Get Scarlet** button that opens Scarlet's GitHub releases in the browser, and **Check Again**.
- The card shows Scarlet's own icon when it is installed.

## Implementation
`ToolInput.companionApp(.scarlet)`; shared with Folio: `Models/CompanionApp.swift`, `Views/CompanionAppView.swift`, `AppState.open(_:)`.
