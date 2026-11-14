import AppKit

/// Represents an opened document with text content, file backing, and metadata.
///
/// The document owns the one authoritative buffer (`textStorage`). The editor's
/// NSTextView is attached to this storage through its layout manager, so there
/// is no second copy to keep in sync: typing and programmatic edits (find,
/// replace, line ops, reloads) all mutate the same characters.
public final class DocumentModel: Identifiable, ObservableObject {
    public let id: UUID
    public private(set) var filePath: URL?

    /// The single source of truth for this document's text.
    public let textStorage: NSTextStorage

    /// Convenience view of the shared buffer. Assigning routes through
    /// `textStorage` and registers undo like any other edit.
    public var text: String {
        get { textStorage.string }
        set { replaceAllText(with: newValue) }
    }

    public var name: String

    /// Posted after a programmatic mutation of `textStorage`. Typing is
    /// reported by NSTextView through its delegate instead.
    public static let textDidChangeNotification = Notification.Name("DocumentModelTextDidChange")
    
    /// Dirty means the in-memory text differs from what was last saved.
    /// This used to compare the file's on-disk mtime, which ordinary typing
    /// does not change, so a saved file never reported modified and quit-time
    /// autosave skipped it. The in-memory diff remains the truthful signal;
    /// the app's external-change watcher resets the baseline via
    /// `reloadText(_:)` when it replaces a clean buffer.
    public var isModified: Bool { unsavedChanges }
    
    public var unsavedChanges: Bool { text != _originalText }
    public var isUntitled: Bool { filePath == nil }

    /// Per-document undo stack. The editor swaps its undoManager to this on
    /// tab switch so switching tabs no longer wipes a tab's undo history.
    /// Not persisted: undo stacks intentionally do not survive app restarts.
    public let undoManager = UndoManager()
    
    private var _originalText: String = ""
    private var savedModificationDate: Date?
    private var _encoding: String = "UTF-8"
    private var _eolType: String = "LF"
    private var _language: String = "Plain Text"
    
    public var encoding: String { _encoding }
    public var eolType: String { _eolType }
    public var language: String { _language }
    public func setLanguage(_ language: String) { _language = language }
    public func setEncoding(_ encoding: String) { _encoding = encoding }
    
    public init(text: String = "", filePath: URL? = nil, encoding: String = "UTF-8", eolType: String = "LF") {
        self.id = UUID()
        self.filePath = filePath
        self.textStorage = NSTextStorage(string: text)
        self.name = filePath?.lastPathComponent ?? "Untitled"
        self._encoding = encoding
        self._eolType = eolType
        self._originalText = text  // a freshly created doc is clean, saved or not
        if let filePath {
            do {
                self.savedModificationDate = try FileManager.default.attributesOfItem(atPath: filePath.path)[.modificationDate] as? Date
            } catch {}
        }
    }

    // MARK: - Text mutation

    /// Replaces `range` in the shared buffer and registers the change on this
    /// document's undo stack. All programmatic edits go through here so the
    /// attached editor shows them immediately and Cmd+Z can revert them.
    public func replaceCharacters(in range: NSRange, with replacement: String) {
        let current = textStorage.string as NSString
        let length = current.length
        guard range.location != NSNotFound,
              range.location >= 0, range.length >= 0,
              range.location <= length,
              range.length <= length - range.location else { return }

        let oldText = current.substring(with: range)
        guard oldText != replacement else { return }

        undoManager.registerUndo(withTarget: self) { doc in
            // Registering while undoing turns this call into the matching redo.
            doc.replaceCharacters(in: NSRange(location: range.location,
                                             length: (replacement as NSString).length),
                                  with: oldText)
        }
        textStorage.replaceCharacters(in: range, with: replacement)
        NotificationCenter.default.post(name: Self.textDidChangeNotification, object: self)
    }

    /// Replaces the whole buffer through the shared storage, preserving undo.
    public func replaceAllText(with newText: String) {
        replaceCharacters(in: NSRange(location: 0, length: (textStorage.string as NSString).length),
                          with: newText)
    }

    /// Loads on-disk text as the new clean baseline. The replacement is still
    /// undoable, but observers see the final baseline in the single notification
    /// instead of a transient dirty state.
    public func reloadText(_ newText: String) {
        _originalText = newText
        replaceAllText(with: newText)
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
        let enc = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: self.encoding))
        guard let data = self.text.data(using: enc) else {
            throw DocumentError.saveFailed("cannot encode text as \(self.encoding)")
        }
        try data.write(to: filePath, options: .atomic)
        self.setModified(false)
    }
    
    public func saveAs(to url: URL) throws {
        let enc = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: self.encoding))
        guard let data = self.text.data(using: enc) else {
            throw DocumentError.saveFailed("cannot encode text as \(self.encoding)")
        }
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
            "language": self.language,
            "isModified": self.isModified
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
        // fileURLWithPath, not URL(string:): paths with spaces, #, ? or % either
        // fail outright or come back percent-encoded and restore as broken tabs.
        let filePath = (data["filePath"] as? String).map { URL(fileURLWithPath: $0) }
        let isModified = data["isModified"] as? Bool ?? false
        let doc = DocumentModel(text: text, filePath: filePath, encoding: encoding, eolType: eolType)
        doc.name = name
        doc._language = language
        // Restore dirty state: if marked modified but file exists on disk, reset original
        // so the in-memory diff reflects actual unsaved changes
        if isModified, FileManager.default.fileExists(atPath: filePath?.path ?? "") {
            // Document was modified and file exists — keep current text as-is (unsaved)
            // _originalText stays empty so isModified returns true
        } else if !isModified {
            doc.setModified(false)
        }
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
