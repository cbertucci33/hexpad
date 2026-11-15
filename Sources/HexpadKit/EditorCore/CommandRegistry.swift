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

    public init(text: String,
                selection: NSRange,
                bookmarkState: BookmarkState = BookmarkState()) {
        self.text = text
        self.selection = selection
        self.bookmarkState = bookmarkState
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
/// also provide a ``documentExecute`` action. Text-only commands keep working
/// through their original ``execute`` action.
public struct EditorCommand {

    /// Transforms a document and selection into a new document and selection.
    public typealias Action = (_ text: String, _ selection: NSRange) -> (text: String, selection: NSRange)

    /// Transforms a full ``DocumentState``, including bookmarks.
    public typealias DocumentAction = (_ state: DocumentState) -> DocumentState

    /// Builds an ``Action`` for a command-specific parameter.
    ///
    /// Commands that accept a parameter (for example the comment prefix of
    /// `toggle-line-comment`) use this to support macro replay, where every
    /// recorded step carries the parameter it was recorded with.
    public typealias ParameterizedAction = (_ parameter: String) -> Action

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

    public init(identifier: String, title: String, execute: @escaping Action) {
        self.identifier = identifier
        self.title = title
        self.execute = execute
        self.parameterizedExecute = nil
        self.documentExecute = nil
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
    }

    /// Creates a command that reads and writes the full document state.
    ///
    /// `execute` remains the text-only entry point, so callers on the legacy
    /// path never have to know about bookmarks.
    public init(identifier: String,
                title: String,
                execute: @escaping Action,
                documentExecute: @escaping DocumentAction) {
        self.identifier = identifier
        self.title = title
        self.execute = execute
        self.parameterizedExecute = nil
        self.documentExecute = documentExecute
    }
}

/// An ordered collection of editor commands with identifier lookup.
///
/// The default registry contains the line-editing commands from `LineOps` in
/// ``commands`` and the bookmark navigation commands in ``bookmarkCommands``.
/// Both groups share identifier lookup and the ``execute(_:on:)`` state-aware
/// path. Menu and keybinding wiring is intentionally left to a later layer:
/// this type only describes and runs the commands.
public struct CommandRegistry {

    /// The line-editing commands, in menu order.
    ///
    /// Bookmark commands are kept in ``bookmarkCommands`` so existing callers
    /// that iterate this list keep seeing exactly the line-editing menu.
    public let commands: [EditorCommand]

    /// The bookmark navigation commands, in menu order.
    public let bookmarkCommands: [EditorCommand]

    private let lookup: [String: EditorCommand]

    /// All commands offered by this registry, line-editing commands first.
    public var allCommands: [EditorCommand] { commands + bookmarkCommands }

    /// Creates a registry containing the default line-editing and bookmark
    /// navigation commands.
    ///
    /// - Parameter lineCommentPrefix: Prefix used by `toggle-line-comment`.
    public init(lineCommentPrefix: String = "//") {
        self.init(commands: CommandRegistry.defaultCommands(lineCommentPrefix: lineCommentPrefix),
                  bookmarkCommands: CommandRegistry.defaultBookmarkCommands())
    }

    /// Creates a registry from explicit command lists. When identifiers
    /// collide the first command wins for lookup; `commands` are searched
    /// before `bookmarkCommands`.
    public init(commands: [EditorCommand], bookmarkCommands: [EditorCommand] = []) {
        self.commands = commands
        self.bookmarkCommands = bookmarkCommands
        var lookup: [String: EditorCommand] = [:]
        for command in commands + bookmarkCommands where lookup[command.identifier] == nil {
            lookup[command.identifier] = command
        }
        self.lookup = lookup
    }

    /// A registry with the standard commands and the default `//` comment prefix.
    public static let `default` = CommandRegistry()

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
            EditorCommand(
                identifier: "toggle-line-comment",
                title: "Toggle Line Comment",
                execute: { text, selection in
                    LineOps.toggleLineComment(text, selection: selection, prefix: lineCommentPrefix)
                },
                parameterizedExecute: { prefix in
                    { text, selection in
                        LineOps.toggleLineComment(text, selection: selection, prefix: prefix)
                    }
                }
            ),
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
            )
        ]
    }

    /// Returns the command registered under `identifier`, if any.
    public func command(for identifier: String) -> EditorCommand? {
        lookup[identifier]
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
                             bookmarkState: state.bookmarkState)
    }
}

/// Implementations of the bookmark commands.
///
/// They operate on a ``BookmarkModel`` so line validation and wrap-around match
/// the rest of the bookmark layer. Text is never modified.
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
