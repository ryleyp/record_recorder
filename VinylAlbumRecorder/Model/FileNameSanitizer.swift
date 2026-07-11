import Foundation

/// Turns user-entered titles into safe file and folder names while keeping
/// them readable.
enum FileNameSanitizer {

    static let maxLength = 100

    /// Replaces characters that are illegal or troublesome in file names on
    /// macOS (and on FAT-formatted iPods / external drives), collapses
    /// whitespace, and trims leading/trailing dots and spaces.
    static func sanitize(_ name: String, fallback: String = "Untitled") -> String {
        var result = ""
        result.reserveCapacity(name.count)
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", ":", "\\", "?", "*", "\"", "<", ">", "|":
                result.append("-")
            default:
                if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                    result.append(" ")
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        // Collapse runs of whitespace.
        result = result
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Leading dots hide files; trailing dots/spaces break some file systems.
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        return result.isEmpty ? fallback : result
    }

    /// "01 - Song Title.mp3"
    static func trackFileName(number: Int, title: String) -> String {
        let safeTitle = sanitize(title, fallback: String(format: "Track %02d", number))
        return String(format: "%02d - %@.mp3", number, safeTitle)
    }
}
