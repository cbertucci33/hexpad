import XCTest
@testable import HexpadKit

final class ExternalCommandTests: XCTestCase {

    // MARK: - Output capture

    func testEchoIsCaptured() throws {
        let result = try ExternalCommandRunner.run("echo hello")
        XCTAssertEqual(result.standardOutput, "hello\n")
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.didTimeOut)
        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.duration, 0)
        XCTAssertEqual(result.command, "echo hello")
    }

    func testStdoutAndStderrAreSeparated() throws {
        let result = try ExternalCommandRunner.run("printf 'to stdout'; printf 'to stderr' >&2")
        XCTAssertEqual(result.standardOutput, "to stdout")
        XCTAssertEqual(result.standardError, "to stderr")
        XCTAssertTrue(result.succeeded)
    }

    func testNonZeroExitStatusIsPreserved() throws {
        let result = try ExternalCommandRunner.run("echo failing >&2; exit 42")
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.standardError, "failing\n")
    }

    func testUnicodeOutputSurvivesCapture() throws {
        let result = try ExternalCommandRunner.run("printf 'héllo 世界 🚀'")
        XCTAssertEqual(result.standardOutput, "héllo 世界 🚀")
    }

    // MARK: - Timeout

    func testTimeoutKillsSleepingCommand() throws {
        let start = Date()
        let result = try ExternalCommandRunner.run(
            "sleep 5",
            options: ExternalCommandOptions(timeout: 0.25)
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.didTimeOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(elapsed, 3, "runner should return soon after the timeout")
        XCTAssertGreaterThanOrEqual(result.duration, 0.2)
    }

    func testOutputWrittenBeforeTimeoutIsKept() throws {
        let result = try ExternalCommandRunner.run(
            "printf 'partial'; sleep 5",
            options: ExternalCommandOptions(timeout: 0.4)
        )
        XCTAssertTrue(result.didTimeOut)
        XCTAssertEqual(result.standardOutput, "partial")
    }

    // MARK: - Placeholders

    private let context = ExternalCommandContext(
        filePath: "/Users/tester/Documents/notes.md",
        lineNumber: 12
    )

    func testPlaceholderSubstitutionInCommand() throws {
        let result = try ExternalCommandRunner.run(
            """
            printf '%s|%s|%s|%s|%s|%s' \
            "$(FULL_CURRENT_PATH)" "$(FILE_NAME)" "$(NAME_PART)" \
            "$(EXT_PART)" "$(CURRENT_DIRECTORY)" "$(CURRENT_LINE)"
            """,
            context: context
        )
        XCTAssertEqual(
            result.standardOutput,
            "/Users/tester/Documents/notes.md|notes.md|notes|md|/Users/tester/Documents|12"
        )
    }

    func testSubstitutionLeavesUnknownPlaceholdersAlone() {
        let expanded = ExternalCommandRunner.substitute(
            "$(FILE_NAME) $(NOT_A_VARIABLE) $(CURRENT_LINE)",
            in: context
        )
        XCTAssertEqual(expanded, "notes.md $(NOT_A_VARIABLE) 12")
    }

    func testMissingFileExpandsToEmptyStrings() {
        let expanded = ExternalCommandRunner.substitute(
            "x$(FULL_CURRENT_PATH)x$(FILE_NAME)x$(CURRENT_DIRECTORY)x$(CURRENT_LINE)x",
            in: ExternalCommandContext()
        )
        XCTAssertEqual(expanded, "xxxxx")
    }

    func testPathWithoutExtensionHasEmptyExtPart() {
        let expanded = ExternalCommandRunner.substitute(
            "$(NAME_PART).$(EXT_PART)",
            in: ExternalCommandContext(filePath: "/tmp/Makefile")
        )
        XCTAssertEqual(expanded, "Makefile.")
    }

    func testQuotedPathWithSpacesArrivesIntact() throws {
        let spaced = ExternalCommandContext(filePath: "/Users/tester/My Notes/todo list.txt")
        let result = try ExternalCommandRunner.run(
            "printf '%s' \"$(FULL_CURRENT_PATH)\"",
            context: spaced
        )
        XCTAssertEqual(result.standardOutput, "/Users/tester/My Notes/todo list.txt")
        XCTAssertEqual(
            ExternalCommandRunner.substitute("$(NAME_PART)", in: spaced),
            "todo list"
        )
    }

    // MARK: - Options

    func testWorkingDirectoryAndEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try ExternalCommandRunner.run(
            "pwd -P; printf '%s' \"$HEXPAD_COMMAND_TEST\"",
            options: ExternalCommandOptions(
                workingDirectory: directory,
                environment: ["HEXPAD_COMMAND_TEST": "from-options"]
            )
        )

        let lines = result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false)
        // `pwd -P` resolves /var to /private/var on macOS, so compare the
        // unique directory name rather than the whole path.
        XCTAssertTrue(
            String(lines[0]).hasSuffix(directory.lastPathComponent),
            "unexpected working directory: \(lines[0])"
        )
        XCTAssertEqual(String(lines[1]), "from-options")
    }

    func testEnvironmentControlWhenInheritanceIsDisabled() throws {
        let result = try ExternalCommandRunner.run(
            "printenv HEXPAD_SHOULD_NOT_BE_INHERITED || echo unset",
            options: ExternalCommandOptions(
                inheritEnvironment: false,
                environment: ["HEXPAD_SHOULD_NOT_BE_INHERITED": "leaked"]
            )
        )
        XCTAssertEqual(result.standardOutput, "leaked\n")

        let clean = try ExternalCommandRunner.run(
            "printenv HEXPAD_SHOULD_NOT_BE_INHERITED || echo unset",
            options: ExternalCommandOptions(inheritEnvironment: false)
        )
        XCTAssertEqual(clean.standardOutput, "unset\n")
    }

    func testConfigurableShell() throws {
        let result = try ExternalCommandRunner.run(
            "echo from-sh",
            options: ExternalCommandOptions(shell: "/bin/sh")
        )
        XCTAssertEqual(result.standardOutput, "from-sh\n")
        XCTAssertTrue(result.succeeded)
    }

    func testMissingShellReportsLaunchFailure() {
        XCTAssertThrowsError(
            try ExternalCommandRunner.run(
                "echo never",
                options: ExternalCommandOptions(shell: "/nonexistent/shell")
            )
        ) { error in
            guard case ExternalCommandError.launchFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - Async variant

    func testAsyncCompletionMatchesSynchronousResult() throws {
        let command = "printf 'async out'; printf 'async err' >&2; exit 7"
        let synchronous = try ExternalCommandRunner.run(command)

        let expectation = expectation(description: "command completes")
        var asynchronous: ExternalCommandResult?
        ExternalCommandRunner.run(command) { outcome in
            asynchronous = try? outcome.get()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        let result = try XCTUnwrap(asynchronous)
        XCTAssertEqual(result.standardOutput, synchronous.standardOutput)
        XCTAssertEqual(result.standardError, synchronous.standardError)
        XCTAssertEqual(result.exitCode, synchronous.exitCode)
        XCTAssertEqual(result.didTimeOut, synchronous.didTimeOut)
        XCTAssertEqual(result.command, synchronous.command)
    }

    func testAsyncCompletionReportsSuccessResult() throws {
        let expectation = expectation(description: "command completes")
        var outcome: Result<ExternalCommandResult, ExternalCommandError>?
        ExternalCommandRunner.run("echo async-ok") {
            outcome = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        let result = try XCTUnwrap(outcome).get()
        XCTAssertEqual(result.standardOutput, "async-ok\n")
        XCTAssertTrue(result.succeeded)
    }
}
