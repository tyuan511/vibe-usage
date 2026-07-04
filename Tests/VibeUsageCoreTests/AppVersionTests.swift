import Foundation
import Testing
import VibeUsageCore

@Test func appVersionParsesPlainAndPrefixedTags() {
    #expect(AppVersion("1.2.3")?.description == "1.2.3")
    #expect(AppVersion("v0.1.1")?.description == "0.1.1")
    #expect(AppVersion("2.0.0-beta.1")?.description == "2.0.0")
}

@Test func appVersionComparesSemverComponents() {
    #expect(AppVersion("1.0.0")! < AppVersion("1.0.1")!)
    #expect(AppVersion("1.10.0")! > AppVersion("1.2.0")!)
    #expect(AppVersion("2.0.0")! == AppVersion("2.0.0")!)
}

@Test func appVersionRejectsEmptyInput() {
    #expect(AppVersion("") == nil)
    #expect(AppVersion("beta") == nil)
}
