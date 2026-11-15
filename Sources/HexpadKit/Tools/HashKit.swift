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

    // MARK: - Helpers

    /// Formats a digest's bytes as lowercase hexadecimal without separators.
    private static func hex<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
