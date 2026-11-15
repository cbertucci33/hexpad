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
    
    /// Dirty means the buffer differs from the saved baseline, or a "Convert
    /// to" changed the save encoding without touching a single character.
    public var unsavedChanges: Bool { text != _originalText || _encodingConversionPending }
    public var isUntitled: Bool { filePath == nil }

    /// Per-document undo stack. The editor swaps its undoManager to this on
    /// tab switch so switching tabs no longer wipes a tab's undo history.
    /// Not persisted: undo stacks intentionally do not survive app restarts.
    public let undoManager = UndoManager()
    
    private var _originalText: String = ""
    private var savedModificationDate: Date?
    private var _encoding: String = "UTF-8"
    /// The encoding the next save writes. `nil` means "same as `encoding`".
    /// "Convert to" sets this without changing the encoding the buffer was
    /// decoded with, so the two menu sections can mark different entries.
    private var _saveEncoding: String?
    private var _encodingConversionPending = false
    private var _eolType: String = "LF"
    private var _language: String = "Plain Text"
    
    /// The encoding the buffer was decoded with (shown in the status bar).
    public var encoding: String { _encoding }

    /// The encoding `save()` will write. Usually equals `encoding`, but
    /// "Convert to" can retarget the next save without re-decoding the buffer.
    public var saveEncoding: String { _saveEncoding ?? _encoding }

    /// The line-ending style used when this document is saved: `"CRLF"`,
    /// `"LF"` or `"CR"`. Detected from the initial text unless the caller
    /// declares one explicitly (a restored session or `convertEOL`).
    public var eolType: String { _eolType }

    public var language: String { _language }
    public func setLanguage(_ language: String) { _language = language }

    /// Per-document editor state (caret, scroll, word wrap, zoom). The model
    /// only stores and persists these values: the app reads and writes them,
    /// and the editor container owns applying them to its TextKit views.
    public var editorState: DocumentEditorState

    /// The user's collapsed fold ranges for this document. Like `editorState`,
    /// the model only stores and persists this value; the app's editor
    /// container owns reading it on unbind and applying it on bind.
    ///
    /// The persisted projection is made of UTF-16 ranges plus kind strings, not
    /// text, so its shape does not change when the document text does. A range
    /// restored into a document whose text changed since the session was saved
    /// is preserved as-is: deciding whether it still refers to a sensible
    /// construct is the app layer's concern, not the model's.
    public var foldState: FoldState

    public var caretRange: NSRange {
        get { editorState.caretRange }
        set { editorState.caretRange = newValue }
    }

    public var scrollOffset: CGPoint {
        get { editorState.scrollOffset }
        set { editorState.scrollOffset = newValue }
    }

    public var wordWrapEnabled: Bool {
        get { editorState.wordWrapEnabled }
        set { editorState.wordWrapEnabled = newValue }
    }

    public var zoomScale: CGFloat {
        get { editorState.zoomScale }
        set { editorState.zoomScale = newValue }
    }

    /// Sets both the decode and save encoding. "Convert to" uses
    /// `convertEncoding(to:)` instead so the two can diverge.
    public func setEncoding(_ encoding: String) {
        _encoding = encoding
        _saveEncoding = encoding
    }
    
    public init(text: String = "", filePath: URL? = nil, encoding: String = "UTF-8", eolType: String? = nil) {
        self.id = UUID()
        self.filePath = filePath
        self.textStorage = NSTextStorage(string: text)
        self.name = filePath?.lastPathComponent ?? "Untitled"
        self._encoding = encoding
        self._saveEncoding = encoding
        // Preserve the file's existing line endings on the first save. Callers
        // that know better (session restore, explicit conversion) pass a style.
        self._eolType = eolType ?? EOLDetective.detect(text)
        self._originalText = text  // a freshly created doc is clean, saved or not
        self.editorState = DocumentEditorState()
        self.foldState = FoldState()
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
        _encodingConversionPending = false
        replaceAllText(with: newText)
    }
    
    public func setModified(_ modified: Bool) {
        if !modified {
            self._originalText = self.text
            self._encodingConversionPending = false
            if let filePath {
                self.savedModificationDate = try? FileManager.default.attributesOfItem(atPath: filePath.path)[.modificationDate] as? Date
            }
        }
    }
    
    public func save() throws {
        guard let filePath else {
            throw DocumentError.noFilePath
        }
        try encodedData().write(to: filePath, options: .atomic)
        self.setModified(false)
    }
    
    public func saveAs(to url: URL) throws {
        try encodedData().write(to: url, options: .atomic)
        self.filePath = url
        self.name = url.lastPathComponent
        self.setModified(false)
    }

    /// Encodes the buffer for disk using the document's encoding and declared
    /// line-ending style. The editor stores newlines as LF internally, so the
    /// text is converted back to `eolType` here; otherwise every save would
    /// silently rewrite CRLF/CR files as LF.
    private func encodedData() throws -> Data {
        let enc = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: self.saveEncoding))
        let serialized = EOLDetective.converting(self.text, to: self.eolType)
        guard let data = serialized.data(using: enc) else {
            throw DocumentError.saveFailed("cannot encode text as \(self.saveEncoding)")
        }
        return data
    }
    
    public func convertEOL(to newType: String) {
        self.text = EOLDetective.converting(self.text, to: newType)
        self._eolType = newType
    }

    // MARK: - Encoding (Encode in / Convert to)

    /// "Encode in": reinterprets raw `data` with `encoding` and reloads the
    /// buffer. No transcoding happens and the file on disk is not touched.
    /// The new text is the clean baseline because it faithfully represents the
    /// same bytes with a different decoder.
    ///
    /// Returns false when the bytes cannot be decoded with `encoding`.
    @discardableResult
    public func redecode(from data: Data, as encoding: String) -> Bool {
        let nsEncoding = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: encoding))
        guard let text = String(data: data, encoding: nsEncoding) else { return false }
        _encoding = encoding
        _saveEncoding = encoding
        reloadText(text)
        return true
    }

    /// "Encode in" against the bytes on disk. File-backed documents only: an
    /// untitled buffer has no raw bytes to reinterpret.
    @discardableResult
    public func redecodeFromDisk(as encoding: String) -> Bool {
        guard let filePath, let data = try? Data(contentsOf: filePath) else { return false }
        return redecode(from: data, as: encoding)
    }

    /// Whether the current buffer can be written with `encoding`. Used to grey
    /// out "Convert to" entries that would fail on the next save.
    public func canEncode(as encoding: String) -> Bool {
        let nsEncoding = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: encoding))
        let serialized = EOLDetective.converting(self.text, to: self.eolType)
        return serialized.data(using: nsEncoding) != nil
    }

    /// "Convert to": retarget the next save at `encoding` without changing the
    /// decode encoding. The buffer stays Unicode; only the bytes written next
    /// differ. The document becomes dirty so the conversion is not forgotten.
    ///
    /// Throws when the text cannot be represented in `encoding`.
    public func convertEncoding(to encoding: String) throws {
        guard canEncode(as: encoding) else {
            throw DocumentError.saveFailed("cannot encode text as \(encoding)")
        }
        _saveEncoding = encoding
        _encodingConversionPending = true
    }
    
    public func toSessionData() -> [String: Any] {
        var data: [String: Any] = [
            "id": self.id.uuidString,
            "text": self.text,
            "name": self.name,
            "encoding": self.encoding,
            "eolType": self.eolType,
            "language": self.language,
            "isModified": self.isModified,
            "editorState": self.editorState.toSessionData(),
            "foldState": self.foldState.toSessionData()
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
        // Sessions written before per-document editor state existed have no
        // "editorState" key; absence restores the startup defaults.
        doc.editorState = DocumentEditorState.fromSessionData(data["editorState"] as? [String: Any])
        // Sessions written before fold persistence existed have no "foldState"
        // key; absence restores an empty (nothing collapsed) state.
        doc.foldState = FoldState.fromSessionData(data["foldState"] as? [String: Any])
        // Restore dirty state: if marked modified, diff against the real saved baseline.
        // File-backed docs diff against their on-disk content; untitled buffers have no
        // file, so their baseline is the empty (never-saved) buffer.
        if isModified {
            if let filePath, FileManager.default.fileExists(atPath: filePath.path) {
                // Document was modified and file exists — read the on-disk content as
                // the saved original so the in-memory diff reflects unsaved changes.
                doc._originalText = (try? String(contentsOf: filePath, encoding: .utf8)) ?? text
            } else {
                // Untitled restored buffer — no file to diff against, mark modified directly.
                doc._originalText = ""
            }
        } else {
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
