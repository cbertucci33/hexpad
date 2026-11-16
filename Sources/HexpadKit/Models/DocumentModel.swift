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
    /// to" changed the save encoding or line endings without touching a single
    /// character. Backed by an explicit flag: comparing the whole buffer to the
    /// saved text here made every tab-dirty check O(document), which turned
    /// keystrokes and tab switches into hundreds of milliseconds on large files.
    public var unsavedChanges: Bool { _isDirty || _saveConversionPending }
    public var isUntitled: Bool { filePath == nil }

    /// Per-document undo stack. The editor swaps its undoManager to this on
    /// tab switch so switching tabs no longer wipes a tab's undo history.
    /// Not persisted: undo stacks intentionally do not survive app restarts.
    public let undoManager = UndoManager()

    /// Monotonic counter of character edits to this document's buffer. Bumped
    /// by the same storage observer that maintains the dirty flag, so typing,
    /// programmatic replacements, reloads and undo all advance it. Callers that
    /// cache work derived from the text (session snapshots, find matches, the
    /// function list) compare it instead of comparing whole strings.
    public private(set) var textRevision: Int = 0
    
    private var _originalText: String = ""
    /// Authoritative O(1) dirty bit. Set by storage character edits (typing and
    /// programmatic replaces), cleared by save/reload. Undo/redo reconcile it
    /// against the baseline; session save gets a cheap repair check.
    private var _isDirty = false
    private var dirtyObservers: [NSObjectProtocol] = []
    private var savedModificationDate: Date?
    private var _encoding: String = "UTF-8"
    /// The encoding the next save writes. `nil` means "same as `encoding`".
    /// "Convert to" sets this without changing the encoding the buffer was
    /// decoded with, so the two menu sections can mark different entries.
    private var _saveEncoding: String?
    /// True when a "Convert to" changed how the next save serializes the
    /// buffer (encoding or line endings) without editing the text itself.
    /// Persisted with the session: a restored tab must still save with the
    /// bytes the user picked, even if the app was quit before that save.
    private var _saveConversionPending = false
    private var _eolType: String = "LF"
    private var _language: String = "Plain Text"

    /// True when the backing file starts with a byte order mark. The buffer
    /// never contains the BOM (it is stripped when decoding), so the next save
    /// re-emits one from this flag. Persisted with the session.
    public var keepsBOM: Bool = false

    /// Set when the backing file changed on disk while this buffer held
    /// unsaved edits. The buffer is deliberately kept; this flag records the
    /// conflict so the app can surface it. `setModified(true)` cannot express
    /// this because the document is already dirty.
    public private(set) var hasExternalChange = false
    
    /// The encoding the buffer was decoded with (shown in the status bar).
    public var encoding: String { _encoding }

    /// The encoding `save()` will write. Usually equals `encoding`, but
    /// "Convert to" can retarget the next save without re-decoding the buffer.
    public var saveEncoding: String { _saveEncoding ?? _encoding }

    /// True while a "Convert to" (encoding or line endings) is waiting to
    /// change the bytes the next save writes.
    public var hasPendingSaveConversion: Bool { _saveConversionPending }

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

    /// The user's bookmarks for this document. Like `foldState`, the model only
    /// stores and persists this value; the app's editor container owns reading
    /// it on unbind and applying it on bind.
    ///
    /// The persisted projection is made of 1-based logical line numbers plus
    /// optional notes, not text, so its shape does not change when the document
    /// text does. A line restored into a document whose text changed since the
    /// session was saved is preserved as-is: deciding whether it still refers to
    /// a sensible line is the app layer's concern, not the model's.
    public var bookmarkState: BookmarkState

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
        self.bookmarkState = BookmarkState()
        if let filePath {
            do {
                self.savedModificationDate = try FileManager.default.attributesOfItem(atPath: filePath.path)[.modificationDate] as? Date
            } catch {}
        }
        startDirtyObservation()
    }

    deinit {
        dirtyObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Dirty state

    /// Follows the shared storage so typing (which bypasses the model's
    /// replace methods) and every programmatic mutation flip the O(1) flag.
    /// Undo/redo are the one case where the flag can become stale in the clean
    /// direction, so they reconcile against the baseline (user-paced, rare).
    private func startDirtyObservation() {
        let center = NotificationCenter.default
        dirtyObservers.append(center.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let storage = notification.object as? NSTextStorage,
                  storage === self.textStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            self._isDirty = true
            self.textRevision &+= 1
        })
        for name in [Notification.Name("NSUndoManagerDidUndoChangeNotification"),
                     Notification.Name("NSUndoManagerDidRedoChangeNotification")] {
            dirtyObservers.append(center.addObserver(
                forName: name,
                object: undoManager,
                queue: nil
            ) { [weak self] _ in
                self?.reconcileDirtyStateFully()
            })
        }
    }

    /// Cheap on-demand repair for callers that persist state (session save):
    /// catches a missed dirty transition without ever comparing full text on a
    /// keystroke path. A length change from the saved baseline can only mean
    /// dirty, so it is safe to promote false -> true here.
    public func reconcileDirtyState() {
        guard !_isDirty else { return }
        if textStorage.length != (_originalText as NSString).length {
            _isDirty = true
        }
    }

    /// Full comparison, reserved for undo/redo where the text can return
    /// exactly to the saved baseline. Not on any typing path.
    private func reconcileDirtyStateFully() {
        _isDirty = text != _originalText
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
        _isDirty = true
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
        _saveConversionPending = false
        hasExternalChange = false
        replaceAllText(with: newText)
        // replaceAllText marks the buffer dirty through the storage observer;
        // the on-disk text it just loaded is the clean baseline.
        _isDirty = false
    }
    
    public func setModified(_ modified: Bool) {
        if modified {
            _isDirty = true
            return
        }
        self._originalText = self.text
        _isDirty = false
        self._saveConversionPending = false
        self.hasExternalChange = false
        if let filePath {
            self.savedModificationDate = try? FileManager.default.attributesOfItem(atPath: filePath.path)[.modificationDate] as? Date
        }
    }

    /// Records that the backing file changed on disk while this buffer had
    /// unsaved edits. The buffer is kept, so dirty state is already true;
    /// this flag is the only observable change such a conflict can make.
    /// Cleared by `reloadText(_:)` (an explicit reload) and by saving.
    public func noteExternalChange() {
        hasExternalChange = true
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
        // The buffer never holds the BOM (open/decode strip it), so a file
        // that came with one gets it back here. Foundation's native-order
        // UTF-16/UTF-32 encoders emit their own BOM, hence the prefix check.
        guard keepsBOM,
              let bom = EncodingDetective.bomBytes(for: self.saveEncoding),
              !data.starts(with: bom) else {
            return data
        }
        return bom + data
    }
    
    /// "Convert to" line endings: retarget the next save at `newType` without
    /// touching the buffer. The editor buffer stays LF-only because every
    /// line-based subsystem (gutter, folds, bookmarks, minimap, Ln/Col) keys on
    /// `\n`; `encodedData()` applies the chosen style when bytes are written.
    /// The document becomes dirty so the conversion is not forgotten.
    public func convertEOL(to newType: String) {
        self._eolType = newType
        self._saveConversionPending = true
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
        let body = EncodingDetective.strippingBOM(from: data)
        guard let text = String(data: body, encoding: nsEncoding) else { return false }
        _encoding = encoding
        _saveEncoding = encoding
        // Keep the byte-order information with the document: the buffer is
        // BOM-free, so the next save has to put the BOM back itself.
        keepsBOM = EncodingDetective.detectBOM(of: data) != nil
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
        _saveConversionPending = true
    }
    
    public func toSessionData() -> [String: Any] {
        // Cheap repair before persisting: length-vs-baseline catches a missed
        // dirty transition without the old full-text comparison on every key.
        reconcileDirtyState()
        var data: [String: Any] = [
            "id": self.id.uuidString,
            "text": self.text,
            "name": self.name,
            "encoding": self.encoding,
            // The decode encoding and the next save's encoding can differ
            // after "Convert to"; both must survive a quit. The pending flag
            // is what keeps the converted document dirty across a restore.
            "saveEncoding": self.saveEncoding,
            "saveConversionPending": self.hasPendingSaveConversion,
            "keepsBOM": self.keepsBOM,
            "eolType": self.eolType,
            "language": self.language,
            "isModified": self.isModified,
            "editorState": self.editorState.toSessionData(),
            "foldState": self.foldState.toSessionData(),
            "bookmarkState": self.bookmarkState.toSessionData()
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
        // Sessions written before these keys existed have no "Convert to"
        // state: the next save keeps using the decode encoding and nothing is
        // pending, which is exactly what those older documents did.
        let saveEncoding = data["saveEncoding"] as? String ?? encoding
        let pendingConversion = data["saveConversionPending"] as? Bool ?? false
        let keepsBOM = data["keepsBOM"] as? Bool ?? false
        let doc = DocumentModel(text: text, filePath: filePath, encoding: encoding, eolType: eolType)
        doc.name = name
        doc._language = language
        doc.keepsBOM = keepsBOM
        // Sessions written before per-document editor state existed have no
        // "editorState" key; absence restores the startup defaults.
        doc.editorState = DocumentEditorState.fromSessionData(data["editorState"] as? [String: Any])
        // Sessions written before fold persistence existed have no "foldState"
        // key; absence restores an empty (nothing collapsed) state.
        doc.foldState = FoldState.fromSessionData(data["foldState"] as? [String: Any])
        // Sessions written before bookmark persistence existed have no
        // "bookmarkState" key; absence restores an empty (no bookmarked lines)
        // state.
        doc.bookmarkState = BookmarkState.fromSessionData(data["bookmarkState"] as? [String: Any])
        // Restore dirty state: if marked modified, diff against the real saved baseline.
        // File-backed docs diff against their on-disk content; untitled buffers have no
        // file, so their baseline is the empty (never-saved) buffer.
        if isModified {
            if let filePath, FileManager.default.fileExists(atPath: filePath.path),
               let onDisk = try? Data(contentsOf: filePath),
               // Decode with the document's own encoding (and strip its BOM):
               // reading UTF-16/CP1252 as UTF-8 used to fail, silently making
               // a restored dirty buffer look clean.
               let savedText = EncodingDetective.decodeForEditing(onDisk, as: encoding) {
                // Document was modified and file exists — read the on-disk content as
                // the saved original so the in-memory diff reflects unsaved changes.
                doc._originalText = savedText
            } else {
                // Untitled restored buffer (or a file that vanished): there is
                // no readable baseline, so treat the whole buffer as unsaved.
                doc._originalText = ""
            }
        } else {
            doc.setModified(false)
        }
        // Apply "Convert to" state after the baseline: setModified(false)
        // clears the pending flag, but an explicitly persisted conversion has
        // to survive the restore.
        doc._saveEncoding = saveEncoding
        doc._saveConversionPending = pendingConversion
        doc._isDirty = isModified
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
