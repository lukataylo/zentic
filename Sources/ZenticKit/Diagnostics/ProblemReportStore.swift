import Foundation

/// Reports on disk, one JSON file each, in `<data>/Diagnostics`.
///
/// Capped by count and age so a crash loop cannot fill the disk, and so old
/// reports about long-fixed problems do not linger. Not thread-safe: the
/// caller serialises access (`Diagnostics` uses one queue).
public struct ProblemReportStore: Sendable {
    public static let maxReports = 30
    public static let maxAge: TimeInterval = 60 * 24 * 60 * 60

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Newest first. A file that cannot be read is deleted: it cannot be
    /// shown, sent or ever become readable.
    public func all() -> [ProblemReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let report = try? decoder.decode(ProblemReport.self, from: data) else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return report
            }
            .sorted { $0.date > $1.date }
    }

    public func save(_ report: ProblemReport, now: Date = .now) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: report.id), options: .atomic)
        prune(now: now)
    }

    public func delete(_ id: ProblemReport.ID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Drop reports older than `maxAge`, then the oldest beyond `maxReports`.
    public func prune(now: Date = .now) {
        for (index, report) in all().enumerated()
        where index >= Self.maxReports || now.timeIntervalSince(report.date) > Self.maxAge {
            delete(report.id)
        }
    }

    private func url(for id: ProblemReport.ID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
