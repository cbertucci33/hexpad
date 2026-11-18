import Foundation

/// The state a document-aware command can read and mutate.
///
/// This is the text-plus-selection pair every command already receives, plus
/// the document's ``BookmarkState``. Commands that do not care about bookmarks
/// leave it untouched, so the same value can be threaded through line edits and
/// bookmark navigation alike.
public struct DocumentState: Equatable {

    /// The document text.
    public var text: String

    /// The UTF-16 selection in `text`.
    public var selection: NSRange

    /// The document's bookmarks.
    public var bookmarkState: BookmarkState

    /// The document's five token styles.
    public var tokenStyleState: TokenStyleState

    public init(text: String,
                selection: NSRange,
                bookmarkState: BookmarkState = BookmarkState(),
                tokenStyleState: TokenStyleState = TokenStyleState()) {
        self.text = text
        self.selection = selection
        self.bookmarkState = bookmarkState
        self.tokenStyleState = tokenStyleState
    }
}

/// Live-editor hooks for commands whose effect is not document text.
///
/// Almost every command is a pure transformation of ``DocumentState``. Folding
/// and soft-wrap toggling are the exceptions: their result lives in the editor
/// view and the document's fold projection, neither of which belongs in the
/// Kit. `EditorCommandContext` is the smallest bridge that lets those commands
/// stay registry commands (so they record and can take keybinding overrides)
/// without moving any `NSTextView`/`NSView` code into the Kit.
///
/// Every hook is optional and returns whether it changed something. A context
/// with no hooks — a headless test, or a pure macro replay — makes view
/// commands no-ops. The app installs hooks that call its live `EditorContainer`.
public struct EditorCommandContext {

    /// Collapse every foldable range. Returns `true` when folds changed.
    public var foldAll: (() -> Bool)?

    /// Expand every collapsed range. Returns `true` when folds changed.
    public var unfoldAll: (() -> Bool)?

    /// Collapse the innermost fold containing the caret line. Returns `true`
    /// when a fold changed.
    public var foldCurrentLevel: (() -> Bool)?

    /// Expand the innermost fold containing the caret line. Returns `true`
    /// when a fold changed.
    public var unfoldCurrentLevel: (() -> Bool)?

    /// Collapse every fold at the given 1-based nesting depth. Returns `true`
    /// when folds changed.
    public var foldLevel: ((Int) -> Bool)?

    /// Expand every fold at the given 1-based nesting depth. Returns `true`
    /// when folds changed.
    public var unfoldLevel: ((Int) -> Bool)?

    /// Toggle soft wrapping. Returns `true` when the wrap mode changed.
    public var toggleWordWrap: (() -> Bool)?

    public init(foldAll: (() -> Bool)? = nil,
                unfoldAll: (() -> Bool)? = nil,
                toggleWordWrap: (() -> Bool)? = nil,
                foldCurrentLevel: (() -> Bool)? = nil,
                unfoldCurrentLevel: (() -> Bool)? = nil,
                foldLevel: ((Int) -> Bool)? = nil,
                unfoldLevel: ((Int) -> Bool)? = nil) {
        self.foldAll = foldAll
        self.unfoldAll = unfoldAll
        self.toggleWordWrap = toggleWordWrap
        self.foldCurrentLevel = foldCurrentLevel
        self.unfoldCurrentLevel = unfoldCurrentLevel
        self.foldLevel = foldLevel
        self.unfoldLevel = unfoldLevel
    }

    /// Whether this context provides any view hook at all.
    public var isEmpty: Bool {
        foldAll == nil && unfoldAll == nil && toggleWordWrap == nil
            && foldCurrentLevel == nil && unfoldCurrentLevel == nil
            && foldLevel == nil && unfoldLevel == nil
    }
}

/// A single editor command.
///
/// Commands are pure transformations: they receive the current document text
/// and UTF-16 selection, and return the mutated text plus the selection to
/// restore. Callers apply the result as one text replacement so the whole
/// command is a single undoable edit.
///
/// Commands that need state beyond text and selection (the bookmark commands)
/// also provide a ``documentExecute`` action. Clipboard-bearing bookmark
/// commands additionally provide a ``clipboardExecute`` action because the
/// pasteboard is not part of ``DocumentState``. Text-only commands keep working
/// through their original ``execute`` action. View-only commands (folding and
/// word wrap) provide a ``viewExecute`` action instead and are run by the app's
/// live ``EditorCommandContext``.
public struct EditorCommand {

    /// Transforms a document and selection into a new document and selection.
    public typealias Action = (_ text: String, _ selection: NSRange) -> (text: String, selection: NSRange)

    /// Transforms a full ``DocumentState``, including bookmarks.
    public typealias DocumentAction = (_ state: DocumentState) -> DocumentState

    /// Transforms a document together with the clipboard snapshot.
    ///
    /// The return value carries the new state and an optional pasteboard
    /// payload to write. Clipboard commands need this because their effect is
    /// split between the buffer and the pasteboard, which is not part of
    /// ``DocumentState``.
    public typealias ClipboardAction = (_ state: DocumentState, _ clipboard: String?)
        -> (state: DocumentState, clipboard: String?)

    /// Builds an ``Action`` for a command-specific parameter.
    ///
    /// Commands that accept a parameter (for example the comment prefix of
    /// `toggle-line-comment`) use this to support macro replay, where every
    /// recorded step carries the parameter it was recorded with.
    public typealias ParameterizedAction = (_ parameter: String) -> Action

    /// Runs a view-only command through the ``EditorCommandContext`` hooks.
    ///
    /// Returns whether the live editor changed. A command whose context has no
    /// matching hook is a no-op.
    public typealias ViewAction = (_ context: EditorCommandContext) -> Bool

    /// Stable, machine-readable identifier (for example `"duplicate-line"`).
    public let identifier: String

    /// Human-readable title suitable for a menu item.
    public let title: String

    /// The pure transformation performed by the command.
    ///
    /// Commands that need bookmark state provide a ``documentExecute`` action
    /// instead; this action is their text-only fallback. For the bookmark
    /// commands it is an identity transformation, because the old execution
    /// path carries no bookmark state to change.
    public let execute: Action

    /// Builds the transformation for a parameter, or `nil` when the command
    /// does not accept one. Callers that pass a parameter use this instead of
    /// ``execute``; commands without parameter support ignore it.
    public let parameterizedExecute: ParameterizedAction?

    /// The state-aware transformation, or `nil` for text-only commands.
    ///
    /// ``CommandRegistry/execute(_:on:)`` uses this when present and otherwise
    /// derives a ``DocumentState`` result from ``execute``, preserving the
    /// caller's bookmarks.
    public let documentExecute: DocumentAction?

    /// The live-editor action for view-only commands, or `nil` for commands
    /// whose effect is fully described by text, selection and bookmarks.
    ///
    /// These commands still provide an identity ``execute`` so the pure
    /// text-and-selection path keeps working; their real effect runs through
    /// ``CommandRegistry/executeView(_:context:)`` when the app supplies an
    /// ``EditorCommandContext``.
    public let viewExecute: ViewAction?

    /// The clipboard-aware action, or `nil` for commands that never read or
    /// write the pasteboard.
    ///
    /// Cut/Copy/Paste bookmarked lines use this because the pasteboard is not
    /// part of ``DocumentState``. The app supplies the current payload and
    /// writes the returned one; headless callers can pass `nil`.
    public let clipboardExecute: ClipboardAction?

    public init(identifier: String, title: String, execute: @escaping Action) {
        self.identifier = identifier
        self.title = title
        self.execute = execute
        self.parameterizedExecute = nil
        self.documentExecute = nil
        self.viewExecute = nil
        self.clipboardExecute = nil
    }

    /// Creates a command that also supports a recorded parameter.
    public init(identifier: String,
                title: String,
                execute: @escaping Action,
                parameterizedExecute: @escaping ParameterizedAction) {
        self.identifier = identifier
        self.title = title
        self.execute = execute
        self.parameterizedExecute = parameterizedExecute
        self.documentExecute = nil
        self.viewExecute = nil
        self.clipboardExecute = nil
    }

    /// Creates a command that reads and writes the full document state.
    ///
    /// `execute` remains the text-only entry point, so callers on the legacy
    /// path never have to know about bookmarks.
    public init(identifier: String,
                title: String,
                execute: @escaping Action,
                documentExecute: @escaping DocumentAction,
                clipboardExecute: ClipboardAction? = nil) {
        self.identifier = identifier
        self.title = title
        self.execute = execute
        self.parameterizedExecute = nil
        self.documentExecute = documentExecute
        self.viewExecute = nil
        self.clipboardExecute = clipboardExecute
    }

    /// Creates a view-only command that runs through ``EditorCommandContext``.
    ///
    /// The text action is the identity: folding and wrapping never touch the
    /// document text, so replay sees no text change and reports the step as
    /// skipped. Recording and keybinding overrides still work normally.
    public init(identifier: String,
                title: String,
                viewExecute: @escaping ViewAction) {
        self.identifier = identifier
        self.title = title
        self.execute = { text, selection in (text, selection) }
        self.parameterizedExecute = nil
        self.documentExecute = nil
        self.viewExecute = viewExecute
        self.clipboardExecute = nil
    }
}

/// An ordered collection of editor commands with identifier lookup.
///
/// The default registry contains the line-editing commands from `LineOps` in
/// ``commands``, the bookmark commands in ``bookmarkCommands``, the
/// Tools/Line Ops commands in ``toolCommands`` and ``lineOpCommands``, the
/// Edit > Convert Case to commands in ``caseCommands``, the Edit > Indent
/// commands in ``indentCommands``, and the view-only fold/wrap commands in
/// ``viewCommands``. All groups share identifier lookup
/// and the ``execute(_:on:)`` state-aware path. Menu and keybinding wiring is
/// intentionally left to a later layer: this type only describes and runs the
/// commands.
public struct CommandRegistry {

    /// The line-editing commands, in menu order.
    ///
    /// Bookmark, Tools, Line Ops and view commands live in their own lists so
    /// existing callers that iterate this list keep seeing exactly the
    /// line-editing menu. Mutable internally so ``updatedLineCommentPrefix(_:)``
    /// can swap one command without rebuilding the whole registry; callers
    /// outside the Kit still see a read-only list.
    public private(set) var commands: [EditorCommand]

    /// The bookmark navigation commands, in menu order.
    public let bookmarkCommands: [EditorCommand]

    /// The Tools commands (hash digests and date/time insertion), in menu order.
    public let toolCommands: [EditorCommand]

    /// The Edit > Insert > Date Time commands, in menu order.
    ///
    /// Separate from ``toolCommands`` so the legacy Tools date items keep
    /// their identifiers while the N++-shaped Edit submenu gets its own three
    /// commands, including the user-customized format.
    public let dateCommands: [EditorCommand]

    /// The bulk line operations, in menu order.
    public let lineOpCommands: [EditorCommand]

    /// The Edit > Convert Case to commands, in menu order.
    public let caseCommands: [EditorCommand]

    /// The Edit > Indent commands, in menu order.
    public let indentCommands: [EditorCommand]

    /// The view-only commands (folding and word wrap), in menu order.
    public let viewCommands: [EditorCommand]

    /// The Search > token style commands, in menu order.
    public let tokenStyleCommands: [EditorCommand]

    private var lookup: [String: EditorCommand]

    /// All commands offered by this registry, line-editing commands first.
    public var allCommands: [EditorCommand] {
        commands + bookmarkCommands + toolCommands + dateCommands + lineOpCommands
            + caseCommands + indentCommands + viewCommands + tokenStyleCommands
    }

    /// Creates a registry containing the default command groups.
    ///
    /// - Parameters:
    ///   - lineCommentPrefix: Prefix used by `toggle-line-comment`.
    ///   - indentSettings: Fallback whitespace policy for the Edit > Indent
    ///     commands when they run without a macro parameter. The app supplies
    ///     its Preferences policy through the parameter instead.
    ///   - now: Clock used by the `insert-date`/`insert-time`/`insert-datetime`
    ///     commands. It is read at execution time, so replay inserts a fresh
    ///     timestamp instead of the one captured while recording. Tests pass a
    ///     fixed closure for deterministic output.
    public init(lineCommentPrefix: String = "//",
                indentSettings: IndentSettings = .default,
                now: @escaping () -> Date = Date.init) {
        self.init(commands: CommandRegistry.defaultCommands(lineCommentPrefix: lineCommentPrefix),
                  bookmarkCommands: CommandRegistry.defaultBookmarkCommands(),
                  toolCommands: CommandRegistry.defaultToolCommands(now: now),
                  dateCommands: CommandRegistry.defaultDateCommands(now: now),
                  lineOpCommands: CommandRegistry.defaultLineOpCommands(),
                  caseCommands: CommandRegistry.defaultCaseCommands(),
                  indentCommands: CommandRegistry.defaultIndentCommands(settings: indentSettings),
                  viewCommands: CommandRegistry.defaultViewCommands(),
                  tokenStyleCommands: CommandRegistry.defaultTokenStyleCommands())
    }

    /// Creates a registry from explicit command lists. When identifiers
    /// collide the first command wins for lookup; groups are searched in the
    /// order listed by ``allCommands``.
    public init(commands: [EditorCommand],
                bookmarkCommands: [EditorCommand] = [],
                toolCommands: [EditorCommand] = [],
                dateCommands: [EditorCommand] = [],
                lineOpCommands: [EditorCommand] = [],
                caseCommands: [EditorCommand] = [],
                indentCommands: [EditorCommand] = [],
                viewCommands: [EditorCommand] = [],
                tokenStyleCommands: [EditorCommand] = []) {
        self.commands = commands
        self.bookmarkCommands = bookmarkCommands
        self.toolCommands = toolCommands
        self.dateCommands = dateCommands
        self.lineOpCommands = lineOpCommands
        self.caseCommands = caseCommands
        self.indentCommands = indentCommands
        self.viewCommands = viewCommands
        self.tokenStyleCommands = tokenStyleCommands
        var lookup: [String: EditorCommand] = [:]
        for command in commands + bookmarkCommands + toolCommands + dateCommands
            + lineOpCommands + caseCommands + indentCommands + viewCommands
            + tokenStyleCommands
        where lookup[command.identifier] == nil {
            lookup[command.identifier] = command
        }
        self.lookup = lookup
    }

    /// A registry with the standard commands and the default `//` comment prefix.
    public static let `default` = CommandRegistry()

    /// Builds the `toggle-line-comment` command for `prefix`.
    ///
    /// Shared by ``defaultCommands(lineCommentPrefix:)`` and by
    /// ``updatedLineCommentPrefix(_:)``, so rebuilding the command for a new
    /// document language produces exactly the command construction would have.
    private static func toggleLineCommentCommand(prefix: String) -> EditorCommand {
        EditorCommand(
            identifier: "toggle-line-comment",
            title: "Toggle Line Comment",
            execute: { text, selection in
                LineOps.toggleLineComment(text, selection: selection, prefix: prefix)
            },
            parameterizedExecute: { parameter in
                { text, selection in
                    LineOps.toggleLineComment(text, selection: selection, prefix: parameter)
                }
            }
        )
    }

    /// The default line-editing commands, in menu order.
    public static func defaultCommands(lineCommentPrefix: String = "//") -> [EditorCommand] {
        [
            EditorCommand(
                identifier: "duplicate-line",
                title: "Duplicate Line",
                execute: LineOps.duplicateLine
            ),
            EditorCommand(
                identifier: "delete-line",
                title: "Delete Line",
                execute: LineOps.deleteLine
            ),
            EditorCommand(
                identifier: "move-line-up",
                title: "Move Line Up",
                execute: LineOps.moveLineUp
            ),
            EditorCommand(
                identifier: "move-line-down",
                title: "Move Line Down",
                execute: LineOps.moveLineDown
            ),
            CommandRegistry.toggleLineCommentCommand(prefix: lineCommentPrefix),
            EditorCommand(
                identifier: "uppercase",
                title: "Uppercase",
                execute: LineOps.uppercase
            ),
            EditorCommand(
                identifier: "lowercase",
                title: "Lowercase",
                execute: LineOps.lowercase
            )
        ]
    }

    /// The bookmark navigation commands, in menu order.
    ///
    /// Each command has an identity `execute` action for the legacy
    /// text-and-selection path (which has no bookmark state) and a
    /// ``EditorCommand/documentExecute`` action for ``execute(_:on:)``.
    public static func defaultBookmarkCommands() -> [EditorCommand] {
        [
            EditorCommand(
                identifier: "bookmark-toggle",
                title: "Toggle Bookmark",
                execute: { text, selection in (text, selection) },
                documentExecute: BookmarkCommandOps.toggle
            ),
            EditorCommand(
                identifier: "bookmark-next",
                title: "Next Bookmark",
                execute: { text, selection in (text, selection) },
                documentExecute: BookmarkCommandOps.next
            ),
            EditorCommand(
                identifier: "bookmark-prev",
                title: "Previous Bookmark",
                execute: { text, selection in (text, selection) },
                documentExecute: BookmarkCommandOps.previous
            ),
            EditorCommand(
                identifier: "bookmark-clear-all",
                title: "Clear All Bookmarks",
                execute: { text, selection in (text, selection) },
                documentExecute: BookmarkCommandOps.clearAll
            ),
            EditorCommand(
                identifier: "bookmark-cut-lines",
                title: "Cut Bookmarked Lines",
                execute: { text, selection in (text, selection) },
                documentExecute: BookmarkCommandOps.cutLines,
                clipboardExecute: BookmarkCommandOps.cutLinesWithClipboard
            ),
            EditorCommand(
                identifier: "bookmark-copy-lines",
                title: "Copy Bookmarked Lines",
                execute: { text, selection in (text, selection) },
                documentExecute: { $0 },
                clipboardExecute: BookmarkCommandOps.copyLinesWithClipboard
            ),
            EditorCommand(
                identifier: "bookmark-paste-replace-lines",
                title: "Paste to (Replace) Bookmarked Lines",
                execute: { text, selection in (text, selection) },
                documentExecute: { $0 },
                clipboardExecute: BookmarkCommandOps.pasteReplacingLines
            ),
            EditorCommand(
                identifier: "bookmark-remove-lines",
                title: "Remove Bookmarked Lines",
                execute: { text, selection in (text, selection) },
                documentExecute: BookmarkCommandOps.removeLines
            ),
            EditorCommand(
                identifier: "bookmark-inverse",
                title: "Inverse Bookmarks",
                execute: { text, selection in (text, selection) },
                documentExecute: BookmarkCommandOps.inverse
            )
        ]
    }

    /// The Tools commands: hash digests and date/time insertion.
    ///
    /// All of them are document commands. The hash commands digest the
    /// selection when there is one and the whole buffer otherwise, then insert
    /// the digest at the caret. The date/time commands read `now` when they
    /// execute, so a replayed macro inserts a fresh timestamp.
    ///
    /// - Parameter now: Clock read by the date/time commands at execution time.
    public static func defaultToolCommands(now: @escaping () -> Date = Date.init) -> [EditorCommand] {
        [
            EditorCommand(
                identifier: "hash-md5",
                title: "MD5",
                execute: { text, selection in
                    HashCommandOps.insert(HashKit.md5, text: text, selection: selection)
                }
            ),
            EditorCommand(
                identifier: "hash-sha1",
                title: "SHA-1",
                execute: { text, selection in
                    HashCommandOps.insert(HashKit.sha1, text: text, selection: selection)
                }
            ),
            EditorCommand(
                identifier: "hash-sha256",
                title: "SHA-256",
                execute: { text, selection in
                    HashCommandOps.insert(HashKit.sha256, text: text, selection: selection)
                }
            ),
            EditorCommand(
                identifier: "hash-sha512",
                title: "SHA-512",
                execute: { text, selection in
                    HashCommandOps.insert(HashKit.sha512, text: text, selection: selection)
                }
            ),
            EditorCommand(
                identifier: "hash-md5-per-line",
                title: "MD5 Per-line",
                execute: { text, selection in
                    HashCommandOps.insert({ HashKit.digestPerLine($0, HashKit.md5) },
                                         text: text,
                                         selection: selection)
                }
            ),
            EditorCommand(
                identifier: "hash-sha1-per-line",
                title: "SHA-1 Per-line",
                execute: { text, selection in
                    HashCommandOps.insert({ HashKit.digestPerLine($0, HashKit.sha1) },
                                         text: text,
                                         selection: selection)
                }
            ),
            EditorCommand(
                identifier: "hash-sha256-per-line",
                title: "SHA-256 Per-line",
                execute: { text, selection in
                    HashCommandOps.insert({ HashKit.digestPerLine($0, HashKit.sha256) },
                                         text: text,
                                         selection: selection)
                }
            ),
            EditorCommand(
                identifier: "hash-sha512-per-line",
                title: "SHA-512 Per-line",
                execute: { text, selection in
                    HashCommandOps.insert({ HashKit.digestPerLine($0, HashKit.sha512) },
                                         text: text,
                                         selection: selection)
                }
            ),
            EditorCommand(
                identifier: "insert-date",
                title: "Short Date",
                execute: { text, selection in
                    HashCommandOps.insertAtCaret(DateTimeInsert.shortDate(now()),
                                                 text: text,
                                                 selection: selection)
                }
            ),
            EditorCommand(
                identifier: "insert-time",
                title: "Short Time",
                execute: { text, selection in
                    HashCommandOps.insertAtCaret(DateTimeInsert.shortTime(now()),
                                                 text: text,
                                                 selection: selection)
                }
            ),
            EditorCommand(
                identifier: "insert-datetime",
                title: "Full Date+Time",
                execute: { text, selection in
                    HashCommandOps.insertAtCaret(
                        DateTimeInsert.formatted(now(), pattern: "yyyy-MM-dd HH:mm:ss"),
                        text: text,
                        selection: selection
                    )
                }
            )
        ]
    }

    /// The Edit > Insert > Date Time commands, in menu order.
    ///
    /// These mirror Notepad++'s three Insert > Date Time entries. The two fixed
    /// styles read `now` when they execute, so a replayed macro inserts a fresh
    /// timestamp. The customized command accepts the user's format pattern as
    /// its macro-style parameter; the app passes the live Settings value, and a
    /// plain replay without one falls back to
    /// ``DateTimeInsert/defaultCustomPattern``.
    ///
    /// - Parameter now: Clock read by the commands at execution time.
    public static func defaultDateCommands(now: @escaping () -> Date = Date.init) -> [EditorCommand] {
        [
            EditorCommand(
                identifier: "insert-datetime-short",
                title: "Date Time (short)",
                execute: { text, selection in
                    HashCommandOps.insertAtCaret(DateTimeInsert.shortStyle(now()),
                                                 text: text,
                                                 selection: selection)
                }
            ),
            EditorCommand(
                identifier: "insert-datetime-long",
                title: "Date Time (long)",
                execute: { text, selection in
                    HashCommandOps.insertAtCaret(DateTimeInsert.longStyle(now()),
                                                 text: text,
                                                 selection: selection)
                }
            ),
            EditorCommand(
                identifier: "insert-datetime-custom",
                title: "Date Time (customized)",
                execute: { text, selection in
                    HashCommandOps.insertAtCaret(
                        DateTimeInsert.customized(now(), pattern: DateTimeInsert.defaultCustomPattern),
                        text: text,
                        selection: selection
                    )
                },
                parameterizedExecute: { pattern in
                    { text, selection in
                        HashCommandOps.insertAtCaret(DateTimeInsert.customized(now(), pattern: pattern),
                                                     text: text,
                                                     selection: selection)
                    }
                }
            )
        ]
    }

    /// The bulk line-operation commands, in menu order.
    ///
    /// Each command transforms the selection when there is one and the whole
    /// buffer otherwise, matching the app's original Line Ops menu behavior.
    public static func defaultLineOpCommands() -> [EditorCommand] {
        [
            EditorCommand(
                identifier: "sort-lines-ascending",
                title: "Sort Lines A-Z",
                execute: { text, selection in
                    LineCommandOps.applying(LineOps.sortAscending, text: text, selection: selection)
                }
            ),
            EditorCommand(
                identifier: "sort-lines-descending",
                title: "Sort Lines Z-A",
                execute: { text, selection in
                    LineCommandOps.applying(LineOps.sortDescending, text: text, selection: selection)
                }
            ),
            EditorCommand(
                identifier: "remove-duplicate-lines",
                title: "Remove Duplicate Lines",
                execute: { text, selection in
                    LineCommandOps.applying(LineOps.removeDuplicates, text: text, selection: selection)
                }
            ),
            EditorCommand(
                identifier: "remove-blank-lines",
                title: "Remove Blank Lines",
                execute: { text, selection in
                    LineCommandOps.applying(LineOps.removeBlankLines, text: text, selection: selection)
                }
            )
        ]
    }

    /// The Edit > Convert Case to commands, in Notepad++ menu order.
    ///
    /// Each command converts the selection, or the word at the caret when the
    /// selection is empty, as one undoable edit. The blend variants preserve
    /// words that are already all upper case (acronyms).
    public static func defaultCaseCommands() -> [EditorCommand] {
        [
            EditorCommand(
                identifier: "case-uppercase",
                title: "UPPERCASE",
                execute: CaseOps.uppercase
            ),
            EditorCommand(
                identifier: "case-lowercase",
                title: "lowercase",
                execute: CaseOps.lowercase
            ),
            EditorCommand(
                identifier: "case-proper",
                title: "Proper Case",
                execute: CaseOps.properCase
            ),
            EditorCommand(
                identifier: "case-proper-blend",
                title: "Proper Case (blend)",
                execute: CaseOps.properCaseBlend
            ),
            EditorCommand(
                identifier: "case-sentence",
                title: "Sentence case",
                execute: CaseOps.sentenceCase
            ),
            EditorCommand(
                identifier: "case-sentence-blend",
                title: "Sentence case (blend)",
                execute: CaseOps.sentenceCaseBlend
            ),
            EditorCommand(
                identifier: "case-invert",
                title: "iNVERT cASE",
                execute: CaseOps.invertCase
            ),
            EditorCommand(
                identifier: "case-random",
                title: "ranDOm CasE",
                execute: CaseOps.randomCase
            )
        ]
    }

    /// The Edit > Indent commands, in Notepad++ menu order.
    ///
    /// Both operate on every line touched by the selection, or the caret's
    /// line when the selection is collapsed. `indentSettings` is the fallback
    /// policy; the app passes its live Preferences through the macro-style
    /// parameter ("tabs:4" / "spaces:4") so the command follows the user's
    /// tabs-vs-spaces choice and tab width.
    public static func defaultIndentCommands(settings: IndentSettings = .default) -> [EditorCommand] {
        [
            EditorCommand(
                identifier: "indent-increase",
                title: "Increase Line Indent",
                execute: { text, selection in
                    IndentOps.indentLines(text, selection: selection, settings: settings)
                },
                parameterizedExecute: { parameter in
                    let resolved = IndentSettings(parameter: parameter) ?? settings
                    return { text, selection in
                        IndentOps.indentLines(text, selection: selection, settings: resolved)
                    }
                }
            ),
            EditorCommand(
                identifier: "indent-decrease",
                title: "Decrease Line Indent",
                execute: { text, selection in
                    IndentOps.dedentLines(text, selection: selection, settings: settings)
                },
                parameterizedExecute: { parameter in
                    let resolved = IndentSettings(parameter: parameter) ?? settings
                    return { text, selection in
                        IndentOps.dedentLines(text, selection: selection, settings: resolved)
                    }
                }
            )
        ]
    }

    /// The view-only commands, in menu order.
    ///
    /// They carry no document transformation; the app supplies the actual
    /// folding/wrapping hooks through ``EditorCommandContext``. Recording works
    /// exactly like any other command, but pure text replay reports them as
    /// unchanged because view state is not part of ``DocumentState``.
    public static func defaultViewCommands() -> [EditorCommand] {
        var commands: [EditorCommand] = [
            EditorCommand(identifier: "fold-all",
                          title: "Fold All",
                          viewExecute: { $0.foldAll?() ?? false }),
            EditorCommand(identifier: "unfold-all",
                          title: "Unfold All",
                          viewExecute: { $0.unfoldAll?() ?? false }),
            EditorCommand(identifier: "fold-current-level",
                          title: "Fold Current Level",
                          viewExecute: { $0.foldCurrentLevel?() ?? false }),
            EditorCommand(identifier: "unfold-current-level",
                          title: "Unfold Current Level",
                          viewExecute: { $0.unfoldCurrentLevel?() ?? false })
        ]
        for level in 1...8 {
            commands.append(EditorCommand(identifier: "fold-level-\(level)",
                                          title: "Fold Level \(level)",
                                          viewExecute: { $0.foldLevel?(level) ?? false }))
        }
        for level in 1...8 {
            commands.append(EditorCommand(identifier: "unfold-level-\(level)",
                                          title: "Unfold Level \(level)",
                                          viewExecute: { $0.unfoldLevel?(level) ?? false }))
        }
        commands.append(EditorCommand(identifier: "toggle-word-wrap",
                                      title: "Word Wrap",
                                      viewExecute: { $0.toggleWordWrap?() ?? false }))
        return commands
    }

    /// The Search > token style commands, in Notepad++ menu order.
    ///
    /// Each style is a document command: the pure text path is an identity
    /// transform because styles live in ``DocumentState/tokenStyleState``.
    /// Copy commands only write the pasteboard, so they provide a
    /// ``EditorCommand/clipboardExecute`` action.
    public static func defaultTokenStyleCommands() -> [EditorCommand] {
        var commands: [EditorCommand] = []

        for style in TokenStyleState.styleNumbers {
            commands.append(EditorCommand(
                identifier: "style-all-occurrences-\(style)",
                title: "Style \(style)",
                execute: { text, selection in (text, selection) },
                documentExecute: TokenStyleCommandOps.styleAllOccurrences(style: style)
            ))
        }
        for style in TokenStyleState.styleNumbers {
            commands.append(EditorCommand(
                identifier: "style-one-token-\(style)",
                title: "Style \(style)",
                execute: { text, selection in (text, selection) },
                documentExecute: TokenStyleCommandOps.styleOneToken(style: style)
            ))
        }
        for style in TokenStyleState.styleNumbers {
            commands.append(EditorCommand(
                identifier: "clear-style-\(style)",
                title: "Clear Style \(style)",
                execute: { text, selection in (text, selection) },
                documentExecute: TokenStyleCommandOps.clear(style: style)
            ))
        }
        commands.append(EditorCommand(
            identifier: "clear-style-all",
            title: "Clear All Styles",
            execute: { text, selection in (text, selection) },
            documentExecute: TokenStyleCommandOps.clearAll
        ))
        for style in TokenStyleState.styleNumbers {
            commands.append(EditorCommand(
                identifier: "jump-up-\(style)",
                title: "Style \(style)",
                execute: { text, selection in (text, selection) },
                documentExecute: TokenStyleCommandOps.jumpUp(style: style)
            ))
        }
        for style in TokenStyleState.styleNumbers {
            commands.append(EditorCommand(
                identifier: "jump-down-\(style)",
                title: "Style \(style)",
                execute: { text, selection in (text, selection) },
                documentExecute: TokenStyleCommandOps.jumpDown(style: style)
            ))
        }
        for style in TokenStyleState.styleNumbers {
            commands.append(EditorCommand(
                identifier: "copy-styled-text-\(style)",
                title: "Style \(style)",
                execute: { text, selection in (text, selection) },
                documentExecute: { $0 },
                clipboardExecute: TokenStyleCommandOps.copyStyledText(style: style)
            ))
        }
        commands.append(EditorCommand(
            identifier: "copy-styled-text-all",
            title: "All Styles",
            execute: { text, selection in (text, selection) },
            documentExecute: { $0 },
            clipboardExecute: TokenStyleCommandOps.copyAllStyledText
        ))
        return commands
    }

    /// Returns the command registered under `identifier`, if any.
    public func command(for identifier: String) -> EditorCommand? {
        lookup[identifier]
    }

    /// Rebuilds only `toggle-line-comment` with a new line-comment prefix.
    ///
    /// The app owns one registry for every document, so its comment prefix has
    /// to follow the focused document's language. This swaps that single
    /// command in place — same identifier, title and parameter support — and
    /// leaves every other command (and the lookup built from them) untouched.
    /// Menus, keybindings and macro steps therefore keep resolving the same
    /// commands they did before the document changed.
    public mutating func updatedLineCommentPrefix(_ prefix: String) {
        let replacement = CommandRegistry.toggleLineCommentCommand(prefix: prefix)
        guard let index = commands.firstIndex(where: { $0.identifier == replacement.identifier }) else {
            return
        }
        commands[index] = replacement
        lookup[replacement.identifier] = replacement
    }

    /// Runs the command registered under `identifier`.
    ///
    /// Returns `nil` when no command with that identifier exists.
    public func execute(_ identifier: String,
                        text: String,
                        selection: NSRange) -> (text: String, selection: NSRange)? {
        command(for: identifier)?.execute(text, selection)
    }

    /// Runs the command registered under `identifier`, passing `parameter`
    /// when the command supports one.
    ///
    /// A `nil` parameter behaves exactly like ``execute(_:text:selection:)``.
    /// A command that does not accept parameters ignores a non-`nil` value.
    ///
    /// Returns `nil` when no command with that identifier exists.
    public func execute(_ identifier: String,
                        parameter: String?,
                        text: String,
                        selection: NSRange) -> (text: String, selection: NSRange)? {
        guard let command = command(for: identifier) else { return nil }
        if let parameter, let makeAction = command.parameterizedExecute {
            return makeAction(parameter)(text, selection)
        }
        return command.execute(text, selection)
    }

    /// Runs the command registered under `identifier` against a full document
    /// state, including bookmarks.
    ///
    /// Text-only commands run through their existing ``EditorCommand/execute``
    /// action and the caller's ``DocumentState/bookmarkState`` is preserved
    /// unchanged. Bookmark commands use their state-aware action instead.
    ///
    /// Returns `nil` when no command with that identifier exists.
    public func execute(_ identifier: String,
                        on state: DocumentState) -> DocumentState? {
        guard let command = command(for: identifier) else { return nil }
        if let documentExecute = command.documentExecute {
            return documentExecute(state)
        }
        let result = command.execute(state.text, state.selection)
        return DocumentState(text: result.text,
                             selection: result.selection,
                             bookmarkState: state.bookmarkState,
                             tokenStyleState: state.tokenStyleState)
    }

    /// Runs the command registered under `identifier` with a clipboard
    /// snapshot.
    ///
    /// Commands with a ``EditorCommand/clipboardExecute`` action receive
    /// `clipboard` and may return a new payload. Every other command runs
    /// through ``execute(_:on:)`` and leaves the payload untouched.
    ///
    /// Returns `nil` when no command with that identifier exists.
    public func execute(_ identifier: String,
                        on state: DocumentState,
                        clipboard: String?) -> (state: DocumentState, clipboard: String?)? {
        guard let command = command(for: identifier) else { return nil }
        if let clipboardExecute = command.clipboardExecute {
            return clipboardExecute(state, clipboard)
        }
        guard let result = execute(identifier, on: state) else { return nil }
        return (result, nil)
    }

    /// Runs a view-only command through the supplied editor context.
    ///
    /// Returns `nil` when no command with that identifier exists or when the
    /// command is not view-only. A view command with no matching hook in
    /// `context` returns `false` and changes nothing.
    public func executeView(_ identifier: String,
                            context: EditorCommandContext) -> Bool? {
        guard let command = command(for: identifier),
              let viewExecute = command.viewExecute else { return nil }
        return viewExecute(context)
    }
}

/// Shared helpers for the Tools hash/date commands.
enum HashCommandOps {

    /// Inserts `digest(source)` at the caret, where `source` is the selection
    /// when non-empty and the whole document otherwise.
    ///
    /// The selection is not replaced, matching the app's original Tools
    /// behavior: the digest lands at the selection's start and the caret moves
    /// after it. Out-of-range or missing selections fall back to the whole
    /// buffer and a caret clamped to the buffer end.
    static func insert(_ digest: (String) -> String,
                       text: String,
                       selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let clamped = clampedSelection(selection, in: ns.length)
        let source = clamped.length > 0
            ? ns.substring(with: clamped)
            : text
        return insertAtCaret(digest(source), text: text, selection: selection)
    }

    /// Inserts `insertion` at the selection's start without deleting anything.
    static func insertAtCaret(_ insertion: String,
                              text: String,
                              selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let caret = clampedSelection(selection, in: ns.length).location
        let newText = ns.replacingCharacters(in: NSRange(location: caret, length: 0),
                                             with: insertion)
        let end = caret + (insertion as NSString).length
        return (newText, NSRange(location: end, length: 0))
    }

    /// Clamps a selection to `length`, preserving an empty caret.
    ///
    /// A missing or out-of-range selection is treated as a caret at the
    /// clamped location, which makes callers fall back to the whole buffer.
    static func clampedSelection(_ selection: NSRange, in length: Int) -> NSRange {
        guard selection.location != NSNotFound,
              selection.location >= 0,
              selection.location <= length,
              selection.length >= 0,
              selection.length <= length - selection.location else {
            let location = selection.location == NSNotFound
                ? length
                : min(max(0, selection.location), length)
            return NSRange(location: location, length: 0)
        }
        return selection
    }
}

/// Shared helper for the bulk Line Ops commands.
enum LineCommandOps {

    /// Applies `transform` to the selection when it is non-empty, otherwise to
    /// the whole document, and returns the new text plus a selection that
    /// covers the transformed slice (or the clamped original caret).
    static func applying(_ transform: (String) -> String,
                         text: String,
                         selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let clamped = HashCommandOps.clampedSelection(selection, in: ns.length)
        guard clamped.length > 0 else {
            return (transform(text), clamped)
        }
        let replacement = transform(ns.substring(with: clamped))
        let newText = ns.replacingCharacters(in: clamped, with: replacement)
        return (newText, NSRange(location: clamped.location,
                                 length: (replacement as NSString).length))
    }
}

/// Implementations of the bookmark commands.
///
/// They operate on a ``BookmarkModel`` so line validation and wrap-around match
/// the rest of the bookmark layer. Navigation commands never modify text; the
/// bookmarked-line operations delegate to ``BookmarkLineOps`` for text and
/// bookmark changes.
enum BookmarkCommandOps {

    /// Bookmarks the current line, or removes its bookmark when present.
    static func toggle(_ state: DocumentState) -> DocumentState {
        var model = BookmarkModel(text: state.text, bookmarkState: state.bookmarkState)
        model.toggle(line: currentLine(in: state))
        return replacingBookmarks(in: state, with: model.bookmarkState)
    }

    /// Moves the caret to the start of the next bookmarked line, wrapping.
    ///
    /// With no bookmarks the state is returned unchanged. A single bookmark
    /// wraps onto itself, matching Notepad++.
    static func next(_ state: DocumentState) -> DocumentState {
        let model = BookmarkModel(text: state.text, bookmarkState: state.bookmarkState)
        guard let bookmark = model.next(afterLine: currentLine(in: state)) else {
            return state
        }
        return moved(to: bookmark, model: model, from: state)
    }

    /// Moves the caret to the start of the previous bookmarked line, wrapping.
    ///
    /// With no bookmarks the state is returned unchanged.
    static func previous(_ state: DocumentState) -> DocumentState {
        let model = BookmarkModel(text: state.text, bookmarkState: state.bookmarkState)
        guard let bookmark = model.previous(beforeLine: currentLine(in: state)) else {
            return state
        }
        return moved(to: bookmark, model: model, from: state)
    }

    /// Removes every bookmark.
    static func clearAll(_ state: DocumentState) -> DocumentState {
        var model = BookmarkModel(text: state.text, bookmarkState: state.bookmarkState)
        model.removeAll()
        return replacingBookmarks(in: state, with: model.bookmarkState)
    }

    // MARK: - Bookmarked-line operations

    /// Removes every bookmarked line. The clipboard-aware variant also
    /// returns those lines as the pasteboard payload.
    static func cutLines(_ state: DocumentState) -> DocumentState {
        applying(BookmarkLineOps.cut(state.text,
                                     selection: state.selection,
                                     bookmarks: state.bookmarkState))
    }

    static func cutLinesWithClipboard(_ state: DocumentState,
                                      clipboard: String?) -> (state: DocumentState, clipboard: String?) {
        let result = BookmarkLineOps.cut(state.text,
                                        selection: state.selection,
                                        bookmarks: state.bookmarkState)
        return (applying(result), result.clipboardText)
    }

    /// Copies every bookmarked line and leaves the buffer alone.
    static func copyLinesWithClipboard(_ state: DocumentState,
                                       clipboard: String?) -> (state: DocumentState, clipboard: String?) {
        let result = BookmarkLineOps.copy(state.text,
                                         selection: state.selection,
                                         bookmarks: state.bookmarkState)
        return (state, result.clipboardText)
    }

    /// Replaces bookmarked lines' content with the clipboard's lines.
    static func pasteReplacingLines(_ state: DocumentState,
                                    clipboard: String?) -> (state: DocumentState, clipboard: String?) {
        guard let clipboard else { return (state, nil) }
        let result = BookmarkLineOps.pasteReplacing(state.text,
                                                   selection: state.selection,
                                                   bookmarks: state.bookmarkState,
                                                   clipboard: clipboard)
        return (applying(result), nil)
    }

    /// Removes every bookmarked line without changing the clipboard.
    static func removeLines(_ state: DocumentState) -> DocumentState {
        applying(BookmarkLineOps.remove(state.text,
                                        selection: state.selection,
                                        bookmarks: state.bookmarkState))
    }

    /// Inverts the bookmark set line by line.
    static func inverse(_ state: DocumentState) -> DocumentState {
        applying(BookmarkLineOps.inverse(state.text,
                                         selection: state.selection,
                                         bookmarks: state.bookmarkState))
    }

    /// Wraps a line-operation result as a document state.
    private static func applying(_ result: BookmarkLineOps.Result) -> DocumentState {
        DocumentState(text: result.text,
                      selection: result.selection,
                      bookmarkState: result.bookmarks)
    }

    // MARK: - Helpers

    /// The 1-based logical line containing the selection's start.
    private static func currentLine(in state: DocumentState) -> Int {
        let length = state.text.utf16.count
        let location = state.selection.location == NSNotFound ? 0 : state.selection.location
        return GutterGeometry.logicalLine(of: max(0, min(location, length)), in: state.text)
    }

    /// Returns `state` with `bookmarkState` replaced and everything else intact.
    private static func replacingBookmarks(in state: DocumentState,
                                           with bookmarks: BookmarkState) -> DocumentState {
        var updated = state
        updated.bookmarkState = bookmarks
        return updated
    }

    /// Returns `state` with a caret at the start of `bookmark`'s line.
    private static func moved(to bookmark: Bookmark,
                              model: BookmarkModel,
                              from state: DocumentState) -> DocumentState {
        var updated = replacingBookmarks(in: state, with: model.bookmarkState)
        updated.selection = NSRange(
            location: GutterGeometry.firstCharIndex(of: bookmark.line, in: state.text),
            length: 0
        )
        return updated
    }
}

/// Implementations of the Search > token style commands.
///
/// Styles live in ``DocumentState/tokenStyleState``; these operations only
/// mutate that value or the selection, never the text. Target resolution for
/// the style commands is shared with Select and Find Next: the selection when
/// it has length, otherwise the word at the caret.
enum TokenStyleCommandOps {

    /// Styles every occurrence of the selection-or-word-at-caret.
    static func styleAllOccurrences(style: Int) -> EditorCommand.DocumentAction {
        { state in
            guard let target = targetRange(in: state) else { return state }
            let token = (state.text as NSString).substring(with: target)
            var model = TokenStyleModel(text: state.text,
                                        tokenStyleState: state.tokenStyleState)
            guard model.styleAllOccurrences(of: token, as: style) else { return state }
            return replacingStyles(in: state, with: model.tokenStyleState)
        }
    }

    /// Styles only the exact current selection-or-word range.
    static func styleOneToken(style: Int) -> EditorCommand.DocumentAction {
        { state in
            guard let target = targetRange(in: state) else { return state }
            var model = TokenStyleModel(text: state.text,
                                        tokenStyleState: state.tokenStyleState)
            guard model.style(target, as: style) else { return state }
            return replacingStyles(in: state, with: model.tokenStyleState)
        }
    }

    /// Removes every range carrying `style`.
    static func clear(style: Int) -> EditorCommand.DocumentAction {
        { state in
            var model = TokenStyleModel(text: state.text,
                                        tokenStyleState: state.tokenStyleState)
            guard model.removeAll(style: style) else { return state }
            return replacingStyles(in: state, with: model.tokenStyleState)
        }
    }

    /// Removes every styled range in every style.
    static func clearAll(_ state: DocumentState) -> DocumentState {
        var model = TokenStyleModel(text: state.text,
                                    tokenStyleState: state.tokenStyleState)
        guard model.removeAll() else { return state }
        return replacingStyles(in: state, with: model.tokenStyleState)
    }

    /// Moves the caret to the previous `style` range, wrapping.
    static func jumpUp(style: Int) -> EditorCommand.DocumentAction {
        { state in
            let model = TokenStyleModel(text: state.text,
                                        tokenStyleState: state.tokenStyleState)
            guard let range = model.previousRange(for: style, before: caret(in: state)) else {
                return state
            }
            return moved(to: range, from: state)
        }
    }

    /// Moves the caret to the next `style` range, wrapping.
    static func jumpDown(style: Int) -> EditorCommand.DocumentAction {
        { state in
            let model = TokenStyleModel(text: state.text,
                                        tokenStyleState: state.tokenStyleState)
            guard let range = model.nextRange(for: style, after: caret(in: state)) else {
                return state
            }
            return moved(to: range, from: state)
        }
    }

    /// Copies every range carrying `style` to the pasteboard.
    static func copyStyledText(style: Int) -> EditorCommand.ClipboardAction {
        { state, _ in
            let model = TokenStyleModel(text: state.text,
                                        tokenStyleState: state.tokenStyleState)
            guard let text = model.styledText(for: style) else { return (state, nil) }
            return (state, text)
        }
    }

    /// Copies every styled range across all styles to the pasteboard.
    static func copyAllStyledText(_ state: DocumentState,
                                  _ clipboard: String?) -> (state: DocumentState, clipboard: String?) {
        let model = TokenStyleModel(text: state.text,
                                    tokenStyleState: state.tokenStyleState)
        guard let text = model.allStyledText() else { return (state, nil) }
        return (state, text)
    }

    // MARK: - Helpers

    /// The selection when it has length, otherwise the word at the caret.
    private static func targetRange(in state: DocumentState) -> NSRange? {
        SearchEngine.selectionSearchRange(text: state.text, selection: state.selection)
    }

    /// The selection's location, clamped to a caret position.
    private static func caret(in state: DocumentState) -> Int {
        let length = (state.text as NSString).length
        guard state.selection.location != NSNotFound else { return 0 }
        return min(max(0, state.selection.location), length)
    }

    /// Returns `state` with the token styles replaced and everything else intact.
    private static func replacingStyles(in state: DocumentState,
                                        with styles: TokenStyleState) -> DocumentState {
        var updated = state
        updated.tokenStyleState = styles
        return updated
    }

    /// Returns `state` with a collapsed caret at the start of `range`.
    private static func moved(to range: NSRange, from state: DocumentState) -> DocumentState {
        var updated = state
        updated.selection = NSRange(location: range.location, length: 0)
        return updated
    }
}
