import SwiftUI
import AppKit

struct PortListView: View {
    @ObservedObject var scanner: PortScanner
    private let pasteboard: NSPasteboard
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var activeAlert: PortAlert? = nil
    @State private var copiedPort: Int? = nil
    @State private var previewPort: PortInfo? = nil
    @State private var selectedPort: PortInfo? = nil
    @State private var copiedCommand: String? = nil

    init(scanner: PortScanner, selectedPort: PortInfo? = nil, pasteboard: NSPasteboard = .general) {
        self.scanner = scanner
        self.pasteboard = pasteboard
        _selectedPort = State(initialValue: selectedPort)
    }

    private enum PortAlert: Identifiable {
        case kill(ProcessKillRequest)
        case failure(String)

        var id: String {
            switch self {
            case .kill(let request): return request.id.uuidString
            case .failure(let message): return message
            }
        }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var filteredPorts: [PortInfo] {
        scanner.ports.filter { $0.matches(searchText: searchQuery) }
    }

    private var canKillFilteredProcesses: Bool {
        !scanner.isKilling && !ProcessKillRequest(ports: filteredPorts).targets.isEmpty
    }

    private var primaryTextColor: Color {
        Color(white: colorScheme == .dark ? 0.95 : 0.10)
    }

    private var secondaryTextColor: Color {
        Color(white: colorScheme == .dark ? 0.78 : 0.30)
    }

    private var surfaceColor: Color {
        Color(white: colorScheme == .dark ? 0.12 : 0.98)
    }

    private var dangerColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.48, blue: 0.49)
            : Color(red: 0.72, green: 0.13, blue: 0.14)
    }

    private var actionColor: Color {
        colorScheme == .dark
            ? Color(red: 0.48, green: 0.72, blue: 1.0)
            : Color(red: 0.12, green: 0.36, blue: 0.72)
    }

    private var commandSurfaceColor: Color {
        Color(white: colorScheme == .dark ? 0.15 : 0.95)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            portList
            Divider()
            commandPanel
        }
        .frame(width: 420, height: 480)
        .foregroundColor(primaryTextColor)
        .background(surfaceColor)
        .tint(actionColor)
        .onAppear { scanner.scan() }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .kill(let request):
                return killConfirmation(for: request)
            case .failure(let message):
                return Alert(
                    title: Text("Some Processes Were Not Killed"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var commandPanel: some View {
        let port = selectedPort ?? previewPort
        let command = port?.fullCommand

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Command", systemImage: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()

                if let port {
                    Text("\(port.processName) / PID \(String(port.pid))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                        .help("\(port.displayName), port \(port.port)")
                }

                Spacer(minLength: 0)

                if let port {
                    Button {
                        if let command {
                            copyCommand(command)
                        }
                    } label: {
                        Image(systemName: command != nil && copiedCommand == command ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(command != nil && copiedCommand == command ? actionColor : secondaryTextColor)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(command == nil)
                    .help(copiedCommand == command && command != nil ? "Command copied" : "Copy full command")
                    .accessibilityLabel("Copy full command")
                    .accessibilityIdentifier("copy-full-command")

                    if selectedPort == nil {
                        Button {
                            selectedPort = port
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Show full command")
                        .accessibilityLabel("Show full command")
                        .accessibilityIdentifier("expand-command")
                    } else {
                        Button {
                            selectedPort = nil
                            previewPort = nil
                            copiedCommand = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12))
                                .foregroundColor(secondaryTextColor)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Close command details")
                        .accessibilityLabel("Close command details")
                        .accessibilityIdentifier("close-command")
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)

            if let selectedPort {
                if let command = selectedPort.fullCommand {
                    CommandTextView(command: command, textColor: NSColor(primaryTextColor))
                        .id(selectedPort.id)
                        .frame(height: 108)
                } else {
                    Text("Command unavailable")
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
            } else {
                Text(command ?? (port == nil ? "No process selected" : "Command unavailable"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .frame(height: selectedPort == nil ? 66 : 140)
        .background(commandSurfaceColor)
    }

    private var header: some View {
        HStack {
            Text("Open Ports")
                .font(.headline)
            Spacer()
            Text(searchQuery.isEmpty
                 ? "\(scanner.ports.count) ports"
                 : "\(filteredPorts.count) / \(scanner.ports.count) ports")
                .font(.caption)
                .foregroundColor(secondaryTextColor)
            Button(action: { scanner.scan() }) {
                Group {
                    if scanner.isKilling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(scanner.isScanning || scanner.isKilling)
            .help("Refresh ports")
            .accessibilityLabel("Refresh ports")
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Quit PortsApp")
            .accessibilityLabel("Quit PortsApp")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(secondaryTextColor)
                .font(.system(size: 13))
            TextField(
                "",
                text: $searchText,
                prompt: Text("Filter by port or process...")
                    .foregroundColor(secondaryTextColor)
            )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel("Filter by port or process")
                .layoutPriority(1)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(secondaryTextColor)
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }

            if !searchQuery.isEmpty {
                Button(role: .destructive) {
                    activeAlert = .kill(ProcessKillRequest(ports: filteredPorts, searchQuery: searchQuery))
                } label: {
                    Label("Kill All", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(canKillFilteredProcesses ? dangerColor : secondaryTextColor)
                        .fixedSize()
                        .frame(height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!canKillFilteredProcesses)
                .help("Kill all processes in the filtered results")
                .accessibilityLabel("Kill all matching processes")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var portList: some View {
        Group {
            if scanner.isScanning && scanner.ports.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Scanning ports...")
                        .font(.caption)
                    Spacer()
                }
            } else if filteredPorts.isEmpty {
                VStack {
                    Spacer()
                    Text(searchQuery.isEmpty ? "No open ports found" : "No matching ports")
                        .foregroundColor(secondaryTextColor)
                        .font(.caption)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredPorts) { port in
                            portRow(port)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    private func rowBackground(for info: PortInfo) -> Color {
        if info.isDocker {
            return Color.blue.opacity(0.06)
        } else if info.isSystemPort {
            return Color.orange.opacity(0.06)
        } else {
            return Color.clear
        }
    }

    private func copyToClipboard(_ info: PortInfo) {
        let text = "localhost:\(info.port)"
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedPort = info.port
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedPort == info.port { copiedPort = nil }
        }
    }

    private func copyCommand(_ command: String) {
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copiedCommand = command
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedCommand == command {
                copiedCommand = nil
            }
        }
    }

    private func openInBrowser(_ info: PortInfo) {
        let scheme = info.port == 443 || info.port == 8443 || info.port == 18443 ? "https" : "http"
        if let url = URL(string: "\(scheme)://localhost:\(info.port)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func killConfirmation(for request: ProcessKillRequest) -> Alert {
        let targets = request.targets
        let isBulk = request.searchQuery != nil
        let summary = targets.prefix(5).map { "\($0.processName) (PID \($0.pid))" }.joined(separator: "\n")
        let more = targets.count > 5 ? "\n...and \(targets.count - 5) more processes." : ""
        let scope: String
        if let query = request.searchQuery {
            scope = "Kill \(targets.count) processes across \(request.ports.count) matching ports for \"\(query)\"?"
        } else {
            scope = "Kill the process using port \(request.ports.first?.port ?? 0)?"
        }
        let warning = request.includesSystemPorts
            ? "\n\nWARNING: Includes system ports. This may interrupt system services."
            : ""

        return Alert(
            title: Text(isBulk ? "Kill All Matching Processes?" : "Kill Process?"),
            message: Text("\(scope)\n\n\(summary)\(more)\n\nProcesses will be force quit. Unsaved data may be lost.\(warning)"),
            primaryButton: .destructive(Text(isBulk ? "Kill All \(targets.count) Processes" : "Kill")) {
                scanner.killProcesses(request) { failures in
                    if !failures.isEmpty {
                        activeAlert = .failure(failures.joined(separator: "\n\n"))
                    }
                }
            },
            secondaryButton: .cancel()
        )
    }

    @ViewBuilder
    private func portRow(_ info: PortInfo) -> some View {
        HStack(spacing: 10) {
            Button(action: {
                activeAlert = .kill(ProcessKillRequest(ports: [info]))
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(dangerColor)
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(scanner.isKilling || ProcessKillRequest(ports: [info]).targets.isEmpty)
            .help("Kill process \(info.pid)")
            .accessibilityLabel("Kill \(info.processName), PID \(info.pid)")

            Button {
                selectedPort = info
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(":\(String(info.port))")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text(info.protocol_)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(actionColor.opacity(0.12))
                            .cornerRadius(3)
                        if info.isDocker {
                            Text("docker")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15))
                                .cornerRadius(3)
                        }
                        if info.isSystemPort {
                            Text("system")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("PID \(String(info.pid))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                            .fixedSize()
                        Text(info.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(primaryTextColor)
                            .lineLimit(1)
                            .help(info.displayName)
                    }
                    if info.hasParentChain {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.turn.up.right")
                                .font(.system(size: 10))
                                .foregroundColor(secondaryTextColor)
                            Text(info.parentChain.map { "\($0.name)" }.joined(separator: " > "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show full command")
            .accessibilityLabel("Show command for \(info.processName), PID \(info.pid), port \(info.port)")
            .accessibilityIdentifier("inspect-\(info.id)")

            if copiedPort == info.port {
                Text("Copied!")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(secondaryTextColor)
                    .fixedSize()
            }

            if info.isHttpLikely {
                Button(action: { openInBrowser(info) }) {
                    Image(systemName: "globe")
                        .font(.system(size: 13))
                        .foregroundColor(actionColor)
                        .frame(width: 22, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Open in browser")
                .accessibilityLabel("Open port \(info.port) in browser")
            }

            Button(action: { copyToClipboard(info) }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
                    .foregroundColor(secondaryTextColor)
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Copy localhost:\(info.port)")
            .accessibilityLabel("Copy localhost:\(info.port)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(selectedPort?.id == info.id ? actionColor.opacity(0.12) : rowBackground(for: info))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                previewPort = info
            }
        }
    }
}

private struct CommandTextView: NSViewRepresentable {
    let command: String
    let textColor: NSColor

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.lineBreakMode = .byCharWrapping
        textView.defaultParagraphStyle = paragraphStyle
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("Full command")
        textView.setAccessibilityIdentifier("full-command")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textColor = textColor
        if textView.string != command {
            textView.string = command
            textView.scrollToBeginningOfDocument(nil)
        }
    }
}
