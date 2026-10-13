# Braus documentation

Start with the app setup below, or choose a guide:

- [MCP setup](Engine/LocalMCP.md): connect Claude Code, Codex or another local client.
- [Compatibility and limitations](LaunchCompatibility.md): supported frameworks and workflow checks.
- [Driver](Driver/README.md): virtual displays, window placement and input routing.
- [Perception](Perception/README.md): turn the current interface into structured text.
- [Engine](Engine/README.md): resolve actions, check effects and use app knowledge.
- [Benchmarks](Driver/reports/CUADriverBenchmark20261013.md): 13 October results, method and per-operation data; [6 October report](Driver/reports/CUADriverBenchmark20261006.md).

## Get started

Braus runs on macOS 15+ on Apple silicon and Intel.

1. Install and open `Braus.app`.
2. Create a worker and connect a supported model. If you use Codex or Claude Code, keep their CLIs up to date to access the latest models available to your account.
3. Grant the [Mac access](#permissions-and-data) needed for the features you use.
4. Give the worker a small task in a disposable document. Name the app, the intended result and where it should stop. Follow the activity and inspect the result.

For a first task, ask the agent to read an open TextEdit test document and summarize it without editing or saving.

To use an external assistant, keep Braus open on the same Mac and follow the [MCP setup guide](MCPSetup.md). To build from source, follow the [developer Quickstart](../QUICKSTART.md).

## Brain

Brain builds a map of an app's controls, relationships and transitions from observations and action evidence. This gives the agent context about how the app works.

The map adds context to a fresh observation. The engine still finds targets in the current interface and checks what changed after acting. See the [Engine's memory integration](Engine/README.md#using-it) and [contracts](Engine/README.md#contracts) for the implementation.

## Memory

Memory records interactions, outcomes and learned procedures in a local SQLite archive. Recall can suggest steps from earlier work for a new task; the agent still resolves controls in the live interface and checks the result. Recall is still in development and can be inconsistent. See the [recall contract and limits](Engine/MemoryRecall.md).

Braus workers, local MCP clients and the CLI share the user's local app knowledge and living memory. Each MCP client's task stream remains private to its grant. This is local sharing on the same Mac, not cross-device or team sync. Workspace history remains separate. See [local MCP scope](Engine/LocalMCP.md#scope-and-lifecycle) and the [shared archive contract](Engine/MemoryFacts.md#one-archive-per-user).

## Permissions and data

Grant access for the features you use:

| Access | Purpose |
| --- | --- |
| Accessibility | Read interface elements and enable desktop control. |
| Screen Recording | Capture windows for Perception. |
| Input Monitoring | Enable passive watching when explicitly selected. |
| Chrome connection authorization | Allow browser tools to use the connected Chrome instance. |

The desktop window-to-text pipeline runs on your Mac. A remote model can receive window text, task context and relevant app knowledge. Other tools, including browser tools, can return screenshots; the data sent depends on the tools and model connection used.

The local MCP bridge does not make model inference local. Choose the capabilities for each client and use [MCP access controls](MCPSetup.md#multiple-clients-and-stopping-access) to stop or revoke a connection.

You can follow activity and stop a worker in Braus. Stopping does not undo actions already delivered; inspect the app before continuing. Read [background work](LaunchCompatibility.md#background-work) for session limits.
