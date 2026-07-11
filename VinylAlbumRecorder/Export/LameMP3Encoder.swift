import Foundation

enum MP3EncoderError: LocalizedError {
    case initializationFailed
    case encodingFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "The MP3 encoder could not be initialized."
        case .encodingFailed(let code):
            return "MP3 encoding failed (LAME error \(code))."
        }
    }
}

/// Thin Swift wrapper around the vendored LAME encoder. Configured for
/// constant-bitrate stereo/mono MP3 at 44.1 kHz — the most compatible format
/// for Apple Music and iPods. ID3 tags are written separately by
/// `ID3TagWriter`, so LAME's own tagging (and its Xing header) are disabled.
final class LameMP3Encoder {
    private var flags: lame_t?
    private let channels: Int32
    private var outputBuffer: [UInt8]

    init(inputSampleRate: Int32, channels: Int32, bitrateKbps: Int32) throws {
        guard let flags = lame_init() else {
            throw MP3EncoderError.initializationFailed
        }
        self.channels = channels
        lame_set_in_samplerate(flags, inputSampleRate)
        lame_set_out_samplerate(flags, 44_100)
        lame_set_num_channels(flags, channels)
        lame_set_mode(flags, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_brate(flags, bitrateKbps)
        lame_set_VBR(flags, vbr_off)          // constant bitrate
        lame_set_bWriteVbrTag(flags, 0)       // no Xing/Info frame needed for CBR
        lame_set_write_id3tag_automatic(flags, 0)
        lame_set_quality(flags, 2)            // high-quality psychoacoustics
        guard lame_init_params(flags) >= 0 else {
            lame_close(flags)
            throw MP3EncoderError.initializationFailed
        }
        self.flags = flags
        outputBuffer = [UInt8](repeating: 0, count: 0)
    }

    deinit {
        if let flags {
            lame_close(flags)
        }
    }

    /// Encodes interleaved 16-bit samples. For mono input, pass the single
    /// channel's samples (not interleaved).
    func encode(interleavedSamples samples: [Int16], frames: Int) throws -> Data {
        guard let flags, frames > 0 else { return Data() }
        let needed = frames + frames / 4 + 7200
        if outputBuffer.count < needed {
            outputBuffer = [UInt8](repeating: 0, count: needed)
        }
        var written: Int32 = 0
        var input = samples
        outputBuffer.withUnsafeMutableBufferPointer { out in
            input.withUnsafeMutableBufferPointer { pcm in
                if channels == 1 {
                    written = lame_encode_buffer(
                        flags, pcm.baseAddress, pcm.baseAddress, Int32(frames),
                        out.baseAddress, Int32(out.count))
                } else {
                    written = lame_encode_buffer_interleaved(
                        flags, pcm.baseAddress, Int32(frames),
                        out.baseAddress, Int32(out.count))
                }
            }
        }
        guard written >= 0 else { throw MP3EncoderError.encodingFailed(written) }
        return Data(outputBuffer.prefix(Int(written)))
    }

    /// Flushes the encoder's internal buffers; call once at the end of a track.
    func finish() throws -> Data {
        guard let flags else { return Data() }
        var tail = [UInt8](repeating: 0, count: 7200)
        var written: Int32 = 0
        tail.withUnsafeMutableBufferPointer { out in
            written = lame_encode_flush(flags, out.baseAddress, Int32(out.count))
        }
        guard written >= 0 else { throw MP3EncoderError.encodingFailed(written) }
        return Data(tail.prefix(Int(written)))
    }
}
