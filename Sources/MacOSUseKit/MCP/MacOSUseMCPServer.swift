@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// Native MCP server exposing 21 frontier computer-use tools for Apple Silicon macOS 27.
public final class MacOSUseMCPServer: Sendable {
    public let serverName = "macos-use"
    public let serverVersion = WindowManager.serverVersion

    public init() {}

    // MARK: - Tool Definitions

    public var tools: [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "system_status",
                description: "Inspect macOS version, Apple Silicon architecture, TCC permissions (Screen Recording, Accessibility, Input Control), attached displays with logical bounds and Retina scale factors, and frontmost application.",
                inputSchema: JSONSchema.object(properties: [
                    "prompt_accessibility": JSONSchema.boolean("If true, triggers macOS Accessibility permission prompt when AXIsProcessTrusted is false. Default: false.")
                ])
            ),
            MCPToolDefinition(
                name: "list_apps_and_windows",
                description: "List running GUI applications and on-screen windows in front-to-back z-order with window IDs, PIDs, bundle IDs, titles, and Global Quartz logical frames.",
                inputSchema: JSONSchema.object(properties: [
                    "app_filter": JSONSchema.string("Optional substring filter matching app name, bundle ID, or window title."),
                    "include_background_apps": JSONSchema.boolean("Include background/accessory processes in the apps list. Default: false."),
                    "include_system_layers": JSONSchema.boolean("Include non-layer-0 system overlays/popups in windows list. Default: false."),
                    "on_screen_only": JSONSchema.boolean("Only include currently on-screen windows. Default: true.")
                ])
            ),
            MCPToolDefinition(
                name: "observe_screen",
                description: "Perceive the screen or a target app/window using hybrid Accessibility + Apple Silicon Vision OCR & button contour detection, render Set-of-Mark numbered bounding boxes [1]..[N], cache the snapshot, and return both the annotated image and structured e1..eN elements with exact coordinates.",
                inputSchema: JSONSchema.object(properties: [
                    "scope": JSONSchema.string("Capture scope when window_id/app_name/bundle_id/region are omitted.", enumValues: ["frontmost_window", "display"]),
                    "window_id": JSONSchema.integer("Specific window ID from list_apps_and_windows."),
                    "app_name": JSONSchema.string("Target application name (e.g., 'Calculator', 'Safari', 'Antigravity')."),
                    "bundle_id": JSONSchema.string("Target bundle identifier (e.g., 'com.apple.calculator')."),
                    "display_id": JSONSchema.integer("Target display ID."),
                    "region": JSONSchema.regionObject("Global Quartz logical region {x, y, width, height}."),
                    "annotate": JSONSchema.boolean("Draw Set-of-Mark numbered boxes [1]..[N] on returned screenshot. Default: true."),
                    "include_vision": JSONSchema.boolean("Run Apple Silicon Vision OCR + button contour detection. Default: true."),
                    "detect_contours": JSONSchema.boolean("Detect button/icon geometric contours and fuse them with OCR text. Default: true."),
                    "classify_icons": JSONSchema.boolean("Classify unlabeled/garbled icon controls on Apple Neural Engine using Vision FeaturePrints. Default: true."),
                    "include_popups": JSONSchema.boolean("Include sheets, dialogs, and open popup menus attached to the target window. Default: true."),
                    "max_elements": JSONSchema.integer("Maximum UI elements to index (10..400). Default: 160."),
                    "max_dimension": JSONSchema.integer("Max pixel dimension of returned screenshot. Default: 1600."),
                    "format": JSONSchema.string("Image encoding format.", enumValues: ["jpeg", "png"]),
                    "jpeg_quality": JSONSchema.number("JPEG quality 0.1..1.0. Default: 0.80."),
                    "save_path": JSONSchema.string("Optional file path to save the rendered screenshot.")
                ])
            ),
            MCPToolDefinition(
                name: "inspect_ui",
                description: "Fast text-only UI discovery (no image returned). Lists detected buttons, text fields, links, and interactive controls as e1..eN with roles, labels, and Global Quartz coordinates, and caches a snapshot for click/type_text.",
                inputSchema: JSONSchema.object(properties: [
                    "scope": JSONSchema.string("Target scope.", enumValues: ["frontmost_window", "display"]),
                    "window_id": JSONSchema.integer("Specific window ID."),
                    "app_name": JSONSchema.string("Target app name."),
                    "bundle_id": JSONSchema.string("Target bundle identifier."),
                    "display_id": JSONSchema.integer("Target display ID."),
                    "region": JSONSchema.regionObject("Global Quartz logical region."),
                    "classify_icons": JSONSchema.boolean("Classify unlabeled/garbled icon controls via Apple Vision FeaturePrint. Default: true."),
                    "include_popups": JSONSchema.boolean("Include sheets, dialogs, and open popup menus. Default: true."),
                    "max_elements": JSONSchema.integer("Maximum UI elements (10..400). Default: 180."),
                    "interactive_only": JSONSchema.boolean("Only include interactive elements in the returned list. Default: false.")
                ])
            ),
            MCPToolDefinition(
                name: "find_elements",
                description: "Search UI elements by label text or role in the latest snapshot (or refresh live on a target window/app first).",
                inputSchema: JSONSchema.object(properties: [
                    "query": JSONSchema.string("Text query to match against element labels/values."),
                    "role": JSONSchema.string("Role filter (e.g., button, textfield, icon_button, text_button, close_button)."),
                    "interactive_only": JSONSchema.boolean("Only match interactive controls. Default: true."),
                    "refresh": JSONSchema.boolean("Re-inspect live UI before searching. Default: false."),
                    "app_name": JSONSchema.string("Optional app name when refreshing."),
                    "bundle_id": JSONSchema.string("Optional bundle ID when refreshing."),
                    "window_id": JSONSchema.integer("Optional window ID when refreshing."),
                    "snapshot_id": JSONSchema.string("Optional specific snapshot ID."),
                    "limit": JSONSchema.integer("Maximum matches to return. Default: 25.")
                ])
            ),
            MCPToolDefinition(
                name: "screenshot",
                description: "Capture a clean screenshot of a window, app, display, or region without running OCR/AX element extraction.",
                inputSchema: JSONSchema.object(properties: [
                    "scope": JSONSchema.string("Capture scope.", enumValues: ["frontmost_window", "display"]),
                    "window_id": JSONSchema.integer("Specific window ID."),
                    "app_name": JSONSchema.string("Target app name."),
                    "bundle_id": JSONSchema.string("Target bundle ID."),
                    "display_id": JSONSchema.integer("Target display ID."),
                    "region": JSONSchema.regionObject("Global Quartz logical region."),
                    "max_dimension": JSONSchema.integer("Max pixel dimension. Default: 1600."),
                    "format": JSONSchema.string("Image encoding format.", enumValues: ["jpeg", "png"]),
                    "jpeg_quality": JSONSchema.number("JPEG quality 0.1..1.0. Default: 0.85."),
                    "show_cursor": JSONSchema.boolean("Include mouse cursor in screenshot. Default: false."),
                    "save_path": JSONSchema.string("Optional file path to save the screenshot.")
                ])
            ),
            MCPToolDefinition(
                name: "click",
                description: "Click a UI element by cached element_id (e.g., 'e12'), by live text query (e.g., '7' or 'Save'), or by explicit (x, y) coordinates in 'global' Quartz logical points or 'image' pixel space.",
                inputSchema: JSONSchema.object(properties: [
                    "element_id": JSONSchema.string("Cached element ID such as 'e12' or '12' from observe_screen/inspect_ui."),
                    "snapshot_id": JSONSchema.string("Optional snapshot ID for element_id lookup."),
                    "query": JSONSchema.string("Text query to locate and click a UI element."),
                    "role": JSONSchema.string("Optional role filter when matching by query."),
                    "app_name": JSONSchema.string("Optional target app name (auto-activates app and refreshes UI if needed for query)."),
                    "bundle_id": JSONSchema.string("Optional target bundle ID."),
                    "window_id": JSONSchema.integer("Optional target window ID."),
                    "x": JSONSchema.number("X coordinate when clicking by coordinates."),
                    "y": JSONSchema.number("Y coordinate when clicking by coordinates."),
                    "coordinate_space": JSONSchema.string("Coordinate space for (x, y).", enumValues: ["global", "image"]),
                    "button": JSONSchema.string("Mouse button.", enumValues: ["left", "right", "middle"]),
                    "click_count": JSONSchema.integer("1 for single click, 2 for double click, 3 for triple click. Default: 1."),
                    "modifiers": JSONSchema.stringArray("Optional modifier keys held during click: command, shift, option, control."),
                    "method": JSONSchema.string("Execution method.", enumValues: ["auto", "cgevent", "ax"]),
                    "background": JSONSchema.boolean("If true, click without activating the target app or stealing foreground focus (uses AXPress or CGEvent postToPid). Default: false."),
                    "focus_mode": JSONSchema.string("Focus behavior: auto, background (no focus change), foreground, or restore (click and restore prior frontmost app & cursor).", enumValues: ["auto", "background", "foreground", "restore"]),
                    "verify": JSONSchema.boolean("Observe post-click UI changes. A missing signal leaves the click unverified. Default: true when method='auto'."),
                    "settle_ms": JSONSchema.integer("Max milliseconds to wait for UI mutation signals when verify=true. Default: 160."),
                    "allow_focus_fallback": JSONSchema.boolean("Legacy option accepted for compatibility. Dispatched clicks are never replayed."),
                    "confirm_destructive": JSONSchema.boolean("Explicitly authorize destructive UI targets (e.g. Empty Trash, Erase, Confirm Payment). Default: false.")
                ])
            ),
            MCPToolDefinition(
                name: "move_mouse",
                description: "Move the macOS mouse cursor to a target element or (x, y) coordinates.",
                inputSchema: JSONSchema.object(properties: [
                    "element_id": JSONSchema.string("Optional element ID from snapshot."),
                    "snapshot_id": JSONSchema.string("Optional snapshot ID."),
                    "x": JSONSchema.number("Target X coordinate."),
                    "y": JSONSchema.number("Target Y coordinate."),
                    "coordinate_space": JSONSchema.string("Coordinate space for (x, y).", enumValues: ["global", "image"]),
                    "smooth": JSONSchema.boolean("Interpolate cursor motion smoothly. Default: false.")
                ])
            ),
            MCPToolDefinition(
                name: "drag",
                description: "Click and drag from a start position/element to an end position/element.",
                inputSchema: JSONSchema.object(properties: [
                    "from_element_id": JSONSchema.string("Starting element ID."),
                    "to_element_id": JSONSchema.string("Ending element ID."),
                    "from_x": JSONSchema.number("Start X coordinate."),
                    "from_y": JSONSchema.number("Start Y coordinate."),
                    "to_x": JSONSchema.number("End X coordinate."),
                    "to_y": JSONSchema.number("End Y coordinate."),
                    "coordinate_space": JSONSchema.string("Coordinate space for raw coordinates.", enumValues: ["global", "image"]),
                    "duration_ms": JSONSchema.integer("Drag duration in milliseconds (120..5000). Default: 350."),
                    "modifiers": JSONSchema.stringArray("Optional modifier keys held during drag.")
                ])
            ),
            MCPToolDefinition(
                name: "type_text",
                description: "Type text into a target element or app using AXSetValue, background postToPid Unicode events, foreground Unicode CGEvents, or paste. Supports background=true to type without stealing foreground focus.",
                inputSchema: JSONSchema.object(
                    properties: [
                        "text": JSONSchema.string("Text to type."),
                        "element_id": JSONSchema.string("Optional element ID to focus before typing."),
                        "query": JSONSchema.string("Optional text query to find & focus an input element before typing."),
                        "app_name": JSONSchema.string("Optional target app name (auto-inspects if needed for query or supplies target PID)."),
                        "bundle_id": JSONSchema.string("Optional target bundle ID."),
                        "window_id": JSONSchema.integer("Optional target window ID."),
                        "pid": JSONSchema.integer("Optional target process ID."),
                        "snapshot_id": JSONSchema.string("Optional snapshot ID."),
                        "clear_first": JSONSchema.boolean("Clear existing input before typing. Default: false."),
                        "press_enter": JSONSchema.boolean("Press Return after typing. Default: false."),
                        "method": JSONSchema.string("Typing method.", enumValues: ["auto", "unicode", "paste", "ax_value"]),
                        "background": JSONSchema.boolean("If true, type into target app/element without bringing it to the front. Default: false."),
                        "focus_mode": JSONSchema.string("Focus behavior: auto, background, foreground, or restore.", enumValues: ["auto", "background", "foreground", "restore"]),
                        "verify": JSONSchema.boolean("Verify AXValue readback and auto-escalate to postToPid Unicode typing if AXSetValue was a no-op. Default: true."),
                        "confirm_destructive": JSONSchema.boolean("Explicitly authorize destructive input if needed. Default: false.")
                    ],
                    required: ["text"]
                )
            ),
            MCPToolDefinition(
                name: "press_key",
                description: "Press a key or keyboard shortcut combination (e.g., key='c' with modifiers=['command'], or key='return', 'escape', 'f5', 'up'). Supports background=true with app_name/bundle_id/pid.",
                inputSchema: JSONSchema.object(
                    properties: [
                        "key": JSONSchema.string("Key name (a-z, 0-9, return, tab, space, escape, delete, up/down/left/right, f1-f20, etc.)."),
                        "modifiers": JSONSchema.stringArray("Modifiers: command, shift, option, control, fn."),
                        "repeat_count": JSONSchema.integer("Number of times to press (1..50). Default: 1."),
                        "app_name": JSONSchema.string("Optional target app name."),
                        "bundle_id": JSONSchema.string("Optional target bundle ID."),
                        "pid": JSONSchema.integer("Optional target PID."),
                        "background": JSONSchema.boolean("If true, send key directly to target PID via CGEvent.postToPid without activating. Default: false."),
                        "focus_mode": JSONSchema.string("Focus behavior: auto, background, foreground, or restore.", enumValues: ["auto", "background", "foreground", "restore"])
                    ],
                    required: ["key"]
                )
            ),
            MCPToolDefinition(
                name: "scroll",
                description: "Scroll at the current cursor position, a target element, or (x, y) coordinates. Positive delta_y scrolls up; negative delta_y scrolls down.",
                inputSchema: JSONSchema.object(properties: [
                    "element_id": JSONSchema.string("Optional element ID to position cursor over."),
                    "x": JSONSchema.number("Optional X coordinate."),
                    "y": JSONSchema.number("Optional Y coordinate."),
                    "coordinate_space": JSONSchema.string("Coordinate space for (x, y).", enumValues: ["global", "image"]),
                    "delta_x": JSONSchema.integer("Horizontal scroll delta (positive=left, negative=right). Default: 0."),
                    "delta_y": JSONSchema.integer("Vertical scroll delta (positive=up, negative=down). Default: -180."),
                    "unit": JSONSchema.string("Scroll unit.", enumValues: ["pixel", "line"])
                ])
            ),
            MCPToolDefinition(
                name: "manage_app",
                description: "Launch, activate, hide, or quit macOS applications, or open URLs via LaunchServices. Supports background=true launch with readiness polling.",
                inputSchema: JSONSchema.object(
                    properties: [
                        "action": JSONSchema.string("Lifecycle action.", enumValues: ["launch", "activate", "hide", "quit", "open_url"]),
                        "app_name": JSONSchema.string("Application name (e.g., 'Calculator', 'Linphone', 'Safari')."),
                        "bundle_id": JSONSchema.string("Bundle identifier (e.g., 'com.belledonnecommunications.linphone')."),
                        "pid": JSONSchema.integer("Process ID of running application."),
                        "url": JSONSchema.string("URL to open when action='open_url'."),
                        "force": JSONSchema.boolean("Force terminate when action='quit'. Default: false."),
                        "background": JSONSchema.boolean("If true for launch, start or unhide app without stealing foreground focus. Default: false."),
                        "wait_ready_ms": JSONSchema.integer("Max milliseconds to poll for launched app window readiness (200..15000). Default: 4000."),
                        "args": JSONSchema.stringArray("Optional command-line arguments passed when launching/messaging the app.")
                    ],
                    required: ["action"]
                )
            ),
            MCPToolDefinition(
                name: "menu_action",
                description: "List or trigger native macOS menu bar items or right-click context menus (requires Accessibility permission).",
                inputSchema: JSONSchema.object(
                    properties: [
                        "action": JSONSchema.string("Menu action.", enumValues: ["list", "click", "context_menu", "list_open_menus"]),
                        "app_name": JSONSchema.string("Target app name (defaults to frontmost app)."),
                        "bundle_id": JSONSchema.string("Target bundle ID."),
                        "pid": JSONSchema.integer("Target PID."),
                        "menu_path": JSONSchema.stringArray("Menu path for click or context_menu item selection, e.g. ['File', 'New Window'] or ['Copy']."),
                        "element_id": JSONSchema.string("Target element ID when opening context_menu."),
                        "snapshot_id": JSONSchema.string("Optional snapshot ID for element_id lookup."),
                        "query": JSONSchema.string("Optional text query when opening context_menu."),
                        "window_id": JSONSchema.integer("Optional target window ID."),
                        "x": JSONSchema.number("X coordinate when opening context_menu by position."),
                        "y": JSONSchema.number("Y coordinate when opening context_menu by position."),
                        "coordinate_space": JSONSchema.string("Coordinate space for (x, y).", enumValues: ["global", "image"]),
                        "confirm_destructive": JSONSchema.boolean("Explicitly authorize destructive menu items. Default: false.")
                    ],
                    required: ["action"]
                )
            ),
            MCPToolDefinition(
                name: "wait_for_ui",
                description: "Poll live UI inspection until a query appears/disappears, or wait event-driven via AXObserver + visual stability until UI settles (condition='settle').",
                inputSchema: JSONSchema.object(
                    properties: [
                        "query": JSONSchema.string("Text query to wait for (required for appear/disappear; omitted for condition='settle')."),
                        "role": JSONSchema.string("Optional role filter."),
                        "condition": JSONSchema.string("Wait condition.", enumValues: ["appear", "disappear", "settle"]),
                        "app_name": JSONSchema.string("Target app name."),
                        "bundle_id": JSONSchema.string("Target bundle ID."),
                        "window_id": JSONSchema.integer("Target window ID."),
                        "timeout_ms": JSONSchema.integer("Maximum wait milliseconds. Default: 5000 (or 1500 for settle)."),
                        "poll_interval_ms": JSONSchema.integer("Polling interval milliseconds. Default: 350."),
                        "quiet_ms": JSONSchema.integer("For condition='settle', AX quiet duration required before considering UI settled. Default: 85.")
                    ],
                    required: []
                )
            ),
            MCPToolDefinition(
                name: "clipboard",
                description: "Read, write, or clear the macOS system clipboard (NSPasteboard.general).",
                inputSchema: JSONSchema.object(
                    properties: [
                        "action": JSONSchema.string("Clipboard operation.", enumValues: ["read", "write", "clear"]),
                        "text": JSONSchema.string("Text to write when action='write'.")
                    ],
                    required: ["action"]
                )
            ),
            MCPToolDefinition(
                name: "scroll_to_element",
                description: "Scroll a virtualized list, table, outline, or viewport (via AXScrollToVisible or incremental wheel scrolling) until an off-screen element matching query becomes visible.",
                inputSchema: JSONSchema.object(
                    properties: [
                        "query": JSONSchema.string("Text query of the target row/element to reveal."),
                        "role": JSONSchema.string("Optional role filter (e.g. 'row', 'button', 'text')."),
                        "direction": JSONSchema.string("Scroll direction.", enumValues: ["down", "up", "left", "right"]),
                        "max_scrolls": JSONSchema.integer("Maximum wheel scroll steps (1..30). Default: 12."),
                        "app_name": JSONSchema.string("Target app name."),
                        "bundle_id": JSONSchema.string("Target bundle ID."),
                        "window_id": JSONSchema.integer("Target window ID.")
                    ],
                    required: ["query"]
                )
            ),
            MCPToolDefinition(
                name: "widget_action",
                description: "Operate rich stateful UI widgets: sliders, checkboxes/switches, dropdown menus, tabs, or text selection ranges.",
                inputSchema: JSONSchema.object(
                    properties: [
                        "action": JSONSchema.string("Widget operation.", enumValues: ["set_slider", "set_checkbox", "toggle", "select_dropdown", "select_tab", "select_text_range"]),
                        "element_id": JSONSchema.string("Cached element ID."),
                        "snapshot_id": JSONSchema.string("Optional snapshot ID."),
                        "query": JSONSchema.string("Text query to locate target widget."),
                        "app_name": JSONSchema.string("Target app name."),
                        "bundle_id": JSONSchema.string("Target bundle ID."),
                        "window_id": JSONSchema.integer("Target window ID."),
                        "number_value": JSONSchema.number("Target numeric value for action='set_slider'."),
                        "checked": JSONSchema.boolean("Desired boolean state for action='set_checkbox'."),
                        "option": JSONSchema.string("Option label to pick for action='select_dropdown'."),
                        "range_start": JSONSchema.integer("Character offset for action='select_text_range'."),
                        "range_length": JSONSchema.integer("Selection length for action='select_text_range'."),
                        "background": JSONSchema.boolean("Avoid stealing foreground focus when possible. Default: false."),
                        "focus_mode": JSONSchema.string("Focus behavior: auto, background, foreground, or restore.", enumValues: ["auto", "background", "foreground", "restore"]),
                        "confirm_destructive": JSONSchema.boolean("Explicitly authorize destructive widget actions. Default: false.")
                    ],
                    required: ["action"]
                )
            ),
            MCPToolDefinition(
                name: "handle_dialog",
                description: "Inspect and control native macOS sheets, NSOpenPanel/NSSavePanel file pickers (using Cmd+Shift+G direct path navigation), alerts, and system dialogs.",
                inputSchema: JSONSchema.object(
                    properties: [
                        "action": JSONSchema.string("Dialog operation.", enumValues: ["inspect", "select_file", "click_button"]),
                        "file_path": JSONSchema.string("Absolute or ~-expanded path for action='select_file'."),
                        "button": JSONSchema.string("For action='click_button': 'default', 'cancel', or button label text."),
                        "submit": JSONSchema.boolean("For action='select_file': confirm dialog after navigating to path. Default: true."),
                        "app_name": JSONSchema.string("Target app name."),
                        "bundle_id": JSONSchema.string("Target bundle ID."),
                        "pid": JSONSchema.integer("Target process ID."),
                        "confirm_destructive": JSONSchema.boolean("Explicitly authorize destructive dialog confirmation buttons. Default: false.")
                    ],
                    required: ["action"]
                )
            ),
            MCPToolDefinition(
                name: "virtual_display",
                description: "Create and manage an off-screen CGVirtualDisplay sandbox workspace so automated GUI apps can run without obstructing the user's active displays.",
                inputSchema: JSONSchema.object(
                    properties: [
                        "action": JSONSchema.string("Virtual display action.", enumValues: ["status", "create", "move_window", "destroy"]),
                        "name": JSONSchema.string("Display name when action='create'. Default: 'macos-use Sandbox'."),
                        "width": JSONSchema.integer("Logical width when creating virtual display (800..3840). Default: 1920."),
                        "height": JSONSchema.integer("Logical height when creating virtual display (600..2160). Default: 1080."),
                        "hidpi": JSONSchema.boolean("Enable 2x HiDPI Retina backing mode. Default: true."),
                        "display_id": JSONSchema.integer("Target display ID for move_window or destroy."),
                        "window_id": JSONSchema.integer("Window ID to move in action='move_window'."),
                        "app_name": JSONSchema.string("App name whose window should be moved."),
                        "bundle_id": JSONSchema.string("Bundle ID whose window should be moved."),
                        "pid": JSONSchema.integer("PID whose window should be moved.")
                    ],
                    required: ["action"]
                )
            ),
            MCPToolDefinition(
                name: "session_trace",
                description: "Configure safety policy guardrails (standard/strict/permissive), rate limits, and start/stop/query the trajectory flight recorder (JSONL + JPG frames).",
                inputSchema: JSONSchema.object(
                    properties: [
                        "action": JSONSchema.string("Session trace or policy action.", enumValues: ["status", "set_policy", "start_trace", "stop_trace", "recent_events"]),
                        "policy_mode": JSONSchema.string("Safety guardrail strictness.", enumValues: ["standard", "strict", "permissive"]),
                        "max_actions_per_minute": JSONSchema.integer("Mutating action rate limit per minute (10..2000)."),
                        "trace_dir": JSONSchema.string("Directory path to write events.jsonl and frames (defaults to /tmp/macos-use-traces/trace-<ts>)."),
                        "save_images": JSONSchema.boolean("Save JPEG frames during active trace. Default: true."),
                        "limit": JSONSchema.integer("Number of recent events to return (1..100). Default: 25.")
                    ],
                    required: ["action"]
                )
            )
        ]
    }

    // MARK: - JSON-RPC Dispatch

    public func handleRequestData(_ data: Data) async -> JSONRPCResponse? {
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            return JSONRPCResponse(
                id: .null,
                error: JSONRPCError(code: -32700, message: "Parse error: \(error.localizedDescription)")
            )
        }

        // Notifications have no `id` and expect no JSON-RPC response
        guard let reqID = request.id else {
            return nil
        }

        switch request.method {
        case "initialize":
            let result: JSONValue = .object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .object([
                    "tools": .object(["listChanged": .bool(false)])
                ]),
                "serverInfo": .object([
                    "name": .string(serverName),
                    "version": .string(serverVersion)
                ])
            ])
            return JSONRPCResponse(id: reqID, result: result)

        case "ping":
            return JSONRPCResponse(id: reqID, result: .object([:]))

        case "tools/list":
            let encodedTools = (try? JSONValue.fromEncodable(tools)) ?? .array([])
            return JSONRPCResponse(id: reqID, result: .object(["tools": encodedTools]))

        case "resources/list":
            return JSONRPCResponse(id: reqID, result: .object(["resources": .array([])]))

        case "prompts/list":
            return JSONRPCResponse(id: reqID, result: .object(["prompts": .array([])]))

        case "tools/call":
            guard let toolName = request.params?["name"]?.stringValue else {
                return JSONRPCResponse(
                    id: reqID,
                    error: JSONRPCError(code: -32602, message: "Missing required parameter 'name'.")
                )
            }
            let args = request.params?["arguments"]?.objectValue ?? [:]
            let toolResult = await executeTool(name: toolName, args: args)
            let encoded = (try? JSONValue.fromEncodable(toolResult))
                ?? .object(["content": .array([.object(["type": .string("text"), "text": .string("Encoding failure")])]), "isError": .bool(true)])
            return JSONRPCResponse(id: reqID, result: encoded)

        default:
            return JSONRPCResponse(
                id: reqID,
                error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)")
            )
        }
    }

    // MARK: - Tool Implementations

    private struct ToolExecutionOutput {
        let result: MCPToolCallResult
        var targetSummary: String = ""
        var methodUsed: String?
        var uiChanged: Bool?
        var escalated: Bool?
        var snapshotID: String?
        var imageData: Data?
    }

    public func executeTool(name: String, args: [String: JSONValue]) async -> MCPToolCallResult {
        let start = ContinuousClock.now
        do {
            let properties = tools.first(where: { $0.name == name })?.inputSchema["properties"]
            for (key, value) in args {
                switch properties?[key]?["type"]?.stringValue {
                case "integer":
                    let valid = ["window_id", "display_id"].contains(key) ? value.uint32Value != nil : value.int32Value != nil
                    guard valid else { throw MacOSUseError.invalidArgument("Invalid integer for '\(key)'.") }
                case "number":
                    guard let number = value.doubleValue, abs(number) <= Double(Int32.max) else {
                        throw MacOSUseError.invalidArgument("Invalid number for '\(key)'.")
                    }
                case "string" where value.stringValue == nil:
                    throw MacOSUseError.invalidArgument("Expected text for '\(key)'.")
                default: break
                }
            }
            let output = try await dispatchTool(name: name, args: args)
            let elapsed = durationMs(from: start, to: .now)
            if name != "session_trace" {
                await TrajectoryRecorder.shared.record(
                    tool: name,
                    targetSummary: output.targetSummary.isEmpty ? summarizeArgs(args) : output.targetSummary,
                    methodUsed: output.methodUsed,
                    uiChanged: output.uiChanged,
                    escalated: output.escalated,
                    elapsedMs: elapsed,
                    snapshotID: output.snapshotID,
                    imageData: output.imageData,
                    error: nil
                )
            }
            return output.result
        } catch {
            let elapsed = durationMs(from: start, to: .now)
            if name != "session_trace" {
                await TrajectoryRecorder.shared.record(
                    tool: name,
                    targetSummary: summarizeArgs(args),
                    methodUsed: nil,
                    uiChanged: false,
                    escalated: false,
                    elapsedMs: elapsed,
                    snapshotID: nil,
                    imageData: nil,
                    error: error.localizedDescription
                )
            }
            return .text(error.localizedDescription, isError: true)
        }
    }

    private func dispatchTool(name: String, args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        switch name {
        case "system_status":
            return try await handleSystemStatus(args)
        case "list_apps_and_windows":
            return try await handleListAppsAndWindows(args)
        case "observe_screen":
            return try await handleObserveScreen(args)
        case "inspect_ui":
            return try await handleInspectUI(args)
        case "find_elements":
            return try await handleFindElements(args)
        case "screenshot":
            return try await handleScreenshot(args)
        case "click":
            return try await handleClick(args)
        case "move_mouse":
            return try await handleMoveMouse(args)
        case "drag":
            return try await handleDrag(args)
        case "type_text":
            return try await handleTypeText(args)
        case "press_key":
            return try await handlePressKey(args)
        case "scroll":
            return try await handleScroll(args)
        case "manage_app":
            return try await handleManageApp(args)
        case "menu_action":
            return try await handleMenuAction(args)
        case "wait_for_ui":
            return try await handleWaitForUI(args)
        case "clipboard":
            return try await handleClipboard(args)
        case "scroll_to_element":
            return try await handleScrollToElement(args)
        case "widget_action":
            return try await handleWidgetAction(args)
        case "handle_dialog":
            return try await handleDialogTool(args)
        case "virtual_display":
            return try await handleVirtualDisplay(args)
        case "session_trace":
            return try await handleSessionTrace(args)
        default:
            return ToolExecutionOutput(result: .text("Unknown tool '\(name)'.", isError: true), targetSummary: name)
        }
    }

    private func handleSystemStatus(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let promptAX = args["prompt_accessibility"]?.boolValue ?? false
        let status = try await WindowManager.systemStatus(promptAccessibility: promptAX)
        let text = try JSONValue.fromEncodable(status).prettyJSONString()
        return ToolExecutionOutput(result: .text(text), targetSummary: "system_status")
    }

    private func handleListAppsAndWindows(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let appFilter = args["app_filter"]?.stringValue
        let includeBG = args["include_background_apps"]?.boolValue ?? false
        let includeSys = args["include_system_layers"]?.boolValue ?? false
        let onScreenOnly = args["on_screen_only"]?.boolValue ?? true

        let apps = await WindowManager.listApps(includeBackground: includeBG)
        let windows = try await WindowManager.listWindows(
            appFilter: appFilter,
            includeSystemLayers: includeSys,
            onScreenOnly: onScreenOnly
        )

        let payload: JSONValue = .object([
            "apps_count": .int(apps.count),
            "windows_count": .int(windows.count),
            "apps": try JSONValue.fromEncodable(apps),
            "windows": try JSONValue.fromEncodable(windows)
        ])
        return ToolExecutionOutput(
            result: .text(try payload.prettyJSONString()),
            targetSummary: appFilter ?? "all_windows"
        )
    }

    private func handleObserveScreen(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let target = try parseTargetScope(args)
        let annotate = args["annotate"]?.boolValue ?? true
        let includeVision = args["include_vision"]?.boolValue ?? true
        let detectContours = args["detect_contours"]?.boolValue ?? true
        let classifyIcons = args["classify_icons"]?.boolValue ?? true
        let includePopups = args["include_popups"]?.boolValue ?? true
        let maxElements = args["max_elements"]?.intValue ?? 160
        let maxDimension = args["max_dimension"]?.intValue ?? 1600
        let format = parseImageFormat(args["format"]?.stringValue)
        let quality = args["jpeg_quality"]?.doubleValue ?? 0.80
        let savePath = args["save_path"]?.stringValue

        let result = try await PerceptionEngine.observe(
            target: target,
            includeImage: true,
            annotate: annotate,
            includeVision: includeVision,
            detectContours: detectContours,
            classifyIcons: classifyIcons,
            includePopups: includePopups,
            maxElements: maxElements,
            maxDimension: maxDimension,
            imageFormat: format,
            jpegQuality: quality
        )

        if let savePath, !savePath.isEmpty, let data = result.encodedImageData {
            try writeDataToPath(data, path: savePath)
        }

        let elementsSummary = result.snapshot.elements.map { stored in
            elementToJSON(stored.ui)
        }
        let meta: JSONValue = .object([
            "snapshot_id": .string(result.snapshot.snapshotID),
            "scope": .string(result.snapshot.scopeDescription),
            "owner_pid": result.snapshot.ownerPID.map { .int(Int($0)) } ?? .null,
            "window_id": result.snapshot.windowID.map { .int(Int($0)) } ?? .null,
            "ax_trusted": .bool(result.snapshot.axTrusted),
            "ax_elements_raw": .int(result.axCount),
            "vision_elements_raw": .int(result.visionCount),
            "elements_count": .int(result.snapshot.elements.count),
            "summary": buildScreenSummary(elements: result.snapshot.elements.map(\.ui)),
            "transform": try JSONValue.fromEncodable(result.snapshot.transform),
            "saved_path": savePath.map(JSONValue.string) ?? .null,
            "elements": .array(elementsSummary)
        ])

        var content: [MCPContentItem] = [.text(try meta.prettyJSONString())]
        if let data = result.encodedImageData {
            content.append(.image(base64Data: data.base64EncodedString(), mimeType: result.imageFormat.mimeType))
        }
        return ToolExecutionOutput(
            result: MCPToolCallResult(content: content, isError: false),
            targetSummary: result.snapshot.scopeDescription,
            snapshotID: result.snapshot.snapshotID,
            imageData: result.encodedImageData
        )
    }

    private func handleInspectUI(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let target = try parseTargetScope(args)
        let classifyIcons = args["classify_icons"]?.boolValue ?? true
        let includePopups = args["include_popups"]?.boolValue ?? true
        let maxElements = args["max_elements"]?.intValue ?? 180
        let interactiveOnly = args["interactive_only"]?.boolValue ?? false

        let result = try await PerceptionEngine.observe(
            target: target,
            includeImage: false,
            annotate: false,
            includeVision: true,
            detectContours: true,
            classifyIcons: classifyIcons,
            includePopups: includePopups,
            maxElements: maxElements
        )

        let filteredUI = result.snapshot.elements
            .map(\.ui)
            .filter { !interactiveOnly || $0.isInteractive }
        let filtered = filteredUI.map(elementToJSON)

        let payload: JSONValue = .object([
            "snapshot_id": .string(result.snapshot.snapshotID),
            "scope": .string(result.snapshot.scopeDescription),
            "owner_pid": result.snapshot.ownerPID.map { .int(Int($0)) } ?? .null,
            "window_id": result.snapshot.windowID.map { .int(Int($0)) } ?? .null,
            "ax_trusted": .bool(result.snapshot.axTrusted),
            "elements_count": .int(filtered.count),
            "summary": buildScreenSummary(elements: result.snapshot.elements.map(\.ui)),
            "transform": try JSONValue.fromEncodable(result.snapshot.transform),
            "elements": .array(filtered)
        ])
        return ToolExecutionOutput(
            result: .text(try payload.prettyJSONString()),
            targetSummary: result.snapshot.scopeDescription,
            snapshotID: result.snapshot.snapshotID
        )
    }

    private func handleFindElements(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let query = args["query"]?.stringValue
        let role = args["role"]?.stringValue
        let interactiveOnly = args["interactive_only"]?.boolValue ?? true
        let refresh = args["refresh"]?.boolValue ?? false
        let snapshotID = args["snapshot_id"]?.stringValue
        let limit = args["limit"]?.intValue ?? 25

        let existingSnap = await SnapshotStore.shared.snapshot(id: snapshotID)
        if refresh || existingSnap == nil {
            let target = try parseTargetScope(args)
            _ = try await PerceptionEngine.observe(
                target: target,
                includeImage: false,
                annotate: false,
                includeVision: true,
                detectContours: true
            )
        }

        let (snap, matches) = await SnapshotStore.shared.findElements(
            query: query,
            role: role,
            interactiveOnly: interactiveOnly,
            snapshotID: snapshotID,
            limit: limit
        )

        let payload: JSONValue = .object([
            "snapshot_id": snap.map { .string($0.snapshotID) } ?? .null,
            "query": query.map(JSONValue.string) ?? .null,
            "role": role.map(JSONValue.string) ?? .null,
            "matches_count": .int(matches.count),
            "matches": .array(matches.map { elementToJSON($0.ui) })
        ])
        return ToolExecutionOutput(
            result: .text(try payload.prettyJSONString()),
            targetSummary: query ?? role ?? "all",
            snapshotID: snap?.snapshotID
        )
    }

    private func handleScreenshot(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let target = try parseTargetScope(args)
        let maxDimension = args["max_dimension"]?.intValue ?? 1600
        let format = parseImageFormat(args["format"]?.stringValue)
        let quality = args["jpeg_quality"]?.doubleValue ?? 0.85
        let showCursor = args["show_cursor"]?.boolValue ?? false
        let savePath = args["save_path"]?.stringValue

        let captured = try await ScreenCapturer.capture(
            target: target,
            maxCaptureDimension: maxDimension,
            showCursor: showCursor
        )
        let resized = ScreenCapturer.resizeIfNeeded(captured.image, maxDimension: maxDimension)
        let outputTransform = CaptureTransform(
            originX: captured.transform.originX,
            originY: captured.transform.originY,
            logicalWidth: captured.transform.logicalWidth,
            logicalHeight: captured.transform.logicalHeight,
            imageWidth: resized.width,
            imageHeight: resized.height
        )
        await SnapshotStore.shared.updateTransformOnly(outputTransform)

        let data = try ScreenCapturer.encodeImage(resized, format: format, jpegQuality: quality)
        if let savePath, !savePath.isEmpty {
            try writeDataToPath(data, path: savePath)
        }

        let meta: JSONValue = .object([
            "scope": .string(captured.scopeDescription),
            "transform": try JSONValue.fromEncodable(outputTransform),
            "saved_path": savePath.map(JSONValue.string) ?? .null
        ])
        return ToolExecutionOutput(
            result: MCPToolCallResult(
                content: [
                    .text(try meta.prettyJSONString()),
                    .image(base64Data: data.base64EncodedString(), mimeType: format.mimeType)
                ],
                isError: false
            ),
            targetSummary: captured.scopeDescription,
            imageData: data
        )
    }

    private func handleClick(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let button = args["button"]?.stringValue ?? "left"
        let clickCount = args["click_count"]?.intValue ?? 1
        let modifiers = args["modifiers"]?.stringArrayValue ?? []
        let method = args["method"]?.stringValue ?? "auto"
        let coordSpace = args["coordinate_space"]?.stringValue ?? "global"
        let focusMode = try FocusMode.resolve(
            background: args["background"]?.boolValue,
            focusMode: args["focus_mode"]?.stringValue
        )
        let verify = args["verify"]?.boolValue ?? (method.lowercased() == "auto")
        let settleMs = args["settle_ms"]?.intValue ?? 160
        let allowFocusFallback = args["allow_focus_fallback"]?.boolValue ?? false
        let confirmDestructive = args["confirm_destructive"]?.boolValue ?? false

        let resolved = try await resolveElementOrPoint(
            args: args,
            coordSpace: coordSpace,
            fallbackToAppPID: true,
            defaultBackgroundPID: focusMode == .background
        )
        guard resolved.point != nil || resolved.element != nil else {
            throw MacOSUseError.invalidArgument("click requires element_id, query, or both x and y.")
        }

        let safetyLabel = resolved.element?.ui.label ?? args["query"]?.stringValue
        try await SafetyPolicyManager.shared.checkAction(
            tool: "click",
            targetLabel: safetyLabel,
            confirmDestructive: confirmDestructive
        )

        let outcome = try await InputController.click(
            point: resolved.point,
            element: resolved.element,
            ownerPID: resolved.ownerPID,
            windowID: resolved.windowID,
            button: button,
            clickCount: clickCount,
            modifiers: modifiers,
            method: method,
            focusMode: focusMode,
            verify: verify,
            settleMs: settleMs,
            allowFocusFallback: allowFocusFallback
        )

        let payload: JSONValue = .object([
            "ok": .bool(true),
            "method_used": .string(outcome.methodUsed),
            "focus_mode": .string(outcome.focusMode.rawValue),
            "clicked_point": try JSONValue.fromEncodable(outcome.point),
            "matched_element": outcome.matchedElement.map(elementToJSON) ?? .null,
            "verification": outcome.verification.flatMap { try? JSONValue.fromEncodable($0) } ?? .null
        ])
        return ToolExecutionOutput(
            result: .text(try payload.prettyJSONString()),
            targetSummary: safetyLabel ?? "(\(Int(outcome.point.x)),\(Int(outcome.point.y)))",
            methodUsed: outcome.methodUsed,
            uiChanged: outcome.verification?.uiChanged,
            escalated: outcome.verification?.escalated
        )
    }

    private func handleMoveMouse(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let smooth = args["smooth"]?.boolValue ?? false
        let coordSpace = args["coordinate_space"]?.stringValue ?? "global"
        let resolved = try await resolveElementOrPoint(args: args, coordSpace: coordSpace, fallbackToAppPID: false, defaultBackgroundPID: false)
        guard let point = resolved.point else {
            throw MacOSUseError.invalidArgument("move_mouse requires element_id, query, or (x, y).")
        }

        try await InputController.moveMouse(to: point, smooth: smooth)
        return ToolExecutionOutput(
            result: .text(try JSONValue.object([
                "ok": .bool(true),
                "x": .double(point.x),
                "y": .double(point.y)
            ]).prettyJSONString()),
            targetSummary: "(\(Int(point.x)),\(Int(point.y)))",
            methodUsed: smooth ? "smooth_move" : "move"
        )
    }

    private func handleDrag(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let coordSpace = args["coordinate_space"]?.stringValue ?? "global"
        let durationMs = args["duration_ms"]?.intValue ?? 350
        let modifiers = args["modifiers"]?.stringArrayValue ?? []

        let start: CGPoint
        if let fromID = args["from_element_id"]?.stringValue, !fromID.isEmpty {
            let (_, elem) = try await SnapshotStore.shared.resolveElement(id: fromID)
            start = elem.ui.frame.center.cgPoint
        } else if let fx = args["from_x"]?.doubleValue, let fy = args["from_y"]?.doubleValue {
            start = try await resolvePoint(x: fx, y: fy, coordinateSpace: coordSpace)
        } else {
            throw MacOSUseError.invalidArgument("drag requires from_element_id or (from_x, from_y).")
        }

        let end: CGPoint
        if let toID = args["to_element_id"]?.stringValue, !toID.isEmpty {
            let (_, elem) = try await SnapshotStore.shared.resolveElement(id: toID)
            end = elem.ui.frame.center.cgPoint
        } else if let tx = args["to_x"]?.doubleValue, let ty = args["to_y"]?.doubleValue {
            end = try await resolvePoint(x: tx, y: ty, coordinateSpace: coordSpace)
        } else {
            throw MacOSUseError.invalidArgument("drag requires to_element_id or (to_x, to_y).")
        }

        try await SafetyPolicyManager.shared.checkAction(tool: "drag", targetLabel: nil, confirmDestructive: false)
        try await InputController.drag(from: start, to: end, durationMs: durationMs, modifiers: modifiers)
        return ToolExecutionOutput(
            result: .text(try JSONValue.object([
                "ok": .bool(true),
                "from": .object(["x": .double(start.x), "y": .double(start.y)]),
                "to": .object(["x": .double(end.x), "y": .double(end.y)])
            ]).prettyJSONString()),
            targetSummary: "(\(Int(start.x)),\(Int(start.y)))->(\(Int(end.x)),\(Int(end.y)))",
            methodUsed: "cgevent_drag"
        )
    }

    private func handleTypeText(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let text = args["text"]?.stringValue else {
            throw MacOSUseError.invalidArgument("Missing required argument 'text'.")
        }
        let clearFirst = args["clear_first"]?.boolValue ?? false
        let pressEnter = args["press_enter"]?.boolValue ?? false
        let focusMode = try FocusMode.resolve(
            background: args["background"]?.boolValue,
            focusMode: args["focus_mode"]?.stringValue
        )
        let defaultMethod = (focusMode == .background) ? "auto" : "unicode"
        let method = args["method"]?.stringValue ?? defaultMethod
        let verify = args["verify"]?.boolValue ?? true
        let confirmDestructive = args["confirm_destructive"]?.boolValue ?? false

        let resolved = try await resolveElementOrPoint(
            args: args,
            coordSpace: "global",
            fallbackToAppPID: true,
            defaultBackgroundPID: focusMode == .background,
            allowRawCoordinates: false
        )

        try await SafetyPolicyManager.shared.checkAction(
            tool: "type_text",
            targetLabel: resolved.element?.ui.label ?? args["query"]?.stringValue,
            confirmDestructive: confirmDestructive
        )

        let outcome = try await InputController.typeText(
            text: text,
            element: resolved.element,
            targetPID: resolved.ownerPID,
            clearFirst: clearFirst,
            pressEnter: pressEnter,
            method: method,
            focusMode: focusMode,
            verify: verify
        )

        return ToolExecutionOutput(
            result: .text(try JSONValue.object([
                "ok": .bool(true),
                "characters": .int(text.count),
                "method": .string(outcome.methodUsed),
                "verified": .bool(outcome.verified),
                "value_matched": .bool(outcome.valueMatched),
                "escalated": .bool(outcome.escalated),
                "focus_mode": .string(outcome.focusMode.rawValue),
                "press_enter": .bool(pressEnter),
                "focused_element": resolved.element.map { elementToJSON($0.ui) } ?? .null
            ]).prettyJSONString()),
            targetSummary: resolved.element?.ui.label ?? "chars=\(text.count)",
            methodUsed: outcome.methodUsed,
            uiChanged: outcome.valueMatched,
            escalated: outcome.escalated
        )
    }

    private func handlePressKey(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let key = args["key"]?.stringValue, !key.isEmpty else {
            throw MacOSUseError.invalidArgument("Missing required argument 'key'.")
        }
        let modifiers = args["modifiers"]?.stringArrayValue ?? []
        let repeatCount = args["repeat_count"]?.intValue ?? 1
        let focusMode = try FocusMode.resolve(
            background: args["background"]?.boolValue,
            focusMode: args["focus_mode"]?.stringValue
        )

        try await SafetyPolicyManager.shared.checkAction(tool: "press_key", targetLabel: nil, confirmDestructive: false)
        let targetPID = try await resolveAppPID(args: args, fallbackToSnapshot: focusMode == .background)

        try await InputController.pressKey(
            key: key,
            modifiers: modifiers,
            repeatCount: repeatCount,
            targetPID: targetPID,
            focusMode: focusMode
        )
        return ToolExecutionOutput(
            result: .text(try JSONValue.object([
                "ok": .bool(true),
                "key": .string(key),
                "modifiers": .array(modifiers.map(JSONValue.string)),
                "repeat_count": .int(repeatCount),
                "focus_mode": .string(focusMode.rawValue)
            ]).prettyJSONString()),
            targetSummary: modifiers.isEmpty ? key : "\(modifiers.joined(separator: "+"))+\(key)",
            methodUsed: focusMode == .background ? "cgevent_pid_key" : "cgevent_key"
        )
    }

    private func handleScroll(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let deltaX = args["delta_x"]?.intValue ?? 0
        let deltaY = args["delta_y"]?.intValue ?? -180
        let unit = args["unit"]?.stringValue ?? "pixel"
        let coordSpace = args["coordinate_space"]?.stringValue ?? "global"

        let resolved = try await resolveElementOrPoint(args: args, coordSpace: coordSpace, fallbackToAppPID: false, defaultBackgroundPID: false)
        try await InputController.scroll(at: resolved.point, deltaX: deltaX, deltaY: deltaY, unit: unit)
        return ToolExecutionOutput(
            result: .text(try JSONValue.object([
                "ok": .bool(true),
                "delta_x": .int(deltaX),
                "delta_y": .int(deltaY),
                "unit": .string(unit)
            ]).prettyJSONString()),
            targetSummary: "scroll(dx:\(deltaX),dy:\(deltaY))",
            methodUsed: "scroll_\(unit)"
        )
    }

    private func handleManageApp(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let action = args["action"]?.stringValue?.lowercased() else {
            throw MacOSUseError.invalidArgument("Missing required argument 'action'.")
        }
        let appName = args["app_name"]?.stringValue
        let bundleID = args["bundle_id"]?.stringValue
        let pid = args["pid"]?.int32Value
        let force = args["force"]?.boolValue ?? false
        let background = args["background"]?.boolValue ?? false
        let waitReadyMs = args["wait_ready_ms"]?.intValue ?? 4000
        let launchArgs = args["args"]?.stringArrayValue ?? []

        let summaryTarget = bundleID ?? appName ?? pid.map(String.init) ?? action
        switch action {
        case "launch":
            let info = try await WindowManager.launchApp(
                appName: appName,
                bundleID: bundleID,
                background: background,
                arguments: launchArgs,
                waitReadyMs: waitReadyMs
            )
            return ToolExecutionOutput(result: .text(try JSONValue.fromEncodable(info).prettyJSONString()), targetSummary: summaryTarget, methodUsed: "launch")
        case "activate":
            let info = try await WindowManager.activateApp(pid: pid, appName: appName, bundleID: bundleID)
            return ToolExecutionOutput(result: .text(try JSONValue.fromEncodable(info).prettyJSONString()), targetSummary: summaryTarget, methodUsed: "activate")
        case "hide":
            let info = try await WindowManager.hideApp(pid: pid, appName: appName, bundleID: bundleID)
            return ToolExecutionOutput(result: .text(try JSONValue.fromEncodable(info).prettyJSONString()), targetSummary: summaryTarget, methodUsed: "hide")
        case "quit":
            let terminated = try await WindowManager.quitApp(pid: pid, appName: appName, bundleID: bundleID, force: force)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object(["ok": .bool(terminated), "terminated": .bool(terminated)]).prettyJSONString()),
                targetSummary: summaryTarget,
                methodUsed: force ? "force_quit" : "quit"
            )
        case "open_url":
            guard let url = args["url"]?.stringValue, !url.isEmpty else {
                throw MacOSUseError.invalidArgument("open_url requires 'url'.")
            }
            let opened = try await WindowManager.openURL(url)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object(["ok": .bool(opened), "url": .string(url)]).prettyJSONString()),
                targetSummary: url,
                methodUsed: "open_url"
            )
        default:
            throw MacOSUseError.invalidArgument("Unsupported manage_app action '\(action)'.")
        }
    }

    private func handleMenuAction(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let action = args["action"]?.stringValue?.lowercased() else {
            throw MacOSUseError.invalidArgument("Missing required argument 'action'.")
        }
        let confirmDestructive = args["confirm_destructive"]?.boolValue ?? false
        let targetPID: Int32
        if let explicit = try await resolveAppPID(args: args, fallbackToSnapshot: true) {
            targetPID = explicit
        } else if let front = await WindowManager.frontmostApp() {
            targetPID = front.pid
        } else {
            throw MacOSUseError.targetNotFound("No target or frontmost application found.")
        }

        switch action {
        case "list":
            let items = try AXInspector.listMenuBar(pid: targetPID)
            return ToolExecutionOutput(result: .text(try JSONValue.fromEncodable(items).prettyJSONString()), targetSummary: "menubar(pid:\(targetPID))")
        case "list_open_menus":
            let items = AXInspector.inspectOpenMenus(pid: targetPID)
            return ToolExecutionOutput(result: .text(try JSONValue.fromEncodable(items).prettyJSONString()), targetSummary: "open_menus(pid:\(targetPID))")
        case "click":
            guard let path = args["menu_path"]?.stringArrayValue, !path.isEmpty else {
                throw MacOSUseError.invalidArgument("menu_action click requires 'menu_path'.")
            }
            try await SafetyPolicyManager.shared.checkAction(
                tool: "menu_action",
                targetLabel: nil,
                menuPath: path,
                confirmDestructive: confirmDestructive
            )
            let triggered = try AXInspector.triggerMenuItem(pid: targetPID, path: path)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object(["ok": .bool(true), "triggered": .string(triggered)]).prettyJSONString()),
                targetSummary: triggered,
                methodUsed: "ax_menubar_press"
            )
        case "context_menu":
            let menuPath = args["menu_path"]?.stringArrayValue
            if let menuPath, !menuPath.isEmpty {
                try await SafetyPolicyManager.shared.checkAction(
                    tool: "menu_action",
                    targetLabel: nil,
                    menuPath: menuPath,
                    confirmDestructive: confirmDestructive
                )
            }
            let coordSpace = args["coordinate_space"]?.stringValue ?? "global"
            let resolved = try await resolveElementOrPoint(args: args, coordSpace: coordSpace, fallbackToAppPID: false, defaultBackgroundPID: false)
            let effectivePID = resolved.ownerPID ?? targetPID
            let (items, triggered) = try await InputController.triggerContextMenu(
                element: resolved.element,
                point: resolved.point,
                pid: effectivePID,
                windowID: resolved.windowID,
                menuPath: menuPath
            )
            let payload: JSONValue = .object([
                "ok": .bool(true),
                "triggered": triggered.map(JSONValue.string) ?? .null,
                "items_count": .int(items.count),
                "items": try JSONValue.fromEncodable(items)
            ])
            return ToolExecutionOutput(
                result: .text(try payload.prettyJSONString()),
                targetSummary: triggered ?? "context_menu",
                methodUsed: "context_menu"
            )
        default:
            throw MacOSUseError.invalidArgument("Unsupported menu_action '\(action)'.")
        }
    }

    private func handleWaitForUI(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        let condition = (args["condition"]?.stringValue ?? "appear").lowercased()
        if condition == "settle" {
            let maxWaitMs = max(100, min(args["timeout_ms"]?.intValue ?? 1500, 15000))
            let quietMs = max(40, min(args["quiet_ms"]?.intValue ?? 85, 2000))
            let wid = args["window_id"]?.uint32Value
            var pid = try await resolveAppPID(args: args, fallbackToSnapshot: true)
            if pid == nil, let wid {
                pid = (try? await WindowManager.listWindows(includeSystemLayers: true, onScreenOnly: false))?
                    .first(where: { $0.windowID == wid })?.ownerPID
            }
            if pid == nil {
                pid = await WindowManager.frontmostApp()?.pid
            }
            let settled = await UIEventObserver.waitForSettle(
                pid: pid,
                windowID: wid,
                region: nil,
                maxWaitMs: maxWaitMs,
                quietWindowMs: quietMs,
                checkVisual: true
            )
            return ToolExecutionOutput(
                result: .text(try JSONValue.fromEncodable(settled).prettyJSONString()),
                targetSummary: "settle(pid:\(pid ?? 0))",
                methodUsed: "ax_observer_settle",
                uiChanged: !settled.axNotifications.isEmpty || settled.visualDeltaScore > 0.01
            )
        }

        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw MacOSUseError.invalidArgument("wait_for_ui requires non-empty 'query' when condition is '\(condition)'.")
        }
        let role = args["role"]?.stringValue
        let timeoutMs = max(200, min(args["timeout_ms"]?.intValue ?? 5000, 30000))
        let pollMs = max(150, min(args["poll_interval_ms"]?.intValue ?? 350, 2000))
        let target = try parseTargetScope(args)

        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        var lastSnapshotID: String?

        while true {
            let observed = try await PerceptionEngine.observe(
                target: target,
                includeImage: false,
                annotate: false
            )
            lastSnapshotID = observed.snapshot.snapshotID
            let (_, matches) = await SnapshotStore.shared.findElements(
                query: query,
                role: role,
                interactiveOnly: false,
                snapshotID: observed.snapshot.snapshotID,
                limit: 10
            )

            let satisfied = (condition == "disappear") ? matches.isEmpty : !matches.isEmpty
            if satisfied {
                return ToolExecutionOutput(
                    result: .text(try JSONValue.object([
                        "ok": .bool(true),
                        "condition": .string(condition),
                        "snapshot_id": .string(observed.snapshot.snapshotID),
                        "matches_count": .int(matches.count),
                        "matches": .array(matches.map { elementToJSON($0.ui) })
                    ]).prettyJSONString()),
                    targetSummary: "\(condition):\(query)",
                    snapshotID: observed.snapshot.snapshotID
                )
            }

            if ContinuousClock.now >= deadline {
                throw MacOSUseError.timeout(
                    "Timed out after \(timeoutMs)ms waiting for '\(query)' to \(condition) (last snapshot: \(lastSnapshotID ?? "none"))."
                )
            }
            try? await Task.sleep(for: .milliseconds(pollMs))
        }
    }

    private func handleClipboard(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let action = args["action"]?.stringValue?.lowercased() else {
            throw MacOSUseError.invalidArgument("Missing required argument 'action'.")
        }
        switch action {
        case "read":
            let content = await ClipboardManager.readText()
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "text": content.map(JSONValue.string) ?? .null
                ]).prettyJSONString()),
                targetSummary: "clipboard_read"
            )
        case "write":
            guard let text = args["text"]?.stringValue else {
                throw MacOSUseError.invalidArgument("clipboard write requires 'text'.")
            }
            await ClipboardManager.writeText(text)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "characters": .int(text.count)
                ]).prettyJSONString()),
                targetSummary: "clipboard_write(\(text.count))"
            )
        case "clear":
            await ClipboardManager.clear()
            return ToolExecutionOutput(result: .text(try JSONValue.object(["ok": .bool(true)]).prettyJSONString()), targetSummary: "clipboard_clear")
        default:
            throw MacOSUseError.invalidArgument("Unsupported clipboard action '\(action)'.")
        }
    }

    private func handleScrollToElement(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw MacOSUseError.invalidArgument("scroll_to_element requires non-empty 'query'.")
        }
        let role = args["role"]?.stringValue
        let direction = args["direction"]?.stringValue ?? "down"
        let maxScrolls = args["max_scrolls"]?.intValue ?? 12
        let target = try parseTargetScope(args)

        let outcome = try await WidgetController.scrollUntilVisible(
            query: query,
            role: role,
            target: target,
            direction: direction,
            maxScrolls: maxScrolls
        )
        return ToolExecutionOutput(
            result: .text(try JSONValue.object([
                "ok": .bool(true),
                "snapshot_id": .string(outcome.snapshot.snapshotID),
                "steps": .int(outcome.steps),
                "method": .string(outcome.method),
                "element": elementToJSON(outcome.element.ui)
            ]).prettyJSONString()),
            targetSummary: query,
            methodUsed: outcome.method,
            uiChanged: outcome.steps > 0,
            snapshotID: outcome.snapshot.snapshotID
        )
    }

    private func handleWidgetAction(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let action = args["action"]?.stringValue?.lowercased() else {
            throw MacOSUseError.invalidArgument("widget_action requires 'action'.")
        }
        let focusMode = try FocusMode.resolve(
            background: args["background"]?.boolValue,
            focusMode: args["focus_mode"]?.stringValue
        )
        let confirmDestructive = args["confirm_destructive"]?.boolValue ?? false

        if action == "select_tab" {
            let resolved = try await resolveElementOrPoint(args: args, coordSpace: "global", fallbackToAppPID: false, defaultBackgroundPID: false, allowRawCoordinates: false)
            let target = try parseTargetScope(args)
            let res = try await WidgetController.selectTab(
                element: resolved.element,
                query: args["query"]?.stringValue,
                target: target,
                focusMode: focusMode
            )
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "action": .string("select_tab"),
                    "tab": .string(res.label),
                    "method": .string(res.method)
                ]).prettyJSONString()),
                targetSummary: res.label,
                methodUsed: res.method,
                uiChanged: true
            )
        }

        let resolved = try await resolveElementOrPoint(
            args: args,
            coordSpace: "global",
            fallbackToAppPID: false,
            defaultBackgroundPID: focusMode == .background,
            allowRawCoordinates: false
        )
        guard let elem = resolved.element else {
            throw MacOSUseError.targetNotFound("widget_action '\(action)' requires a matching element_id or query.")
        }

        try await SafetyPolicyManager.shared.checkAction(
            tool: "widget_action",
            targetLabel: elem.ui.label,
            confirmDestructive: confirmDestructive
        )

        switch action {
        case "set_slider":
            guard let num = args["number_value"]?.doubleValue else {
                throw MacOSUseError.invalidArgument("set_slider requires 'number_value'.")
            }
            let res = try await WidgetController.setSlider(element: elem, value: num, focusMode: focusMode)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "action": .string(action),
                    "applied_value": .double(res.appliedValue),
                    "method": .string(res.method),
                    "element": elementToJSON(elem.ui)
                ]).prettyJSONString()),
                targetSummary: elem.ui.label,
                methodUsed: res.method,
                uiChanged: true
            )
        case "set_checkbox", "toggle":
            let desired = (action == "toggle") ? nil : args["checked"]?.boolValue
            let res = try await WidgetController.setCheckbox(element: elem, desiredChecked: desired, focusMode: focusMode)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "action": .string(action),
                    "checked": res.newState.map(JSONValue.bool) ?? .null,
                    "changed": .bool(res.changed),
                    "method": .string(res.method),
                    "element": elementToJSON(elem.ui)
                ]).prettyJSONString()),
                targetSummary: elem.ui.label,
                methodUsed: res.method,
                uiChanged: res.changed
            )
        case "select_dropdown":
            guard let option = args["option"]?.stringValue, !option.isEmpty else {
                throw MacOSUseError.invalidArgument("select_dropdown requires 'option'.")
            }
            let res = try await WidgetController.selectDropdown(element: elem, option: option, focusMode: focusMode)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "action": .string(action),
                    "selected": .string(res.selected),
                    "method": .string(res.method)
                ]).prettyJSONString()),
                targetSummary: "\(elem.ui.label)->\(option)",
                methodUsed: res.method,
                uiChanged: true
            )
        case "select_text_range":
            guard let start = args["range_start"]?.intValue, let len = args["range_length"]?.intValue else {
                throw MacOSUseError.invalidArgument("select_text_range requires 'range_start' and 'range_length'.")
            }
            let selectedText = try WidgetController.selectTextRange(element: elem, start: start, length: len)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "action": .string(action),
                    "range_start": .int(start),
                    "range_length": .int(len),
                    "selected_text": selectedText.map(JSONValue.string) ?? .null
                ]).prettyJSONString()),
                targetSummary: elem.ui.label,
                methodUsed: "ax_selected_text_range",
                uiChanged: true
            )
        default:
            throw MacOSUseError.invalidArgument("Unsupported widget_action '\(action)'.")
        }
    }

    private func handleDialogTool(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let action = args["action"]?.stringValue?.lowercased() else {
            throw MacOSUseError.invalidArgument("handle_dialog requires 'action'.")
        }
        let targetPID = try await resolveAppPID(args: args, fallbackToSnapshot: false)
        let confirmDestructive = args["confirm_destructive"]?.boolValue ?? false

        switch action {
        case "inspect":
            let dialogs = try await DialogController.inspectDialogs(pid: targetPID)
            let payload: JSONValue = .object([
                "dialogs_count": .int(dialogs.count),
                "dialogs": try JSONValue.fromEncodable(dialogs)
            ])
            return ToolExecutionOutput(result: .text(try payload.prettyJSONString()), targetSummary: "inspect_dialogs")
        case "select_file":
            guard let path = args["file_path"]?.stringValue, !path.isEmpty else {
                throw MacOSUseError.invalidArgument("handle_dialog select_file requires 'file_path'.")
            }
            let submit = args["submit"]?.boolValue ?? true
            let res = try await DialogController.selectFile(path: path, pid: targetPID, submit: submit)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object(res).prettyJSONString()),
                targetSummary: path,
                methodUsed: "file_dialog_cmd_shift_g",
                uiChanged: true
            )
        case "click_button":
            guard let btn = args["button"]?.stringValue, !btn.isEmpty else {
                throw MacOSUseError.invalidArgument("handle_dialog click_button requires 'button'.")
            }
            try await SafetyPolicyManager.shared.checkAction(
                tool: "handle_dialog",
                targetLabel: btn,
                confirmDestructive: confirmDestructive
            )
            let res = try await DialogController.clickDialogButton(button: btn, pid: targetPID)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object(res).prettyJSONString()),
                targetSummary: btn,
                methodUsed: res["method"]?.stringValue,
                uiChanged: true
            )
        default:
            throw MacOSUseError.invalidArgument("Unsupported handle_dialog action '\(action)'.")
        }
    }

    private func handleVirtualDisplay(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let action = args["action"]?.stringValue?.lowercased() else {
            throw MacOSUseError.invalidArgument("virtual_display requires 'action'.")
        }
        switch action {
        case "status":
            let supported = await MainActor.run { VirtualDisplayManager.shared.isSupported() }
            let list = await MainActor.run { VirtualDisplayManager.shared.listVirtualDisplays() }
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "supported": .bool(supported),
                    "active_count": .int(list.count),
                    "virtual_displays": try JSONValue.fromEncodable(list)
                ]).prettyJSONString()),
                targetSummary: "virtual_display_status"
            )
        case "create":
            let name = args["name"]?.stringValue ?? "macos-use Sandbox"
            let w = args["width"]?.intValue ?? 1920
            let h = args["height"]?.intValue ?? 1080
            let hidpi = args["hidpi"]?.boolValue ?? true
            let info = try await VirtualDisplayManager.shared.createDisplay(name: name, width: w, height: h, hiDPI: hidpi)
            return ToolExecutionOutput(
                result: .text(try JSONValue.fromEncodable(info).prettyJSONString()),
                targetSummary: "\(name)(\(w)x\(h))",
                methodUsed: "cg_virtual_display_create"
            )
        case "move_window":
            let frame = try await VirtualDisplayManager.shared.moveWindowToDisplay(
                windowID: args["window_id"]?.uint32Value,
                pid: args["pid"]?.int32Value,
                appName: args["app_name"]?.stringValue,
                bundleID: args["bundle_id"]?.stringValue,
                displayID: args["display_id"]?.uint32Value
            )
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "moved_frame": try JSONValue.fromEncodable(frame)
                ]).prettyJSONString()),
                targetSummary: "move_window",
                methodUsed: "ax_move_window",
                uiChanged: true
            )
        case "destroy":
            let removed = await MainActor.run {
                VirtualDisplayManager.shared.destroyDisplay(displayID: args["display_id"]?.uint32Value)
            }
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "destroyed_count": .int(removed)
                ]).prettyJSONString()),
                targetSummary: "destroy_virtual_display(\(removed))",
                methodUsed: "cg_virtual_display_destroy"
            )
        default:
            throw MacOSUseError.invalidArgument("Unsupported virtual_display action '\(action)'.")
        }
    }

    private func handleSessionTrace(_ args: [String: JSONValue]) async throws -> ToolExecutionOutput {
        guard let action = args["action"]?.stringValue?.lowercased() else {
            throw MacOSUseError.invalidArgument("session_trace requires 'action'.")
        }
        switch action {
        case "status":
            let policy = await SafetyPolicyManager.shared.currentConfig()
            let trace = await TrajectoryRecorder.shared.status()
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "policy": try JSONValue.fromEncodable(policy),
                    "trace_active": .bool(trace.active),
                    "trace_directory": trace.directory.map(JSONValue.string) ?? .null,
                    "save_images": .bool(trace.saveImages),
                    "buffered_events": .int(trace.bufferedEvents),
                    "disk_events": .int(trace.diskEvents)
                ]).prettyJSONString()),
                targetSummary: "session_trace_status"
            )
        case "set_policy":
            let policy = try await SafetyPolicyManager.shared.configure(
                mode: args["policy_mode"]?.stringValue,
                maxActionsPerMinute: args["max_actions_per_minute"]?.intValue
            )
            return ToolExecutionOutput(
                result: .text(try JSONValue.fromEncodable(policy).prettyJSONString()),
                targetSummary: "set_policy(\(policy.mode))"
            )
        case "start_trace":
            let saveImages = args["save_images"]?.boolValue ?? true
            let dir = try await TrajectoryRecorder.shared.startTrace(
                directory: args["trace_dir"]?.stringValue,
                saveImages: saveImages
            )
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "trace_active": .bool(true),
                    "trace_directory": .string(dir),
                    "save_images": .bool(saveImages)
                ]).prettyJSONString()),
                targetSummary: dir
            )
        case "stop_trace":
            let stopped = await TrajectoryRecorder.shared.stopTrace()
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "ok": .bool(true),
                    "trace_active": .bool(stopped.active),
                    "trace_directory": stopped.directory.map(JSONValue.string) ?? .null,
                    "events_written": .int(stopped.eventsWritten)
                ]).prettyJSONString()),
                targetSummary: "stop_trace"
            )
        case "recent_events":
            let limit = args["limit"]?.intValue ?? 25
            let events = await TrajectoryRecorder.shared.recentEvents(limit: limit)
            return ToolExecutionOutput(
                result: .text(try JSONValue.object([
                    "events_count": .int(events.count),
                    "events": try JSONValue.fromEncodable(events)
                ]).prettyJSONString()),
                targetSummary: "recent_events(\(events.count))"
            )
        default:
            throw MacOSUseError.invalidArgument("Unsupported session_trace action '\(action)'.")
        }
    }

    // MARK: - Shared Target Resolution Helpers

    private func resolveElementOrPoint(
        args: [String: JSONValue],
        coordSpace: String,
        fallbackToAppPID: Bool,
        defaultBackgroundPID: Bool,
        allowRawCoordinates: Bool = true
    ) async throws -> (element: StoredElement?, point: CGPoint?, ownerPID: Int32?, windowID: UInt32?) {
        let elementID = args["element_id"]?.stringValue
        let snapshotID = args["snapshot_id"]?.stringValue
        let query = args["query"]?.stringValue
        let role = args["role"]?.stringValue
        var ownerPID = try await resolveAppPID(args: args, fallbackToSnapshot: false)
        var targetWindowID: UInt32? = args["window_id"]?.uint32Value
        var resolvedElement: StoredElement?
        var resolvedPoint: CGPoint?

        if let elementID, !elementID.isEmpty {
            let (snap, elem) = try await SnapshotStore.shared.resolveElement(id: elementID, snapshotID: snapshotID)
            resolvedElement = elem
            resolvedPoint = elem.ui.frame.center.cgPoint
            ownerPID = ownerPID ?? elem.ui.ownerPID ?? snap.ownerPID
            targetWindowID = targetWindowID ?? elem.ui.windowID ?? snap.windowID
        } else if let query, !query.isEmpty {
            let hasExplicitTarget = args["app_name"] != nil || args["bundle_id"] != nil || args["window_id"] != nil
            let cachedSnap = await SnapshotStore.shared.snapshot(id: snapshotID)
            if hasExplicitTarget || cachedSnap == nil {
                let target = try parseTargetScope(args)
                _ = try await PerceptionEngine.observe(target: target, includeImage: false)
            }
            var (snap, matches) = await SnapshotStore.shared.findElements(
                query: query,
                role: role,
                interactiveOnly: false,
                snapshotID: snapshotID,
                limit: 5
            )
            if matches.isEmpty {
                let target = try parseTargetScope(args)
                _ = try await PerceptionEngine.observe(target: target, includeImage: false)
                (snap, matches) = await SnapshotStore.shared.findElements(
                    query: query,
                    role: role,
                    interactiveOnly: false,
                    limit: 5
                )
            }
            guard let best = matches.first else {
                throw MacOSUseError.targetNotFound("No UI element matched query '\(query)'.")
            }
            resolvedElement = best
            resolvedPoint = best.ui.frame.center.cgPoint
            ownerPID = ownerPID ?? best.ui.ownerPID ?? snap?.ownerPID
            targetWindowID = targetWindowID ?? best.ui.windowID ?? snap?.windowID
        } else if allowRawCoordinates, let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue {
            resolvedPoint = try await resolvePoint(x: x, y: y, coordinateSpace: coordSpace)
        }

        if let element = resolvedElement {
            if let ownerPID, let actual = element.ui.ownerPID, ownerPID != actual {
                throw MacOSUseError.targetNotFound("Element belongs to a different application.")
            }
            if let targetWindowID, let actual = element.ui.windowID, targetWindowID != actual {
                throw MacOSUseError.targetNotFound("Element belongs to a different window.")
            }
        }
        if ownerPID == nil && fallbackToAppPID {
            ownerPID = try await resolveAppPID(args: args, fallbackToSnapshot: defaultBackgroundPID, snapshotID: snapshotID)
        }
        return (resolvedElement, resolvedPoint, ownerPID, targetWindowID)
    }

    private func resolveAppPID(args: [String: JSONValue], fallbackToSnapshot: Bool, snapshotID: String? = nil) async throws -> Int32? {
        var pid = args["pid"]?.int32Value
        if args["pid"] != nil && (pid ?? 0) <= 0 {
            throw MacOSUseError.invalidArgument("Expected a positive process ID.")
        }
        if let window = args["window_id"]?.uint32Value {
            guard let owner = try await WindowManager.listWindows(includeSystemLayers: true, onScreenOnly: false)
                .first(where: { $0.windowID == window })?.ownerPID, pid == nil || pid == owner else {
                throw MacOSUseError.targetNotFound("Target window is missing or belongs to another process.")
            }
            pid = owner
        }
        let name = args["app_name"]?.stringValue
        let bundle = args["bundle_id"]?.stringValue
        if pid != nil || name != nil || bundle != nil {
            guard let app = await WindowManager.findRunningApp(pid: pid, appName: name, bundleID: bundle),
                  !app.isTerminated,
                  name == nil || name?.caseInsensitiveCompare(app.localizedName ?? "") == .orderedSame,
                  bundle == nil || bundle?.caseInsensitiveCompare(app.bundleIdentifier ?? "") == .orderedSame else {
                throw MacOSUseError.targetNotFound("The requested application is not running or does not match the target.")
            }
            return app.processIdentifier
        }
        if fallbackToSnapshot, let cached = await SnapshotStore.shared.snapshot(id: snapshotID)?.ownerPID {
            guard let app = await WindowManager.findRunningApp(pid: cached), !app.isTerminated else {
                throw MacOSUseError.targetNotFound("The observed application has exited.")
            }
            return cached
        }
        return nil
    }

    private func summarizeArgs(_ args: [String: JSONValue]) -> String {
        for key in ["element_id", "query", "file_path", "app_name", "bundle_id", "key", "action", "window_id"] {
            if let val = args[key]?.stringValue, !val.isEmpty {
                return "\(key)=\(val)"
            }
            if let num = args[key]?.intValue {
                return "\(key)=\(num)"
            }
        }
        return "-"
    }

    private func durationMs(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: end)
        let ms = Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) / 1e15
        return max(0, Int(ms.rounded()))
    }

    // MARK: - Parsing & Formatting Helpers

    private func parseTargetScope(_ args: [String: JSONValue]) throws -> CaptureTargetScope {
        let region: ScreenRect?
        if let r = args["region"]?.objectValue,
           let x = r["x"]?.doubleValue,
           let y = r["y"]?.doubleValue,
           let w = r["width"]?.doubleValue,
           let h = r["height"]?.doubleValue
        {
            guard [x, y, w, h].allSatisfy({ abs($0) <= Double(Int32.max) }), w > 0, h > 0 else {
                throw MacOSUseError.invalidArgument("Invalid capture region.")
            }
            region = ScreenRect(x: x, y: y, width: w, height: h)
        } else {
            region = nil
        }

        return try PerceptionEngine.resolveTargetScope(
            scope: args["scope"]?.stringValue,
            windowID: args["window_id"]?.uint32Value,
            appName: args["app_name"]?.stringValue,
            bundleID: args["bundle_id"]?.stringValue,
            displayID: args["display_id"]?.uint32Value,
            region: region
        )
    }

    private func parseImageFormat(_ raw: String?) -> CaptureImageFormat {
        switch (raw ?? "jpeg").lowercased() {
        case "png": return .png
        default: return .jpeg
        }
    }

    private func resolvePoint(x: Double, y: Double, coordinateSpace: String) async throws -> CGPoint {
        switch coordinateSpace.lowercased() {
        case "global", "":
            return CGPoint(x: x, y: y)
        case "image":
            guard let transform = await SnapshotStore.shared.currentTransform() else {
                throw MacOSUseError.targetNotFound(
                    "coordinate_space='image' requires a prior observe_screen, inspect_ui, or screenshot call."
                )
            }
            return transform.imagePixelToGlobal(x: x, y: y)
        default:
            throw MacOSUseError.invalidArgument("Unsupported coordinate_space '\(coordinateSpace)'. Expected 'global' or 'image'.")
        }
    }

    private func writeDataToPath(_ data: Data, path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func elementToJSON(_ ui: UIElement) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(ui.id),
            "index": .int(ui.index),
            "role": .string(ui.role),
            "label": .string(ui.label),
            "center_x": .double(ui.centerX),
            "center_y": .double(ui.centerY),
            "frame": .object([
                "x": .double((ui.frame.x * 10).rounded() / 10),
                "y": .double((ui.frame.y * 10).rounded() / 10),
                "width": .double((ui.frame.width * 10).rounded() / 10),
                "height": .double((ui.frame.height * 10).rounded() / 10)
            ]),
            "enabled": .bool(ui.enabled),
            "interactive": .bool(ui.isInteractive),
            "source": .string(ui.source.rawValue),
            "confidence": .double(ui.confidence)
        ]
        if let value = ui.value {
            obj["value"] = .string(value)
        }
        if ui.focused {
            obj["focused"] = .bool(true)
        }
        if ui.selected {
            obj["selected"] = .bool(true)
        }
        return .object(obj)
    }

    private func buildScreenSummary(elements: [UIElement]) -> JSONValue {
        let interactiveCount = elements.filter(\.isInteractive).count
        let buttonsCount = elements.filter {
            ["button", "icon_button", "text_button", "close_button", "minimize_button", "zoom_button"].contains($0.role)
        }.count
        let textfieldsCount = elements.filter { $0.role == "textfield" }.count
        let focusedElem = elements.first(where: \.focused)

        var seenTexts = Set<String>()
        var visibleSamples: [JSONValue] = []
        for el in elements {
            let trimmed = el.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != el.role, trimmed != "Icon Button" else { continue }
            if seenTexts.insert(trimmed).inserted {
                visibleSamples.append(.string(String(trimmed.prefix(80))))
                if visibleSamples.count >= 15 { break }
            }
        }

        return .object([
            "interactive_count": .int(interactiveCount),
            "buttons_count": .int(buttonsCount),
            "textfields_count": .int(textfieldsCount),
            "focused_element": focusedElem.map {
                .object(["id": .string($0.id), "role": .string($0.role), "label": .string($0.label)])
            } ?? .null,
            "visible_text_sample": .array(visibleSamples)
        ])
    }
}
