import Foundation
import VibeUsageCore

public struct DeviceBreakdownRow: Sendable, Equatable {
    public let device: SyncedUsageDevice
    public let tokens: TokenCounts
    public let costUSD: Decimal
    public let eventCount: Int
    public let estimatedEventCount: Int

    public var name: String { device.name }
}
