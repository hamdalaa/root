import Foundation
import Testing
@testable import Parabolic

@Suite("Login item analysis")
struct LoginItemAnalysisTests {
    private let home = "/Users/me"

    private func plist(program: String? = nil, args: [String] = [], path: String? = nil) -> LoginItemPlist {
        var plist = LoginItemPlist()
        plist.program = program
        plist.arguments = args
        plist.pathEnvironment = path
        return plist
    }

    private func health(_ plist: LoginItemPlist?, existing: Set<String>, mounted: Set<String> = ["External"]) -> LoginItemHealth {
        LoginItemInspector.evaluate(plist: plist, parseError: nil, home: home,
                                    fileExists: { existing.contains($0) }, mountedVolumes: mounted)
    }

    // MARK: Broken detection

    @Test("Missing absolute program is broken; present is ok")
    func brokenProgram() {
        #expect(health(plist(program: "/opt/gone/tool"), existing: []).isBroken)
        #expect(health(plist(program: "/opt/tool"), existing: ["/opt/tool"]) == .ok)
        #expect(health(plist(args: ["~/bin/tool"]), existing: ["/Users/me/bin/tool"]) == .ok)
        #expect(health(plist(args: ["$HOME/bin/tool"]), existing: ["/Users/me/bin/tool"]) == .ok)
    }

    @Test("Program on a disconnected drive isn't counted as broken")
    func offlineVolume() {
        let result = health(plist(program: "/Volumes/Backup/tool"), existing: [], mounted: ["External"])
        #expect(result == .volumeOffline("Backup"))
        #expect(!result.isBroken)
        #expect(health(plist(program: "/Volumes/External/tool"), existing: [], mounted: ["External"]).isBroken)
    }

    @Test("Missing scripts run by an interpreter are broken; inline code isn't checked")
    func scripts() {
        #expect(health(plist(args: ["/usr/bin/python3", "/Users/me/gone.py"]), existing: ["/usr/bin/python3"]).isBroken)
        #expect(health(plist(args: ["/usr/bin/python3", "-u", "/Users/me/ok.py"]),
                       existing: ["/usr/bin/python3", "/Users/me/ok.py"]) == .ok)
        #expect(health(plist(args: ["/bin/zsh", "-c", "exec /gone/thing"]), existing: ["/bin/zsh"]) == .ok)
        #expect(LoginItemInspector.scriptPath(plist(args: ["/usr/bin/env", "node", "/srv/app.js"])) == "/srv/app.js")
        #expect(LoginItemInspector.scriptPath(plist(args: ["/opt/tool", "/etc/config"])) == nil)
    }

    @Test("Bare commands are searched on PATH, and unverified rather than broken when not found")
    func bareCommands() {
        #expect(health(plist(args: ["true"]), existing: ["/usr/bin/true"]) == .ok)
        #expect(health(plist(args: ["node"]), existing: ["/opt/bin/node"], mounted: []) != .ok)
        #expect(health(plist(args: ["node"], path: "/opt/bin"), existing: ["/opt/bin/node"]) == .ok)
        if case .unverified = health(plist(args: ["nothing"]), existing: []) {} else { Issue.record("expected unverified") }
    }

    @Test("Unreadable files and files without a program are broken")
    func noProgram() {
        #expect(LoginItemInspector.evaluate(plist: nil, parseError: "bad", home: home, fileExists: { _ in true },
                                            mountedVolumes: []) == .broken("bad"))
        #expect(health(LoginItemPlist(), existing: []).isBroken)
        var bundled = LoginItemPlist()
        bundled.bundleProgram = "Contents/MacOS/x"
        if case .unverified = health(bundled, existing: []) {} else { Issue.record("expected unverified") }
    }

    // MARK: Owners

    @Test("Outermost app bundle is found in a path")
    func outermostApp() {
        #expect(LoginItemOwnerResolver.outermostApp(in: "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/h")
            == "/Applications/Foo.app")
        #expect(LoginItemOwnerResolver.outermostApp(in: "/usr/local/bin/tool") == nil)
        #expect(LoginItemOwnerResolver.outermostApp(in: "/Applications/Foo.app") == "/Applications/Foo.app")
    }

    @Test("App paths inside shell one-liners are found, spaces included")
    func mentionedApp() {
        let fdm = "app='/Volumes/External/Applications/Free Download Manager.app'; while [[ ! -d \"$app\" ]]; do /bin/sleep 3; done"
        let found = LoginItemOwnerResolver.mentionedApp(in: ["/bin/zsh", "-c", fdm], appExists: { _ in false })
        #expect(found == "/Volumes/External/Applications/Free Download Manager.app")
        let spaced = "/bin/foo arg /Applications/My App.app"
        #expect(LoginItemOwnerResolver.mentionedApp(in: [spaced], appExists: { $0 == "/Applications/My App.app" })
            == "/Applications/My App.app")
        #expect(LoginItemOwnerResolver.mentionedApp(in: ["/bin/echo", "application"], appExists: { _ in true }) == nil)
    }

    @Test("Owner resolution prefers the app, then the signer, then the program name")
    func resolveOwner() {
        func resolve(_ plist: LoginItemPlist, signer: String? = nil) -> LoginItemOwner {
            LoginItemOwnerResolver.resolve(plist: plist, label: "com.vendor.agent", home: home,
                                           appExists: { _ in false }, appForBundleID: { $0 == "com.x.app" ? "/Applications/X.app" : nil },
                                           appName: { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") },
                                           signer: { _ in signer })
        }
        let inApp = resolve(plist(program: "/Applications/Foo.app/Contents/MacOS/helper"))
        #expect(inApp == LoginItemOwner(name: "Foo", kind: .app, appPath: "/Applications/Foo.app"))

        let open = resolve(plist(args: ["/usr/bin/open", "-b", "com.x.app"]))
        #expect(open.appPath == "/Applications/X.app")

        let openByName = resolve(plist(args: ["/usr/bin/open", "-a", "Some App"]))
        #expect(openByName == LoginItemOwner(name: "Some App", kind: .app, appPath: nil))

        let signed = resolve(plist(program: "/Users/me/Library/Google/updater"), signer: "Google LLC")
        #expect(signed == LoginItemOwner(name: "Google LLC", kind: .developer, appPath: nil))

        let plain = resolve(plist(args: ["/usr/bin/python3", "/Users/me/radar.py"]), signer: "Apple")
        #expect(plain == LoginItemOwner(name: "radar", kind: .program, appPath: nil))

        #expect(resolve(LoginItemPlist()).name == "agent")
        #expect(resolve(plist(args: ["/bin/zsh", "-c", "echo hi"]), signer: "Apple").name == "agent")
        #expect(resolve(plist(program: "/opt/com.docker.socket")).name == "com.docker.socket")
        #expect(resolve(plist(program: "/opt/run.sh")).name == "run")
        #expect(resolve(plist(args: ["/bin/launchctl", "setenv", "X", "1"])).name == "agent")
    }

    @Test("Developer names come from certificate summaries")
    func developerNames() {
        #expect(LoginItemOwnerResolver.developerName(fromCertificateSummary: "Developer ID Application: Google LLC (EQHXZ8M8AV)") == "Google LLC")
        #expect(LoginItemOwnerResolver.developerName(fromCertificateSummary: "Software Signing") == "Apple")
        #expect(LoginItemOwnerResolver.developerName(fromCertificateSummary: "macOS Software Signing") == "Apple")
        #expect(LoginItemOwnerResolver.developerName(fromCertificateSummary: "Apple Development: a@b.com (ABC123)") == "a@b.com")
    }

    // MARK: launchctl

    @Test("launchctl print: top-level keys only")
    func parsePrint() {
        let output = """
        gui/501/com.example.wakelauncher = {
        \tactive count = 1
        \tpath = /Users/someone/Library/LaunchAgents/com.example.wakelauncher.plist
        \tstate = running

        \tprogram = /Users/someone/Library/Application Support/WakeLauncher/wakelauncher
        \tenvironment = {
        \t\tstate = nested
        \t\tpid = 1
        \t}
        \truns = 7
        \tpid = 11266
        \tlast exit code = (never exited)
        }
        """
        let info = LoginItemLaunchctl.parsePrint(output)
        #expect(info == LoginItemServiceInfo(state: "running", pid: 11266, lastExitCode: "(never exited)", runs: 7,
                                             path: "/Users/someone/Library/LaunchAgents/com.example.wakelauncher.plist"))
        #expect(LoginItemLaunchctl.parsePrint("Bad request.\nCould not find service \"x\" in domain for user gui: 501") == nil)
    }

    @Test("print-disabled and list output")
    func parseOthers() {
        let disabled = """
        \tdisabled services = {
        \t\t"com.ollama.ollama" => disabled
        \t\t"ai.hermes.gateway" => enabled
        \t\t"com.old.style" => true
        \t}
        """
        #expect(LoginItemLaunchctl.parseDisabled(disabled) == ["com.ollama.ollama": true, "ai.hermes.gateway": false,
                                                               "com.old.style": true])
        let list = "PID\tStatus\tLabel\n936\t0\tcom.example.engine\n-\t0\tcom.example.home\n"
        let parsed = LoginItemLaunchctl.parseList(list)
        #expect(parsed["com.example.engine"] == .some(936))
        #expect(parsed["com.example.home"] == .some(nil))
    }

    @Test("Status derivation")
    func status() {
        let running = LoginItemServiceInfo(state: "running", pid: 42)
        let idle = LoginItemServiceInfo(state: "not running", pid: nil, lastExitCode: "0")
        #expect(LoginItemStatus.derive(info: running, isDisabled: false, queried: true) == .running(pid: 42))
        #expect(LoginItemStatus.derive(info: running, isDisabled: true, queried: true) == .running(pid: 42))
        #expect(LoginItemStatus.derive(info: idle, isDisabled: false, queried: true) == .loaded(lastExit: "0"))
        #expect(LoginItemStatus.derive(info: nil, isDisabled: true, queried: true) == .disabled)
        #expect(LoginItemStatus.derive(info: nil, isDisabled: false, queried: true) == .notLoaded)
        #expect(LoginItemStatus.derive(info: nil, isDisabled: false, queried: false) == .unknown)
    }

    @Test("Scanner reads a temp LaunchAgents folder and flags broken items")
    func scannerReadsFolder() throws {
        let temp = try UninstallTempDir()
        let folder = try temp.makeDir("LaunchAgents")
        let tool = try temp.makeFile("bin/tool")
        func write(_ name: String, _ dict: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
                .write(to: folder.appendingPathComponent(name))
        }
        try write("ok.plist", ["Label": "com.test.ok", "Program": tool.path, "RunAtLoad": true])
        try write("gone.plist", ["Label": "com.test.gone", "ProgramArguments": [temp.url.path + "/bin/missing"]])
        try write("empty.plist", [:])
        try Data("junk".utf8).write(to: folder.appendingPathComponent("junk.plist"))
        try Data().write(to: folder.appendingPathComponent("notes.txt"))

        let entries = LoginItemScanner.readEntries(scope: .user, folder: folder, home: temp.url.path, mounted: [])
        #expect(entries.count == 4)
        let byLabel = Dictionary(uniqueKeysWithValues: entries.map { ($0.label, $0) })
        #expect(byLabel["com.test.ok"]?.health == .ok)
        #expect(byLabel["com.test.ok"]?.startsAtLogin == true)
        #expect(byLabel["com.test.gone"]?.health.isBroken == true)
        #expect(byLabel["empty"]?.health.isBroken == true)
        #expect(byLabel["junk"]?.health.isBroken == true)

        let library = temp.url.deletingLastPathComponent()
        #expect(!LoginItemsModel.isSafeToRemove(byLabel["junk"]!, library: library))
    }
}
