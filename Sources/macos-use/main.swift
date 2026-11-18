import AppKit
import CoreGraphics
import Darwin
import Foundation
import MacOSUseKit

// Initialize CoreGraphics WindowServer & AppKit on the main thread before any ScreenCaptureKit calls.
_ = CGMainDisplayID()
_ = NSApplication.shared.setActivationPolicy(.accessory)

let rawArgs = Array(CommandLine.arguments.dropFirst())
let command = rawArgs.first?.lowercased() ?? "mcp"

switch command {
case "mcp", "--mcp", "-m":
    // Isolate fd 1 exclusively for MCP JSON-RPC output; redirect any accidental C/framework stdout to stderr.
    let mcpOutFD = Darwin.dup(STDOUT_FILENO)
    Darwin.dup2(STDERR_FILENO, STDOUT_FILENO)

    let transport = MCPStdioTransport(inputFD: STDIN_FILENO, outputFD: mcpOutFD)
    let server = MacOSUseMCPServer()

    DispatchQueue(label: "com.macosuse.mcp.loop").async {
        while let data = transport.nextMessageData() {
            let sem = DispatchSemaphore(value: 0)
            _ = Task {
                if let response = await server.handleRequestData(data) {
                    transport.sendResponse(response)
                }
                sem.signal()
            }
            sem.wait()
        }
        Darwin.exit(0)
    }
    RunLoop.main.run()

case "status":
    _ = Task {
        do {
            let status = try await WindowManager.systemStatus(promptAccessibility: false)
            let json = try JSONValue.fromEncodable(status).prettyJSONString()
            print(json)
            Darwin.exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }
    RunLoop.main.run()

case "windows":
    let appFilter = parseFlag("--app", in: rawArgs)
    _ = Task {
        do {
            let windows = try await WindowManager.listWindows(appFilter: appFilter)
            let json = try JSONValue.fromEncodable(windows).prettyJSONString()
            print(json)
            Darwin.exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }
    RunLoop.main.run()

case "observe", "inspect":
    let isObserve = (command == "observe")
    let appFilter = parseFlag("--app", in: rawArgs)
    let bundleID = parseFlag("--bundle-id", in: rawArgs)
    let windowID = parseFlag("--window", in: rawArgs).flatMap(UInt32.init)
    let outputPath = parseFlag("--output", in: rawArgs)
    let query = parseFlag("--query", in: rawArgs)
    let scopeArg = parseFlag("--scope", in: rawArgs)
    let noAnnotate = rawArgs.contains("--no-annotate")

    _ = Task {
        do {
            let target = try PerceptionEngine.resolveTargetScope(
                scope: scopeArg,
                windowID: windowID,
                appName: appFilter,
                bundleID: bundleID,
                displayID: nil,
                region: nil
            )
            let result = try await PerceptionEngine.observe(
                target: target,
                includeImage: isObserve && outputPath != nil,
                annotate: !noAnnotate
            )

            if let outputPath, let data = result.encodedImageData {
                let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                fputs("Saved annotated capture to \(url.path)\n", stderr)
            }

            var elements = result.snapshot.elements.map(\.ui)
            if let query, !query.isEmpty {
                let q = query.lowercased()
                elements = elements.filter { $0.label.lowercased().contains(q) || $0.role.lowercased().contains(q) }
            }

            let out: JSONValue = .object([
                "snapshot_id": .string(result.snapshot.snapshotID),
                "scope": .string(result.snapshot.scopeDescription),
                "ax_trusted": .bool(result.snapshot.axTrusted),
                "elements_count": .int(elements.count),
                "elements": try JSONValue.fromEncodable(elements)
            ])
            print(try out.prettyJSONString())
            Darwin.exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }
    RunLoop.main.run()

case "doctor":
    let promptAX = rawArgs.contains("--prompt-ax")
    let openAX = rawArgs.contains("--open-ax")
    _ = Task {
        do {
            let status = try await WindowManager.systemStatus(promptAccessibility: promptAX)
            if openAX {
                await MainActor.run {
                    _ = PermissionsManager.openSystemSettingsPrivacy(pane: "accessibility")
                }
            }
            print(try JSONValue.fromEncodable(status).prettyJSONString())
            Darwin.exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }
    RunLoop.main.run()

case "dialogs":
    _ = Task {
        do {
            let dialogs = try await DialogController.inspectDialogs(pid: nil)
            print(try JSONValue.fromEncodable(dialogs).prettyJSONString())
            Darwin.exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }
    RunLoop.main.run()

case "help", "--help", "-h":
    printUsage()
    Darwin.exit(0)

default:
    fputs("Unknown subcommand '\(command)'.\n", stderr)
    printUsage()
    Darwin.exit(2)
}

func parseFlag(_ flag: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
        return nil
    }
    return args[idx + 1]
}

func printUsage() {
    let usage = """
    macos-use \(WindowManager.serverVersion) — Native Apple Silicon macOS 27 Computer Use Engine & MCP Server

    USAGE:
      macos-use [mcp]                         Start the MCP stdio server (default)
      macos-use status                        Print macOS, display, and TCC permission status
      macos-use windows [--app <name>]        List visible windows in front-to-back z-order
      macos-use dialogs                       Inspect active sheets, file pickers, and system alerts
      macos-use observe [--app <name>] [--window <id>] [--output <path>] [--no-annotate]
                                              Capture + ground UI buttons/elements (+ SoM image + ML icons)
      macos-use inspect [--app <name>] [--query <text>]
                                              Print detected UI elements e1..eN
      macos-use doctor [--prompt-ax] [--open-ax]
                                              Inspect TCC permissions and optionally trigger AX prompt
    """
    print(usage)
}
