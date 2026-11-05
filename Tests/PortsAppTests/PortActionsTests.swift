import XCTest
@testable import PortsApp

final class PortActionsTests: XCTestCase {
    private func port(
        _ number: Int = 3000,
        pid: Int = 12345,
        name: String = "node",
        protocolName: String = "TCP",
        container: String? = nil,
        image: String? = nil,
        command: String? = "/usr/local/bin/node server.js"
    ) -> PortInfo {
        PortInfo(
            port: number,
            pid: pid,
            processName: name,
            protocol_: protocolName,
            localAddress: "127.0.0.1",
            dockerImage: image,
            dockerContainer: container,
            parentChain: [],
            fullCommand: command
        )
    }

    func testSearchMatchesNamesCaseInsensitivelyAndTrimsWhitespace() {
        XCTAssertTrue(port().matches(searchText: " NODE\n"))
        XCTAssertTrue(port().matches(searchText: "  "))
        XCTAssertFalse(port(name: "python").matches(searchText: "node"))
    }

    func testSearchMatchesPortAndDockerDetails() {
        XCTAssertTrue(port(8080).matches(searchText: "808"))
        let docker = port(name: "com.docker", container: "web-api", image: "node:22")
        XCTAssertTrue(docker.matches(searchText: "WEB-API"))
        XCTAssertTrue(docker.matches(searchText: "node"))
        XCTAssertFalse(docker.matches(searchText: "redis"))
    }

    func testKillRequestDeduplicatesPIDsAcrossPortsAndProtocols() {
        let request = ProcessKillRequest(ports: [
            port(3000, pid: 12345),
            port(3001, pid: 12345),
            port(3000, pid: 12345, protocolName: "UDP"),
            port(4000, pid: 12346),
        ], searchQuery: " node ")

        XCTAssertEqual(request.targets.map(\.pid), [12345, 12346])
        XCTAssertEqual(request.ports.count, 4)
        XCTAssertEqual(request.searchQuery, "node")
    }

    func testKillRequestOnlyIncludesFilteredSnapshot() {
        var ports = [port(pid: 12345), port(pid: 12346, name: "python")]
        let matches = ports.filter { $0.matches(searchText: "node") }
        let request = ProcessKillRequest(ports: matches, searchQuery: "node")
        ports.append(port(pid: 12347))

        XCTAssertEqual(request.targets.map(\.pid), [12345])
        XCTAssertEqual(request.ports.count, 1)
        XCTAssertEqual(ports.count, 3)
    }

    func testKillRequestExcludesUnsafePIDsAndTheAppItself() {
        let request = ProcessKillRequest(ports: [
            port(pid: -1),
            port(pid: 0),
            port(pid: 1),
            port(pid: Int(ProcessInfo.processInfo.processIdentifier)),
            port(pid: 12345),
        ])

        XCTAssertEqual(request.targets.map(\.pid), [12345])
        XCTAssertEqual(request.ports.count, 1)
    }

    func testSystemPortWarningIncludesEveryPortOfDeduplicatedProcess() {
        let request = ProcessKillRequest(ports: [
            port(8080),
            port(80),
        ])

        XCTAssertEqual(request.targets.count, 1)
        XCTAssertTrue(request.includesSystemPorts)
        XCTAssertFalse(ProcessKillRequest(ports: [port()]).includesSystemPorts)
        XCTAssertTrue(ProcessKillRequest(ports: []).targets.isEmpty)
    }

    private func startDummyProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    private func stopDummyProcess(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }

    private func command(for process: Process) throws -> String {
        let ps = Process()
        let output = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ww", "-p", String(process.processIdentifier), "-o", "command="]
        ps.standardOutput = output
        try ps.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testKillRejectsChangedCommandAndReportsFailure() throws {
        let process = try startDummyProcess()
        defer { stopDummyProcess(process) }
        let completed = expectation(description: "Changed command is rejected")
        let scanner = PortScanner()
        let target = port(pid: Int(process.processIdentifier), command: "not-the-dummy-command")

        scanner.killProcesses(ProcessKillRequest(ports: [target])) { failures in
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures.first?.contains("exited or changed") == true)
            XCTAssertFalse(scanner.isKilling)
            XCTAssertTrue(process.isRunning)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 10)
        scanner.stopAutoRefresh()
    }

    func testKillStopsOnlyConfirmedDummyProcessesAndDeduplicatesPorts() throws {
        let first = try startDummyProcess()
        defer { stopDummyProcess(first) }
        let second = try startDummyProcess()
        defer { stopDummyProcess(second) }
        let untouched = try startDummyProcess()
        defer { stopDummyProcess(untouched) }
        let firstCommand = try command(for: first)
        let secondCommand = try command(for: second)
        let completed = expectation(description: "Confirmed dummy processes are killed")
        let scanner = PortScanner()
        let request = ProcessKillRequest(ports: [
            port(3000, pid: Int(first.processIdentifier), command: firstCommand),
            port(3001, pid: Int(first.processIdentifier), command: firstCommand),
            port(3002, pid: Int(second.processIdentifier), command: secondCommand),
        ], searchQuery: "node")

        scanner.killProcesses(request) { failures in
            XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
            XCTAssertFalse(scanner.isKilling)
            completed.fulfill()
        }
        XCTAssertTrue(scanner.isKilling)

        wait(for: [completed], timeout: 10)
        first.waitUntilExit()
        second.waitUntilExit()
        XCTAssertEqual(first.terminationReason, .uncaughtSignal)
        XCTAssertEqual(second.terminationReason, .uncaughtSignal)
        XCTAssertTrue(untouched.isRunning)
        scanner.stopAutoRefresh()
    }

    func testKillMatchesCompleteLongCommandWithoutTruncation() throws {
        let process = Process()
        let longPath = "/Users/developer/" + String(repeating: "long-directory/", count: 30) + "command-tail"
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read -r value", longPath]
        process.standardInput = Pipe()
        try process.run()
        defer { stopDummyProcess(process) }

        let fullCommand = try command(for: process)
        XCTAssertTrue(fullCommand.hasSuffix("command-tail"))
        XCTAssertGreaterThan(fullCommand.count, 400)
        let target = port(pid: Int(process.processIdentifier), name: "sh", command: fullCommand)
        let scanner = PortScanner()
        let completed = expectation(description: "The entire command is used to validate the dummy process")

        scanner.killProcesses(ProcessKillRequest(ports: [target])) { failures in
            XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 10)
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, 9)
    }
}
