import Foundation
import MachO
import Testing

@testable import ZenticKit

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zentic-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Files store dates to the second; a value compared after a round trip must too.
private let wholeSecond = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))

private func noSymbols(_: String, _: UInt64) -> String? { nil }

@Suite struct BreadcrumbTests {
    /// The breadcrumb is only useful if it is still there after the crash.
    @Test func survivesAnUnexpectedQuitAndIsGoneAfterACleanOne() {
        let guard_ = LaunchGuard(directory: temporaryDirectory())
        _ = guard_.begin()
        var crumb = Breadcrumb(appVersion: "0.1.0 (7)", launched: wholeSecond)
        crumb.tabs = 3
        crumb.note("Closed a tab", at: wholeSecond)
        guard_.record(crumb)
        // Crashed: no end().
        let next = guard_.begin()
        #expect(next.outcome == .recovered)
        #expect(next.breadcrumb == crumb)

        guard_.end()
        #expect(guard_.begin().breadcrumb == nil)
    }

    /// A breadcrumb written after a clean quit would bring the marker back,
    /// and the next launch would apologise for a crash that never happened.
    @Test func recordingAfterACleanQuitDoesNotResurrectTheMarker() {
        let guard_ = LaunchGuard(directory: temporaryDirectory())
        _ = guard_.begin()
        guard_.end()
        guard_.record(Breadcrumb(appVersion: "1"))
        #expect(guard_.begin().outcome == .clean)
    }

    /// Markers written before breadcrumbs existed must still be understood,
    /// or the first launch after updating would miss a real crash.
    @Test func aMarkerFromBeforeBreadcrumbsStillReportsTheCrash() throws {
        let dir = temporaryDirectory()
        try Data(#"{"startupCrashes":0,"survivedStartup":true}"#.utf8)
            .write(to: dir.appendingPathComponent("running.marker"))
        let launch = LaunchGuard(directory: dir).begin()
        #expect(launch.outcome == .recovered)
        #expect(launch.breadcrumb == nil)
    }

    @Test func keepsOnlyTheLastEventsAndFoldsRepeats() {
        var crumb = Breadcrumb(appVersion: "1")
        for _ in 0..<5 { crumb.note("Closed a tab") }
        for index in 0..<(Breadcrumb.eventLimit + 3) { crumb.note("Action \(index)") }
        #expect(crumb.events.count == Breadcrumb.eventLimit)
        #expect(crumb.events.last?.action == "Action \(Breadcrumb.eventLimit + 2)")

        var folded = Breadcrumb(appVersion: "1")
        folded.note("Closed a tab")
        folded.note("Closed a tab")
        folded.note("Opened a tab")
        #expect(folded.events.map(\.times) == [2, 1])
        #expect(folded.rendered().contains("Closed a tab ×2"))
    }
}

@Suite struct ProblemReportStoreTests {
    private func report(daysAgo: Double, now: Date, kind: ProblemReport.Kind = .crash) -> ProblemReport {
        ProblemReport(kind: kind, date: now.addingTimeInterval(-daysAgo * 86_400), summary: "s", text: "t")
    }

    @Test func listsNewestFirstAndDeletes() {
        let store = ProblemReportStore(directory: temporaryDirectory())
        let now = wholeSecond
        let old = report(daysAgo: 2, now: now)
        let new = report(daysAgo: 1, now: now, kind: .hang)
        store.save(old, now: now)
        store.save(new, now: now)
        #expect(store.all() == [new, old])
        store.delete(new.id)
        #expect(store.all() == [old])
    }

    /// A crash loop must not fill the disk, and a report about a problem
    /// fixed two months ago is noise.
    @Test func isCappedByCountAndAge() {
        let store = ProblemReportStore(directory: temporaryDirectory())
        let now = wholeSecond
        let stale = report(daysAgo: 61, now: now)
        store.save(stale, now: now)
        #expect(store.all().isEmpty)

        for index in 0..<(ProblemReportStore.maxReports + 5) {
            store.save(report(daysAgo: Double(index), now: now), now: now)
        }
        let kept = store.all()
        #expect(kept.count == ProblemReportStore.maxReports)
        // The newest are the ones kept.
        #expect(kept.first?.date == now)
    }

    @Test func anUnreadableReportIsDroppedNotFatal() throws {
        let dir = temporaryDirectory()
        let store = ProblemReportStore(directory: dir)
        try Data("{".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
        let good = report(daysAgo: 0, now: wholeSecond)
        store.save(good)
        #expect(store.all() == [good])
    }
}

@Suite struct MetricKitReportTests {
    // The shape of `MXDiagnosticPayload.jsonRepresentation()`: a crash whose
    // stack is a chain from the top frame down, and a hang whose tree has
    // branches weighted by samples.
    static let payload = """
        {
          "timeStampBegin": "2026-10-03 00:00:00 +0000",
          "timeStampEnd": "2026-10-03 23:59:00 +0000",
          "crashDiagnostics": [{
            "version": "1.0.0",
            "diagnosticMetaData": {
              "appVersion": "0.1.0", "appBuildVersion": "212", "osVersion": "macOS 26.1 (25B78)",
              "exceptionType": 1, "signal": 11, "exceptionCode": 0, "pid": 4242,
              "terminationReason": "Namespace SIGNAL, Code 0xb", "virtualMemoryRegionInfo": "0 is not in any region"
            },
            "callStackTree": {
              "callStackPerThread": true,
              "callStacks": [
                {"threadAttributed": false, "callStackRootFrames": [
                  {"binaryName": "libsystem_kernel.dylib", "binaryUUID": "11111111-1111-1111-1111-111111111111",
                   "offsetIntoBinaryTextSegment": 4000, "sampleCount": 1, "address": 1}]},
                {"threadAttributed": true, "callStackRootFrames": [
                  {"binaryName": "Zentic", "binaryUUID": "22222222-2222-2222-2222-222222222222",
                   "offsetIntoBinaryTextSegment": 4096, "sampleCount": 1, "address": 2,
                   "subFrames": [
                     {"binaryName": "AppKit", "binaryUUID": "33333333-3333-3333-3333-333333333333",
                      "offsetIntoBinaryTextSegment": 255, "sampleCount": 1, "address": 3}]}]}
              ]
            }
          }],
          "hangDiagnostics": [{
            "diagnosticMetaData": {"appVersion": "0.1.0", "hangDuration": "4.2 sec", "pid": 4242},
            "callStackTree": {"callStackPerThread": false, "callStacks": [{"threadAttributed": true,
              "callStackRootFrames": [{"binaryName": "Zentic", "binaryUUID": "22222222-2222-2222-2222-222222222222",
                "offsetIntoBinaryTextSegment": 1, "sampleCount": 10, "subFrames": [
                  {"binaryName": "Light", "offsetIntoBinaryTextSegment": 2, "sampleCount": 1},
                  {"binaryName": "Heavy", "offsetIntoBinaryTextSegment": 3, "sampleCount": 9}]}]}]}
          }],
          "somethingNewer": [{"diagnosticMetaData": {}}]
        }
        """

    @Test func makesOneReportPerDiagnosticWithAReadableSummary() throws {
        let reports = MetricKitReports.reports(from: Data(Self.payload.utf8), symbolicate: noSymbols)
        #expect(reports.map(\.kind) == [.crash, .hang])
        let crash = try #require(reports.first)
        #expect(crash.summary == "EXC_BAD_ACCESS (SIGSEGV)")
        #expect(crash.date == ISO8601DateFormatter().date(from: "2026-10-03T23:59:00Z"))
        #expect(crash.text.contains("Zentic 0.1.0 (212)"))
        #expect(crash.text.contains("virtualMemoryRegionInfo"))
        #expect(reports[1].summary == "Not responding for 4.2 sec")
    }

    /// The crashed thread is the one that matters, top frame first; an
    /// unsymbolicated frame keeps its binary UUID and offset so the developer
    /// can symbolicate it against the build's dSYM.
    @Test func showsTheAttributedThreadTopFirstAndUsesSymbolsWhenItHasThem() throws {
        let reports = MetricKitReports.reports(from: Data(Self.payload.utf8)) { uuid, offset in
            uuid.hasPrefix("2222") && offset == 4096 ? "Browser.close(_:) + 12" : nil
        }
        let crash = try #require(reports.first)
        let stack = try #require(crash.text.components(separatedBy: "Crashed thread\n--------------\n").last)
        let lines = stack.split(separator: "\n").prefix(2).map(String.init)
        #expect(lines[0].hasPrefix("0   Zentic"))
        #expect(lines[0].hasSuffix("Browser.close(_:) + 12"))
        #expect(lines[1].hasPrefix("1   AppKit"))
        #expect(lines[1].hasSuffix("0xff (33333333-3333-3333-3333-333333333333)"))
        #expect(!stack.prefix(200).contains("libsystem_kernel"))
    }

    @Test func followsTheHeaviestBranchOfAHang() throws {
        let hang = try #require(MetricKitReports.reports(from: Data(Self.payload.utf8), symbolicate: noSymbols).last)
        #expect(hang.text.contains("Heavy"))
        #expect(!hang.text.contains("1   Light"))
    }

    @Test func somethingThatIsNotAPayloadMakesNoReports() {
        #expect(MetricKitReports.reports(from: Data("[]".utf8)).isEmpty)
        #expect(MetricKitReports.reports(from: Data("not json".utf8)).isEmpty)
    }
}

@Suite struct SystemCrashLogTests {
    // Trimmed from a real `.ips` macOS wrote for a Swift array index trap.
    static let ips = """
        {"app_name":"Zentic","timestamp":"2026-10-04 20:18:51.00 +0100","app_version":"0.1.0","bug_type":"309","os_version":"macOS 26.1 (25B78)","name":"Zentic"}
        {
          "procName" : "Zentic",
          "pid" : 4242,
          "exception" : {"codes":"0x0000000000000001, 0x000000018ce3856c","type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
          "termination" : {"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5"},
          "asi" : {"libswiftCore.dylib":["Fatal error: Index out of range"]},
          "faultingThread" : 0,
          "threads" : [{"triggered":true,"queue":"com.apple.main-thread","frames":[
            {"imageOffset":1445952,"symbol":"_assertionFailure(_:_:file:line:flags:)","symbolLocation":196,"imageIndex":1},
            {"imageOffset":1768,"sourceLine":1,"sourceFile":"Browser.swift","symbol":"Browser.close(_:)","imageIndex":0,"symbolLocation":52},
            {"imageOffset":9000,"imageIndex":0}
          ]},{"frames":[]}],
          "usedImages" : [
            {"base":4344791040,"uuid":"de259f12-c51d-30ac-8cf0-d1e4c6fe77ab","name":"Zentic"},
            {"base":6657241088,"uuid":"beee30cf-1550-3a6e-b7d7-616fe2da97e3","name":"libswiftCore.dylib"}
          ]
        }
        """

    @Test func readsTheCrashedThreadAndTheRuntimeMessage() throws {
        let log = try #require(
            SystemCrashLog.parse(Self.ips, fileName: "Zentic-2026-10-04-201851.ips") { uuid, offset in
                uuid == "de259f12-c51d-30ac-8cf0-d1e4c6fe77ab" && offset == 9000 ? "main + 4" : nil
            })
        #expect(log.summary == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(log.date == ISO8601DateFormatter().date(from: "2026-10-04T19:18:51Z"))
        let lines = log.crashedThread.split(separator: "\n").map(String.init)
        #expect(lines.first == "Fatal error: Index out of range")
        #expect(lines.contains("Thread 0 (com.apple.main-thread)"))
        #expect(lines.contains { $0.hasPrefix("0   libswiftCore.dylib") && $0.hasSuffix("+ 196") })
        #expect(lines.contains { $0.hasPrefix("1   Zentic") && $0.hasSuffix("Browser.close(_:) + 52 (Browser.swift:1)") })
        // No symbol in the log: ours, when this is the build that crashed.
        #expect(lines.last?.hasSuffix("main + 4") == true)
        #expect(log.contents == Self.ips)
    }

    @Test func onlyCrashLogsAreRead() {
        let other = Self.ips.replacingOccurrences(of: #""bug_type":"309""#, with: #""bug_type":"288""#)
        #expect(SystemCrashLog.parse(other, fileName: "x.ips", symbolicate: noSymbols) == nil)
        #expect(SystemCrashLog.parse("garbage", fileName: "x.ips", symbolicate: noSymbols) == nil)
    }

    /// A log from an earlier run, or from another app, is not this crash.
    @Test func findsOnlyThisProcessesLogsFromTheRunThatQuit() throws {
        let dir = temporaryDirectory()
        let launched = Date.now.addingTimeInterval(-60)
        func write(_ name: String, modified: Date) throws {
            let url = dir.appendingPathComponent(name)
            try Data(Self.ips.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        try write("Zentic-earlier.ips", modified: launched.addingTimeInterval(-3600))
        try write("ZenticHelper-now.ips", modified: .now)
        try write("ExcUserFault_Zentic-now.ips", modified: .now)
        #expect(SystemCrashLog.newest(for: "Zentic", since: launched, in: dir, symbolicate: noSymbols) == nil)

        try write("Zentic-now.ips", modified: .now)
        let found = SystemCrashLog.newest(for: "Zentic", since: launched, in: dir, symbolicate: noSymbols)
        #expect(found?.fileName == "Zentic-now.ips")
    }
}

@Suite struct UnexpectedQuitReportTests {
    @Test func carriesTheBreadcrumbAndTheCrashLog() throws {
        var crumb = Breadcrumb(appVersion: "0.1.0 (7)")
        crumb.windows = 2
        crumb.tabs = 9
        crumb.note("Switched space")
        let log = try #require(SystemCrashLog.parse(SystemCrashLogTests.ips, fileName: "Zentic-1.ips", symbolicate: noSymbols))
        let report = ProblemReport.unexpectedQuit(previousRun: crumb, crashLog: log)
        #expect(report.kind == .unexpectedQuit)
        #expect(report.summary == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(report.date == log.date)
        #expect(report.text.contains("2 windows, 9 tabs"))
        #expect(report.text.contains("Switched space"))
        #expect(report.text.contains("Fatal error: Index out of range"))
        // The whole log rides along, for Console or Xcode.
        #expect(report.text.contains(#""procName" : "Zentic""#))
    }

    @Test func saysSoWhenThereIsNothingToGoOn() {
        let report = ProblemReport.unexpectedQuit(previousRun: nil, crashLog: nil)
        #expect(report.summary.hasPrefix("No crash log"))
        #expect(report.text.contains("Nothing was recorded"))
        #expect(!report.text.contains("Crashed thread"))
    }
}

@Suite struct DuplicateReportTests {
    /// One crash, two sources: macOS's log (in the unexpected-quit report)
    /// at launch, MetricKit's diagnostic seconds later. The list shows it once.
    @Test func aMetricKitCrashIsCoveredByTheUnexpectedQuitOfTheSameProcess() throws {
        let log = try #require(SystemCrashLog.parse(SystemCrashLogTests.ips, fileName: "Zentic-1.ips", symbolicate: noSymbols))
        let quit = ProblemReport.unexpectedQuit(previousRun: nil, crashLog: log)
        let fromMetricKit = MetricKitReports.reports(from: Data(MetricKitReportTests.payload.utf8), symbolicate: noSymbols)
        let crash = try #require(fromMetricKit.first { $0.kind == .crash })
        let hang = try #require(fromMetricKit.first { $0.kind == .hang })

        #expect(crash.isCovered(by: quit))
        // Delivered again (MetricKit can): still one.
        #expect(crash.isCovered(by: crash))
        // A hang in that run is a different problem.
        #expect(!hang.isCovered(by: quit))

        var elsewhere = crash
        elsewhere.processID = 1
        #expect(!elsewhere.isCovered(by: quit))
        // Without a process to match on, never assume.
        #expect(!ProblemReport.unexpectedQuit(previousRun: nil, crashLog: nil).isCovered(by: quit))
    }
}

@Suite struct SymbolicatorTests {
    /// The address arithmetic (image header + offset) must land on the
    /// function the offset was taken from, or every name in a report lies.
    @Test func namesAFunctionFromItsImageUUIDAndOffset() throws {
        let strlenAddress = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "strlen"))
        var info = Dl_info()
        #expect(dladdr(strlenAddress, &info) != 0)
        let header = try #require(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        let uuid = try #require(Symbolicator.imageUUID(header))
        let offset = UInt64(UnsafeRawPointer(strlenAddress) - UnsafeRawPointer(header))

        let name = try #require(Symbolicator.symbol(binaryUUID: uuid.uuidString, offset: offset + 4))
        #expect(name.hasSuffix("strlen + 4"))
    }

    @Test func leavesABinaryThatIsNotLoadedAlone() {
        #expect(Symbolicator.symbol(binaryUUID: UUID().uuidString, offset: 16) == nil)
        #expect(Symbolicator.symbol(binaryUUID: "not a uuid", offset: 16) == nil)
    }

    @Test func demanglesSwiftNames() {
        #expect(Symbolicator.demangle("$sSi1poiyS2i_SitFZ") == "static Swift.Int.+ infix(Swift.Int, Swift.Int) -> Swift.Int")
        #expect(Symbolicator.demangle("strlen") == "strlen")
    }
}
