import Testing
@testable import VibeUsageAggregation

@Suite struct ProjectNameHumanizerTests {
    @Test func emptyStringIsUngrouped() {
        let humanizer = ProjectNameHumanizer(homeDirectory: "/Users/yuantang", directoryExists: { _ in false })
        #expect(humanizer.humanize("") == nil)
    }

    @Test func dateLikeValuesAreUngrouped() {
        let humanizer = ProjectNameHumanizer(homeDirectory: "/Users/yuantang", directoryExists: { _ in false })
        #expect(humanizer.humanize("2025/09/19") == nil)
        #expect(humanizer.humanize("2025-09-19") == nil)
        // Not a full date match: should NOT be treated as date-like.
        #expect(humanizer.humanize("2025/09/1") != nil)
    }

    @Test func resolvesMungedPathWithHyphenatedDirectoryName() {
        // Real directories: /Users, /Users/yuantang, /Users/yuantang/code,
        // /Users/yuantang/code/vibe-usage. Note /Users/yuantang/code/vibe
        // does NOT exist, which is what makes naive splitting ambiguous.
        let existingDirs: Set<String> = [
            "/Users",
            "/Users/yuantang",
            "/Users/yuantang/code",
            "/Users/yuantang/code/vibe-usage"
        ]
        let humanizer = ProjectNameHumanizer(
            homeDirectory: "/Users/yuantang",
            directoryExists: { existingDirs.contains($0) }
        )

        let result = humanizer.humanize("-Users-yuantang-code-vibe-usage")
        #expect(result?.key == "/Users/yuantang/code/vibe-usage")
        #expect(result?.title == "vibe-usage")
        #expect(result?.subtitle == "~/code/vibe-usage")
    }

    @Test func fallsBackToNaiveReplacementWhenProbingFindsNoRealDirectory() {
        let humanizer = ProjectNameHumanizer(homeDirectory: "/Users/yuantang", directoryExists: { _ in false })

        let raw = "-Users-yuantang-code-vibe-usage"
        let result = humanizer.humanize(raw)
        // No directory ever exists, so the key stays the raw string (to avoid
        // colliding unrelated inputs), but the display falls back to naive
        // all-"/" replacement.
        #expect(result?.key == raw)
        #expect(result?.title == "usage")
        #expect(result?.subtitle == "~/code/vibe/usage")
    }

    @Test func normalAbsolutePathIsUsedAsIs() {
        let humanizer = ProjectNameHumanizer(homeDirectory: "/Users/yuantang", directoryExists: { _ in true })

        let result = humanizer.humanize("/Users/yuantang/code/vibe-usage")
        #expect(result?.key == "/Users/yuantang/code/vibe-usage")
        #expect(result?.title == "vibe-usage")
        #expect(result?.subtitle == "~/code/vibe-usage")
    }

    @Test func pathOutsideHomeDirectoryIsNotAbbreviated() {
        let humanizer = ProjectNameHumanizer(homeDirectory: "/Users/yuantang", directoryExists: { _ in true })

        let result = humanizer.humanize("/opt/tools/build")
        #expect(result?.key == "/opt/tools/build")
        #expect(result?.title == "build")
        #expect(result?.subtitle == "/opt/tools/build")
    }

    @Test func bareNamePassesThrough() {
        let humanizer = ProjectNameHumanizer(homeDirectory: "/Users/yuantang", directoryExists: { _ in false })

        let result = humanizer.humanize("my-workspace")
        #expect(result?.key == "my-workspace")
        #expect(result?.title == "my-workspace")
        #expect(result?.subtitle == nil)
    }

    @Test func cachesRepeatedLookups() {
        var callCount = 0
        let humanizer = ProjectNameHumanizer(homeDirectory: "/Users/yuantang", directoryExists: { _ in
            callCount += 1
            return false
        })

        _ = humanizer.humanize("-Users-yuantang-code-app")
        let countAfterFirst = callCount
        _ = humanizer.humanize("-Users-yuantang-code-app")
        #expect(callCount == countAfterFirst)
    }

    @Test func homeDirectoryRootAbbreviatesToTilde() {
        let humanizer = ProjectNameHumanizer(homeDirectory: "/Users/yuantang", directoryExists: { _ in true })

        let result = humanizer.humanize("/Users/yuantang")
        #expect(result?.subtitle == "~")
    }
}
