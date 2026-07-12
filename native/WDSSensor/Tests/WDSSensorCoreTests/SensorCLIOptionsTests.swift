import Testing
@testable import WDSSensorCore

@Test func cliDefaultsToRedactedTextAndMouseCapture() throws {
    let options = try #require(
        try SensorCLIOptions.parse(["--bundle-id", "com.example.Editor"])
    )

    #expect(options.bundleIdentifier == "com.example.Editor")
    #expect(!options.emitText)
    #expect(!options.textOnly)
    #expect(options.mouseWindowMilliseconds == 2_000)
}

@Test func cliAcceptsRawTextOnlyAsExplicitIndependentFlags() throws {
    let options = try #require(
        try SensorCLIOptions.parse([
            "--text-only",
            "--bundle-id", "com.example.Editor",
            "--emit-text",
            "--duration-ms", "500",
        ])
    )

    #expect(options.emitText)
    #expect(options.textOnly)
    #expect(options.durationMilliseconds == 500)
}

@Test func cliRejectsDuplicateTextOnlyFlag() {
    #expect(throws: SensorCLIParseFailure.self) {
        try SensorCLIOptions.parse([
            "--bundle-id", "com.example.Editor",
            "--text-only",
            "--text-only",
        ])
    }
}

@Test func cliHelpRemainsAStandaloneControlPath() throws {
    #expect(try SensorCLIOptions.parse(["--help"]) == nil)
    #expect(try SensorCLIOptions.parse(["-h"]) == nil)
}

@Test func cliPreservesMouseWindowValidationInTextOnlyMode() {
    #expect(throws: SensorCLIParseFailure.self) {
        try SensorCLIOptions.parse([
            "--bundle-id", "com.example.Editor",
            "--text-only",
            "--mouse-window-ms", "99",
        ])
    }
}

@Test func cliParseErrorsDoNotEchoUnexpectedArguments() {
    let unexpected = "private-draft-fragment"
    do {
        _ = try SensorCLIOptions.parse([unexpected, "value"])
        Issue.record("Expected an unexpected_argument parse failure.")
    } catch let failure as SensorCLIParseFailure {
        #expect(failure.code == "unexpected_argument")
        #expect(!failure.message.contains(unexpected))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func textOnlyRuntimePlanDisablesEveryMousePermissionAndCapturePath() {
    let plan = SensorRuntimePlan(textOnly: true)

    #expect(!plan.usesMouseCapture)
    #expect(!plan.requiresInputMonitoringPermission)
    #expect(!plan.emitsMouseSummaries)
    #expect(plan.mouseOutputAttestation == "disabled")
}

@Test func defaultRuntimePlanPreservesExistingMouseBehavior() {
    let plan = SensorRuntimePlan(textOnly: false)

    #expect(plan.usesMouseCapture)
    #expect(plan.requiresInputMonitoringPermission)
    #expect(plan.emitsMouseSummaries)
    #expect(plan.mouseOutputAttestation == "derived_summary_only")
}

@Test func redactedDisclosurePlanNeverReadsAccessibilityValueOrLength() {
    let plan = SensorTextDisclosurePlan(emitText: false)

    #expect(!plan.readsAccessibilityValue)
    #expect(!plan.includesRawText)
    #expect(!plan.includesUTF16Length)
    #expect(plan.textRedacted)
}

@Test func rawDisclosurePlanRequiresExplicitValueReadAndDisclosure() {
    let plan = SensorTextDisclosurePlan(emitText: true)

    #expect(plan.readsAccessibilityValue)
    #expect(plan.includesRawText)
    #expect(plan.includesUTF16Length)
    #expect(!plan.textRedacted)
}
