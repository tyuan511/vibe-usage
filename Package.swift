// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VibeUsage",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "VibeUsageApp", targets: ["VibeUsageApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        // MARK: - Core (no internal dependencies; defines the extensibility contract)
        .target(
            name: "VibeUsageCore",
            dependencies: []
        ),
        .testTarget(
            name: "VibeUsageCoreTests",
            dependencies: ["VibeUsageCore"]
        ),

        // MARK: - Pricing
        .target(
            name: "VibeUsagePricing",
            dependencies: ["VibeUsageCore"],
            resources: [
                .copy("Resources/model_prices.json")
            ]
        ),
        .testTarget(
            name: "VibeUsagePricingTests",
            dependencies: ["VibeUsagePricing"]
        ),

        // MARK: - Storage (GRDB-backed persistence; owns SQLite schema)
        .target(
            name: "VibeUsageStorage",
            dependencies: [
                "VibeUsageCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "VibeUsageStorageTests",
            dependencies: ["VibeUsageStorage"]
        ),

        // MARK: - Watching (FSEvents-based file watching, adapter-agnostic)
        .target(
            name: "VibeUsageWatching",
            dependencies: ["VibeUsageCore"]
        ),
        .testTarget(
            name: "VibeUsageWatchingTests",
            dependencies: ["VibeUsageWatching"]
        ),

        // MARK: - Aggregation (rollup queries -> DTOs, sits on Storage)
        .target(
            name: "VibeUsageAggregation",
            dependencies: ["VibeUsageCore", "VibeUsageStorage"]
        ),
        .testTarget(
            name: "VibeUsageAggregationTests",
            dependencies: ["VibeUsageAggregation", "VibeUsageStorage"]
        ),

        // MARK: - Adapters (each self-contained; only depends on Core + Pricing)
        .target(
            name: "VibeUsageAdapterClaude",
            dependencies: ["VibeUsageCore", "VibeUsagePricing"]
        ),
        .testTarget(
            name: "VibeUsageAdapterClaudeTests",
            dependencies: ["VibeUsageAdapterClaude"],
            resources: [.copy("Fixtures")]
        ),

        .target(
            name: "VibeUsageAdapterCodex",
            dependencies: ["VibeUsageCore", "VibeUsagePricing"]
        ),
        .testTarget(
            name: "VibeUsageAdapterCodexTests",
            dependencies: ["VibeUsageAdapterCodex"],
            resources: [.copy("Fixtures")]
        ),

        .target(
            name: "VibeUsageAdapterAdditional",
            dependencies: [
                "VibeUsageCore",
                "VibeUsagePricing",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "VibeUsageAdapterAdditionalTests",
            dependencies: [
                "VibeUsageAdapterAdditional",
                "VibeUsagePricing",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),

        // MARK: - UI (SwiftUI views; only knows adapters through AdapterRegistry)
        .target(
            name: "VibeUsageUI",
            dependencies: ["VibeUsageCore", "VibeUsageAggregation"],
            resources: [
                .copy("Resources/logo.png"),
                .copy("Resources/AgentIcons")
            ]
        ),

        // MARK: - App (composition root: only place that imports concrete adapters)
        .executableTarget(
            name: "VibeUsageApp",
            dependencies: [
                "VibeUsageCore",
                "VibeUsagePricing",
                "VibeUsageStorage",
                "VibeUsageWatching",
                "VibeUsageAggregation",
                "VibeUsageAdapterClaude",
                "VibeUsageAdapterCodex",
                "VibeUsageAdapterAdditional",
                "VibeUsageUI"
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
