import Darwin
import Foundation
import Testing
@testable import Parabolic

@Suite struct MemoryBreakdownTests {
    private let page: UInt64 = 16384

    /// Mirrors a real 36 GB Apple silicon `vm_stat` reading.
    private var counts: MemoryVMCounts {
        MemoryVMCounts(pageSize: page, free: 6020, active: 422_300, inactive: 418_045, speculative: 2494,
                       wired: 444_307, purgeable: 2, internalPages: 531_176, externalPages: 311_663,
                       compressorPages: 1_029_489, uncompressedInCompressor: 2_049_357)
    }

    @Test func activityMonitorCategories() {
        let b = MemoryBreakdown(counts: counts, total: 38_654_705_664)
        #expect(b.app == (531_176 - 2) * page)
        #expect(b.wired == 444_307 * page)
        #expect(b.compressed == 1_029_489 * page)
        #expect(b.cached == (311_663 + 2) * page)
        #expect(b.free == 6020 * page)
        #expect(b.used == b.app + b.wired + b.compressed)
        #expect(b.available == b.cached + b.free)
    }

    @Test func otherIsTheUncountedRemainder() {
        let b = MemoryBreakdown(counts: counts, total: 38_654_705_664)
        #expect(b.used + b.cached + b.free + b.other == b.total)
        #expect(b.other == (2_359_296 - 2_322_655) * page)
    }

    @Test func otherNeverGoesNegative() {
        let b = MemoryBreakdown(counts: counts, total: 1 << 30)
        #expect(b.other == 0)
    }

    @Test func purgeableLargerThanInternalClampsAppToZero() {
        var c = counts
        c.internalPages = 10
        c.purgeable = 50
        let b = MemoryBreakdown(counts: c, total: 1 << 34)
        #expect(b.app == 0)
        #expect(b.cached == (311_663 + 50) * page)
    }

    @Test func compressionRatio() {
        let b = MemoryBreakdown(counts: counts, total: 38_654_705_664)
        let ratio = try! #require(b.compressionRatio)
        #expect(abs(ratio - 2_049_357.0 / 1_029_489.0) < 0.0001)
        var empty = counts
        empty.compressorPages = 0
        #expect(MemoryBreakdown(counts: empty, total: 1 << 34).compressionRatio == nil)
    }

    @Test func pressureLevelsFromSysctl() {
        #expect(MemoryPressureLevel(sysctlValue: 1) == .normal)
        #expect(MemoryPressureLevel(sysctlValue: 2) == .warning)
        #expect(MemoryPressureLevel(sysctlValue: 4) == .critical)
        #expect(MemoryPressureLevel(sysctlValue: 0) == nil)
        #expect(MemoryPressureLevel(sysctlValue: 3) == nil)
    }

    /// Read-only: exercises the real Mach/sysctl calls without changing anything.
    @Test func liveSampleIsConsistent() throws {
        let snapshot = try MemorySampler.read()
        let b = snapshot.breakdown
        #expect(b.total > 0)
        #expect(snapshot.counts.pageSize >= 4096)
        #expect(b.used + b.cached + b.free <= b.total + (b.total / 20))
        if let percent = snapshot.pressurePercent { #expect((0...100).contains(percent)) }
    }
}

@Suite struct MemoryGroupingTests {
    @Test(arguments: [
        ("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
         "/Applications/Google Chrome.app"),
        ("/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "/Applications/Utilities/Terminal.app"),
        ("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
         "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
        ("/Users/me/Applications/Foo.APP/Contents/MacOS/Foo", "/Users/me/Applications/Foo.APP"),
    ])
    func outermostApp(path: String, expected: String) {
        #expect(MemoryBundlePath.outermostApp(of: path) == expected)
    }

    @Test func pathsOutsideBundles() {
        #expect(MemoryBundlePath.outermostApp(of: "/usr/libexec/trustd") == nil)
        #expect(MemoryBundlePath.outermostApp(of: "/opt/homebrew/bin/node") == nil)
        #expect(MemoryBundlePath.outermostApp(of: "/Users/me/.app/bin/tool") == nil)
        #expect(MemoryBundlePath.outermostApp(of: "relative/Foo.app/x") == nil)
        #expect(MemoryBundlePath.outermostApp(of: nil) == nil)
    }

    @Test func displayName() {
        #expect(MemoryBundlePath.displayName(ofApp: "/Applications/Google Chrome.app") == "Google Chrome")
    }

    private func process(_ pid: pid_t, _ path: String?, _ mb: UInt64?, responsible: pid_t? = nil) -> MemoryProcess {
        MemoryProcess(pid: pid, name: path.map { ($0 as NSString).lastPathComponent } ?? "p\(pid)", path: path,
                      footprint: mb.map { $0 << 20 }, responsiblePID: responsible)
    }

    @Test func helpersAndResponsibleProcessesRollUp() {
        let safari = "/Applications/Safari.app"
        let chrome = "/Applications/Google Chrome.app"
        let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        let groups = MemoryGrouping.group([
            process(10, "\(safari)/Contents/MacOS/Safari", 300),
            process(11, webContent, 900, responsible: 10),
            process(20, "\(chrome)/Contents/MacOS/Google Chrome", 400),
            process(21, "\(chrome)/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/H", 1500),
            process(30, "/usr/libexec/trustd", 20),
            process(31, "/usr/sbin/cfprefsd", nil),
            process(40, "/opt/homebrew/bin/node", 50, responsible: 999),
        ])
        #expect(groups.map(\.id) == [chrome, safari, MemoryGroup.systemID])
        #expect(groups[0].footprint == 1900 << 20)
        #expect(groups[0].processes.map(\.pid) == [21, 20])
        #expect(groups[1].footprint == 1200 << 20)
        #expect(groups[1].name == "Safari")
        let system = groups[2]
        #expect(system.isSystem)
        #expect(system.name == "System & background")
        // Unreadable processes are counted by the scan, not shown with a made-up size.
        #expect(Set(system.processes.map(\.pid)) == [30, 40])
    }

    @Test func filteringAndSorting() {
        let groups = MemoryGrouping.group([
            process(1, "/Applications/Zed.app/Contents/MacOS/zed", 100),
            process(2, "/Applications/Arc.app/Contents/MacOS/Arc", 50),
            process(3, "/Applications/Arc.app/Contents/MacOS/Arc Helper", 10),
            process(4, "/usr/libexec/trustd", 900),
        ])
        #expect(groups.memoryFiltered("", order: .memory).map(\.name) == ["Zed", "Arc", "System & background"])
        #expect(groups.memoryFiltered("", order: .name).map(\.name) == ["Arc", "Zed", "System & background"])
        #expect(groups.memoryFiltered("", order: .processes).first?.name == "Arc")
        #expect(groups.memoryFiltered("helper", order: .memory).map(\.name) == ["Arc"])
        #expect(groups.memoryFiltered("trust", order: .memory).map(\.name) == ["System & background"])
        #expect(groups.memoryFiltered("  ", order: .memory).count == 3)
    }

    /// Read-only scan of the real process table.
    @Test func liveScanFindsThisProcess() {
        let scan = MemoryProcessReader.scan()
        let me = scan.processes.first { $0.pid == getpid() }
        #expect(me != nil)
        #expect((me?.footprint ?? 0) > 0)
        #expect(scan.processes.count > 10)
    }
}

@Suite struct MemoryAdviceTests {
    private func breakdown(free: UInt64 = 1000, cached: UInt64 = 50_000, compressed: UInt64 = 100_000) -> MemoryBreakdown {
        MemoryBreakdown(counts: MemoryVMCounts(pageSize: 16384, free: free, wired: 100_000, internalPages: 500_000,
                                               externalPages: cached, compressorPages: compressed),
                        total: 1 << 35)
    }

    private let chrome = MemoryCandidate(name: "Google Chrome", footprint: 3_328_599_654)

    @Test func normalPressureSaysPlenty() {
        let v = MemoryVerdict.make(pressure: .normal, breakdown: breakdown(free: 400_000), swap: MemorySwap(total: 0, used: 0), candidate: chrome)
        #expect(v.severity == .ok)
        #expect(v.headline == "Plenty of memory free")
        #expect(!v.detail.contains("swap"))
    }

    @Test func normalPressureWithLittleLeftIsBusyNotPlenty() {
        let v = MemoryVerdict.make(pressure: .normal, breakdown: breakdown(), swap: MemorySwap(total: 0, used: 0), candidate: chrome)
        #expect(v.severity == .ok)
        #expect(v.headline == "Memory is busy, but macOS is keeping up")
    }

    @Test func normalPressureMentionsLeftoverSwap() {
        let v = MemoryVerdict.make(pressure: .normal, breakdown: breakdown(), swap: MemorySwap(total: 4 << 30, used: 2 << 30), candidate: nil)
        #expect(v.detail.contains("swap"))
    }

    @Test func warningNamesTheBiggestApp() {
        let v = MemoryVerdict.make(pressure: .warning, breakdown: breakdown(), swap: MemorySwap(total: 4 << 30, used: 1 << 30), candidate: chrome)
        #expect(v.severity == .warning)
        #expect(v.headline == "Memory is tight — quitting Google Chrome would free about \(MemoryFormat.bytes(chrome.footprint))")
        #expect(v.detail.contains("moved to disk"))
    }

    @Test func smallCandidatesAreNotSuggested() {
        let tiny = MemoryCandidate(name: "Notes", footprint: 40 << 20)
        let v = MemoryVerdict.make(pressure: .warning, breakdown: breakdown(), swap: nil, candidate: tiny)
        #expect(v.headline == "Memory is tight")
        #expect(v.detail.contains("Close windows"))
    }

    @Test func critical() {
        let v = MemoryVerdict.make(pressure: .critical, breakdown: breakdown(), swap: nil, candidate: chrome)
        #expect(v.severity == .critical)
        #expect(v.headline.hasPrefix("Memory is critically low — quitting Google Chrome would free about"))
    }

    @Test func footprintBiggerThanUsedIsNotPromisedAsFreed() {
        let huge = MemoryCandidate(name: "kitty", footprint: 46 << 30)
        let v = MemoryVerdict.make(pressure: .critical, breakdown: breakdown(), swap: nil, candidate: huge)
        #expect(v.headline == "Memory is critically low — kitty is using \(MemoryFormat.bytes(huge.footprint)), counting what’s compressed or in swap")
    }

    @Test func unknownPressureIsHonest() {
        let v = MemoryVerdict.make(pressure: nil, breakdown: breakdown(), swap: nil, candidate: chrome)
        #expect(v.severity == .unknown)
        #expect(!v.headline.contains("Chrome"))
    }

    @Test func quitPolicy() {
        let me = "/Applications/Root.app"
        func can(_ id: String?, _ path: String) -> Bool {
            MemoryQuitPolicy.canQuit(bundleID: id, bundlePath: path, ownBundleID: "app.scoop", ownBundlePath: me)
        }
        #expect(can("com.google.Chrome", "/Applications/Google Chrome.app"))
        #expect(can("com.apple.Safari", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"))
        #expect(!can("com.apple.finder", "/System/Library/CoreServices/Finder.app"))
        #expect(!can("com.apple.dock", "/System/Library/CoreServices/Dock.app"))
        #expect(!can("com.apple.loginwindow", "/System/Library/CoreServices/loginwindow.app"))
        #expect(!can("com.example.agent", "/System/Library/PrivateFrameworks/X.framework/Agent.app"))
        #expect(!can("app.scoop", "/Users/me/Desktop/Root.app"))
        #expect(!can(nil, me))
    }

    @Test func purgeSummaries() {
        let big = MemoryPurgeResult(freeBefore: 100 << 20, freeAfter: 2100 << 20, cachedBefore: 5 << 30, cachedAfter: 3 << 30)
        #expect(big.freeGain == 2000 << 20)
        #expect(big.headline.hasPrefix("Free memory up"))
        #expect(big.summary.contains("file cache"))

        let small = MemoryPurgeResult(freeBefore: 100 << 20, freeAfter: 200 << 20, cachedBefore: 1 << 30, cachedAfter: 1 << 30)
        #expect(small.summary.contains("small"))

        let none = MemoryPurgeResult(freeBefore: 300 << 20, freeAfter: 200 << 20, cachedBefore: 1 << 30, cachedAfter: 1 << 30)
        #expect(none.freeGain < 0)
        #expect(none.headline == "Free memory didn’t go up")
    }
}

@Suite struct MemoryCommandLineToolTests {
    private let kitty = "/Applications/kitty.app"
    private let zed = "/Applications/Zed.app"

    private func process(_ pid: pid_t, _ path: String?, _ mb: UInt64?, responsible: pid_t? = nil, uid: uid_t? = 501) -> MemoryProcess {
        MemoryProcess(pid: pid, name: path.map { ($0 as NSString).lastPathComponent } ?? "p\(pid)", path: path,
                      footprint: mb.map { $0 << 20 }, responsiblePID: responsible, uid: uid)
    }

    private func isHost(_ path: String) -> Bool { path == kitty || path == zed }

    @Test func terminalChildrenAreToolsNotTerminalMemory() {
        let groups = MemoryGrouping.group([
            process(1, "\(kitty)/Contents/MacOS/kitty", 200),
            process(2, "\(kitty)/Contents/MacOS/kitten", 30, responsible: 1),
            process(3, "/bin/zsh", 5, responsible: 1),
            process(4, "/opt/homebrew/bin/node", 900, responsible: 1),
            process(5, "/opt/homebrew/Cellar/node/26/bin/node", 700, responsible: 1),
            // Framework-hosted binary: not a plain CLI path, but its host is a terminal, so still a tool.
            process(6, "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12", 400, responsible: 1),
            process(7, "/Users/me/.vscode/rust-analyzer", 300, responsible: 8),
            process(8, "\(zed)/Contents/MacOS/zed", 250),
        ], isHost: isHost)

        let terminal = groups.first { $0.id == kitty }
        #expect(terminal?.footprint == 230 << 20)
        #expect(terminal?.processes.map(\.pid) == [1, 2])

        let node = groups.first { $0.id == "tool:node" }
        #expect(node?.kind == .tool)
        #expect(node?.processes.count == 2)
        #expect(node?.footprint == 1600 << 20)
        #expect(node?.hostNames == ["kitty"])
        #expect(groups.first { $0.id == "tool:python3.12" }?.isTool == true)
        #expect(groups.first { $0.id == "tool:rust-analyzer" }?.hostNames == ["Zed"])
        #expect(groups.first { $0.id == zed }?.footprint == 250 << 20)

        // Apps, then tools (largest first), then system.
        #expect(groups.map(\.kind) == [.app, .app, .tool, .tool, .tool, .tool])
        #expect(groups.filter(\.isTool).first?.name == "node")
        #expect(MemoryGrouping.hostPaths(in: groups) == [kitty, zed])
    }

    @Test func plainBinariesFromUnknownAppsAreTools() {
        let newTerm = "/Applications/NewTerm.app"
        let safari = "/Applications/Safari.app"
        let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        let groups = MemoryGrouping.group([
            process(1, "\(newTerm)/Contents/MacOS/NewTerm", 100),
            process(2, "/usr/bin/ssh", 10, responsible: 1),
            process(3, "\(safari)/Contents/MacOS/Safari", 300),
            process(4, webContent, 900, responsible: 3),
        ], isHost: { _ in false })
        #expect(groups.first { $0.id == "tool:ssh" }?.hostNames == ["NewTerm"])
        #expect(groups.first { $0.id == newTerm }?.footprint == 100 << 20)
        // Bundled XPC helpers still roll up into the app responsible for them.
        #expect(groups.first { $0.id == safari }?.footprint == 1200 << 20)
    }

    @Test func scoopKeepsItsOwnDownloads() {
        let scoop = "/Applications/Root.app"
        let groups = MemoryGrouping.group([
            process(1, "\(scoop)/Contents/MacOS/Parabolic", 150),
            process(2, "/Users/me/Library/Application Support/Parabolic/bin/yt-dlp", 80, responsible: 1),
        ], ownAppPath: scoop, isHost: { _ in false })
        #expect(groups.map(\.id) == [scoop])
        #expect(groups[0].processes.count == 2)
    }

    @Test func commandLineBinaryDetection() {
        #expect(MemoryBundlePath.isCommandLineBinary("/opt/homebrew/bin/node"))
        #expect(MemoryBundlePath.isCommandLineBinary("/bin/zsh"))
        #expect(!MemoryBundlePath.isCommandLineBinary("/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"))
        #expect(!MemoryBundlePath.isCommandLineBinary("/System/Library/Foo.xpc/Contents/MacOS/Foo"))
        #expect(!MemoryBundlePath.isCommandLineBinary("/Applications/X.app/Contents/MacOS/X"))
        #expect(!MemoryBundlePath.isCommandLineBinary(nil))
    }

    @Test(arguments: ["net.kovidgoyal.kitty", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                      "com.github.wez.wezterm", "dev.warp.Warp-Stable", "org.alacritty", "co.zeit.hyper", "org.tabby",
                      "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.jetbrains.intellij",
                      "com.jetbrains.pycharm"])
    func knownHosts(bundleID: String) {
        #expect(MemoryHostApps.isHost(bundleID: bundleID))
    }

    @Test func nonHosts() {
        #expect(!MemoryHostApps.isHost(bundleID: "com.google.Chrome"))
        #expect(!MemoryHostApps.isHost(bundleID: nil))
    }

    @Test func suggestionsNeverIncludeTerminals() {
        let chrome = "/Applications/Google Chrome.app"
        let iterm = "/Applications/iTerm.app"
        let newTerm = "/Applications/NewTerm.app"
        let notes = "/Applications/Notes.app"
        let groups = MemoryGrouping.group([
            process(1, "\(kitty)/Contents/MacOS/kitty", 9000),
            process(2, "\(iterm)/Contents/MacOS/iTerm2", 8000),
            process(3, "\(newTerm)/Contents/MacOS/NewTerm", 7000),
            process(4, "/bin/zsh", 5, responsible: 3),
            process(5, "\(chrome)/Contents/MacOS/Google Chrome", 3000),
            process(6, "\(notes)/Contents/MacOS/Notes", 2000),
        ], isHost: { _ in false })
        func info(_ pid: pid_t, active: Bool = false, host: Bool = false) -> MemoryAppInfo {
            MemoryAppInfo(pid: pid, bundleID: nil, isActive: active, isHidden: false, isSelf: false, canQuit: true, isHost: host)
        }
        let apps = [kitty: info(1, host: true), iterm: info(2, host: true), newTerm: info(3),
                    chrome: info(5), notes: info(6, active: true)]
        // kitty/iTerm by bundle id, NewTerm because it launched a tool, Notes because it's in front.
        #expect(MemorySuggestions.pick(groups, apps: apps).map(\.id) == [chrome])
    }

    @Test func killPolicy() {
        let me: uid_t = 501
        #expect(MemoryKillPolicy.canSignal(process(400, "/opt/homebrew/bin/node", 10, uid: me), ownUID: me, ownPID: 100))
        #expect(!MemoryKillPolicy.canSignal(process(400, "/usr/sbin/x", 10, uid: 0), ownUID: me, ownPID: 100))
        #expect(!MemoryKillPolicy.canSignal(process(400, "/usr/bin/x", 10, uid: 502), ownUID: me, ownPID: 100))
        #expect(!MemoryKillPolicy.canSignal(process(400, "/usr/bin/x", 10, uid: nil), ownUID: me, ownPID: 100))
        #expect(!MemoryKillPolicy.canSignal(process(100, "/x", 10, uid: me), ownUID: me, ownPID: 100))
        #expect(!MemoryKillPolicy.canSignal(process(1, "/sbin/launchd", 10, uid: me), ownUID: me, ownPID: 100))
        #expect(!MemoryKillPolicy.canSignal(process(400, "/x/yt-dlp", 10, responsible: 100, uid: me), ownUID: me, ownPID: 100))
        #expect(!MemoryKillPolicy.canSignal(process(400, "/x", 10, uid: 0), ownUID: 0, ownPID: 100))
    }
}
