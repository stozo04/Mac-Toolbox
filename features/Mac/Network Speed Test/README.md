# Network Speed Test

**Category:** Mac  
**SF Symbol:** `gauge.with.dots.needle.67percent`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Network Speed Test`)

Measure download, upload and responsiveness with Apple's own network test.

## Design reference
`images/Mac/Network Speed Test.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/NetworkSpeedTest/`:
- `NetworkSpeedTestView` / `NetworkSpeedTestModel` - log-scale gauge (1 Mbps to 1 Gbps), Upload / Responsiveness / Latency tiles, a plain-language verdict, history (last 20 tests, kept in UserDefaults) and a mode choice (download and upload together, or one after the other).
- `SpeedResult` / `NetworkQuality` - runs `/usr/bin/networkQuality -c [-s]` through `Shell` and parses its JSON (throughput is bits per second; responsiveness in RPM: under 200 Low, under 1000 Medium, above High). Uses the network, as this tool's README allows.
- Tests: `MacNetworkTests.swift` (parser on a real result; an opt-in live run with `TOOLBOX_LIVE_NET=1`).

## Implementation notes for an agent
- `/usr/bin/networkQuality` via Process.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
