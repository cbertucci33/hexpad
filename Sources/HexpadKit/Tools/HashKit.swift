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
    /// Line breaks are preserved exactly, empty lines stay empty (matching
    /// Notepad++'s per-line behavior, which never hashes a blank line into the
    /// digest of the empty string), and no trailing newline is appended. A
    /// trailing `\r` is treated as part of a CRLF terminator rather than as
    /// line content, so the digest is identical for LF and CRLF input.
    public static func digestPerLine(_ text: String, _ digest: (String) -> String) -> String {
        // Split on the LF *scalar*: Swift treats a CRLF pair as one Character,
        // so a Character-based split would not find line breaks in CRLF text.
        text.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { segment in
                let line = String(segment)
                guard !line.isEmpty else { return line }
                if line.hasSuffix("\r") {
                    let content = String(line.dropLast())
                    return content.isEmpty ? line : digest(content) + "\r"
                }
                return digest(line)
            }
            .joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Formats a digest's bytes as lowercase hexadecimal without separators.
    private static func hex<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
