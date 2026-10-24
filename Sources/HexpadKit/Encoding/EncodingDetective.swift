import Foundation

/// Encoding detective for detecting file encoding from raw bytes
public final class EncodingDetective {
    
    /// Detect the encoding of raw data
    public static func detect(_ data: Data) -> String {
        guard data.count > 2 else {
            return "UTF-8"
        }
        
        // Check for BOM
        if data.count >= 4 && data.prefix(4) == Data([0xFF, 0xFE, 0x00, 0x00]) {
            return "UTF-32LE"
        }
        if data.count >= 4 && data.prefix(4) == Data([0x00, 0x00, 0xFE, 0xFF]) {
            return "UTF-32BE"
        }
        if data.count >= 2 && data.prefix(2) == Data([0xFF, 0xFE]) {
            return "UTF-16LE"
        }
        if data.count >= 2 && data.prefix(2) == Data([0xFE, 0xFF]) {
            return "UTF-16BE"
        }
        if data.count >= 3 && data.prefix(3) == Data([0xEF, 0xBB, 0xBF]) {
            return "UTF-8"
        }
        
        // Try to decode as UTF-8
        if let str = String(data: data, encoding: .utf8), str.count == data.count {
            return "UTF-8"
        }
        
        // Try UTF-16
        if let str = String(data: data, encoding: .unicode) {
            return "UTF-16"
        }
        
        // Fallback: try UTF-8 anyway (may have replacement characters)
        return "UTF-8"
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
        let normalized = name.uppercased().replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "UTF-8": return String.Encoding.utf8.rawValue
        case "UTF-16": return String.Encoding.utf16.rawValue
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
