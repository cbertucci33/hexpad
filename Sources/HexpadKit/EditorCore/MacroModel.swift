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
/// The model is a pure value type over document state. It never touches
/// `NSTextView` and does not mutate app state; callers apply the returned text
/// and selection as a single edit. `name` and `steps` are `Codable`, so a
/// later layer can persist macros like keybinding overrides. The transient
/// `isRecording` flag is deliberately not encoded.
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

    /// Replays every step in order against `text` and `selection`.
    ///
    /// Each step runs through `registry` on the state produced by the previous
    /// step. Unknown commands and commands that leave the document unchanged
    /// are skipped, and replay continues with the next step.
    ///
    /// - Returns: The final document state plus one result per recorded step.
    public func replay(using registry: CommandRegistry = .default,
                       text: String,
                       selection: NSRange) -> MacroReplayResult {
        var currentText = text
        var currentSelection = selection
        var results: [MacroStepResult] = []
        results.reserveCapacity(steps.count)

        for (index, step) in steps.enumerated() {
            guard let result = registry.execute(step.identifier,
                                                parameter: step.parameter,
                                                text: currentText,
                                                selection: currentSelection) else {
                results.append(MacroStepResult(index: index,
                                               step: step,
                                               outcome: .skipped(.unknownCommand)))
                continue
            }

            guard result.text != currentText else {
                results.append(MacroStepResult(index: index,
                                               step: step,
                                               outcome: .skipped(.noChange)))
                continue
            }

            currentText = result.text
            currentSelection = result.selection
            results.append(MacroStepResult(index: index, step: step, outcome: .applied))
        }

        return MacroReplayResult(text: currentText,
                                 selection: currentSelection,
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

    /// One result per recorded step, in replay order.
    public let stepResults: [MacroStepResult]

    public init(text: String, selection: NSRange, stepResults: [MacroStepResult]) {
        self.text = text
        self.selection = selection
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
