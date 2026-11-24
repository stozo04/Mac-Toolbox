# Contributing

Thanks for helping. This app is built in the open and there is plenty left to build: many of its tools have a card and a written brief but no working view yet.

## Ways to help

- **Build a tool.** Pick one from the "Coming soon" list in the [README](README.md#coming-soon), read its brief in `features/<Category>/<Tool>/README.md`, and open a pull request. Open an issue first to say which one you're taking, so two people don't build the same tool.
- **Report a problem.** [Open an issue](../../issues/new/choose) with the tool's name, what you did and what happened.
- **Ask for a tool.** Start a thread in [Discussions](../../discussions) describing the small job you still open another app for.

## Set up

You need an Apple silicon Mac on macOS 14 or later, Xcode or the Command Line Tools, and CMake.

```
scripts/build-llama.sh
swift build
swift run Toolbox
```

`scripts/build-llama.sh` is needed once; it builds llama.cpp for the Vault's search. A run from the project folder keeps its own test vault and sends no error reports.

## Building a tool

[AGENTS.md](AGENTS.md) is the full guide: the code map, "How to build a tool" and the rules. The short version:

1. Put the view and its logic in `Sources/Toolbox/Tools/<Category>/<Tool>/`, with the work in a type separate from the UI state so it can be tested.
2. A tool that takes a list of files builds on `BatchQueue` and takes drops with `.fileDrop`. Don't copy another tool's model.
3. Give the tool its own `ToolInput` case and route to it from `ToolWorkspace`. That removes its "Feature not implemented" banner.
4. Never change the user's original files; write new ones. Everything runs on the Mac, with no network calls unless the tool's brief says so.
5. Run programs only through `Shell.run`, and use `Theme.*` colors.

## Before you open a pull request

- `scripts/mac-check.sh` passes: it runs SwiftLint, the tests and the app build on your Mac. New behavior has a test; a bug fix has a test that failed before the fix. GitHub doesn't build the app, so the maintainer runs the same script on your branch before merging.
- Raise `AppVersion.current` in `Sources/Toolbox/Support/ReleaseNotes.swift` and add a `Release` entry at the top of `ReleaseNotes.all`, written for users. `scripts/check-version-bump.sh` checks this, and so does CI. Changes to docs only don't need it.
- Say in the pull request what you changed, why, and how you checked it. A screenshot helps for anything visible.

## License

By contributing you agree that your work is released under the [MIT license](LICENSE.md).
