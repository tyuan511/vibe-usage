import VibeUsageCore

public enum AdditionalSourceAdapters {
    public static let all: [any UsageSourceAdapter] = [
        OpenCodeUsageAdapter(),
        AmpUsageAdapter(),
        DroidUsageAdapter(),
        HermesUsageAdapter(),
        PiAgentUsageAdapter(),
        OhMyPiUsageAdapter(),
        FastVibeUsageAdapter(),
        GooseUsageAdapter(),
        OpenClawUsageAdapter(),
        KiloUsageAdapter(),
        KimiUsageAdapter(),
        QwenUsageAdapter(),
        GitHubCopilotUsageAdapter(),
        GeminiUsageAdapter()
    ]
}
