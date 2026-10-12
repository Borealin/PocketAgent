import Foundation
import Testing
@testable import PocketAgentCore

@Suite struct RunnerBundleIDTests {
    private let main = "io.github.borealin.PocketAgent"
    private let runner = "io.github.borealin.PocketAgent.WDA.xctrunner"

    @Test func UnsuffixedPublicInstallationUsesItsInstalledCompanion() throws {
        #expect(try RunnerBundleID.resolve(override: nil, embeddedDefaultID: runner,
            assistantBundleID: main, installedIDs: [runner]) == runner)
    }

    @Test func SideStoreMatchingSuffixWinsOverDefaultAndOtherAccounts() throws {
        let actualMain = main + ".TESTTEAM01"
        let matching = runner + ".TESTTEAM01"
        let other = runner + ".OTHERTEAM1"
        #expect(try RunnerBundleID.resolve(override: nil, embeddedDefaultID: runner,
            assistantBundleID: actualMain, installedIDs: [runner, matching, other]) == matching)
    }

    @Test func SuffixIsNotRestrictedToOneInstallerTeamIDLength() throws {
        let suffix = "test-signer"
        #expect(try RunnerBundleID.resolve(override: nil, embeddedDefaultID: runner,
            assistantBundleID: main + "." + suffix, installedIDs: [runner + "." + suffix]) == runner + "." + suffix)
    }

    @Test func ExplicitInstalledOverrideWinsAndIsNotRewritten() throws {
        let custom = "org.example.Automation.dev"
        #expect(try RunnerBundleID.resolve(override: custom, embeddedDefaultID: runner,
            assistantBundleID: main + ".TESTTEAM01", installedIDs: [custom, runner, runner + ".TESTTEAM01"]) == custom)
    }

    @Test func MissingOverrideDoesNotSilentlySelectAnAutomaticCompanion() {
        #expect(throws: RunnerBundleID.ResolutionError.overrideNotInstalled) {
            try RunnerBundleID.resolve(override: "org.example.Automation.missing", embeddedDefaultID: runner,
                assistantBundleID: main + ".TESTTEAM01", installedIDs: [runner, runner + ".TESTTEAM01"])
        }
    }

    @Test func EmptyOverrideRetainsAutomaticMatching() throws {
        #expect(try RunnerBundleID.resolve(override: " \n", embeddedDefaultID: runner,
            assistantBundleID: main + ".TESTTEAM01", installedIDs: [runner + ".TESTTEAM01"]) == runner + ".TESTTEAM01")
    }

    @Test func LocalDevelopmentBuildUsesOnlyItsExactEmbeddedID() throws {
        let local = "org.example.Automation.dev"
        #expect(try RunnerBundleID.resolve(override: nil, embeddedDefaultID: local,
            assistantBundleID: "org.example.Assistant.dev", installedIDs: [local, local + ".test", runner]) == local)
        #expect(throws: RunnerBundleID.ResolutionError.automationNotInstalled) {
            try RunnerBundleID.resolve(override: nil, embeddedDefaultID: local,
                assistantBundleID: main + ".TESTTEAM01", installedIDs: [local + ".TESTTEAM01", runner + ".TESTTEAM01"])
        }
    }

    @Test func MissingCurrentSignerCompanionNeverSelectsForeignOrAmbiguousSuffixes() {
        for installed: Set<String> in [[runner + ".OTHERTEAM1"],
                                      [runner + ".OTHERTEAM1", runner + ".OTHERTEAM2"], []] {
            #expect(throws: RunnerBundleID.ResolutionError.automationNotInstalled) {
                try RunnerBundleID.resolve(override: nil, embeddedDefaultID: runner,
                    assistantBundleID: main + ".TESTTEAM01", installedIDs: installed)
            }
        }
    }

    @Test func ExactDefaultRemainsAnEligibleInstalledFallback() throws {
        #expect(try RunnerBundleID.resolve(override: nil, embeddedDefaultID: runner,
            assistantBundleID: main + ".TESTTEAM01", installedIDs: [runner, runner + ".OTHERTEAM1"]) == runner)
    }

    @Test func ArbitraryPrefixesAndMultipleSuffixComponentsAreNotGuessed() {
        for actualMain in [main + "Copy.TESTTEAM01", main + ".copy.TESTTEAM01",
                           "org.example.PocketAgent.TESTTEAM01", main + ".", main + ".签名",
                           main + ".TESTTEAM01\n", main + ".TEST_TEAM01"] {
            #expect(throws: RunnerBundleID.ResolutionError.automationNotInstalled) {
                try RunnerBundleID.resolve(override: nil, embeddedDefaultID: runner,
                    assistantBundleID: actualMain, installedIDs: [runner + ".TESTTEAM01", runner + ".copy.TESTTEAM01"])
            }
        }
    }

    @Test func UnsuffixedMainDoesNotSelectASignedCompanionByPrefix() {
        #expect(throws: RunnerBundleID.ResolutionError.automationNotInstalled) {
            try RunnerBundleID.resolve(override: nil, embeddedDefaultID: runner,
                assistantBundleID: main, installedIDs: [runner + ".TESTTEAM01"])
        }
    }

    @Test func MissingCompanionErrorExplainsInstallationAndAdvancedSetting() {
        let missing = RunnerBundleID.ResolutionError.automationNotInstalled.localizedDescription
        #expect(missing.contains("安装 Automation"))
        #expect(missing.contains("高级设备设置"))
        let manual = RunnerBundleID.ResolutionError.overrideNotInstalled.localizedDescription
        #expect(manual.contains("留空可自动匹配"))
    }
}
