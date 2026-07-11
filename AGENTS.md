# Repository Guidelines

## Project Structure

VibeUsage is a macOS 26 Swift 6.2 package. Production code is split under `Sources/`:

- `VibeUsageCore` defines shared models, errors, protocols, and the adapter registry.
- `VibeUsageAdapter`, `VibeUsageWatching`, `VibeUsageStorage`, and `VibeUsageAggregation` form the local usage-ingestion pipeline.
- `VibeUsagePricing` owns bundled pricing data; `VibeUsageQuota` handles optional OAuth quota monitoring; `VibeUsageUI` contains SwiftUI views.
- `VibeUsageApp/main.swift` is the composition root and the only place concrete adapters are registered. `VibeUsagePreviewRenderer` renders documentation previews.

Keep tests in the matching `Tests/VibeUsage*Tests/` target. Put bundled target resources in that target's `Resources/` directory; application icons and release assets live in `Resources/` and `Scripts/`.

## Build, Test, and Development

- `swift test` or `make test`: run the complete XCTest suite.
- `swift build` or `make build`: compile SwiftPM targets.
- `make app`: assemble a debug `.build/VibeUsage.app` bundle.
- `make restart`: rebuild, stop, and relaunch the debug app.
- `make preview`: regenerate `docs/usage-share-preview.png` from real SwiftUI code.
- `make pricing`: refresh `Sources/VibeUsagePricing/Resources/model_prices.json` (requires Python 3 and network access).
- `make dmg`: assemble and package a release DMG.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for members, and one primary type per appropriately named file. Prefer clear names such as `CodexQuotaProvider` and `UsageEventRecord`. Preserve target layering: depend on `VibeUsageCore` interfaces rather than concrete targets; keep adapter registration in the app target. No formatter or linter is configured, so match adjacent code and let `swift build` catch issues.

## Testing Guidelines

Use XCTest and name test files `*Tests.swift`, with focused test methods describing behavior. Add or update tests alongside changes to adapters, migrations, pricing aliases, quota parsing, or aggregation rules. Run `swift test` before opening a pull request; CI runs this suite on macOS.

## Commit & Pull Request Guidelines

Use short, imperative commit subjects consistent with history: `Add quota monitoring support`, `Fix Codex fork replay overcounting`, or `Update pricing for GPT-5.6 family`. Keep each commit and PR focused. PR descriptions should explain behavior and data/model changes, link issues when available, and include screenshots for SwiftUI or preview-image updates. Regenerate and include `docs/usage-share-preview.png` when modifying the share card.

## Security & Release Configuration

Never commit OAuth tokens, Keychain exports, signing identities, or Sparkle private keys. `SPARKLE_PRIVATE_KEY` and optional `SIGN_IDENTITY` belong in secure local/CI configuration; release signing changes require extra review.
