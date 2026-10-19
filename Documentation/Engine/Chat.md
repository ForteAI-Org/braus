# CLI chat

Braus can use the installed, signed-in Claude Code or Codex CLI as its reasoning
provider. The provider calls Braus through MCP; perception and input stay in the
Braus process. This does not connect to or import conversations from the ChatGPT
website.

## Use

```sh
.build/debug/braus --chat --allow-unvalidated-build
```

Choose a saved conversation or a new one, then choose the provider and model.
Claude offers its default plus Sonnet/Opus aliases and custom model names.
Codex offers its default plus visible models from its local model cache and custom
model names. The provider validates availability; a cache entry is not a guarantee.

A quoted prompt starts the conversation immediately:

```sh
.build/debug/braus --chat "Inspect Pro Tools and tell me which window is open" \
  --provider claude --model sonnet --allow-unvalidated-build
```

In an interactive terminal this continues as a chat. For one turn and exit:

```sh
.build/debug/braus --chat "Inspect Pro Tools without changing anything" \
  --provider codex --once --allow-unvalidated-build
```

Saved conversations:

```sh
.build/debug/braus --chat --list
.build/debug/braus --chat --resume last --allow-unvalidated-build
.build/debug/braus --chat --resume <conversation-UUID> --allow-unvalidated-build
```

A script runs its requests one conversation each, on one archive, with the Seat
and the application session released between requests, so each starts from the
applications as they are, with the knowledge the earlier ones left in the memory:

```sh
.build/debug/braus chat --script tasks.txt --provider claude --model haiku \
  --knowledge /private/tmp/braus-live/AppSupport/Knowledge \
  --preflight expected.json --evidence /private/tmp/braus-live/Evidence/run-1
```

`tasks.txt` holds blocks of lines separated by empty lines; `#` starts a comment;
a block whose first line starts with `>` continues the previous conversation
instead of opening a new one (a request that depends on the one before it).
`expected.json` names the keys of `memory_task status` the run depends on
(`archive`, `recall.channel`, `recall.model`, `recall.owns_index`, …): the process
answers before any turn and a difference stops the chat. The evidence folder keeps
the preflight's answer and, per request, the conversation as saved, the tasks it
named, each task's diagnosis as `braus memory --task` prints it, and a summary with
the times, the outcome and the request's token counts (every provider run of it added:
the interpretation reminder is a second run). A failed request stops the script unless
`--continue`. A reopening of Braus between two requests is two runs of the script
command on the same archive.

The summary (`NN/summary.json`) says in fields what a run of many tasks needs, so it
never parses a message. New fields are added; none is renamed or removed.

| Field | What it says |
| --- | --- |
| `outcome` | `ok`, `error`, or `interrupted` (stopped by a signal) |
| `failure` | null, or `{source, kind, retryable, …}`: `source` is `provider` (with `kind` among `rate_limited`, `auth`, `unavailable`, `api_error`, `turn_error`, `no_result`, `exited`, `malformed`, read from the provider's fields, and `api_status`, `subtype`, `exit_status`, `resets_at`), `signal` (with `signal`), or `braus` |
| `task_states` | per task the request named: `status`, `versions`, `candidates`, `uninterpreted`, `result` (Braus's verdict from the checks it read: `passed`, `failed`, `unknown`, `none`, `missing`) and `guards_failed` |
| `braus_closed` | the task Braus closed as abandoned because the conversation did not end it, and whether the archive recorded it |
| `braus_interpreted` | the candidate of a completed task Braus interpreted itself because the agent left it uninterpreted after its reminder (`ProcedureProducer.brausInterpretation`) |
| `tool_calls` | the agent's own calls, Braus's status and closing calls left out |
| `repeated_calls` | the longest run of identical consecutive calls and its tool: shown, never acted on |
| `rate_limits` | the provider's usage windows, when it reported them |

The process exits 0 when every request succeeded, 3 when the script stopped on a provider
failure, 1 on any other failure, and 128 plus the signal's number when stopped (130 for
SIGINT, 143 for SIGTERM). Before it ends, the Recall's index takes what the requests
learned (`RecallService.waitAllIdle`, at most 10 s), so the next process finds it; a
search also catches the index up first (`RecallService.catchUp`, at most 5 s).

Inside chat: `/model`, `/status`, `/memory` (the archive this process records into
and the Recall it runs, as `memory_task status` answers), `/release`, `/help`, `/quit`.
Ctrl+C or SIGTERM stops further tool calls, cancels the provider, drains the
active tool operation, releases the Seat and saves an interrupted entry. In a script,
whose task no one resumes, the stop first closes the open task as abandoned with the
signal as its note, writes the request's evidence and saves the memory: a run stopped
at its time limit left the task open and no summary until 14 October 2026. An
interactive chat keeps the task open for `--resume`.

The explicit research flag is still required on a macOS build not validated by
the Driver ledger. It is never inferred from a prior chat or silently enabled.
Likewise, `--allow-destructive` belongs to this invocation, not the saved model context.

## Architecture

- **ChatCore:** provider/turn/event/conversation values. No process, MCP, storage,
  AppKit, perception or Driver dependency.
- **CLIProviders:** argv construction, Claude/Codex JSONL decoding, streaming
  child process ownership and cancellation. No shell command interpolation.
- **FileConversations:** private atomic transcripts and exclusive conversation leases.
- **LocalMCP:** JSON-RPC stdio bridge, authenticated ephemeral loopback host and
  serialized tool router. No application behavior.
- **AutomationRuntime:** the shared engine composition and the living memory. Ordinary
  CLI actions and chat use the same EngineRuntime.
- **SeatBroker:** the chat's application session is the app's,
  `BrokeredAutomationSession` over a `SeatBroker` of the chat process, as the app's
  workers and the benchmark server compose it: `apps` lists the installed applications,
  `open_session` launches one that is not running on the Seat's display and records that
  the agent opened it, the Seat is held for the whole turn and kept warm between turns,
  and the run's frames go to `Runs` beside the knowledge. So what the agent can open in
  the chat is what a worker can open in the app.
- **AutomationMCP:** validation, tool schemas and result formatting over
  `AutomationSessionOperating`. No provider, terminal or conversation-store dependency.
- **CLI composition:** menus, signals, paths, explicit policy flags and the event
  wiring between modules.

The chat process owns one host. Each provider turn may launch a fresh
`braus mcp-bridge` process, which only forwards MCP messages to that existing host.
It never starts another capture pipeline or Seat. The app launches the same bridge
from `braus-bridge`, a helper that holds only the bridge and depends on LocalMCP
alone, so the app does not carry the whole command line.

The internal bridge uses authenticated newline-framed JSON on an ephemeral
127.0.0.1 port. It is not a public Streamable HTTP endpoint. The external provider
interface is standard MCP over stdio. A private temporary file carries the
connection credential, and is removed at shutdown.

Only one CLI chat host per user runs at a time, even with different transcript
directories. Within that host, concurrent tool effects are refused rather than
interleaved. The first version controls one application session at a time.
A provider process disconnect between turns does not release the Seat.

## Tools and results

`status`, `windows`, `apps`, `open_session`, `observe`, `act`, `select`,
`type_text`, `insert_text`, `press_key`, `scroll`, `drag`, `context_menu`,
`menu`, `press`, `batch`, `close_session`. CLI chat and the signed Braus app
share these definitions and their validation.

`app_capabilities` and `app_call` reach an app's adapter (`AppAdapters`) with
no session, and exist only where the composition passes the adapters to
`AutomationTools`: the app does for its workers and external clients, CLI chat
does not. An irreversible verb (`mail.send`, `messages.send_message`,
`calendar.delete_event`, `files.move_to_trash`) runs only when the person
allows that one call: `AppAdapters` asks its approver (`AdapterApproving`)
with what the call would do (recipient, subject and first lines of a mail,
an event's title and date, a path), after the read-back contract and the
availability pass. The app's approver is the team window's approval sheet
(`AdapterApprover` over `AdapterApprovals`: Allow Once only, buttons inert
for a second, refused after two minutes); a no, a timeout or a cancelled
call is refused with nothing done, an allowed call runs once and is never
retried. A composition without an approver, CLI chat included, refuses
every irreversible verb. An `app_call` whose adapter stands for the app the
session holds on the seat (`memoryApplication`, among the adapter's bundle
ids) is refused with nothing done, telling the model to finish with the
interface and `close_session` first or to use one route for the whole task;
the files adapter is exempt, since its verbs are file operations a Finder
window on the seat neither holds nor reads back. Only the calling session's
own hold counts. An `app_call` keeps the values of its
verb's content parameters out of its record and transcript, and a verb's
content results out of the transcript line of its answer.

The verb runs off the main actor (`AppAdapters.call` is `@concurrent`), so a
script, a contacts fetch, the Messages history read or the `defaults` process
never stalls the app; its call line is transcribed before it runs and its
answer line after, so a host shows it running meanwhile. Every AppleScript
runs on one serial queue (`ScriptQueue`), one at a time, and each fixed
script bounds its Apple events with `with timeout` (Mail 30 seconds, Notes'
search 30, the rest 15), so a hung app answers a timeout rather than holding
the queue.

With the adapters, `open_session` takes `named` and asks the `TaskRouter`
first: the session resolves the app's name to a bundle id as `open` would
(the broker through `ApplicationOpening.resolve`, so a name in the person's
language counts), and an app the `RouteCatalogue` gives an adapter (Calendar,
Reminders, Notes, Finder, System Settings, Mail) is answered with that adapter
and not opened, unless the person named the app, the seat already holds it, or
the adapter cannot run. The answer says to call `open_session` again with
`named` true when none of the adapter's verbs does the task.

Action tools require the ephemeral session ID returned by open_session.
Observations carry a revision, capture report time, and the current text scene,
or its `changes` since an earlier revision (`since`) of the same window.
The existing engine observes afresh before acting; saved observations are not
coordinates or authority for later input.

A result carries its value once, as the JSON text of one content item. No tool
declares an output schema, so there is no `structuredContent` copy, which a
client that shows both made the model read twice. AutomationMCP keeps the last
scene the model read of up to eight windows, by the seat's window number or else
by bundle ID and title; an untitled window of the same size is taken for the
titled one it was. An action's or `observe`'s scene of such a window is sent as
`SceneChanges` when they are under half the scene's size. `open_session` and
`observe` with `full: true` send the whole scene. The baselines are forgotten at
each turn, when the session ends, and left as they were by a call whose answer
never reached the model.

`SceneChanges` matches elements by identity and writes them in the lines of
`text()`, which prints sections and their elements in reading order so one screen
renders one text. Two readings of one screen still differ in their sections (pixel
seams move with the text that protects them, and a header read differently renames
a panel and renumbers each `region N`) and in learned group tags, so the update
ignores those, element order, and moves of elements and panel edges under 2% of
the window. An element now in another section is reported while its old section
name still exists, since `section:` targets by it; a section name that is gone is
reported once, in the new section lines.

Replayed over one recorded Codex session on Resolve and Slack (89 Braus tool
results, 72 of them scenes, with no window numbers), the results come to 279
thousand characters against the 820 thousand that session printed; dropping the
duplicate alone gives 412 thousand. Half the scene stays the cut: two thirds turned
three more scenes into changes and saved 5% of the scene characters.

Batch validates all steps before starting, executes at most 20 act/select/input steps,
and stops on the first failed/ambiguous/unverified result. Earlier effects remain.
A verified toggle already in its desired state may continue. No action is
automatically replayed after a provider failure.

The host follows new application windows using the Driver's existing window
tracking. Dropdown selection uses the same native/custom dropdown selector as
the terminal command. Tool results preserve the Engine's outcome vocabulary,
including honest_miss, ambiguous and acted_unverified.

`type_text` resolves and focuses a named field. `insert_text` keeps a focus and
selection already established, including a dialog's initially selected name,
and inserts one intact payload. Only exact native focused-field readback against
an explicit complete `expected_value` verifies that insertion. An opaque field
remains unverified; batch stops before a subsequent Return. A separately
authorized commit must be followed by verification of its actual effect.
There is no foreground fallback. Multi-app concurrent control and remote
ChatGPT connections remain separate work.

## Permissions and provider access

Run from the terminal that has the necessary macOS permissions. This CLI phase
does not solve the signed application identity/deployment work. Opening a Seat
checks Screen Recording, Accessibility and posting access, as the app does: a
missing one is asked for, so macOS may show its prompt for the terminal, and the
open is refused with a sentence that names the terminal launching Braus as the
one to allow. The model cannot grant it.

Claude runs with built-in tools disabled, strict MCP configuration and only
Braus tools allowed. Codex ignores user MCP configuration, disables shell, browser,
computer-use and image tools,
uses a read-only sandbox, and explicitly authorizes the Braus server's tools.
Neither adapter uses a global permission/sandbox bypass. Managed provider policies
can still refuse a request.

Normal chat sends the user's prompts and Braus's textual tool results to the
selected provider. Screenshots are not sent by this interface. Provider sign-in
credentials remain with the provider CLI.

## Persistence

Default transcripts:
`~/Library/Application Support/Braus/Conversations/<UUID>.json`

Use `--history-dir` to override transcript storage. A transcript includes provider,
model, native provider session ID, user messages, assistant text, tool requests and
results, and interruptions/errors. Connection credentials are excluded. Files are
private (0600) under a private directory (0700), and updates replace files atomically.

Provider-native conversation history supplies actual continuation context.
The local transcript is an inspectable record, not a fabricated replacement for a
missing provider session. A failed resume is reported; there is no silent fresh
conversation or automatic replay. After restarting Braus, old Seat IDs are invalid.

## Verification

Local tests cover provider argv/stream parsing, complete-vs-truncated responses,
concurrent pipe draining, process cancellation, MCP authentication/reconnection,
serialized calls and draining, transcript round trips/locks, CLI parsing, and the
script's requests, task ids and preflight differences (`ChatScriptTests`).

Real signed-in provider tests are opt-in and return only invented MCP data.
They do not enumerate or capture real apps:

```sh
BRAUS_SYNTHETIC_PROVIDER_TESTS=1 \
BRAUS_TEST_BRIDGE="$PWD/.build/debug/braus" \
swift test --filter SyntheticProviderTests
```

These checks verify two provider turns, real MCP tool calls and exact native
session resumption with a remembered test phrase. They do not prove a live
Pro Tools or Premiere workflow through the model.
