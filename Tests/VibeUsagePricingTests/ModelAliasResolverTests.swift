import Testing
@testable import VibeUsagePricing

@Test func stripsTrailingCalendarDateSuffix() {
    #expect(ModelAliasResolver.resolveFamily(fromRawModel: "claude-sonnet-4-20250514") == "claude-sonnet-4")
    #expect(ModelAliasResolver.resolveFamily(fromRawModel: "claude-3-5-sonnet-20241022") == "claude-3-5-sonnet")
    #expect(ModelAliasResolver.resolveFamily(fromRawModel: "claude-opus-4-1-20250805") == "claude-opus-4-1")
}

@Test func leavesBareModelNamesUnchanged() {
    #expect(ModelAliasResolver.resolveFamily(fromRawModel: "gpt-5.1-codex-max") == "gpt-5.1-codex-max")
    #expect(ModelAliasResolver.resolveFamily(fromRawModel: "o3") == "o3")
    #expect(ModelAliasResolver.resolveFamily(fromRawModel: "gpt-5") == "gpt-5")
}

@Test func doesNotStripAnEightDigitSuffixThatIsNotAValidCalendarDate() {
    // Month "99" is not valid, so this should NOT be treated as a date suffix.
    #expect(ModelAliasResolver.resolveFamily(fromRawModel: "custom-model-20259999") == "custom-model-20259999")
}
