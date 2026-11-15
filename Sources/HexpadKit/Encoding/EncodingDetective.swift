import Foundation

/// Encoding detective for detecting file encoding from raw bytes
public final class EncodingDetective {
    
    /// Detect the encoding of raw data
    public static func detect(_ data: Data) -> String {
        guard data.count > 2 else {
            return "UTF-8"
        }
        
        // Check for BOM
        if let bom = detectBOM(of: data) {
            return bom
        }
        
        // No BOM: fall back to a UTF-16 null-byte density heuristic
        if likelyUTF16WithoutBOM(data) {
            return "UTF-16"
        }
        
        // Try strict UTF-8 first
        if isValidUTF8(data) {
            return "UTF-8"
        }
        
        // Strict UTF-8 failed; look for high-byte patterns typical of CP1252/Latin-1
        if isPossiblyCP1252(data) {
            return "Windows-1252"
        }
        
        // Fallback: assume UTF-8 (may have replacement characters)
        return "UTF-8"
    }
    
    // MARK: - BOM detection
    
    /// Detects a byte order mark at the start of `data`.
    /// Returns the encoding name of the detected BOM (e.g. "UTF-8", "UTF-16LE"),
    /// or nil when no BOM is present.
    public static func detectBOM(of data: Data) -> String? {
        if data.count >= 4 && data.prefix(4) == Data([0x00, 0x00, 0xFE, 0xFF]) {
            return "UTF-32BE"
        }
        if data.count >= 4 && data.prefix(4) == Data([0xFF, 0xFE, 0x00, 0x00]) {
            return "UTF-32LE"
        }
        if data.count >= 2 && data.prefix(2) == Data([0xFE, 0xFF]) {
            return "UTF-16BE"
        }
        if data.count >= 2 && data.prefix(2) == Data([0xFF, 0xFE]) {
            return "UTF-16LE"
        }
        if data.count >= 3 && data.prefix(3) == Data([0xEF, 0xBB, 0xBF]) {
            return "UTF-8"
        }
        return nil
    }
    
    /// Returns true when `data` begins with a UTF-8 byte order mark.
    public static func hasUTF8BOM(_ data: Data) -> Bool {
        data.count >= 3 && data.prefix(3) == Data([0xEF, 0xBB, 0xBF])
    }
    
    /// Returns true when `data` begins with a UTF-16 little-endian byte order mark.
    public static func hasUTF16LEBOM(_ data: Data) -> Bool {
        data.count >= 2 && data.prefix(2) == Data([0xFF, 0xFE])
    }
    
    /// Returns true when `data` begins with a UTF-16 big-endian byte order mark.
    public static func hasUTF16BEBOM(_ data: Data) -> Bool {
        data.count >= 2 && data.prefix(2) == Data([0xFE, 0xFF])
    }
    
    // MARK: - BOM stripping
    
    /// Removes a leading byte order mark from `data`, returning the cleaned bytes.
    /// Returns the original data when no BOM is present.
    public static func strippingBOM(from data: Data) -> Data {
        guard let bom = detectBOM(of: data) else { return data }
        let bytes = Array(data)
        var start = 0
        switch bom {
        case "UTF-8":
            start = 3
        case "UTF-16LE", "UTF-16BE":
            start = 2
        case "UTF-32LE", "UTF-32BE":
            start = 4
        default:
            return data
        }
        var stripped = [UInt8]()
        var index = start
        while index < bytes.count {
            stripped.append(bytes[index])
            index += 1
        }
        return Data(stripped)
    }
    
    // MARK: - Encoding heuristics
    
    /// Strictly validates `data` as UTF-8 (rejects overlong encodings, surrogates, and code points above U+10FFFF).
    public static func isValidUTF8(_ data: Data) -> Bool {
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            var length = 0
            var lowerBound: UInt8 = 0x80
            var upperBound: UInt8 = 0xBF
            switch first {
            case 0x00...0x7F:
                length = 0
            case 0xC2...0xDF:
                length = 1
            case 0xE0:
                length = 2
                lowerBound = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF:
                length = 2
            case 0xED:
                length = 2
                upperBound = 0x9F
            case 0xF0:
                length = 3
                lowerBound = 0x90
            case 0xF1...0xF3:
                length = 3
            case 0xF4:
                length = 3
                upperBound = 0x8F
            default:
                // 0x80...0xC1 are continuation bytes or overlong leads; 0xF5... are invalid.
                return false
            }
            let endIndex = index + 1 + length
            if endIndex > bytes.count { return false }
            if length > 0 {
                let firstContinuation = bytes[index + 1]
                if firstContinuation < lowerBound || firstContinuation > upperBound { return false }
                if length > 1 {
                    var offset = 2
                    while offset <= length {
                        let continuation = bytes[index + offset]
                        if continuation < 0x80 || continuation > 0xBF { return false }
                        offset += 1
                    }
                }
            }
            index = endIndex
        }
        return true
    }
    
    /// Heuristic: returns true when strict UTF-8 validation failed but the data
    /// contains high-byte patterns (0x80...0xFF) typical of single-byte legacy
    /// encodings such as Windows-1252 / Latin-1.
    public static func isPossiblyCP1252(_ data: Data) -> Bool {
        guard !isValidUTF8(data) else { return false }
        return Array(data).contains { $0 >= 0x80 }
    }
    
    /// Heuristic: returns true when null-byte density in the leading bytes
    /// suggests UTF-16 encoding without a BOM.
    public static func likelyUTF16WithoutBOM(_ data: Data) -> Bool {
        let sampleCount = min(data.count, 64)
        guard sampleCount >= 4 else { return false }
        var nulls = 0
        var total = 0
        for byte in data {
            if total >= sampleCount { break }
            if byte == 0 { nulls += 1 }
            total += 1
        }
        guard total > 0 else { return false }
        // UTF-16 encodes each ASCII character as two bytes (char + NUL for LE, NUL + char for BE),
        // so roughly half of the sampled bytes are null terminators.
        return nulls * 4 > total
    }
    
    /// Get encoding name from string encoding value
    public static func encodingName(from nsEncoding: UInt) -> String {
        switch nsEncoding {
        case String.Encoding.utf8.rawValue: return "UTF-8"
        case String.Encoding.utf16.rawValue: return "UTF-16"
        case String.Encoding.utf16BigEndian.rawValue: return "UTF-16-BE"
        case String.Encoding.utf16LittleEndian.rawValue: return "UTF-16-LE"
        case String.Encoding.utf32BigEndian.rawValue: return "UTF-32-BE"
        case String.Encoding.utf32LittleEndian.rawValue: return "UTF-32-LE"
        case String.Encoding.ascii.rawValue: return "ASCII"
        case String.Encoding.isoLatin1.rawValue: return "ISO-8859-1"
        case String.Encoding.isoLatin2.rawValue: return "ISO-8859-2"
        case String.Encoding.windowsCP1252.rawValue: return "Windows-1252"
        case String.Encoding.windowsCP1251.rawValue: return "Windows-1251"
        case String.Encoding.windowsCP1254.rawValue: return "Windows-1254"
        case String.Encoding.shiftJIS.rawValue: return "Shift_JIS"
        case String.Encoding.japaneseEUC.rawValue: return "EUC-JP"
        case String.Encoding.iso2022JP.rawValue: return "ISO-2022-JP"
        case String.Encoding.macOSRoman.rawValue: return "MacRoman"
        case String.Encoding.nonLossyASCII.rawValue: return "Non-Lossy ASCII"
        default: return "UTF-8"
        }
    }
    
    /// Get UInt from encoding name
    ///
    /// Normalizes the input by stripping dashes and uppercasing so both spellings
    /// resolve ("UTF-16-LE" and "UTF-16LE"). Every string that encodingName(from:) can
    /// emit must round-trip back to the same UInt here.
    public static func nsEncoding(from name: String) -> UInt {
        let normalized = name.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "UTF8": return String.Encoding.utf8.rawValue
        case "UTF16": return String.Encoding.utf16.rawValue
        case "UTF16LE": return String.Encoding.utf16LittleEndian.rawValue
        case "UTF16BE": return String.Encoding.utf16BigEndian.rawValue
        case "UTF32LE": return String.Encoding.utf32LittleEndian.rawValue
        case "UTF32BE": return String.Encoding.utf32BigEndian.rawValue
        case "ASCII": return String.Encoding.ascii.rawValue
        case "ISO88591": return String.Encoding.isoLatin1.rawValue
        case "ISO88592": return String.Encoding.isoLatin2.rawValue
        case "WINDOWS1252": return String.Encoding.windowsCP1252.rawValue
        case "WINDOWS1251": return String.Encoding.windowsCP1251.rawValue
        case "WINDOWS1254": return String.Encoding.windowsCP1254.rawValue
        case "SHIFTJIS": return String.Encoding.shiftJIS.rawValue
        case "EUCJP": return String.Encoding.japaneseEUC.rawValue
        case "ISO2022JP": return String.Encoding.iso2022JP.rawValue
        case "MACROMAN": return String.Encoding.macOSRoman.rawValue
        case "NONLOSSYASCII": return String.Encoding.nonLossyASCII.rawValue
        default: return String.Encoding.utf8.rawValue
        }
    }
}
