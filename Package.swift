// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VibeUsage",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "VibeUsageApp", targets: ["VibeUsageApp"]),
        .executable(name: "VibeUsagePreviewRenderer", targets: ["VibeUsagePreviewRenderer"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
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
            dependencies: [
                "VibeUsageStorage",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),

        // MARK: - Sync (backend-neutral shard format and remote adapters)
        .target(
            name: "VibeUsageSync",
            dependencies: ["VibeUsageCore", "VibeUsageStorage"]
        ),
        .testTarget(
            name: "VibeUsageSyncTests",
            dependencies: ["VibeUsageSync", "VibeUsageStorage"]
        ),

        // MARK: - Watching (FSEvents-based file watching, adapter-agnostic)
        .target(
            name: "VibeUsageWatching",
            dependencies: ["VibeUsageCore"]
        ),
        .testTarget(
            name: "VibeUsageWatchingTests",
            dependencies: ["VibeUsageWatching", "VibeUsageStorage", "VibeUsagePricing"]
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

        // MARK: - Adapters
        .target(
            name: "VibeUsageAdapter",
            dependencies: [
                "VibeUsageCore",
                "VibeUsagePricing",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "VibeUsageAdapterTests",
            dependencies: [
                "VibeUsageAdapter",
                "VibeUsagePricing",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),

        // MARK: - Quota (real-time subscription limit monitoring; independent
        // of the local-cost aggregation pipeline above — no GRDB, no Storage)
        .target(
            name: "VibeUsageQuota",
            dependencies: ["VibeUsageCore"]
        ),
        .testTarget(
            name: "VibeUsageQuotaTests",
            dependencies: ["VibeUsageQuota"]
        ),

        // MARK: - UI (SwiftUI views; only knows adapters through AdapterRegistry)
        .target(
            name: "VibeUsageUI",
            dependencies: [
                "VibeUsageCore",
                "VibeUsageAggregation",
                "VibeUsageQuota"
            ],
            resources: [
                .copy("Resources/logo.png"),
                .copy("Resources/AgentIcons")
            ]
        ),
        .testTarget(
            name: "VibeUsageUITests",
            dependencies: ["VibeUsageUI", "VibeUsageQuota"]
        ),

        // MARK: - App (composition root: only place that imports concrete adapters)
        .executableTarget(
            name: "VibeUsageApp",
            dependencies: [
                "VibeUsageCore",
                "VibeUsagePricing",
                "VibeUsageStorage",
                "VibeUsageSync",
                "VibeUsageWatching",
                "VibeUsageAggregation",
                "VibeUsageAdapter",
                "VibeUsageQuota",
                "VibeUsageUI",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "VibeUsageAppTests",
            dependencies: ["VibeUsageApp", "VibeUsageUI"],
            linkerSettings: [
                // Binary frameworks are emitted beside the test bundle, but
                // SwiftPM does not add that product directory to the bundle's
                // runtime search paths.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../.."
                ])
            ]
        ),

        .executableTarget(
            name: "VibeUsagePreviewRenderer",
            dependencies: [
                "VibeUsageCore",
                "VibeUsageAggregation",
                "VibeUsageAdapter",
                "VibeUsageQuota",
                "VibeUsageUI"
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
