# macos-use

Give a local MCP client control of native macOS apps. The server uses Accessibility to read controls, ScreenCaptureKit and Vision to inspect custom-drawn interfaces, and Quartz to send mouse and keyboard events. It runs over stdio and also includes a CLI and the Swift library `MacOSUseKit`.

## Install with Homebrew

On Apple Silicon with macOS 27 or later:

```sh
brew install yeoleobun/tap/macos-use
macos-use status
```

For Antigravity, run `agy mcp add macos-use "$(brew --prefix)/bin/macos-use" mcp`. For other clients, use this stdio configuration with the default Apple Silicon Homebrew prefix:

```json
{
  "mcpServers": {
    "macos-use": {
      "command": "/opt/homebrew/bin/macos-use",
      "args": ["mcp"]
    }
  }
}
```

For a custom Homebrew prefix, replace the command with the absolute path printed by `brew --prefix` followed by `/bin/macos-use`. The [GitHub release](https://github.com/yeoleobun/macos-use/releases/latest) also contains the arm64 binary and its SHA-256 checksum.

## Install from source

Use an Apple Silicon Mac running macOS 27 or later with Swift 6.4 or later. Check the toolchain with `swift --version`. If Swift is missing, install the Command Line Tools with `xcode-select --install`.

Download and unpack the source release or clone the repository. From the directory containing `Package.swift`, run the following commands in Terminal.

```sh
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/macos-use "$HOME/.local/bin/macos-use"
codesign --force --sign - --identifier com.macosuse.mcp "$HOME/.local/bin/macos-use"
"$HOME/.local/bin/macos-use" status
```

The installed executable works independently of the source directory. Repeat these steps to upgrade, then restart the MCP client.

## Connect an MCP client

For a source installation, register the executable with Antigravity.

```sh
agy mcp add macos-use "$HOME/.local/bin/macos-use" mcp
agy mcp list
```

For clients using a JSON `mcpServers` configuration, merge the entry from [mcp_config.example.json](mcp_config.example.json) into the client's settings and restart it. The example uses the current account's home directory and works with spaces in its path. Clients with separate command and argument fields can also use the full absolute path to the installed executable and the single argument `mcp`.

## Permissions and first use

Call `system_status` from the connected client to check the permissions of the process actually running the server. In System Settings → Privacy & Security, grant Accessibility for input and the accessibility tree, and Screen & System Audio Recording for screenshots and OCR. Grant access to the executable or launching app identified by macOS, restart that client, and check status again. To request the Accessibility prompt from Terminal, run `"$HOME/.local/bin/macos-use" doctor --prompt-ax`.

1. Open Calculator. Call `list_apps_and_windows` with `{"app_filter":"Calculator"}`.
2. Call `observe_screen` with the returned `window_id` to get an annotated image and indexed controls.
3. Pass the returned `snapshot_id` and a control's `element_id` to `click`. Check `verification.ui_changed` and observe again if the result is uncertain. A dispatched click is performed once per request, subject to the requested click count.

Use `background: true` for app-targeted Accessibility or PID-directed input. Some custom controls require foreground input. Use `focus_mode: "restore"` for a foreground interaction that returns focus to the previous app. Native file selection requires a recognizable open/save panel and Go to Folder field.

## Tools

| Purpose | MCP tools |
| --- | --- |
| System and windows | `system_status`, `list_apps_and_windows`, `manage_app`, `virtual_display` |
| Perception | `observe_screen`, `inspect_ui`, `find_elements`, `screenshot`, `wait_for_ui` |
| Input | `click`, `move_mouse`, `drag`, `type_text`, `press_key`, `scroll`, `scroll_to_element` |
| Native controls | `menu_action`, `widget_action`, `handle_dialog`, `clipboard` |
| Diagnostics and action policy | `session_trace` |

The server exposes 21 tools and negotiates MCP version `2025-03-26`. Trace recording can save screenshots and action metadata to disk when enabled. Virtual display support depends on runtime availability of macOS display classes.

## CLI and tests

```sh
"$HOME/.local/bin/macos-use" help
"$HOME/.local/bin/macos-use" windows --app Calculator
"$HOME/.local/bin/macos-use" observe --app Calculator --output /tmp/calculator.jpg
```

Run the test executable from the source directory after the release build. It exercises AppKit, Vision, and window services and requires a logged-in macOS desktop session.

```sh
.build/release/macos-use-tests
```

## License

[BSD Zero Clause License](LICENSE).
