import Foundation

/// One recorded command invocation.
///
/// A step names a command in the ``CommandRegistry`` and carries the optional
/// parameter it was recorded with. The only parameterized default command is
/// `toggle-line-comment`, whose parameter is the comment prefix (for example
/// `"# "`); a `nil` parameter means "use the registry's configured default".
public struct MacroStep: Equatable, Hashable, Codable {

    /// Identifier of the command to run, for example `"duplicate-line"`.
    public let identifier: String

    /// Optional command-specific parameter, such as a comment prefix.
    public let parameter: String?

    public init(identifier: String, parameter: String? = nil) {
        self.identifier = identifier
        self.parameter = parameter
    }
}

/// A recorded sequence of editor commands that can be replayed.
///
/// Recording is best-effort in the Notepad++ sense: every step is replayed
/// against the document produced by the previous step, and a step that turns
/// out to be inapplicable (an unknown command, or one that would not change
/// the document) is recorded as skipped while the remaining steps still run.
///
/// Only commands that run through the app's `performCommand` path are
/// recorded; direct buffer edits and other programmatic document changes are
/// not captured.
///
/// The model is a pure value type over document state. It never touches
/// `NSTextView` and does not mutate app state; callers apply the returned
/// state (text, selection, bookmarks and token styles) as a single edit.
/// `name` and `steps` are `Codable`, so a later layer can persist macros like
/// keybinding overrides. The transient `isRecording` flag is deliberately not
/// encoded.
public struct MacroModel: Equatable, Codable {

    /// Human-readable macro name, used as the persistence key.
    public var name: String

    /// The recorded invocations, in replay order.
    public private(set) var steps: [MacroStep]

    /// Whether the model is currently appending recorded invocations.
    ///
    /// Not persisted: a decoded model is never recording.
    public private(set) var isRecording: Bool

    /// Creates a macro value, optionally pre-populated with steps.
    public init(name: String = "Macro", steps: [MacroStep] = []) {
        self.name = name
        self.steps = steps
        self.isRecording = false
    }

    /// Number of recorded steps.
    public var stepCount: Int { steps.count }

    /// Whether the macro has no steps.
    public var isEmpty: Bool { steps.isEmpty }

    // MARK: - Recording

    /// Starts a new recording, discarding any previously recorded steps.
    ///
    /// - Parameter name: New name; pass `nil` to keep the current name.
    public mutating func startRecording(name: String? = nil) {
        if let name {
            self.name = name
        }
        steps.removeAll()
        isRecording = true
    }

    /// Stops recording. Recorded steps are kept and can be replayed.
    public mutating func stopRecording() {
        isRecording = false
    }

    /// Appends `step` while recording.
    ///
    /// - Returns: `true` when the step was appended; `false` when the model is
    ///   not recording.
    @discardableResult
    public mutating func append(_ step: MacroStep) -> Bool {
        guard isRecording else { return false }
        steps.append(step)
        return true
    }

    /// Records a command invocation while recording.
    ///
    /// - Parameters:
    ///   - identifier: Identifier of the command to record.
    ///   - parameter: Optional command-specific parameter, such as a comment
    ///     prefix.
    /// - Returns: `true` when the step was appended; `false` when the model is
    ///   not recording.
    @discardableResult
    public mutating func record(_ identifier: String, parameter: String? = nil) -> Bool {
        append(MacroStep(identifier: identifier, parameter: parameter))
    }

    // MARK: - Replay

    /// Replays every step in order against a full document state.
    ///
    /// Each step runs through `registry` on the state produced by the previous
    /// step. Commands whose effect lives outside the text — bookmark navigation,
    /// the bookmarked-line operations and the token styles — run through their
    /// document-aware `documentExecute` action, so replay changes the same
    /// bookmarks and styles the live command path changes instead of skipping
    /// the step. Unknown commands and commands that leave the document
    /// unchanged are skipped, and replay continues with the next step.
    ///
    /// - Parameters:
    ///   - text: The starting document text.
    ///   - selection: The starting UTF-16 selection.
    ///   - bookmarkState: The starting bookmarks; replayed bookmark steps
    ///     mutate this state.
    ///   - tokenStyleState: The starting token styles; replayed style steps
    ///     mutate this state.
    /// - Returns: The final document state plus one result per recorded step.
    public func replay(using registry: CommandRegistry = .default,
                       text: String,
                       selection: NSRange,
                       bookmarkState: BookmarkState = BookmarkState(),
                       tokenStyleState: TokenStyleState = TokenStyleState()) -> MacroReplayResult {
        var current = DocumentState(text: text,
                                    selection: selection,
                                    bookmarkState: bookmarkState,
                                    tokenStyleState: tokenStyleState)
        var results: [MacroStepResult] = []
        results.reserveCapacity(steps.count)

        for (index, step) in steps.enumerated() {
            guard let command = registry.command(for: step.identifier) else {
                results.append(MacroStepResult(index: index,
                                               step: step,
                                               outcome: .skipped(.unknownCommand)))
                continue
            }

            // Bookmark and style commands carry their effect in the document
            // state, so replay has to use the same state-aware action the live
            // command path uses rather than their identity text fallback.
            let usesDocumentState = command.documentExecute != nil
                || command.clipboardExecute != nil
            let next: DocumentState?
            if usesDocumentState {
                next = registry.execute(step.identifier, on: current)
            } else if let parameter = step.parameter,
                      let makeAction = command.parameterizedExecute {
                let result = makeAction(parameter)(current.text, current.selection)
                next = DocumentState(text: result.text,
                                     selection: result.selection,
                                     bookmarkState: current.bookmarkState,
                                     tokenStyleState: current.tokenStyleState)
            } else {
                next = registry.execute(step.identifier, on: current)
            }

            guard let next else {
                results.append(MacroStepResult(index: index,
                                               step: step,
                                               outcome: .skipped(.unknownCommand)))
                continue
            }

            // Text steps keep the historical "no text change" rule. Document
            // steps also count bookmark, style and caret changes, because
            // navigating to the next bookmark is a real step in a bookmark
            // macro even though the text stays put.
            let changed = usesDocumentState ? next != current : next.text != current.text
            guard changed else {
                results.append(MacroStepResult(index: index,
                                               step: step,
                                               outcome: .skipped(.noChange)))
                continue
            }

            current = next
            results.append(MacroStepResult(index: index, step: step, outcome: .applied))
        }

        return MacroReplayResult(text: current.text,
                                 selection: current.selection,
                                 bookmarkState: current.bookmarkState,
                                 tokenStyleState: current.tokenStyleState,
                                 stepResults: results)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case name
        case steps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Macro"
        let steps = try container.decodeIfPresent([MacroStep].self, forKey: .steps) ?? []
        self.init(name: name, steps: steps)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(steps, forKey: .steps)
    }
}

/// The outcome of one step during a macro replay.
public enum MacroStepOutcome: Equatable {

    /// The command ran and changed the document.
    case applied

    /// The command was not applicable and was passed over.
    case skipped(MacroSkipReason)

    /// Whether the command changed the document.
    public var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }

    /// The reason a step was skipped, or `nil` when it was applied.
    public var skipReason: MacroSkipReason? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }
}

/// Why a recorded macro step could not be applied.
public enum MacroSkipReason: Equatable, CustomStringConvertible {

    /// No command with the step's identifier is registered.
    case unknownCommand

    /// The command ran but produced no change to the document text.
    case noChange

    public var description: String {
        switch self {
        case .unknownCommand:
            return "unknown command"
        case .noChange:
            return "command made no change"
        }
    }
}

/// The result of one recorded step within a replay.
public struct MacroStepResult: Equatable {

    /// Zero-based position of the step in the macro.
    public let index: Int

    /// The recorded step that was replayed.
    public let step: MacroStep

    /// Whether the step was applied or skipped, and why.
    public let outcome: MacroStepOutcome

    public init(index: Int, step: MacroStep, outcome: MacroStepOutcome) {
        self.index = index
        self.step = step
        self.outcome = outcome
    }

    /// Whether the step changed the document.
    public var isApplied: Bool { outcome.isApplied }

    /// The reason the step was skipped, or `nil` when it was applied.
    public var skipReason: MacroSkipReason? { outcome.skipReason }
}

/// The final document state after replaying a macro, plus per-step outcomes.
public struct MacroReplayResult: Equatable {

    /// The document text after the last applied step.
    public let text: String

    /// The selection after the last applied step.
    public let selection: NSRange

    /// The bookmarks after the last applied step.
    public let bookmarkState: BookmarkState

    /// The token styles after the last applied step.
    public let tokenStyleState: TokenStyleState

    /// One result per recorded step, in replay order.
    public let stepResults: [MacroStepResult]

    public init(text: String,
                selection: NSRange,
                bookmarkState: BookmarkState = BookmarkState(),
                tokenStyleState: TokenStyleState = TokenStyleState(),
                stepResults: [MacroStepResult]) {
        self.text = text
        self.selection = selection
        self.bookmarkState = bookmarkState
        self.tokenStyleState = tokenStyleState
        self.stepResults = stepResults
    }

    /// Number of steps that changed the document.
    public var appliedCount: Int {
        stepResults.reduce(0) { $0 + ($1.isApplied ? 1 : 0) }
    }

    /// Number of steps that were skipped.
    public var skippedCount: Int { stepResults.count - appliedCount }

    /// The skipped steps, for reporting to the user.
    public var skippedSteps: [MacroStepResult] {
        stepResults.filter { !$0.isApplied }
    }

    /// Whether every step was applied. An empty macro is fully applied.
    public var isFullyApplied: Bool {
        stepResults.allSatisfy { $0.isApplied }
    }
}
