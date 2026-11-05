import AppKit
import SwiftUI
import XCTest
@testable import PortsApp

private final class AppearanceScanner: PortScanner {
    override func scan() {}
}

@MainActor
final class PortListAppearanceTests: XCTestCase {
    func testLightAppearanceAndFilteredControls() throws {
        try checkAppearance(.light, name: "light")
    }

    func testDarkAppearanceAndFilteredControls() throws {
        try checkAppearance(.dark, name: "dark")
    }

    func testLightCommandInspectorWrapsAndScrollsFullCommand() throws {
        try checkCommandInspector(.light, name: "light")
    }

    func testDarkCommandInspectorWrapsAndScrollsFullCommand() throws {
        try checkCommandInspector(.dark, name: "dark")
    }

    func testRowSelectionCopyAndCloseDoNotInterfereWithPortActions() throws {
        _ = NSApplication.shared
        let scanner = AppearanceScanner()
        let command = "/Users/developer/.local/bin/node /Users/developer/Projects/server.js --port=3000"
        scanner.ports = [
            port(3000, pid: 12345, name: "node", command: command),
            port(3001, pid: 12346, name: "python"),
        ]
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let host = NSHostingView(rootView: PortListView(scanner: scanner, pasteboard: pasteboard))
        let window = makeWindow(for: host, scheme: .light)
        defer { window.close() }
        settle(host)

        try click(window, x: 170, y: 110)
        settle(host)
        XCTAssertEqual(commandTextView(in: host)?.string, command)

        try click(window, x: 364, y: 356)
        settle(host)
        XCTAssertEqual(pasteboard.string(forType: .string), command)
        _ = try capture(host, name: "command-copied")

        try click(window, x: 396, y: 356)
        settle(host)
        XCTAssertNil(commandTextView(in: host))
        XCTAssertEqual(host.bounds.height, 480, accuracy: 1)

        try click(window, x: 393, y: 110)
        settle(host)
        XCTAssertEqual(pasteboard.string(forType: .string), "localhost:3000")
        XCTAssertNil(commandTextView(in: host))

        try click(window, x: 170, y: 178)
        settle(host)
        XCTAssertEqual(commandTextView(in: host)?.string, scanner.ports[1].fullCommand)
        _ = try capture(host, name: "command-row-selected")
    }

    func testUnavailableCommandHasNoEditableOrCopyableText() throws {
        _ = NSApplication.shared
        let scanner = AppearanceScanner()
        let selected = port(3000, pid: 12345, name: "node", command: nil)
        scanner.ports = [selected]
        let host = NSHostingView(rootView: PortListView(scanner: scanner, selectedPort: selected))
        let window = makeWindow(for: host, scheme: .light)
        defer { window.close() }
        settle(host)

        XCTAssertNil(commandTextView(in: host))
        _ = try capture(host, name: "command-unavailable")
        XCTAssertEqual(host.bounds.height, 480, accuracy: 1)
    }

    private func checkCommandInspector(_ scheme: ColorScheme, name: String) throws {
        _ = NSApplication.shared
        let scanner = AppearanceScanner()
        let component = String(repeating: "long_directory_name_", count: 18)
        let command = "/Users/developer/.local/share/runtime/node/bin/node " +
            "/Users/developer/Documents/Projects/\(component)/server.js " +
            String(repeating: "--include=/Users/developer/Documents/Projects/worker/configuration.json ", count: 12) +
            "--port=3000 --end-of-command"
        let selected = port(3000, pid: 12345, name: "node", command: command)
        scanner.ports = [selected, port(3001, pid: 12346, name: "python")]

        let host = NSHostingView(
            rootView: PortListView(scanner: scanner, selectedPort: selected).environment(\.colorScheme, scheme)
        )
        let window = makeWindow(for: host, scheme: scheme)
        defer { window.close() }
        settle(host)

        let textView = try XCTUnwrap(commandTextView(in: host))
        let container = try XCTUnwrap(textView.textContainer)
        let layout = try XCTUnwrap(textView.layoutManager)
        layout.ensureLayout(for: container)

        XCTAssertEqual(textView.string, command)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(container.lineBreakMode, .byCharWrapping)
        XCTAssertEqual(textView.enclosingScrollView?.hasHorizontalScroller, false)
        XCTAssertEqual(layout.glyphRange(for: container).length, command.utf16.count)
        XCTAssertGreaterThan(layout.usedRect(for: container).height, textView.visibleRect.height)
        XCTAssertLessThanOrEqual(layout.usedRect(for: container).width, container.size.width + 1)
        XCTAssertEqual(host.bounds.width, 420, accuracy: 1)
        XCTAssertEqual(host.bounds.height, 480, accuracy: 1)
        _ = try capture(host, name: "\(name)-command")

        let tail = NSRange(location: command.utf16.count - 26, length: 26)
        textView.setSelectedRange(tail)
        textView.scrollRangeToVisible(tail)
        settle(host)
        XCTAssertGreaterThan(textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0, 0)
        _ = try capture(host, name: "\(name)-command-scrolled")

        let field = try XCTUnwrap(textField(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("python", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settle(host)
        XCTAssertTrue(commandTextView(in: host) === textView)
        XCTAssertEqual(textView.string, command)
        XCTAssertEqual(textView.selectedRange(), tail)

        scanner.ports = []
        settle(host)
        XCTAssertTrue(commandTextView(in: host) === textView)
        XCTAssertEqual(textView.string, command)
        XCTAssertEqual(textView.selectedRange(), tail)
        _ = try capture(host, name: "\(name)-command-pinned")
    }

    private func makeWindow(for host: NSView, scheme: ColorScheme) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func checkAppearance(_ scheme: ColorScheme, name: String) throws {
        _ = NSApplication.shared
        let scanner = AppearanceScanner()
        scanner.ports = [
            port(3000, pid: 12345, name: "node"),
            port(3001, pid: 12345, name: "node"),
            port(80, pid: 12346, name: "web"),
            port(8080, pid: 12347, name: "com.docker", image: "redis:7", container: "local-cache"),
        ]

        let host = NSHostingView(rootView: PortListView(scanner: scanner).environment(\.colorScheme, scheme))
        let window = makeWindow(for: host, scheme: scheme)
        defer { window.close() }
        settle(host)

        let bitmap = try capture(host, name: name)
        let background = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        if scheme == .dark {
            XCTAssertLessThan(background.redComponent, 0.25)
        } else {
            XCTAssertGreaterThan(background.redComponent, 0.90)
        }
        XCTAssertEqual(background.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(dangerPixelCount(in: bitmap), 0)

        let field = try XCTUnwrap(textField(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("node", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settle(host)
        let filtered = try capture(host, name: "\(name)-filtered")
        XCTAssertGreaterThan(dangerPixelCount(in: filtered), 20)

        editor.insertText("no-such-process", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settle(host)
        let empty = try capture(host, name: "\(name)-empty")
        XCTAssertEqual(dangerPixelCount(in: empty), 0)

        editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settle(host)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(dangerPixelCount(in: try capture(host, name: "\(name)-cleared")), 0)
    }

    private func settle(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func click(_ window: NSWindow, x: CGFloat, y: CGFloat) throws {
        let point = NSPoint(x: x, y: window.contentLayoutRect.height - y)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ))
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
    }

    private func capture(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PortsApp-\(name).png")
        try data.write(to: url)
        print("Appearance snapshot: \(url.path)")
        return bitmap
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { self.textField(in: $0) }.first
    }

    private func commandTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.accessibilityIdentifier() == "full-command" {
            return textView
        }
        return view.subviews.lazy.compactMap { self.commandTextView(in: $0) }.first
    }

    private func dangerPixelCount(in bitmap: NSBitmapImageRep) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / 420
        var count = 0
        // Inspect only the bulk action's fixed search-bar region, excluding row actions.
        for y in Int(46 * scale)..<Int(76 * scale) {
            for x in Int(300 * scale)..<Int(410 * scale) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.35 &&
                    color.redComponent > color.greenComponent * 1.5 &&
                    color.redComponent > color.blueComponent * 1.5 {
                    count += 1
                }
            }
        }
        return count
    }

    private func port(
        _ number: Int,
        pid: Int,
        name: String,
        image: String? = nil,
        container: String? = nil,
        command: String? = "/usr/local/bin/node server.js"
    ) -> PortInfo {
        PortInfo(
            port: number,
            pid: pid,
            processName: name,
            protocol_: "TCP",
            localAddress: "127.0.0.1",
            dockerImage: image,
            dockerContainer: container,
            parentChain: [ProcessTreeEntry(pid: 12300, name: "zsh"), ProcessTreeEntry(pid: 12200, name: "Terminal")],
            fullCommand: command
        )
    }
}
