# Contributing to VibeUsage

Thanks for helping improve VibeUsage. This guide covers the most common contribution paths.

## Prerequisites

- macOS 26 SDK
- Swift 6.2
- Python 3 (for pricing updates)

## Common commands

```bash
make test          # run unit tests
make app           # build debug .app
make restart       # rebuild and relaunch locally
make preview       # regenerate docs/usage-preview.png
make pricing       # refresh model_prices.json from LiteLLM
make dmg           # build release DMG
```

## Adding a new agent adapter

1. Implement `UsageSourceAdapter` in `Sources/VibeUsageAdapter/`.
2. Register the adapter in `Sources/VibeUsageApp/main.swift`.
3. Add agent icons under `Sources/VibeUsageUI/Resources/AgentIcons/{light,dark}/`.
4. Extend `Scripts/update-pricing.py` if the agent uses models not already covered.
5. Add adapter tests in `Tests/VibeUsageAdapterTests/`.
6. Document any supported environment variables in `README.md`.

Adapter contract lives in `Sources/VibeUsageCore/Protocols/UsageSourceAdapter.swift`.

## Pricing updates

Run:

```bash
python3 Scripts/update-pricing.py
```

Then add/adjust tests in `Tests/VibeUsagePricingTests/` when new model families matter for supported agents.

## UI preview

The menu bar preview image is generated from real SwiftUI code:

```bash
Scripts/regenerate-preview.sh
```

CI on `main` can auto-commit preview changes when the UI changes.

## Pull requests

- Keep diffs focused.
- Run `swift test` before opening a PR.
- PR CI runs on macOS and executes the full test suite.

## Release signing

Release builds accept an optional signing identity:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh release
```

In GitHub Actions, set repository secret `SIGN_IDENTITY` to enable signed release DMGs.
