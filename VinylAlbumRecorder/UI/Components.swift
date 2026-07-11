import SwiftUI

enum TimeFormat {
    /// "43:12" or "1:02:45"
    static func mmss(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One horizontal stereo channel meter with dBFS scale and peak text.
struct LevelMeterBar: View {
    let label: String
    let reading: LevelReading

    private let floorDB: Float = -60

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.monospaced())
                .frame(width: 14, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(gradient)
                        .frame(width: proxy.size.width * fraction(reading.rmsDB))
                    Rectangle()
                        .fill(peakColor)
                        .frame(width: 2)
                        .offset(x: proxy.size.width * fraction(reading.peakDB))
                    // Recommended range -12…-6 dBFS
                    Rectangle()
                        .fill(Color.green.opacity(0.35))
                        .frame(width: 1.5)
                        .offset(x: proxy.size.width * fraction(-12))
                    Rectangle()
                        .fill(Color.green.opacity(0.35))
                        .frame(width: 1.5)
                        .offset(x: proxy.size.width * fraction(-6))
                }
            }
            .frame(height: 14)
            Text(peakText)
                .font(.caption.monospaced())
                .foregroundStyle(peakColor)
                .frame(width: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) channel level")
        .accessibilityValue(peakText + " peak")
    }

    private var peakText: String {
        reading.peakDB <= floorDB ? "silent" : String(format: "%.1f dB", reading.peakDB)
    }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(min(max((db - floorDB) / -floorDB, 0), 1))
    }

    private var peakColor: Color {
        if reading.peakDB >= -1 { return .red }
        if reading.peakDB >= -6 { return .orange }
        return .primary
    }

    private var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .green, location: 0),
                .init(color: .green, location: 0.75),
                .init(color: .yellow, location: 0.88),
                .init(color: .red, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

/// Red lamp that lights when peaks approach 0 dBFS.
struct ClipIndicator: View {
    let isClipping: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isClipping ? Color.red : Color.primary.opacity(0.15))
                .frame(width: 12, height: 12)
                .shadow(color: isClipping ? .red.opacity(0.8) : .clear, radius: 4)
            Text("CLIP")
                .font(.caption2.bold())
                .foregroundStyle(isClipping ? .red : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clipping indicator")
        .accessibilityValue(isClipping ? "Clipping detected" : "No clipping")
    }
}

/// Standard framed step content with title and explanation.
struct StageContainer<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title.bold())
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct HelpCallout: View {
    let systemImage: String
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.title3)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
