import Foundation
import Testing
@testable import Parabolic

@Suite("Login item plist parsing")
struct LoginItemPlistTests {
    private func parse(_ dict: [String: Any]) throws -> LoginItemPlist {
        try LoginItemPlist.parse(data: PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0))
    }

    @Test("Program wins over ProgramArguments[0]")
    func programWins() throws {
        let plist = try parse(["Label": "a.b.c", "Program": "/usr/bin/true", "ProgramArguments": ["/bin/false", "-x"]])
        #expect(plist.executable == "/usr/bin/true")
        #expect(plist.arguments == ["/bin/false", "-x"])
    }

    @Test("ProgramArguments[0] is used without Program")
    func argumentsOnly() throws {
        let plist = try parse(["Label": "com.example.wakelauncher",
                               "ProgramArguments": ["/Users/me/Library/Application Support/WakeLauncher/wakelauncher"],
                               "RunAtLoad": true, "KeepAlive": true])
        #expect(plist.executable == "/Users/me/Library/Application Support/WakeLauncher/wakelauncher")
        #expect(plist.runAtLoad)
        #expect(plist.keepAlive == .always)
        #expect(plist.startsAtLogin)
        #expect(plist.trigger == "Always running")
    }

    @Test("Missing keys get safe defaults")
    func missingKeys() throws {
        let plist = try parse([:])
        #expect(plist.label == nil)
        #expect(plist.executable == nil)
        #expect(!plist.runAtLoad)
        #expect(plist.keepAlive == .never)
        #expect(!plist.startsAtLogin)
        #expect(plist.trigger == "On demand")
    }

    @Test("KeepAlive dictionaries are conditional; schedules are described")
    func triggers() throws {
        #expect(try parse(["KeepAlive": ["SuccessfulExit": false]]).keepAlive == .conditional)
        #expect(try parse(["KeepAlive": [String: Any]()]).keepAlive == .never)
        #expect(try parse(["StartInterval": 300]).trigger == "Every 5 min")
        #expect(try parse(["StartInterval": 3600]).trigger == "Every hour")
        #expect(try parse(["StartCalendarInterval": ["Hour": 3]]).trigger == "On a schedule")
        #expect(try parse(["WatchPaths": ["/tmp"]]).trigger == "When files change")
        #expect(try parse(["RunAtLoad": true]).trigger == "At login")
    }

    @Test("Empty strings count as missing; other keys are read")
    func emptyAndExtras() throws {
        let plist = try parse(["Label": "  ", "Program": "", "ProgramArguments": ["", "x"], "Disabled": true,
                               "BundleProgram": "Contents/MacOS/helper", "AssociatedBundleIdentifiers": "com.x.app",
                               "EnvironmentVariables": ["PATH": "/opt/bin"]])
        #expect(plist.label == nil)
        #expect(plist.program == nil)
        #expect(plist.executable == nil)
        #expect(plist.isDisabledInFile)
        #expect(plist.bundleProgram == "Contents/MacOS/helper")
        #expect(plist.associatedBundleIDs == ["com.x.app"])
        #expect(plist.pathEnvironment == "/opt/bin")
    }

    @Test("Garbage and non-dictionaries are rejected")
    func invalid() throws {
        #expect(throws: LoginItemPlist.ParseError.unreadable) { try LoginItemPlist.parse(data: Data("<plist><dict><key>".utf8)) }
        let array = try PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0)
        #expect(throws: LoginItemPlist.ParseError.notADictionary) { try LoginItemPlist.parse(data: array) }
    }
}
