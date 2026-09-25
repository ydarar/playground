import Foundation

// Runs every test in GoldieCoreTests. Add new tests to this list.
// Usage: swift run goldie-selftest   (debug build; @testable needs it)

#if DEBUG
let suite = GoldieCoreTests()
let tests: [(String, () throws -> Void)] = [
    ("testRulesMoodBands", suite.testRulesMoodBands),
    ("testRulesPickWorstThreadAndRespectSnooze", suite.testRulesPickWorstThreadAndRespectSnooze),
    ("testLoopScore", suite.testLoopScore),
    ("testSpeechBudgetAndAlarmFloor", suite.testSpeechBudgetAndAlarmFloor),
    ("testCelebratesFreshStartAfterNudge", suite.testCelebratesFreshStartAfterNudge),
    ("testBubbleParsingAndContextEstimate", suite.testBubbleParsingAndContextEstimate),
    ("testHookTrackerRuns", suite.testHookTrackerRuns),
    ("testPartialConfigMergesOverDefaults", suite.testPartialConfigMergesOverDefaults),
    ("testHandoffDraft", suite.testHandoffDraft),
    ("testLLMReplyParsing", suite.testLLMReplyParsing),
    ("testParseUsageEvents", suite.testParseUsageEvents),
    ("testJWTUserID", suite.testJWTUserID),
    ("testCostAttributionByTime", suite.testCostAttributionByTime),
    ("testRateFallbackWhenNoEventsMatch", suite.testRateFallbackWhenNoEventsMatch),
    ("testNearestDistance", suite.testNearestDistance),
    ("testStressedWhenMonthRunsHotButNoChatIsToBlame", suite.testStressedWhenMonthRunsHotButNoChatIsToBlame),
    ("testProjectionIsFilledFromLedger", suite.testProjectionIsFilledFromLedger),
    ("testModelPolicyBlocksChineseVendors", suite.testModelPolicyBlocksChineseVendors),
    ("testTaskKindClassification", suite.testTaskKindClassification),
    ("testSegmentsSplitOnUserMessagesAndDetectReask", suite.testSegmentsSplitOnUserMessagesAndDetectReask),
    ("testModelFitCanRecommendThePricierModel", suite.testModelFitCanRecommendThePricierModel),
    ("testModelFitStaysQuietWithoutEvidence", suite.testModelFitStaysQuietWithoutEvidence),
    ("testTaskStorePersistsFinishedPricedTasks", suite.testTaskStorePersistsFinishedPricedTasks),
    ("testBloatDetection", suite.testBloatDetection),
    ("testTaskStoreKeepsModelAndNeverLowersCost", suite.testTaskStoreKeepsModelAndNeverLowersCost),
    ("testLoopGuardBlocksRepeatsOnlyWithoutEdits", suite.testLoopGuardBlocksRepeatsOnlyWithoutEdits),
    ("testReadGuardDeniesOnceThenAllowsRetry", suite.testReadGuardDeniesOnceThenAllowsRetry),
    ("testHandoffWriterSavesInRepoAndExcludesFromGit", suite.testHandoffWriterSavesInRepoAndExcludesFromGit),
    ("testInstallerAddsGuardHooksOnlyWhenAskedAndKeepsUserHooks", suite.testInstallerAddsGuardHooksOnlyWhenAskedAndKeepsUserHooks),
    ("testHookReplyFailsOpen", suite.testHookReplyFailsOpen),
    ("testConversationIdAttributionIsExactAndNeverGuessed", suite.testConversationIdAttributionIsExactAndNeverGuessed),
    ("testTaskModelComesFromBilledEvents", suite.testTaskModelComesFromBilledEvents),
    ("testUsageEventReconciliationFields", suite.testUsageEventReconciliationFields),
    ("testBigReadIgnoresScreenshots", suite.testBigReadIgnoresScreenshots),
    ("testProbeHidesPathLikeKeys", suite.testProbeHidesPathLikeKeys),
    ("testLedgerKeepsNewestCopyOfARefetchedEvent", suite.testLedgerKeepsNewestCopyOfARefetchedEvent),
]

var failedTests = 0
for (name, run) in tests {
    let before = SelfTest.failures.count
    do { try run() } catch { SelfTest.failures.append("\(name): threw \(error)") }
    let newFailures = SelfTest.failures[before...]
    if newFailures.isEmpty {
        print("✓ \(name)")
    } else {
        failedTests += 1
        print("✗ \(name)")
        newFailures.forEach { print("    \($0)") }
    }
}
print("\n\(tests.count - failedTests)/\(tests.count) tests passed")
exit(failedTests == 0 ? 0 : 1)
#else
print("goldie-selftest needs a debug build: swift run goldie-selftest")
exit(1)
#endif
