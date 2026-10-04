import Foundation

/// Turns the JSON of one `MXDiagnosticPayload` into reports, one per
/// diagnostic. Parsed from JSON rather than the MetricKit objects so the
/// format can be tested without MetricKit, and so an unfamiliar key is
/// carried along in the report rather than dropped.
public enum MetricKitReports {
    static let kinds: [(key: String, kind: ProblemReport.Kind)] = [
        ("crashDiagnostics", .crash),
        ("hangDiagnostics", .hang),
        ("cpuExceptionDiagnostics", .cpuUsage),
        ("diskWriteExceptionDiagnostics", .diskWrites),
    ]

    public static func reports(
        from json: Data, received: Date = .now, symbolicate: (String, UInt64) -> String? = Symbolicator.symbol
    ) -> [ProblemReport] {
        guard let payload = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return [] }
        // A payload covers a period, usually the previous day; its end is the
        // closest it says to when the problem happened.
        let date = (payload["timeStampEnd"] as? String).flatMap(SystemCrashLog.parseTimestamp) ?? received
        return kinds.flatMap { key, kind in
            (payload[key] as? [[String: Any]] ?? []).map { diagnostic in
                report(kind: kind, diagnostic: diagnostic, date: date, symbolicate: symbolicate)
            }
        }
    }

    static func report(
        kind: ProblemReport.Kind, diagnostic: [String: Any], date: Date,
        symbolicate: (String, UInt64) -> String?
    ) -> ProblemReport {
        let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
        let summary = summary(kind: kind, meta)
        var facts: [(String, String)] = []
        if let version = meta["appVersion"] as? String {
            facts.append(("App", "Zentic \(version)" + ((meta["appBuildVersion"] as? String).map { " (\($0))" } ?? "")))
        }
        if let os = meta["osVersion"] as? String { facts.append(("System", os)) }
        // The rest of the metadata is in the diagnostic, printed in full below.
        if let reason = meta["terminationReason"] as? String { facts.append(("Reason", reason)) }
        if let region = meta["virtualMemoryRegionInfo"] as? String { facts.append(("Memory", region)) }
        let stack = (diagnostic["callStackTree"] as? [String: Any]).map { render($0, symbolicate: symbolicate) } ?? ""
        let text = ProblemReport.compose(
            kind: kind, date: date, summary: summary, facts: facts,
            sections: [
                (kind == .crash ? "Crashed thread" : "Heaviest stack", stack),
                ("MetricKit diagnostic", pretty(diagnostic)),
            ])
        return ProblemReport(
            kind: kind, date: date, summary: summary, text: text, processID: meta["pid"] as? Int)
    }

    static func summary(kind: ProblemReport.Kind, _ meta: [String: Any]) -> String {
        switch kind {
        case .crash:
            let type = (meta["exceptionType"] as? Int).map(exceptionName) ?? "Crash"
            let signal = (meta["signal"] as? Int).map(signalName)
            if let reason = meta["terminationReason"] as? String, signal == nil { return "\(type) — \(reason)" }
            return signal.map { "\(type) (\($0))" } ?? type
        case .hang:
            return (meta["hangDuration"] as? String).map { "Not responding for \($0)" } ?? "Not responding"
        case .cpuUsage:
            return (meta["totalCPUTime"] as? String).map { "\($0) of CPU time" } ?? "High CPU use"
        case .diskWrites:
            return (meta["writesCaused"] as? String).map { "\($0) written" } ?? "Excessive disk writes"
        case .unexpectedQuit:
            return "Unexpected quit"
        }
    }

    /// Each attributed thread (the one that crashed or hung), else every
    /// thread, as frames from the top. Aggregated trees (hangs, CPU) keep
    /// many branches; following the heaviest is the stack that mattered.
    static func render(_ tree: [String: Any], symbolicate: (String, UInt64) -> String?) -> String {
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        let attributed = stacks.filter { $0["threadAttributed"] as? Bool == true }
        return (attributed.isEmpty ? stacks : attributed).map { stack in
            var lines: [String] = []
            var frame = heaviest(stack["callStackRootFrames"])
            while let current = frame, lines.count < 200 {
                let binary = current["binaryName"] as? String ?? "???"
                let offset = (current["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
                let symbol =
                    (current["binaryUUID"] as? String).flatMap { symbolicate($0, offset) }
                    ?? String(format: "0x%llx", offset) + ((current["binaryUUID"] as? String).map { " (\($0))" } ?? "")
                lines.append(StackLine.format(index: lines.count, binary: binary, symbol: symbol))
                frame = heaviest(current["subFrames"])
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func heaviest(_ frames: Any?) -> [String: Any]? {
        (frames as? [[String: Any]])?.max { ($0["sampleCount"] as? Int ?? 0) < ($1["sampleCount"] as? Int ?? 0) }
    }

    private static func pretty(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // <mach/exception_types.h> and <sys/signal.h>: MetricKit gives numbers.
    static func exceptionName(_ code: Int) -> String {
        let names = [
            1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
            5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL", 9: "EXC_RPC_ALERT",
            10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY",
        ]
        return names[code] ?? "Exception \(code)"
    }

    static func signalName(_ code: Int) -> String {
        let names = [
            1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT",
            8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE", 14: "SIGALRM",
            15: "SIGTERM",
        ]
        return names[code] ?? "signal \(code)"
    }
}
