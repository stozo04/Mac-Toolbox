# Folio

**Category:** Docs
**Tagline:** Read, annotate, sign and edit PDFs. Opens Folio, a free PDF app.

## What it is
A card that opens [Folio](https://github.com/Forward-Future/folio), Forward Future's free, open-source PDF reader and editor. It replaces the thirteen PDF tools Toolbox had planned (Scan Document, Redact PDF, Sign PDF, Merge PDFs and the rest).

## Behavior
- Clicking the card opens Folio when it is installed (bundle ID `app.folio.reader`, found through Launch Services). Toolbox stays on the page you were on.
- When Folio is not installed, the card opens its page: what Folio does, a **Get Folio** button that opens Folio's GitHub releases in the browser, and **Check Again**.
- The card shows Folio's own icon when it is installed.

## Implementation
`ToolInput.companionApp(.folio)`; `Models/CompanionApp.swift` (name, bundle ID, pitch, download page, `CompanionApps` to find and open it), `Views/CompanionAppView.swift`, `AppState.open(_:)`.
