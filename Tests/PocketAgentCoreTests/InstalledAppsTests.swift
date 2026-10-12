import Foundation
import Testing
@testable import PocketAgentCore

struct InstalledAppsTests {
    private let apps = [
        InstalledApp(bundleID: "test.shop", names: ["闲鱼", "Flea Market"]),
        InstalledApp(bundleID: "test.browser", names: ["Safari"]),
        InstalledApp(bundleID: "test.unknown", names: [])
    ]

    @Test func resolvesDeviceReportedNamesAndAliases() {
        #expect(InstalledApps.resolve(name: " 闲鱼\n", in: apps) == .found(apps[0]))
        #expect(InstalledApps.resolve(name: "ＳＡＦＡＲＩ", in: apps) == .found(apps[1]))
        #expect(InstalledApps.resolve(name: "flea market", in: apps) == .found(apps[0]))
    }

    @Test func partialOrMissingNamesNeverBecomeAnImplicitLaunch() {
        #expect(InstalledApps.resolve(name: "闲", in: apps) == .notFound)
        #expect(InstalledApps.resolve(name: "test.unknown", in: apps) == .notFound)
        #expect(InstalledApps.resolve(name: "", in: apps) == .notFound)
        #expect(InstalledApps.search("闲", in: apps) == [apps[0]])
        #expect(InstalledApps.search("test.unknown", in: apps) == [apps[2]])
    }

    @Test func duplicateNamesReturnBothTargetsInsteadOfChoosingOne() {
        let other = InstalledApp(bundleID: "test.second", names: ["闲鱼"])
        #expect(InstalledApps.resolve(name: "闲鱼", in: apps + [other]) == .ambiguous([other, apps[0]].sorted { $0.bundleID < $1.bundleID }))
    }

    @Test func appExtensionsAndFrameworksAreNotLaunchTargets() {
        #expect(InstalledApps.isLaunchable(packageType: "APPL", path: "/apps/Shop.app", hasExtensionDefinition: false))
        #expect(!InstalledApps.isLaunchable(packageType: "XPC!", path: nil, hasExtensionDefinition: false))
        #expect(!InstalledApps.isLaunchable(packageType: nil, path: "/apps/Shop.app/PlugIns/Notify.appex", hasExtensionDefinition: false))
        #expect(!InstalledApps.isLaunchable(packageType: nil, path: nil, hasExtensionDefinition: true))
        #expect(!InstalledApps.isLaunchable(packageType: "BNDL", path: nil, hasExtensionDefinition: false))
        #expect(!InstalledApps.isLaunchable(packageType: nil, path: nil, hasExtensionDefinition: false))
    }

    @Test func systemLookupKeepsLocalizedSettingsAndExcludesHiddenNamesakes() {
        let records: [[String: Any]] = [
            ["CFBundleIdentifier": "com.apple.Preferences", "CFBundlePackageType": "APPL",
             "CFBundleDisplayName": "设置", "Path": "/Applications/Preferences.app"],
            ["CFBundleIdentifier": "com.apple.CarPlaySettings", "CFBundlePackageType": "APPL",
             "CFBundleDisplayName": "设置", "SBAppTags": ["hidden"]],
            ["CFBundleIdentifier": "test.extension", "CFBundlePackageType": "APPL",
             "CFBundleDisplayName": "设置", "NSExtension": [:]],
            ["CFBundleIdentifier": "test.offloaded", "CFBundlePackageType": "APPL",
             "CFBundleDisplayName": "设置", "IsDemotedApp": true],
        ]
        let apps = InstalledApps.fromMetadata(records)
        #expect(apps == [InstalledApp(bundleID: "com.apple.Preferences", names: ["设置"])])
        #expect(InstalledApps.resolve(name: "设置", in: apps) == .found(apps[0]))
        #expect(InstalledApps.search("com.apple.Preferences", in: apps) == apps)
    }

    @Test func metadataCopiesNamesDeduplicatesAndRejectsNonApplications() {
        let apps = InstalledApps.fromMetadata([
            ["CFBundleIdentifier": "test.app", "CFBundlePackageType": "APPL",
             "CFBundleDisplayName": " 应用 ", "CFBundleName": "应用"],
            ["CFBundleIdentifier": "test.app", "CFBundlePackageType": "APPL", "CFBundleName": "App"],
            ["CFBundleIdentifier": "test.xpc", "CFBundlePackageType": "XPC!", "CFBundleName": "App"],
            ["CFBundleIdentifier": "test.unknown", "CFBundleName": "App"],
            ["CFBundleIdentifier": "test.appex", "CFBundlePackageType": "APPL", "Path": "/PlugIns/App.appex"],
        ])
        #expect(apps == [InstalledApp(bundleID: "test.app", names: ["应用", "App"])])
    }

    @Test func searchesRankExactNamesAheadOfPartialNames() {
        let longer = InstalledApp(bundleID: "a.helper", names: ["闲鱼助手"])
        #expect(InstalledApps.search("闲鱼", in: apps + [longer]) == [apps[0], longer])
        #expect(InstalledApps.search("SAFARI", in: apps) == [apps[1]])
    }

    @Test func catalogAndPromptExposeDiscoveryWithoutAWorkspace() {
        let tools = Set(ToolCatalog.available(ToolCapabilities()).map(\.name))
        #expect(tools.isSuperset(of: ["find_apps", "open_app_by_name"]))
        #expect(!tools.contains("search_spotlight"))
        #expect(ToolCatalog.scriptDecision(for: "search_spotlight") != .allow)
        #expect(!AgentInstructions.phone(assistantBundleID: "test.assistant").contains("search_spotlight"))
        let prompt = AgentInstructions.phone(assistantBundleID: "test.assistant")
        #expect(prompt.contains("禁止凭记忆猜包名"))
        #expect(prompt.contains("不能直接重放点击或输入"))
    }
}
