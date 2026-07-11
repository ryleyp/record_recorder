import Foundation

/// Reads Audacity's exported label track files (File › Export › Export
/// Labels): one label per line, tab-separated
///
///     12.345678\t45.678901\tTrack Title
///
/// Region labels have distinct start/end; point labels repeat the start.
/// Frequency columns from spectral selection (a 4th/5th field) are ignored.
enum AudacityLabels {

    struct Label: Equatable {
        var start: Double
        var end: Double
        var title: String
    }

    /// What applying a label file to a side yields.
    struct Applied: Equatable {
        var boundaries: [Double]
        var trimStart: Double
        var trimEnd: Double
        var titles: [String]
    }

    static func parse(_ text: String) -> [Label] {
        var labels: [Label] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("\\") else { continue } // "\" lines are Audacity envelope points
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 2,
                  let start = Double(fields[0].trimmingCharacters(in: .whitespaces)),
                  let end = Double(fields[1].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            let title = fields.count >= 3
                ? fields[2].trimmingCharacters(in: .whitespaces)
                : ""
            labels.append(Label(start: start, end: max(start, end), title: title))
        }
        return labels.sorted { $0.start < $1.start }
    }

    /// Converts labels into track boundaries + titles for a side of the given
    /// duration.
    ///
    /// - Region labels (start < end) are treated as one track each: the side
    ///   is trimmed to the first region's start and last region's end, and
    ///   cuts fall at each following region's start.
    /// - Point labels are treated as cut positions between tracks.
    static func apply(labels: [Label], duration: Double) -> Applied? {
        let valid = labels.filter { $0.start >= 0 && $0.start <= duration }
        guard !valid.isEmpty else { return nil }

        let regions = valid.filter { $0.end > $0.start + 0.05 }
        if regions.count == valid.count && !regions.isEmpty {
            // All region labels → each region is a track.
            let boundaries = regions.dropFirst().map(\.start)
            return Applied(
                boundaries: boundaries,
                trimStart: regions.first!.start,
                trimEnd: min(regions.last!.end, duration),
                titles: regions.map(\.title))
        }

        // Point labels (or a mix): treat each label as a cut. A label at the
        // very start is the music start, one at the very end is the music end.
        var trimStart = 0.0
        var trimEnd = duration
        var cuts = valid.map(\.start)
        if let first = cuts.first, first < 2.0 {
            trimStart = first
            cuts.removeFirst()
        }
        if let last = cuts.last, last > duration - 2.0 {
            trimEnd = last
            cuts.removeLast()
        }
        let titles = valid.map(\.title).filter { !$0.isEmpty }
        return Applied(
            boundaries: cuts,
            trimStart: trimStart,
            trimEnd: trimEnd,
            titles: titles)
    }

    static func isLabelFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "txt",
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return !parse(text).isEmpty
    }
}
