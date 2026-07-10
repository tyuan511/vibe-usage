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
make preview       # regenerate docs/usage-share-preview.png
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

## Share Poster Preview

The share poster preview image is generated from real SwiftUI code:

```bash
Scripts/regenerate-preview.sh
```

CI on `main` can auto-commit preview changes when the UI changes.

## Pull requests

- Keep diffs focused.
- Run `swift test` before opening a PR.
- PR CI runs on macOS and executes the full test suite.

## Release signing

Sparkle update signing is mandatory for releases. The public key is embedded
in `Scripts/package-Info.plist.template`; the matching private key must be
available as the `SPARKLE_PRIVATE_KEY` GitHub Actions secret. The local copy is
stored in the login Keychain under account `me.tangge.vibeusage` and can be
exported for an encrypted offline backup with:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account me.tangge.vibeusage \
  -x /path/to/secure-backup-key
```

Never commit the exported private key. Losing this key strands ad-hoc-signed
installations because there is no Developer ID signature available for key
rotation.

Release builds accept an optional signing identity:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh release
```

In GitHub Actions, set repository secret `SIGN_IDENTITY` to enable signed release DMGs.
