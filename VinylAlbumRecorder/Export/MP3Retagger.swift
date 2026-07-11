import Foundation

/// Rewrites an MP3's ID3 tags without touching its audio frames, so tracks
/// that are already MP3s can be exported with fresh album metadata and zero
/// generation loss ("Keep original encoding").
enum MP3Retagger {

    /// Returns the MP3's raw audio frames: any leading ID3v2 tag and trailing
    /// ID3v1 tag are removed.
    static func stripTags(_ data: Data) -> Data {
        var start = data.startIndex
        var end = data.endIndex

        // Leading ID3v2: "ID3" + version(2) + flags(1) + synchsafe size(4).
        if data.count > 10,
           data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 {
            let size = (UInt32(data[6] & 0x7F) << 21)
                | (UInt32(data[7] & 0x7F) << 14)
                | (UInt32(data[8] & 0x7F) << 7)
                | UInt32(data[9] & 0x7F)
            let footer = (data[5] & 0x10) != 0 ? 10 : 0
            let tagTotal = 10 + Int(size) + footer
            if tagTotal < data.count {
                start = data.index(data.startIndex, offsetBy: tagTotal)
            }
        }

        // Trailing ID3v1: exactly 128 bytes beginning "TAG".
        if data.count >= 128 {
            let tagStart = data.index(data.endIndex, offsetBy: -128)
            if data[tagStart] == 0x54, // T
               data[data.index(after: tagStart)] == 0x41, // A
               data[data.index(tagStart, offsetBy: 2)] == 0x47, // G
               tagStart > start {
                end = tagStart
            }
        }

        return data.subdata(in: start..<end)
    }

    /// New file contents: fresh ID3v2.3 tag followed by the original frames.
    static func retag(_ data: Data, with tag: TrackTagInfo) -> Data {
        var output = ID3TagWriter.makeTag(tag)
        output.append(stripTags(data))
        return output
    }
}
