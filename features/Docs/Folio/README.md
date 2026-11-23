# Folio

**Category:** Docs
**Tagline:** Read, annotate, sign and edit PDFs. Opens Folio, a free PDF app.

## What it is
A card that opens [Folio](https://github.com/Forward-Future/folio), Forward Future's free, open-source PDF reader and editor. It replaces the Docs category: the two built tools, Scan Document and Redact PDF, were removed with the eleven that were only planned. Folio does not scan paper or redact text for good, so those two jobs have no replacement in Toolbox.

## Behavior
- Clicking the card opens Folio when it is installed (bundle ID `app.folio.reader`, found through Launch Services). Toolbox stays on the page you were on.
- When Folio is not installed, the card opens its page: what Folio does, a **Get Folio** button that opens Folio's download page ([mberman84/folio-releases](https://github.com/mberman84/folio-releases/releases/latest); Folio's source repository publishes no releases) in the browser, and **Check Again**.
- The card shows Folio's own icon when it is installed. Right-click a card to add it to or remove it from Favorites, since an installed app opens instead of the page with the star.

## Implementation
`ToolInput.companionApp(.folio)`; `Models/CompanionApp.swift` (name, bundle ID, pitch, download page, `CompanionApps` to find and open it), `Views/CompanionAppView.swift`, `AppState.open(_:)`.
