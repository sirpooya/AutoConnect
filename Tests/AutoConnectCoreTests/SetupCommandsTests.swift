import XCTest

@testable import AutoConnectCore

/// The setup lines are copied into a root shell by hand, so they are worth asserting on: a rule
/// that does not cover what the app launches, or a command with a quote in it, fails somewhere the
/// user cannot debug.
final class SetupCommandsTests: XCTestCase {

    // MARK: - Locating Homebrew

    func testHomebrewFoundOnAppleSilicon() {
        let path = SetupCommands.homebrewPath { $0 == "/opt/homebrew/bin/brew" }
        XCTAssertEqual(path, "/opt/homebrew/bin/brew")
    }

    func testHomebrewFoundOnIntel() {
        let path = SetupCommands.homebrewPath { $0 == "/usr/local/bin/brew" }
        XCTAssertEqual(path, "/usr/local/bin/brew")
    }

    func testHomebrewAbsent() {
        XCTAssertNil(SetupCommands.homebrewPath { _ in false })
    }

    // MARK: - Install advice

    func testAdviceWithHomebrewOffersTheCommand() {
        let advice = SetupCommands.openconnectInstall(homebrewInstalled: true)
        XCTAssertEqual(advice.command, "brew install openconnect")
        XCTAssertNil(advice.link)
    }

    func testAdviceWithoutHomebrewOffersALinkAndNoCommand() {
        let advice = SetupCommands.openconnectInstall(homebrewInstalled: false)
        XCTAssertNil(advice.command, "brew install would fail with command not found")
        XCTAssertEqual(advice.link?.host, "brew.sh")
        XCTAssertTrue(advice.message.contains("Homebrew"))
    }

    // MARK: - The sudo rule

    func testRuleCoversTheBinaryAndTheShutdownSignal() {
        let rule = SetupCommands.sudoersRule(user: "ada", binaryPath: "/usr/local/bin/openconnect")

        XCTAssertTrue(rule.hasPrefix("ada ALL=(root) NOPASSWD: "))
        XCTAssertTrue(rule.contains("/usr/local/bin/openconnect"))
        // The shutdown half must be the exact command the runner uses, pid-file marker included,
        // or a disconnect asks for a password the app cannot supply.
        XCTAssertTrue(
            rule.contains(OpenConnectRunner.shutdownArguments().joined(separator: " ")),
            rule
        )
        XCTAssertTrue(rule.contains(OpenConnectRunner.pidFilePath))
    }

    func testInstallCommandValidatesBeforeItTakesEffect() {
        let command = SetupCommands.sudoersInstallCommand(
            user: "ada",
            binaryPath: "/opt/homebrew/bin/openconnect"
        )

        // Staged, checked, locked down, then moved. A malformed drop-in breaks sudo for the whole
        // machine, so the ordering is the point.
        let staged = SetupCommands.sudoersStagingFile
        XCTAssertTrue(command.contains("> \(staged)"))
        XCTAssertTrue(command.contains("visudo -cf \(staged)"))
        XCTAssertTrue(command.contains("chmod 440 \(staged)"))
        XCTAssertTrue(command.contains("mv \(staged) \(SetupCommands.sudoersFile)"))

        guard
            let write = command.range(of: "> \(staged)"),
            let check = command.range(of: "visudo -cf"),
            let move = command.range(of: "mv \(staged)")
        else { return XCTFail("command lost a step: \(command)") }
        XCTAssertTrue(write.lowerBound < check.lowerBound)
        XCTAssertTrue(check.lowerBound < move.lowerBound)
    }

    func testStagingPathIsIgnoredBySudo() {
        // sudo skips any name in sudoers.d containing a dot, which is what makes staging inert.
        let name = (SetupCommands.sudoersStagingFile as NSString).lastPathComponent
        XCTAssertTrue(name.contains("."))
    }

    func testCommandIsASingleLine() {
        let command = SetupCommands.sudoersInstallCommand(user: "ada", binaryPath: "/bin/oc")
        XCTAssertFalse(command.contains("\n"))
        XCTAssertFalse(command.contains("\r"))
    }

    func testQuotesAndSubstitutionsCannotSurviveIntoTheShellLine() {
        let command = SetupCommands.sudoersInstallCommand(
            user: "ada'; rm -rf /; echo '",
            binaryPath: "/bin/$(whoami)/`id`/oc"
        )

        // Whatever is left may be a path that does not exist, which fails harmlessly. What it must
        // not be is a second command, a closed quote, or a substitution the root shell expands.
        XCTAssertFalse(command.contains("$("))
        XCTAssertFalse(command.contains("`"))
        XCTAssertEqual(command.filter { $0 == "'" }.count, 2, "only the sh -c quotes remain")
        XCTAssertEqual(command.filter { $0 == "\"" }.count, 2, "only the echo quotes remain")
    }

    func testRemoveCommandNamesOnlyThisAppsFile() {
        XCTAssertEqual(SetupCommands.sudoersRemoveCommand, "sudo rm /etc/sudoers.d/autoconnect")
    }
}
