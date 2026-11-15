import Foundation

/// A single editor command.
///
/// Commands are pure transformations: they receive the current document text
/// and UTF-16 selection, and return the mutated text plus the selection to
/// restore. Callers apply the result as one text replacement so the whole
/// command is a single undoable edit.
public struct EditorCommand {

    /// Transforms a document and selection into a new document and selection.
    public typealias Action = (_ text: String, _ selection: NSRange) -> (text: String, selection: NSRange)

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
    public let execute: Action

    /// Builds the transformation for a parameter, or `nil` when the command
    /// does not accept one. Callers that pass a parameter use this instead of
    /// ``execute``; commands without parameter support ignore it.
    public let parameterizedExecute: ParameterizedAction?

    public init(identifier: String, title: String, execute: @escaping Action) {
        self.identifier = identifier
        self.title = title
        self.execute = execute
        self.parameterizedExecute = nil
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
    }
}

/// An ordered collection of editor commands with identifier lookup.
///
/// The default registry contains the line-editing commands from `LineOps`.
/// Menu and keybinding wiring is intentionally left to a later layer: this
/// type only describes and runs the commands.
public struct CommandRegistry {

    public let commands: [EditorCommand]
    private let lookup: [String: EditorCommand]

    /// Creates a registry containing the default line-editing commands.
    ///
    /// - Parameter lineCommentPrefix: Prefix used by `toggle-line-comment`.
    public init(lineCommentPrefix: String = "//") {
        self.init(commands: CommandRegistry.defaultCommands(lineCommentPrefix: lineCommentPrefix))
    }

    /// Creates a registry from an explicit command list. When identifiers
    /// collide the first command wins for lookup.
    public init(commands: [EditorCommand]) {
        self.commands = commands
        var lookup: [String: EditorCommand] = [:]
        for command in commands where lookup[command.identifier] == nil {
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
}
