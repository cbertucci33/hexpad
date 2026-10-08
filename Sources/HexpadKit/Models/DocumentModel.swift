import Foundation

/// Represents an opened document with text content, file backing, and metadata
public final class DocumentModel: Identifiable, ObservableObject {
    public let id: UUID
    public private(set) var filePath: URL?
    public var text: String
    public var name: String
    
    public var isModified: Bool {
        if let filePath {
            do {
                let modified = try FileManager.default.attributesOfItem(atPath: filePath.path)[.modificationDate] as? Date
                return modified != self.savedModificationDate
            } catch {
                return true
            }
        }
        return unsavedChanges
    }
    
    public var unsavedChanges: Bool { !self._originalText.isEmpty && self.text != self._originalText }
    public var isUntitled: Bool { filePath == nil }
    
    private var _originalText: String = ""
    private var savedModificationDate: Date?
    private var _encoding: String = "UTF-8"
    private var _eolType: String = "LF"
    private var _language: String = "Plain Text"
    
    public var encoding: String { _encoding }
    public var eolType: String { _eolType }
    public var language: String { _language }
    public func setLanguage(_ language: String) { _language = language }
    
    public init(text: String = "", filePath: URL? = nil, encoding: String = "UTF-8", eolType: String = "LF") {
        self.id = UUID()
        self.filePath = filePath
        self.text = text
        self.name = filePath?.lastPathComponent ?? "Untitled"
        self._encoding = encoding
        self._eolType = eolType
        if let filePath {
            self._originalText = text
            do {
                self.savedModificationDate = try FileManager.default.attributesOfItem(atPath: filePath.path)[.modificationDate] as? Date
            } catch {}
        }
    }
    
    public func setModified(_ modified: Bool) {
        if !modified {
            self._originalText = self.text
            if let filePath {
                self.savedModificationDate = try? FileManager.default.attributesOfItem(atPath: filePath.path)[.modificationDate] as? Date
            }
        }
    }
    
    public func save() throws {
        guard let filePath else {
            throw DocumentError.noFilePath
        }
        let data = self.text.data(using: String.Encoding(rawValue: EncodingDetective.nsEncoding(from: self.encoding))) ?? Data()
        try data.write(to: filePath, options: .atomic)
        self.setModified(false)
    }
    
    public func saveAs(to url: URL) throws {
        let data = self.text.data(using: String.Encoding(rawValue: EncodingDetective.nsEncoding(from: self.encoding))) ?? Data()
        try data.write(to: url, options: .atomic)
        self.filePath = url
        self.name = url.lastPathComponent
        self.setModified(false)
    }
    
    public func convertEOL(to newType: String) {
        let normalized = self.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        
        switch newType {
        case "CRLF":
            self.text = normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case "CR":
            self.text = normalized.replacingOccurrences(of: "\n", with: "\r")
        default:
            self.text = normalized
        }
        self._eolType = newType
    }
    
    public func toSessionData() -> [String: Any] {
        var data: [String: Any] = [
            "id": self.id.uuidString,
            "text": self.text,
            "name": self.name,
            "encoding": self.encoding,
            "eolType": self.eolType,
            "language": self.language
        ]
        if let path = self.filePath?.path {
            data["filePath"] = path
        }
        return data
    }
    
    public static func fromSessionData(_ data: [String: Any]) -> DocumentModel? {
        guard let idStr = data["id"] as? String,
              let text = data["text"] as? String,
              let name = data["name"] as? String,
              let encoding = data["encoding"] as? String,
              let eolType = data["eolType"] as? String,
              let language = data["language"] as? String else {
            return nil
        }
        let id = UUID(uuidString: idStr) ?? UUID()
        let filePath = (data["filePath"] as? String).flatMap { URL(string: $0) }
        let doc = DocumentModel(text: text, filePath: filePath, encoding: encoding, eolType: eolType)
        doc.name = name
        doc._language = language
        return doc
    }
}

public enum DocumentError: Error, LocalizedError {
    case noFilePath
    case saveFailed(String)
    case fileNotFound(URL)
    
    public var errorDescription: String? {
        switch self {
        case .noFilePath: return "No file path available"
        case .saveFailed(let msg): return "Save failed: \(msg)"
        case .fileNotFound(let url): return "File not found: \(url.path)"
        }
    }
}
