import Darwin
import Foundation

/// The editor state a command string can refer to through `$(...)` placeholders.
///
/// This mirrors the variables Notepad++ exposes to its "Run…" command dialog.
/// Pass the file and caret position at the moment the command is invoked; the
/// runner itself never touches the editor or the file system to fill them in.
///
/// ```swift
/// let context = ExternalCommandContext(
///     filePath: "/Users/tester/Documents/notes.md",
///     lineNumber: 12
/// )
/// ExternalCommandRunner.substitute("wc -l \"$(FULL_CURRENT_PATH)\"", in: context)
/// // "wc -l \"/Users/tester/Documents/notes.md\""
/// ```
public struct ExternalCommandContext: Equatable, Sendable {

    /// Absolute path of the current file, or `nil` when no file is open.
    public var filePath: String?

    /// One-based caret line, or `nil` when the position is not meaningful.
    public var lineNumber: Int?

    public init(filePath: String? = nil, lineNumber: Int? = nil) {
        self.filePath = filePath
        self.lineNumber = lineNumber
    }

    /// Convenience initialiser for callers that already hold a file URL.
    public init(fileURL: URL, lineNumber: Int? = nil) {
        self.init(filePath: fileURL.path, lineNumber: lineNumber)
    }
}

/// How an external command is launched, and how long the runner waits for it.
public struct ExternalCommandOptions {

    /// Shell used to interpret the command string. The command is run as
    /// `<shell> -c <command>`.
    public var shell: String

    /// Directory the shell starts in. `nil` keeps the caller's directory.
    public var workingDirectory: URL?

    /// Seconds to wait before the command is terminated. `nil` waits
    /// indefinitely. Negative values are treated as `0`.
    public var timeout: TimeInterval?

    /// Whether the child inherits the caller's environment.
    ///
    /// When `true` (the default) `environment` is merged over
    /// `ProcessInfo.processInfo.environment`; when `false` the child sees only
    /// the entries in `environment`.
    public var inheritEnvironment: Bool

    /// Extra environment entries for the child. Values override inherited ones.
    public var environment: [String: String]

    public init(
        shell: String = "/bin/zsh",
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        inheritEnvironment: Bool = true,
        environment: [String: String] = [:]
    ) {
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.inheritEnvironment = inheritEnvironment
        self.environment = environment
    }
}

/// What a command produced, whether it succeeded, and how long it took.
public struct ExternalCommandResult {

    /// The command actually handed to the shell, after placeholder expansion.
    public let command: String

    /// Everything the command wrote to standard output, decoded as UTF-8.
    /// Bytes that are not valid UTF-8 are replaced with `U+FFFD`.
    public let standardOutput: String

    /// Everything the command wrote to standard error, decoded as UTF-8.
    public let standardError: String

    /// The shell's exit status. When a signal terminated the command this is
    /// the signal number (for example `15` after a timeout); check
    /// `didTimeOut` for that case.
    public let exitCode: Int32

    /// Wall-clock seconds from launch until the shell exited.
    public let duration: TimeInterval

    /// `true` when the runner terminated the command because its timeout
    /// expired. The captured output is whatever had been written by then.
    public let didTimeOut: Bool

    /// `true` when the command finished without a timeout and reported exit
    /// status 0.
    public var succeeded: Bool { exitCode == 0 && !didTimeOut }
}

/// Failures that happen before the command can produce an exit status.
public enum ExternalCommandError: Error, Equatable {
    /// The shell could not be started: bad path, missing executable or an
    /// unusable working directory.
    case launchFailed(shell: String, reason: String)
}

/// Runs Tools-menu shell commands and captures their output.
///
/// ### Placeholders
///
/// The command string is expanded before it reaches the shell. Names follow
/// Notepad++'s "Run…" conventions and are written `$(NAME)`:
///
/// | Placeholder            | Value                                             |
/// | ---------------------- | ------------------------------------------------- |
/// | `$(FULL_CURRENT_PATH)` | Absolute path of the current file                  |
/// | `$(CURRENT_DIRECTORY)` | Directory containing the file, without a trailing slash |
/// | `$(FILE_NAME)`         | File name including its extension                  |
/// | `$(NAME_PART)`         | File name without its extension                    |
/// | `$(EXT_PART)`          | Extension without the leading dot (`""` if none)   |
/// | `$(CURRENT_LINE)`      | One-based caret line                               |
///
/// Unknown placeholders are left untouched, so a command can still pass a
/// literal `$(...)` through. A known placeholder with no value (for example
/// `$(FULL_CURRENT_PATH)` when no file is open) expands to the empty string.
///
/// Expansion is literal and happens before parsing: a path containing spaces
/// must be quoted in the command itself, such as
/// `open "$(FULL_CURRENT_PATH)"`. Values are not escaped, so never build a
/// command from untrusted text without quoting it.
///
/// ### Execution
///
/// Output is captured separately for stdout and stderr. The command never
/// reads the caller's standard input. `run` blocks until the shell exits;
/// the overload with a `completion` handler runs on a private background queue
/// and delivers the same result there.
public enum ExternalCommandRunner {

    /// Completion delivered on a background queue.
    public typealias Completion = (Result<ExternalCommandResult, ExternalCommandError>) -> Void

    /// Expands the `$(...)` placeholders described in the type documentation.
    ///
    /// The expansion is purely textual: values are inserted verbatim, with no
    /// shell quoting or escaping applied.
    public static func substitute(_ command: String, in context: ExternalCommandContext) -> String {
        let path = context.filePath
        let file = path.map { ($0 as NSString).lastPathComponent } ?? ""
        let directory: String
        if let path, !path.isEmpty {
            directory = (path as NSString).deletingLastPathComponent
        } else {
            directory = ""
        }

        let replacements: [String: String] = [
            "$(FULL_CURRENT_PATH)": path ?? "",
            "$(CURRENT_DIRECTORY)": directory,
            "$(FILE_NAME)": file,
            "$(NAME_PART)": (file as NSString).deletingPathExtension,
            "$(EXT_PART)": (file as NSString).pathExtension,
            "$(CURRENT_LINE)": context.lineNumber.map(String.init) ?? ""
        ]

        var expanded = command
        for (placeholder, value) in replacements {
            expanded = expanded.replacingOccurrences(of: placeholder, with: value)
        }
        return expanded
    }

    /// Runs `command` and blocks until it finishes.
    ///
    /// - Throws: `ExternalCommandError.launchFailed` when the shell cannot be
    ///   started, for example because `options.shell` does not exist or
    ///   `options.workingDirectory` is not a directory.
    public static func run(
        _ command: String,
        context: ExternalCommandContext = ExternalCommandContext(),
        options: ExternalCommandOptions = ExternalCommandOptions()
    ) throws -> ExternalCommandResult {
        let expanded = substitute(command, in: context)
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("hexpad-command-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: scratch) }

            let stdoutURL = scratch.appendingPathComponent("stdout")
            let stderrURL = scratch.appendingPathComponent("stderr")
            guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
                  fileManager.createFile(atPath: stderrURL.path, contents: nil) else {
                throw ExternalCommandError.launchFailed(
                    shell: options.shell,
                    reason: "could not create capture files"
                )
            }

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: options.shell)
            process.arguments = ["-c", expanded]
            process.currentDirectoryURL = options.workingDirectory
            process.environment = environment(for: options)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            let started = ProcessInfo.processInfo.systemUptime
            do {
                try process.run()
            } catch {
                throw ExternalCommandError.launchFailed(
                    shell: options.shell,
                    reason: error.localizedDescription
                )
            }

            // The child owns duplicated descriptors now; release ours so the
            // files are complete when we read them back.
            try? stdoutHandle.close()
            try? stderrHandle.close()

            var didTimeOut = false
            if let timeout = options.timeout {
                let limit = max(0, timeout)
                while process.isRunning,
                      ProcessInfo.processInfo.systemUptime - started < limit {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    didTimeOut = true
                    terminate(process)
                }
            }
            process.waitUntilExit()

            let duration = ProcessInfo.processInfo.systemUptime - started
            let stdout = decode(fileManager.contents(atPath: stdoutURL.path) ?? Data())
            let stderr = decode(fileManager.contents(atPath: stderrURL.path) ?? Data())

            return ExternalCommandResult(
                command: expanded,
                standardOutput: stdout,
                standardError: stderr,
                exitCode: process.terminationStatus,
                duration: duration,
                didTimeOut: didTimeOut
            )
        } catch let error as ExternalCommandError {
            throw error
        } catch {
            throw ExternalCommandError.launchFailed(
                shell: options.shell,
                reason: error.localizedDescription
            )
        }
    }

    /// Runs `command` without blocking the caller.
    ///
    /// The completion handler is invoked on a private background queue with the
    /// same result (or failure) the blocking overload would produce.
    public static func run(
        _ command: String,
        context: ExternalCommandContext = ExternalCommandContext(),
        options: ExternalCommandOptions = ExternalCommandOptions(),
        completion: @escaping Completion
    ) {
        queue.async {
            let outcome: Result<ExternalCommandResult, ExternalCommandError>
            do {
                outcome = .success(try run(command, context: context, options: options))
            } catch let error as ExternalCommandError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.launchFailed(shell: options.shell, reason: error.localizedDescription))
            }
            completion(outcome)
        }
    }

    // MARK: - Helpers

    private static let queue = DispatchQueue(
        label: "com.hexpad.external-command",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static func environment(for options: ExternalCommandOptions) -> [String: String] {
        var environment = options.inheritEnvironment ? ProcessInfo.processInfo.environment : [:]
        for (key, value) in options.environment {
            environment[key] = value
        }
        return environment
    }

    /// Sends `SIGTERM`, waits briefly for a clean exit, then escalates to
    /// `SIGKILL` so a command that ignores the first signal cannot hang the
    /// runner.
    private static func terminate(_ process: Process) {
        process.terminate()
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.2
        while process.isRunning, ProcessInfo.processInfo.systemUptime < graceDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
