# Braus documentation

Start with the app setup below, or choose a guide:

- [MCP setup](Engine/LocalMCP.md): connect Claude Code, Codex or another local client.
- [Compatibility and limitations](LaunchCompatibility.md): supported frameworks and workflow checks.
- [Driver](Driver/README.md): virtual displays, window placement and input routing.
- [Perception](Perception/README.md): turn the current interface into structured text.
- [Engine](Engine/README.md): resolve actions, check effects and use app knowledge.
- [Optional automation routes](Engine/README.md#channels-beyond-the-seat): native Mac controls, Chrome and local app adapters.
- [Chrome setup and profiles](Engine/WebDriver.md#chrome-profiles-and-setup): connect a Chrome profile or use Braus's own browser.
- [Benchmarks](Driver/reports/CUADriverBenchmark20261013.md): 13 October results, method and per-operation data; [6 October report](Driver/reports/CUADriverBenchmark20261006.md).

## Get started

Braus runs on macOS 15+ on Apple silicon and Intel.

1. Install and open `Braus.app`.
2. Create a worker and connect a supported model. If you use Codex or Claude Code, keep their CLIs up to date to access the latest models available to your account.
3. Grant the [Mac access](#permissions-and-data) needed for the features you use.
4. Give the worker a small task in a disposable document. Name the app, the intended result and where it should stop. Follow the activity and inspect the result.

For a first task, ask the agent to read an open TextEdit test document and summarize it without editing or saving.

To use an external assistant, keep Braus open on the same Mac and follow the [local MCP setup guide](Engine/LocalMCP.md). To build from source, follow the [developer Quickstart](../QUICKSTART.md).

## Brain

Brain builds a map of an app's controls, relationships and transitions from observations and action evidence. This gives the agent context about how the app works.

The map adds context to a fresh observation. The engine still finds targets in the current interface and checks what changed after acting. See the [Engine's memory integration](Engine/README.md#using-it) and [contracts](Engine/README.md#contracts) for the implementation.

## Memory

Memory records interactions, outcomes and learned procedures in a local SQLite archive. A procedure can combine verified interface actions, adapter operations and reads whose results later steps need. Recalled steps use the current task's inputs and the current run's results; missing or ambiguous values remain explicit. The agent still resolves controls in the live interface and checks the result. Recall is still in development and can be inconsistent. See [mixed procedures](Engine/MemoryProcedures.md#adapter-steps-and-typed-reuse) and the [recall contract and limits](Engine/MemoryRecall.md).

Braus workers, local MCP clients and the CLI share the user's local app knowledge and living memory. Each MCP client's task stream remains private to its grant. This is local sharing on the same Mac, not cross-device or team sync. Workspace history remains separate. See [local MCP scope](Engine/LocalMCP.md#scope-and-lifecycle) and the [shared archive contract](Engine/MemoryFacts.md#one-archive-per-user).

## Permissions and data

Grant access for the features you use:

| Access | Purpose |
| --- | --- |
| Accessibility and Screen Recording | Desktop interface reading and control, where the selected route needs them. |
| Calendar, Reminders and Contacts permissions | The corresponding local adapters; granted through macOS when requested. |
| Automation permissions | Apple-event access for local app adapters where required. |
| Full Disk Access | Messages send read-back requires access to its history; without that evidence, the send is refused. |
| Chrome profile connection | Explicit pairing with the Braus extension when using a chosen Chrome profile. |
| Input Monitoring | Separate passive diagnostics when explicitly started; not a Watcher capability of the local MCP grant. |

The app sends anonymous usage metrics (tool names, outcomes and durations, with a random installation ID) unless you turn them off; [Telemetry](Telemetry.md) lists everything sent and how to stop it.

When adapters are enabled, **Settings → Apps** shows availability and permission requests. Granting an app permission does not enable its automation channel. Some irreversible adapter actions also require approval for that individual call. The app can ask for this approval; CLI chat has no approver and refuses those actions.

The desktop window-to-text pipeline runs on your Mac. A remote model can receive window text, task context and relevant app knowledge. Other tools, including browser tools, can return screenshots; the data sent depends on the tools and model connection used.

Content withheld from saved records can still be present in live tool answers sent to the model. The documented policy covers specific apps and sites; it is not a universal guarantee that sensitive content stays on the Mac.

The local MCP bridge does not make model inference local. Choose the capabilities for each client and use [MCP access controls](Engine/LocalMCP.md#scope-and-lifecycle) to stop or revoke a connection.

You can follow activity and stop a worker in Braus. Stopping does not undo actions already delivered; inspect the app before continuing. Read [background work](LaunchCompatibility.md#background-work) for session limits.
