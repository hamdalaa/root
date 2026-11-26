import Darwin
import Foundation
import Testing
@testable import Parabolic

private func app(_ pid: pid_t, _ name: String, bundleID: String? = nil, path: String? = nil,
                 isSelf: Bool = false) -> ForceQuitRunningApp {
    ForceQuitRunningApp(pid: pid, bundleID: bundleID ?? "com.test.\(name.lowercased())", name: name,
                        bundlePath: path ?? "/Applications/\(name).app", isSelf: isSelf)
}

private func process(_ pid: pid_t, path: String?, footprint: UInt64?, responsible: pid_t? = nil,
                     cpu: UInt64 = 0) -> ForceQuitProcessSample {
    ForceQuitProcessSample(pid: pid, path: path, footprint: footprint, responsiblePID: responsible, cpuNanoseconds: cpu)
}

@Suite struct ForceQuitAggregationTests {
    @Test func helpersInsideTheBundleCountTowardTheApp() {
        let apps = [app(100, "Chrome", path: "/Applications/Chrome.app")]
        let processes = [
            process(100, path: "/Applications/Chrome.app/Contents/MacOS/Chrome", footprint: 500),
            process(101, path: "/Applications/Chrome.app/Contents/Frameworks/Helper (Renderer).app/Contents/MacOS/Helper",
                    footprint: 1500),
        ]
        let rows = ForceQuitAggregator.rows(apps: apps, processes: processes)
        #expect(rows.count == 1)
        #expect(rows[0].memory == 2000)
        #expect(rows[0].processCount == 2)
    }

    @Test func processesOutsideTheBundleJoinTheResponsibleApp() {
        let apps = [app(200, "Safari", path: "/Applications/Safari.app")]
        let processes = [
            process(200, path: "/Applications/Safari.app/Contents/MacOS/Safari", footprint: 100),
            process(201, path: "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent.xpc/WebContent",
                    footprint: 900, responsible: 200),
            process(300, path: "/usr/libexec/unrelated", footprint: 5000, responsible: nil),
        ]
        let rows = ForceQuitAggregator.rows(apps: apps, processes: processes)
        #expect(rows.first?.memory == 1000)
    }

    @Test func unreadableFootprintsCountAsZeroButTheAppStillShows() {
        let rows = ForceQuitAggregator.rows(apps: [app(1, "Locked")],
                                            processes: [process(1, path: "/Applications/Locked.app/Contents/MacOS/Locked",
                                                                footprint: nil)])
        #expect(rows.count == 1)
        #expect(rows[0].memory == 0)
    }

    @Test func sortedByMemoryLargestFirstThenName() {
        let apps = [app(1, "Small"), app(2, "Big"), app(3, "Alpha"), app(4, "Beta")]
        let processes = [
            process(1, path: "/Applications/Small.app/x", footprint: 10),
            process(2, path: "/Applications/Big.app/x", footprint: 999),
            process(3, path: "/Applications/Alpha.app/x", footprint: 50),
            process(4, path: "/Applications/Beta.app/x", footprint: 50),
        ]
        let names = ForceQuitAggregator.rows(apps: apps, processes: processes).map(\.name)
        #expect(names == ["Big", "Alpha", "Beta", "Small"])
    }

    @Test func cpuComesFromTheDifferenceBetweenTwoSamples() {
        let apps = [app(1, "Busy")]
        let before = [process(1, path: "/Applications/Busy.app/x", footprint: 1, cpu: 1_000_000_000)]
        let after = [process(1, path: "/Applications/Busy.app/x", footprint: 1, cpu: 1_500_000_000)]
        let first = ForceQuitAggregator.rows(apps: apps, processes: before)
        #expect(first[0].cpuPercent == nil, "no CPU figure from a single sample")
        let second = ForceQuitAggregator.rows(apps: apps, processes: after,
                                              previousCPU: ForceQuitAggregator.cpuTotals(first), elapsed: 1.0)
        #expect(second[0].cpuPercent == 50)
    }
}

@Suite struct ForceQuitCPUTests {
    @Test func percentOfOneCoreOverTheInterval() {
        #expect(ForceQuitCPU.percent(previous: 0, current: 2_000_000_000, elapsed: 1) == 200)
        #expect(ForceQuitCPU.percent(previous: 5, current: 5, elapsed: 1) == 0)
    }

    @Test func noFigureForABadInterval() {
        #expect(ForceQuitCPU.percent(previous: 10, current: 5, elapsed: 1) == nil, "pid reused: counter went back")
        #expect(ForceQuitCPU.percent(previous: 0, current: 5, elapsed: 0) == nil)
    }

    @Test func machTicksToNanoseconds() {
        // Apple silicon timebase is 125/3: 24 MHz ticks.
        #expect(ForceQuitCPU.nanoseconds(machTicks: 24_000_000, numer: 125, denom: 3) == 1_000_000_000)
        #expect(ForceQuitCPU.nanoseconds(machTicks: 7, numer: 1, denom: 1) == 7)
        #expect(ForceQuitCPU.nanoseconds(machTicks: 7, numer: 1, denom: 0) == 7)
    }
}

@Suite struct ForceQuitPolicyTests {
    private var rows: [ForceQuitApp] {
        [
            ForceQuitApp(app: app(1, "Root", bundleID: "com.hamad.parabolic", isSelf: true)),
            ForceQuitApp(app: app(2, "Finder", bundleID: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app")),
            ForceQuitApp(app: app(3, "Safari", bundleID: "com.apple.Safari")),
            ForceQuitApp(app: app(4, "Xcode", bundleID: "com.apple.dt.Xcode")),
            ForceQuitApp(app: app(5, "Slack")),
        ]
    }

    @Test func rootCanNeverQuitItself() {
        #expect(!ForceQuitPolicy.canQuit(rows[0]))
        #expect(ForceQuitPolicy.canQuit(rows[2]))
    }

    @Test func finderIsRelaunchedNotEndedByQuitAll() {
        #expect(ForceQuitPolicy.canQuit(rows[1]), "Finder can be force quit on its own (macOS relaunches it)")
        let targets = ForceQuitPolicy.targetsForQuitAll(rows, keeping: [])
        #expect(!targets.contains { $0.pid == 2 })
    }

    @Test func quitAllExceptKeepsTheChosenAppsAndRoot() {
        let targets = ForceQuitPolicy.targetsForQuitAll(rows, keeping: [4]).map(\.pid)
        #expect(targets == [3, 5])
    }

    @Test func confirmTextNamesTheAppsAndCount() {
        let targets = ForceQuitPolicy.targetsForQuitAll(rows, keeping: [4])
        let text = ForceQuitPolicy.confirmMessage(for: targets)
        #expect(text.contains("2 apps"))
        #expect(text.contains("Safari"))
        #expect(text.contains("Slack"))
    }
}

@Suite struct ForceQuitEscalationTests {
    private final class Probe: @unchecked Sendable {
        var alive = true
        var signals: [Int32] = []
    }

    @Test func forceTerminateThatWorksNeedsNoSignal() async {
        let probe = Probe()
        let outcome = await ForceQuitEscalation.run(
            pid: 42, name: "App",
            forceTerminate: { probe.alive = false; return true },
            isAlive: { probe.alive },
            sendSignal: { _, sig in probe.signals.append(sig); return 0 },
            wait: { _ in })
        #expect(outcome == .terminated)
        #expect(probe.signals.isEmpty)
    }

    @Test func stuckAppFallsBackToSIGKILL() async {
        let probe = Probe()
        let outcome = await ForceQuitEscalation.run(
            pid: 42, name: "App",
            forceTerminate: { false },
            isAlive: { probe.alive },
            sendSignal: { _, sig in probe.signals.append(sig); probe.alive = false; return 0 },
            wait: { _ in })
        #expect(outcome == .killed)
        #expect(probe.signals == [SIGKILL])
    }

    @Test func reportsFailureWhenEvenSIGKILLIsRefused() async {
        let probe = Probe()
        let outcome = await ForceQuitEscalation.run(
            pid: 42, name: "App",
            forceTerminate: { false },
            isAlive: { probe.alive },
            sendSignal: { _, _ in -1 },
            wait: { _ in })
        guard case .failed = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
    }
}

/// Owner, 2026-11-18: Force Quit lives in the main window as the last Mac Care page.
@Suite struct ForceQuitPageTests {
    @MainActor @Test func forceQuitIsTheLastMacCareTool() {
        #expect(SidebarItem.careTools == [.memory, .storage, .cleanup, .uninstaller, .loginItems, .forceQuit])
        #expect(SidebarItem.forceQuit.title == "Force Quit")
        #expect(SidebarItem.forceQuit.symbol == "xmark.octagon")
        #expect(!SidebarItem.forceQuit.showsDownloads)
    }

    @Test func searchMatchesNameOrBundleID() {
        let apps = [ForceQuitApp(app: app(1, "Slack", bundleID: "com.tinyspeck.slackmacgap")),
                    ForceQuitApp(app: app(2, "Brave Browser", bundleID: "com.brave.Browser"))]
        #expect(ForceQuitPolicy.filter(apps, query: "slack").map(\.name) == ["Slack"])
        #expect(ForceQuitPolicy.filter(apps, query: "com.brave").map(\.name) == ["Brave Browser"])
        #expect(ForceQuitPolicy.filter(apps, query: "  ").count == 2)
    }

    @Test func busiestAppNeedsACPUFigure() {
        var quiet = ForceQuitApp(app: app(1, "Notes"))
        quiet.cpuPercent = 0.4
        var busy = ForceQuitApp(app: app(2, "Discord"))
        busy.cpuPercent = 72
        let unknown = ForceQuitApp(app: app(3, "Mail"))
        #expect(ForceQuitPolicy.busiest([quiet, busy, unknown])?.name == "Discord")
        #expect(ForceQuitPolicy.busiest([unknown]) == nil)
    }
}
