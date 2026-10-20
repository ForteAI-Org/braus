<h1 align="center">Braus</h1>

<p align="center"><strong>Let agents work in your apps while you keep using your Mac.</strong></p>

<p align="center">Braus gives agents a desktop workspace on your Mac. Give a worker a task in the Braus app, or connect Claude Code or Codex through MCP to work in desktop apps, even when they expose neither an API nor an AX tree.</p>

<p align="center">
  <a href="https://github.com/ForteAI-Org/braus/releases/download/v1.1.0-2/Braus-1.1.0-2.dmg"><img src="readme-assets/badge-download.svg" alt="Download Braus 1.1.0-2 for macOS" width="213" height="30" /></a>
  <a href="Documentation/README.md"><img src="readme-assets/badge-docs.svg" alt="Docs" width="94" height="30" /></a>
  <a href="https://discord.gg/SBqrAN9wDg"><img src="readme-assets/badge-discord.svg" alt="Discord" width="125" height="30" /></a>
  <a href="https://x.com/brausai_"><img src="readme-assets/badge-x.svg" alt="Follow Braus on X" width="158" height="30" /></a>
</p>

<p align="center">
  <a href="#license"><img src="readme-assets/badge-apache.svg" alt="License: Apache 2.0" width="180" height="30" /></a>
  <a href="Package.swift"><img src="readme-assets/badge-swift.svg" alt="Swift 6.4" width="116" height="30" /></a>
</p>

## See Braus in action

<div align="center">

https://github.com/user-attachments/assets/83ced839-9b8d-47fe-8e27-f64f53a0d1f7

</div>

## Get started

Braus runs on **macOS 15+**, on **Apple silicon and Intel**. Follow the [installation guide](Documentation/README.md#get-started) to get set up.

1. Install and open Braus.
2. Create a worker, connect a supported model and grant the Mac access needed for desktop work.
3. Start with a small task in a disposable document. Name the app, the result you want and where the agent should stop.
4. Follow the activity and inspect the result in the app.

For your first task, ask the agent to read an open TextEdit test document and summarize it without editing or saving.

If you use Codex or Claude Code, keep their CLIs up to date to access the latest models available to your account.

To build from source with **Swift 6.4**, follow the [developer Quickstart](QUICKSTART.md).

<details>
<summary>Connect Claude Code, Codex or another local MCP client</summary>

<br>

Braus and your client must run on the same Mac. The app includes the STDIO bridge; no Node.js or Python installation is needed.

1. Keep Braus open. In **MCP → MCP Connections…**, name your client, choose its capabilities and click **Add Client**.
2. Turn **Enabled** on and wait for **Ready**.
3. Expand **Client configuration** and use **Copy Claude Code command**, **Copy Codex command** or **Copy JSON**. Prefer these generated values over the templates below.

**Claude Code**

```sh
claude mcp add --scope user --transport stdio braus -- \
  "/Applications/Braus.app/Contents/Helpers/braus-bridge" \
  mcp-bridge --connection \
  "/Users/YOUR_USERNAME/Library/Application Support/Braus/MCP/CLIENT_UUID.connection.json"
```

**Codex**

```sh
codex mcp add braus -- \
  "/Applications/Braus.app/Contents/Helpers/braus-bridge" \
  mcp-bridge --connection \
  "/Users/YOUR_USERNAME/Library/Application Support/Braus/MCP/CLIENT_UUID.connection.json"
```

These are templates. Replace `YOUR_USERNAME` and `CLIENT_UUID` with the values from Braus, and use the generated helper path if the app is elsewhere. Keep paths quoted. Save configurations in personal settings.

Check registration with `claude mcp get braus` or `codex mcp list`. Start a new client session and use `/mcp` to inspect the live connection, then run the [read-only connection check](Documentation/Engine/LocalMCP.md#setup).

Each connection entry accepts one active client. Create separate entries for independently running clients. Never share the contents of `*.connection.json`.

The [local MCP guide](Documentation/Engine/LocalMCP.md) covers generated configurations, access scope and connection lifecycle. Not every client has been tested end to end.

</details>

## What works today

Supported frameworks: **AppKit, Chromium, Electron and Qt**, plus **DFW, DUI and BUI** for [Pro Tools 2026.4+](Documentation/Driver/platforms/ProTools.md#ui-frameworks). UXP support is in development (Adobe apps).

Workers that use the virtual desktop take turns. While one works there, the others wait in line.

Optional routes can work with native Mac controls, Chrome pages and local app adapters. They are enabled separately; available operations depend on the app and its permissions. See [automation routes and setup](Documentation/Engine/README.md#channels-beyond-the-seat).

In this release, we focused on improving background work in Pro Tools, including [track renaming and selection counters](Documentation/Driver/platforms/ProTools.md#live-seat-verification-19-october-2026) and [file dialogs, Send and Output controls](Documentation/Driver/platforms/ProTools.md#save-panel-send-and-output-verification-16-october-2026).

Read the [compatibility and limitations guide](Documentation/LaunchCompatibility.md) for the current scope and how to report a workflow.

## How it works

- **[Driver](Documentation/Driver/README.md):** written in Swift, it moves app windows to a virtual display and routes the agent's input there, so you can keep working on your Mac without a virtual machine.
- **[Perception](Documentation/Perception/README.md):** turns the current interface into structured text and refreshes it as the window changes.
- **[Brain](Documentation/README.md#brain):** builds a map of each app's controls, relationships and transitions, giving agents context about how the app works.
- **[Memory](Documentation/README.md#memory):** keeps interactions, outcomes and learned procedures in a local SQLite archive shared by Braus workers and local MCP clients. Procedures can combine interface actions and adapter calls, using values from the current task. Recall can suggest steps for a new task; the agent still checks the live interface and result. Recall is still in development and can be inconsistent.

Driver, Perception and Engine are [Swift package libraries](Package.swift) you can use in your own macOS apps.

Braus checks what changed after each action. You can follow the activity, review the result and stop the worker from the app.

The desktop window-to-text pipeline runs locally. A remote model can receive window text, task context and relevant app knowledge. Read [Permissions & data](Documentation/README.md#permissions-and-data).

## Benchmarks

Braus's full-scene responses used **67.5–95.4% fewer estimated tokens** than Cua Driver 0.34.0's screenshot + AX tree responses. The median full read was 351 tokens for Braus versus 2,156 for Cua, about **84% lower**.

### Driver comparison

3 measured repetitions after 1 warm-up. Times include the action and updated view, using weighted medians of the per-operation medians on the shared response-completed subset.

<table border="1" cellspacing="0" cellpadding="8">
  <thead>
    <tr><th scope="col" align="left">Application / framework</th><th scope="col">Braus effect checks</th><th scope="col">Cua effect checks</th><th scope="col">Braus step (ms)</th><th scope="col">Cua step (ms)</th></tr>
  </thead>
  <tbody>
    <tr><th scope="row" align="left">TextEdit (AppKit)</th><td>18/24</td><td>12/24</td><td><img src="readme-assets/benchmark-values/value-393.svg" alt="393" width="26" height="20" /></td><td>1,234</td></tr>
    <tr><th scope="row" align="left">Chrome (Chromium)</th><td>12/21</td><td>11/18</td><td><img src="readme-assets/benchmark-values/value-1174.svg" alt="1,174" width="42" height="20" /></td><td>1,535</td></tr>
    <tr><th scope="row" align="left">Obsidian (Electron)</th><td>Unverified</td><td>Unverified</td><td><img src="readme-assets/benchmark-values/value-844.svg" alt="844" width="26" height="20" /></td><td>1,256</td></tr>
    <tr><th scope="row" align="left">Stocks (Mac Catalyst)</th><td>0/9</td><td>0/9</td><td><img src="readme-assets/benchmark-values/value-955.svg" alt="955" width="26" height="20" /></td><td>1,767</td></tr>
    <tr><th scope="row" align="left">kitty (OpenGL/GLFW)</th><td>0/6</td><td>0/9</td><td><img src="readme-assets/benchmark-values/value-978.svg" alt="978" width="26" height="20" /></td><td>1,259</td></tr>
    <tr><th scope="row" align="left">DaVinci Resolve (Qt + GPU UI)</th><td>3/9</td><td>3/9</td><td><img src="readme-assets/benchmark-values/value-384.svg" alt="384" width="26" height="20" /></td><td>1,635</td></tr>
    <tr><th scope="row" align="left">Prism Launcher (Qt 6)</th><td>3/6</td><td>3/6</td><td><img src="readme-assets/benchmark-values/value-412.svg" alt="412" width="26" height="20" /></td><td>1,172</td></tr>
    <tr><th scope="row" align="left">Calculator (SwiftUI)</th><td>6/6</td><td>6/6</td><td><img src="readme-assets/benchmark-values/value-412.svg" alt="412" width="26" height="20" /></td><td>1,227</td></tr>
    <tr><th scope="row" align="left">Safari (WebKit)</th><td>12/18</td><td>9/18</td><td><img src="readme-assets/benchmark-values/value-864.svg" alt="864" width="26" height="20" /></td><td>1,267</td></tr>
    <tr><th scope="row" align="left">Photoshop (Adobe UXP)</th><td>6/8</td><td>0/18</td><td>1,151</td><td>1,168</td></tr>
  </tbody>
</table>

Effect checks show independently confirmed effects / checkable attempts. Unverified means the probe had no readable effect to check. A successful tool response alone does not confirm the action's effect or qualify an entire app.

The Qt rows include Cua's attempted measurements, although its documentation places those scenarios outside declared background support. They cover the tested controls, not general Qt workflows.

See the [full report](Documentation/Driver/reports/CUADriverBenchmark20261013.md) for the method and observed limits.

### Perception context per read

Estimated tokens in the tool response, rather than total tokens for a task with a model:

<table border="1" cellspacing="0" cellpadding="8">
  <thead>
    <tr><th scope="col" align="left">Application / framework</th><th scope="col">Braus full read</th><th scope="col">Braus unchanged</th><th scope="col">Cua full read</th></tr>
  </thead>
  <tbody>
    <tr><th scope="row" align="left">TextEdit (AppKit)</th><td><img src="readme-assets/benchmark-values/value-342.svg" alt="342" width="26" height="20" /></td><td><img src="readme-assets/benchmark-values/value-38.svg" alt="38" width="18" height="20" /></td><td>1,736</td></tr>
    <tr><th scope="row" align="left">Chrome (Chromium)</th><td><img src="readme-assets/benchmark-values/value-399.svg" alt="399" width="26" height="20" /></td><td><img src="readme-assets/benchmark-values/value-38.svg" alt="38" width="18" height="20" /></td><td>3,195</td></tr>
    <tr><th scope="row" align="left">Obsidian (Electron)</th><td><img src="readme-assets/benchmark-values/value-652.svg" alt="652" width="26" height="20" /></td><td><img src="readme-assets/benchmark-values/value-38.svg" alt="38" width="18" height="20" /></td><td>2,866</td></tr>
    <tr><th scope="row" align="left">Stocks (Mac Catalyst)</th><td><img src="readme-assets/benchmark-values/value-621.svg" alt="621" width="26" height="20" /></td><td><img src="readme-assets/benchmark-values/value-38.svg" alt="38" width="18" height="20" /></td><td>3,649</td></tr>
    <tr><th scope="row" align="left">kitty (OpenGL/GLFW)</th><td><img src="readme-assets/benchmark-values/value-80.svg" alt="80" width="18" height="20" /></td><td><img src="readme-assets/benchmark-values/value-38.svg" alt="38" width="18" height="20" /></td><td>1,741</td></tr>
    <tr><th scope="row" align="left">DaVinci Resolve (Qt + GPU UI)</th><td><img src="readme-assets/benchmark-values/value-360.svg" alt="360" width="26" height="20" /></td><td><img src="readme-assets/benchmark-values/value-37.svg" alt="37" width="18" height="20" /></td><td>2,160</td></tr>
    <tr><th scope="row" align="left">Prism Launcher (Qt 6)</th><td><img src="readme-assets/benchmark-values/value-326.svg" alt="326" width="26" height="20" /></td><td><img src="readme-assets/benchmark-values/value-37.svg" alt="37" width="18" height="20" /></td><td>2,151</td></tr>
    <tr><th scope="row" align="left">Calculator (SwiftUI)</th><td><img src="readme-assets/benchmark-values/value-190.svg" alt="190" width="26" height="20" /></td><td><img src="readme-assets/benchmark-values/value-37.svg" alt="37" width="18" height="20" /></td><td>730</td></tr>
    <tr><th scope="row" align="left">Safari (WebKit)</th><td><img src="readme-assets/benchmark-values/value-432.svg" alt="432" width="26" height="20" /></td><td><img src="readme-assets/benchmark-values/value-38.svg" alt="38" width="18" height="20" /></td><td>3,107</td></tr>
    <tr><th scope="row" align="left">Photoshop (Adobe UXP)</th><td><img src="readme-assets/benchmark-values/value-340.svg" alt="340" width="26" height="20" /></td><td>38</td><td>1,047</td></tr>
  </tbody>
</table>

**Full read:** the complete returned view, as structured text for Braus or screenshot + a capped AX tree for Cua. Green values are lower than Cua's full-read result.

**Unchanged:** no changes since the previous step. Braus sends a short confirmation. Cua also has a compact diff path in this run: unchanged values are green only when lower than that diff, detailed in the report. In Photoshop, Cua's diff uses 10 estimated tokens versus Braus's 38.

Test hardware: Apple M4, 16 GB RAM, macOS 27.0.1 (26A434). Estimated context is not billed cost or complete-task savings.

[Read the method, results and per-operation data →](Documentation/Driver/reports/CUADriverBenchmark20261013.md) · [6 October benchmark](Documentation/Driver/reports/CUADriverBenchmark20261006.md)

## Contribute

We welcome help with Qt driver coverage, UXP and Flutter support, missing Perception controls, and feedback on Brain and Memory as you use apps. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and [GitHub Issues](https://github.com/ForteAI-Org/braus/issues).

For questions and workflows, join [Discord](https://discord.gg/SBqrAN9wDg).

## License

[Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0), Copyright 2026 Forte Audio S.r.l.
