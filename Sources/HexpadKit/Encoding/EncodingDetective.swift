import Foundation

/// Encoding detective for detecting file encoding from raw bytes
public final class EncodingDetective {

    /// Notepad++-style "Character sets" menu table: groups in menu order, each
    /// holding the encodings that group exposes. Titles are used both as the
    /// menu item names and as the canonical names resolved by `nsEncoding(from:)`.
    public static let characterSets: [(group: String, charsets: [(title: String, rawValue: UInt)])] = [
        ("Western European", [
            ("ISO 8859-1", String.Encoding.isoLatin1.rawValue),
            ("ISO 8859-15", 2147484175),
            ("Windows-1252", String.Encoding.windowsCP1252.rawValue),
            ("OEM 437", 2147484672),
            ("OEM 850", 2147484688),
            ("OEM 860", 2147484693),
            ("OEM 861", 2147484694),
            ("OEM 862", 2147484695),
            ("OEM 863", 2147484696),
            ("OEM 865", 2147484698),
        ]),
        ("Central European", [
            ("ISO 8859-2", String.Encoding.isoLatin2.rawValue),
            ("OEM 852", 2147484690),
            ("Windows-1250", String.Encoding.windowsCP1250.rawValue),
        ]),
        ("Baltic", [
            ("ISO 8859-4", 2147484164),
            ("ISO 8859-13", 2147484173),
            ("OEM 775", 2147484678),
            ("Windows-1257", 2147484935),
        ]),
        ("Cyrillic", [
            ("ISO 8859-5", 2147484165),
            ("KOI8-R", 2147486210),
            ("KOI8-U", 2147486216),
            ("OEM 855", 2147484691),
            ("OEM 866", 2147484699),
            ("Windows-1251", String.Encoding.windowsCP1251.rawValue),
        ]),
        ("Greek", [
            ("ISO 8859-7", 2147484167),
            ("OEM 737", 2147484677),
            ("OEM 869", 2147484700),
            ("Windows-1253", String.Encoding.windowsCP1253.rawValue),
        ]),
        ("Turkish", [
            ("ISO 8859-9", 2147484169),
            ("ISO 8859-3", 2147484163),
            ("OEM 857", 2147484692),
            ("Windows-1254", String.Encoding.windowsCP1254.rawValue),
        ]),
        ("Hebrew", [
            ("ISO 8859-8", 2147484168),
            ("OEM 862", 2147484695),
            ("Windows-1255", 2147484933),
        ]),
        ("Arabic", [
            ("ISO 8859-6", 2147484166),
            ("Windows-1256", 2147484934),
        ]),
        ("North European", [
            ("OEM 861", 2147484694),
            ("OEM 865", 2147484698),
        ]),
        ("Vietnamese", [
            ("Windows-1258", 2147484936),
        ]),
        ("Thai", [
            ("TIS-620", 2147484701),
        ]),
        ("Japanese", [
            ("Shift-JIS", String.Encoding.shiftJIS.rawValue),
            ("Shift-JIS X0213", 2147486209),
        ]),
        ("Korean", [
            ("Windows 949", 2147484706),
            ("EUC-KR", 2147486016),
        ]),
        ("Chinese", [
            ("Big5", 2147486211),
            ("GB2312", 2147486000),
            ("GBK", 2147484705),
            ("GB18030", 2147485234),
        ]),
    ]

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
    
    /// The byte order mark `encoding` should be written with, or nil when the
    /// encoding is BOM-less or is a native-order name (`"UTF-16"`, `"UTF-32"`)
    /// whose Foundation encoder already emits one.
    ///
    /// Used by `DocumentModel` to re-emit the BOM of a file that was opened
    /// with one: the editor buffer never contains a BOM, because it is
    /// stripped during decode.
    public static func bomBytes(for encoding: String) -> Data? {
        switch normalizedName(encoding) {
        case "UTF8": return Data([0xEF, 0xBB, 0xBF])
        case "UTF16LE": return Data([0xFF, 0xFE])
        case "UTF16BE": return Data([0xFE, 0xFF])
        case "UTF32LE": return Data([0xFF, 0xFE, 0x00, 0x00])
        case "UTF32BE": return Data([0x00, 0x00, 0xFE, 0xFF])
        default: return nil
        }
    }

    /// Decodes raw file bytes the way the editor should see them: a leading
    /// BOM is removed so the buffer starts at the first real character, then
    /// the remaining bytes are decoded with `encoding`.
    ///
    /// Returns nil when the bytes are not valid for `encoding`.
    public static func decodeForEditing(_ data: Data, as encoding: String) -> String? {
        let body = strippingBOM(from: data)
        let nsEncoding = String.Encoding(rawValue: nsEncoding(from: encoding))
        return String(data: body, encoding: nsEncoding)
    }

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
        // Character sets menu table (see `characterSets`).
        case 2147484175: return "ISO 8859-15"
        case 2147484173: return "ISO 8859-13"
        case 2147484672: return "OEM 437"
        case 2147484688: return "OEM 850"
        case 2147484693: return "OEM 860"
        case 2147484694: return "OEM 861"
        case 2147484695: return "OEM 862"
        case 2147484696: return "OEM 863"
        case 2147484698: return "OEM 865"
        case String.Encoding.windowsCP1250.rawValue: return "Windows-1250"
        case 2147484690: return "OEM 852"
        case 2147484164: return "ISO 8859-4"
        case 2147484678: return "OEM 775"
        case 2147484935: return "Windows-1257"
        case 2147484165: return "ISO 8859-5"
        case 2147486210: return "KOI8-R"
        case 2147486216: return "KOI8-U"
        case 2147484691: return "OEM 855"
        case 2147484699: return "OEM 866"
        case 2147484167: return "ISO 8859-7"
        case 2147484677: return "OEM 737"
        case 2147484700: return "OEM 869"
        case String.Encoding.windowsCP1253.rawValue: return "Windows-1253"
        case 2147484169: return "ISO 8859-9"
        case 2147484163: return "ISO 8859-3"
        case 2147484692: return "OEM 857"
        case 2147484168: return "ISO 8859-8"
        case 2147484933: return "Windows-1255"
        case 2147484166: return "ISO 8859-6"
        case 2147484934: return "Windows-1256"
        case 2147484936: return "Windows-1258"
        case 2147484701: return "TIS-620"
        case 2147486209: return "Shift-JIS X0213"
        case 2147484706: return "Windows 949"
        case 2147486016: return "EUC-KR"
        case 2147486211: return "Big5"
        case 2147486000: return "GB2312"
        case 2147484705: return "GBK"
        case 2147485234: return "GB18030"
        default: return "UTF-8"
        }
    }
    
    /// Get UInt from encoding name
    ///
    /// Normalizes the input by stripping dashes and uppercasing so both spellings
    /// resolve ("UTF-16-LE" and "UTF-16LE"). Every string that encodingName(from:) can
    /// emit must round-trip back to the same UInt here.
    public static func nsEncoding(from name: String) -> UInt {
        switch normalizedName(name) {
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
        // Character sets menu table (see `characterSets`).
        case "ISO885915": return 2147484175
        case "OEM437": return 2147484672
        case "OEM850": return 2147484688
        case "OEM860": return 2147484693
        case "OEM861": return 2147484694
        case "OEM862": return 2147484695
        case "OEM863": return 2147484696
        case "OEM865": return 2147484698
        case "WINDOWS1250": return String.Encoding.windowsCP1250.rawValue
        case "OEM852": return 2147484690
        case "ISO88594": return 2147484164
        case "ISO885913": return 2147484173
        case "OEM775": return 2147484678
        case "WINDOWS1257": return 2147484935
        case "ISO88595": return 2147484165
        case "KOI8R": return 2147486210
        case "KOI8U": return 2147486216
        case "OEM855": return 2147484691
        case "OEM866": return 2147484699
        case "ISO88597": return 2147484167
        case "OEM737": return 2147484677
        case "OEM869": return 2147484700
        case "WINDOWS1253": return String.Encoding.windowsCP1253.rawValue
        case "ISO88599": return 2147484169
        case "ISO88593": return 2147484163
        case "OEM857": return 2147484692
        case "ISO88598": return 2147484168
        case "WINDOWS1255": return 2147484933
        case "ISO88596": return 2147484166
        case "WINDOWS1256": return 2147484934
        case "WINDOWS1258": return 2147484936
        case "TIS620": return 2147484701
        case "SHIFTJISX0213": return 2147486209
        case "WINDOWS949": return 2147484706
        case "EUCKR": return 2147486016
        case "BIG5": return 2147486211
        case "GB2312": return 2147486000
        case "GBK": return 2147484705
        case "GB18030": return 2147485234
        default: return String.Encoding.utf8.rawValue
        }
    }

    /// One spelling for the encoding names callers pass in: strips dashes,
    /// underscores and spaces, then uppercases. "UTF-16-LE" and "UTF-16LE"
    /// both resolve to "UTF16LE".
    private static func normalizedName(_ name: String) -> String {
        name.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
