import Foundation
import Combine

struct ProcessTreeEntry: Hashable {
    let pid: Int
    let name: String
}

struct PortInfo: Identifiable, Hashable {
    var id: String { "\(port)-\(pid)-\(protocol_)" }
    let port: Int
    let pid: Int
    let processName: String
    let protocol_: String
    let localAddress: String
    let dockerImage: String?
    let dockerContainer: String?
    let parentChain: [ProcessTreeEntry]
    let fullCommand: String?

    var isDocker: Bool { dockerImage != nil }
    var displayName: String {
        if let container = dockerContainer, let image = dockerImage {
            return "\(container) (\(image))"
        }
        return processName
    }

    var isSystemPort: Bool { port < 1024 }

    var isHttpLikely: Bool {
        let httpPorts: Set<Int> = [80, 443, 3000, 3001, 4200, 5000, 5173, 5174, 8000, 8080, 8443, 8888, 9000, 9090]
        return httpPorts.contains(port)
    }

    var hasParentChain: Bool { !parentChain.isEmpty }

    func matches(searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ||
            processName.localizedCaseInsensitiveContains(query) ||
            displayName.localizedCaseInsensitiveContains(query) ||
            String(port).contains(query)
    }
}

struct ProcessKillRequest: Identifiable {
    let id = UUID()
    let ports: [PortInfo]
    let searchQuery: String?

    init(ports: [PortInfo], searchQuery: String? = nil) {
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        self.ports = ports.filter { $0.pid > 1 && $0.pid != ownPID }
        self.searchQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var targets: [PortInfo] {
        var seen = Set<Int>()
        return ports.filter { seen.insert($0.pid).inserted }
    }

    var includesSystemPorts: Bool { ports.contains { $0.isSystemPort } }
}

class PortScanner: ObservableObject {
    @Published var ports: [PortInfo] = []
    @Published var isScanning = false
    @Published private(set) var isKilling = false

    private var autoRefreshTimer: Timer?

    func scan() {
        guard !isScanning, !isKilling else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = Self.getOpenPorts()
            DispatchQueue.main.async {
                self?.ports = results.sorted { $0.port < $1.port }
                self?.isScanning = false
            }
        }
    }

    func startAutoRefresh(interval: TimeInterval = 5) {
        stopAutoRefresh()
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    func killProcesses(_ request: ProcessKillRequest, completion: @escaping ([String]) -> Void) {
        guard !isKilling, !request.targets.isEmpty else { return }
        isKilling = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commands = Self.getFullCommands()
            var failures: [String] = []

            for target in request.targets {
                // Do not use a stale confirmation to kill a PID now owned by a different command.
                guard let expectedCommand = target.fullCommand,
                      commands[target.pid] == expectedCommand else {
                    failures.append("\(target.processName) (PID \(target.pid)): process exited or changed. Refresh and try again.")
                    continue
                }

                let process = Process()
                let errorPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/kill")
                process.arguments = ["-9", String(target.pid)]
                process.standardError = errorPipe

                do {
                    try process.run()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let detail = String(data: errorData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        failures.append("\(target.processName) (PID \(target.pid)): \(detail.isEmpty ? "Unable to kill process." : detail)")
                    }
                } catch {
                    failures.append("\(target.processName) (PID \(target.pid)): \(error.localizedDescription)")
                }
            }

            let errors = failures
            DispatchQueue.main.async {
                self?.isKilling = false
                completion(errors)
                self?.scan()
            }
        }
    }

    private static func getOpenPorts() -> [PortInfo] {
        let output = runCommand("/usr/sbin/lsof", arguments: ["-iTCP", "-iUDP", "-sTCP:LISTEN", "-P", "-n"])
        let dockerPorts = getDockerPortMap()
        let processTree = getProcessTree()
        let commands = getFullCommands()
        return parseLsofOutput(output, dockerPorts: dockerPorts, processTree: processTree, commands: commands)
    }

    private static func getFullCommands() -> [Int: String] {
        let output = runCommand("/bin/ps", arguments: ["-ww", "-eo", "pid=,command="])
        var map: [Int: String] = [:]
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            map[pid] = String(parts[1])
        }
        return map
    }

    private static func getProcessTree() -> [Int: (ppid: Int, name: String)] {
        // Get all processes with pid, ppid, and command name
        let output = runCommand("/bin/ps", arguments: ["-eo", "pid=,ppid=,comm="])
        var tree: [Int: (ppid: Int, name: String)] = [:]

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            guard let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            // comm= can be a full path; take just the last component
            let fullPath = String(parts[2])
            let name = (fullPath as NSString).lastPathComponent
            tree[pid] = (ppid: ppid, name: name)
        }
        return tree
    }

    static func buildParentChain(pid: Int, tree: [Int: (ppid: Int, name: String)], maxDepth: Int = 4) -> [ProcessTreeEntry] {
        var chain: [ProcessTreeEntry] = []
        var current = pid

        for _ in 0..<maxDepth {
            guard let entry = tree[current] else { break }
            let ppid = entry.ppid
            if ppid <= 1 { break } // Stop at launchd/kernel
            guard let parent = tree[ppid] else { break }
            chain.append(ProcessTreeEntry(pid: ppid, name: parent.name))
            current = ppid
        }

        return chain
    }

    private static func getDockerPortMap() -> [Int: (image: String, container: String)] {
        let dockerPath = findDocker()
        guard let path = dockerPath else { return [:] }

        let output = runCommand(path, arguments: ["ps", "--format", "{{.Image}}\t{{.Names}}\t{{.Ports}}"])
        var map: [Int: (image: String, container: String)] = [:]

        for line in output.components(separatedBy: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3 else { continue }
            let image = fields[0]
            let container = fields[1]
            let portsField = fields[2]

            // Ports look like: "0.0.0.0:8080->80/tcp, :::8080->80/tcp"
            for portMapping in portsField.components(separatedBy: ", ") {
                guard let arrowRange = portMapping.range(of: "->") else { continue }
                let hostPart = portMapping[..<arrowRange.lowerBound]
                if let colonRange = hostPart.range(of: ":", options: .backwards) {
                    let portStr = hostPart[colonRange.upperBound...]
                    if let port = Int(portStr) {
                        map[port] = (image: image, container: container)
                    }
                }
            }
        }
        return map
    }

    private static func findDocker() -> String? {
        let paths = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/usr/bin/docker",
        ]
        for p in paths {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Try `which docker` as fallback
        let result = runCommand("/usr/bin/which", arguments: ["docker"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func runCommand(_ path: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }

        // Read before waiting to avoid deadlock when pipe buffer fills
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseLsofOutput(_ output: String, dockerPorts: [Int: (image: String, container: String)] = [:], processTree: [Int: (ppid: Int, name: String)] = [:], commands: [Int: String] = [:]) -> [PortInfo] {
        let lines = output.components(separatedBy: "\n")
        var results: [PortInfo] = []
        var seen = Set<String>()

        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }

            let processName = parts[0]
            guard let pid = Int(parts[1]) else { continue }

            let typeField = parts[4]
            let proto = parts[7]
            let nameField = parts[8]

            guard typeField == "IPv4" || typeField == "IPv6" else { continue }

            let addressParts = nameField.components(separatedBy: ":")
            guard let portStr = addressParts.last, let port = Int(portStr) else { continue }
            let address = addressParts.dropLast().joined(separator: ":")

            let key = "\(port)-\(pid)-\(proto)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let lowerName = processName.lowercased()
            let isDockerProcess = lowerName.contains("docker") ||
                                   lowerName.hasPrefix("com.docke")
            let dockerInfo = isDockerProcess ? dockerPorts[port] : nil

            let parentChain = buildParentChain(pid: pid, tree: processTree)
            let fullCommand = commands[pid]

            results.append(PortInfo(
                port: port,
                pid: pid,
                processName: processName,
                protocol_: proto,
                localAddress: address,
                dockerImage: dockerInfo?.image,
                dockerContainer: dockerInfo?.container,
                parentChain: parentChain,
                fullCommand: fullCommand
            ))
        }

        return results
    }
}
