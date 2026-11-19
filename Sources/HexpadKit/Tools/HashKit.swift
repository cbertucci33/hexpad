import Foundation
import CryptoKit

/// Cryptographic digests used by the Tools menu hash commands.
///
/// Every function is pure: it hashes only the value it is given and returns a
/// lowercase hexadecimal string (for example
/// `"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"` for
/// the SHA-256 of `"abc"`). No padding, prefixes or separators are added, so
/// the result can be inserted into a document or copied directly.
///
/// The `String` overloads hash the UTF-8 bytes of the string, matching what
/// command-line tools such as `md5`, `shasum` and `sha256sum` produce for a
/// UTF-8 encoded file.
public enum HashKit {

    // MARK: - MD5

    /// Returns the lowercase hexadecimal MD5 digest of `text` (hashed as UTF-8).
    public static func md5(_ text: String) -> String {
        md5(Data(text.utf8))
    }

    /// Returns the lowercase hexadecimal MD5 digest of `data`.
    public static func md5(_ data: Data) -> String {
        hex(Insecure.MD5.hash(data: data))
    }

    // MARK: - SHA-1

    /// Returns the lowercase hexadecimal SHA-1 digest of `text` (hashed as UTF-8).
    public static func sha1(_ text: String) -> String {
        sha1(Data(text.utf8))
    }

    /// Returns the lowercase hexadecimal SHA-1 digest of `data`.
    public static func sha1(_ data: Data) -> String {
        hex(Insecure.SHA1.hash(data: data))
    }

    // MARK: - SHA-256

    /// Returns the lowercase hexadecimal SHA-256 digest of `text` (hashed as UTF-8).
    public static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    /// Returns the lowercase hexadecimal SHA-256 digest of `data`.
    public static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    // MARK: - SHA-512

    /// Returns the lowercase hexadecimal SHA-512 digest of `text` (hashed as UTF-8).
    public static func sha512(_ text: String) -> String {
        sha512(Data(text.utf8))
    }

    /// Returns the lowercase hexadecimal SHA-512 digest of `data`.
    public static func sha512(_ data: Data) -> String {
        hex(SHA512.hash(data: data))
    }

    // MARK: - Per-line digests

    /// Returns `text` with every non-empty line replaced by `digest(line)`.
    ///
    /// Lines are terminated by CR, LF or CRLF, so a CR-only file hashes as
    /// several lines rather than one giant line. The terminator is preserved
    /// exactly after each digest, empty lines stay empty, and no trailing
    /// newline is appended.
    ///
    /// The splitting follows the codebase's line model (`components(separatedBy:)`
    /// style: every terminator opens the next line, a trailing terminator opens
    /// a final empty line) while widening the accepted terminators to CR and
    /// CRLF, so hashing agrees with the editor's line model for LF text and
    /// treats CR/CRLF text the way the editor treats its line endings.
    public static func digestPerLine(_ text: String, _ digest: (String) -> String) -> String {
        var result = ""
        var line = String.UnicodeScalarView()
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\r" || scalar == "\n" {
                // CRLF is one terminator; a lone CR or LF is its own.
                let next = scalars.index(after: index)
                let isCRLF = scalar == "\r" && next < scalars.endIndex && scalars[next] == "\n"
                let terminator = isCRLF ? "\r\n" : String(scalar)
                index = isCRLF ? scalars.index(after: next) : next
                result += line.isEmpty ? "" : digest(String(line))
                result += terminator
                line = String.UnicodeScalarView()
            } else {
                line.append(scalar)
                index = scalars.index(after: index)
            }
        }
        // The final line has no terminator of its own; digest it when
        // non-empty and add nothing else, so no trailing newline appears.
        if !line.isEmpty {
            result += digest(String(line))
        }
        return result
    }

    // MARK: - Helpers

    /// Formats a digest's bytes as lowercase hexadecimal without separators.
    private static func hex<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
