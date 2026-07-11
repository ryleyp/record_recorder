import Foundation

/// Metadata for one exported MP3.
struct TrackTagInfo: Equatable {
    var title = ""
    var artist = ""
    var albumTitle = ""
    var albumArtist = ""
    var year: Int?
    var genre = ""
    var trackNumber = 1
    var trackTotal = 1
    var discNumber = 1
    var discTotal = 1
    /// JPEG or PNG bytes.
    var artwork: Data?
    var artworkIsPNG = false
}

/// Builds an ID3v2.3 tag block to prepend to the LAME-encoded MP3 frames.
///
/// Written in Swift (rather than using LAME's tag writer) so that titles with
/// any Unicode characters round-trip correctly: text frames use UTF-16 with a
/// BOM, which ID3v2.3 supports and Apple Music reads reliably.
enum ID3TagWriter {

    /// Renders the complete tag: "ID3" header + frames, padded slightly.
    static func makeTag(_ info: TrackTagInfo) -> Data {
        var frames = Data()

        func appendTextFrame(_ id: String, _ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // 0x01 = UTF-16 with BOM.
            var payload = Data([0x01])
            payload.append(contentsOf: [0xFF, 0xFE]) // little-endian BOM
            for unit in Array(trimmed.utf16) {
                payload.append(UInt8(unit & 0xFF))
                payload.append(UInt8(unit >> 8))
            }
            frames.append(frame(id: id, payload: payload))
        }

        appendTextFrame("TIT2", info.title)
        appendTextFrame("TPE1", info.artist)
        appendTextFrame("TALB", info.albumTitle)
        appendTextFrame("TPE2", info.albumArtist)
        if let year = info.year, year > 0 {
            appendTextFrame("TYER", String(year))
        }
        appendTextFrame("TCON", info.genre)
        appendTextFrame("TRCK", "\(info.trackNumber)/\(info.trackTotal)")
        appendTextFrame("TPOS", "\(info.discNumber)/\(info.discTotal)")

        if let artwork = info.artwork, !artwork.isEmpty {
            var payload = Data([0x00]) // Latin-1 for the MIME/description strings
            let mime = info.artworkIsPNG ? "image/png" : "image/jpeg"
            payload.append(mime.data(using: .isoLatin1)!)
            payload.append(0x00)
            payload.append(0x03) // picture type: front cover
            payload.append(0x00) // empty description, Latin-1 terminator
            payload.append(artwork)
            frames.append(frame(id: "APIC", payload: payload))
        }

        guard !frames.isEmpty else { return Data() }

        let padding = 256
        var tag = Data()
        tag.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        tag.append(contentsOf: [0x03, 0x00])       // version 2.3.0
        tag.append(0x00)                           // flags
        tag.append(synchsafe(UInt32(frames.count + padding)))
        tag.append(frames)
        tag.append(Data(count: padding))
        return tag
    }

    private static func frame(id: String, payload: Data) -> Data {
        var data = Data()
        data.append(id.data(using: .ascii)!)
        // ID3v2.3 frame sizes are plain big-endian (not synchsafe).
        let size = UInt32(payload.count)
        data.append(contentsOf: [
            UInt8((size >> 24) & 0xFF),
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
        ])
        data.append(contentsOf: [0x00, 0x00]) // frame flags
        data.append(payload)
        return data
    }

    /// 28-bit synchsafe integer used by the tag header.
    private static func synchsafe(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ])
    }

    // MARK: Reading (used by tests to verify round-trips)

    /// Minimal ID3v2.3 parser returning text frames and whether artwork exists.
    static func parseTag(_ data: Data) -> (textFrames: [String: String], hasArtwork: Bool)? {
        guard data.count > 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33,
              data[3] == 0x03 else { return nil }
        let size = (UInt32(data[6]) << 21) | (UInt32(data[7]) << 14) | (UInt32(data[8]) << 7) | UInt32(data[9])
        var offset = 10
        let end = min(data.count, 10 + Int(size))
        var textFrames: [String: String] = [:]
        var hasArtwork = false
        while offset + 10 <= end {
            let idData = data.subdata(in: offset..<(offset + 4))
            if idData[0] == 0 { break } // reached padding
            guard let id = String(data: idData, encoding: .ascii) else { break }
            let frameSize = Int(
                (UInt32(data[offset + 4]) << 24) | (UInt32(data[offset + 5]) << 16) |
                (UInt32(data[offset + 6]) << 8) | UInt32(data[offset + 7]))
            offset += 10
            guard frameSize > 0, offset + frameSize <= end else { break }
            let payload = data.subdata(in: offset..<(offset + frameSize))
            offset += frameSize
            if id == "APIC" {
                hasArtwork = true
            } else if id.hasPrefix("T"), payload.count > 1 {
                let encoding = payload[payload.startIndex]
                let body = payload.dropFirst()
                let text: String?
                if encoding == 0x01 {
                    text = String(data: body, encoding: .utf16)
                } else {
                    text = String(data: body, encoding: .isoLatin1)
                }
                if let text {
                    textFrames[id] = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                }
            }
        }
        return (textFrames, hasArtwork)
    }
}
