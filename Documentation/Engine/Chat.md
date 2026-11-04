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

Optional native, web and adapter routes are selected explicitly. With no `--channels` option,
chat uses the virtual desktop alone:

```sh
.build/debug/braus chat --channels native,web,adapters
```

The CLI's web route uses its own headless Chrome profile; it does not join a personal or paired
profile from the app. Adapter verbs that require one-call approval are refused because CLI chat
has no approval interface. See [channel configuration](README.md#advanced-channel-configuration).

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
`expected.json` names the keys of the host runtime identity the run depends on
(`archive`, `recall.channel`, `recall.model`, `recall.owns_index`, …): the process
answers before any turn and a difference stops the chat. The evidence folder keeps
the preflight's answer and, per request, the conversation as saved, the tasks it
named, each task's diagnosis as `braus memory --task` prints it, and a summary with
the times, the outcome and the request's token counts (every provider run of it added:
the interpretation reminder is a second run). A failed request stops the script unless
`--continue`. A reopening of Braus between two requests is two runs of the script
command on the same archive.

The host identity is independent of the model tool catalogue. Preflight reads the host directly;
it never calls or exposes `memory_task`. The identity retains `archive`, `recall` and the profile
reported by the composition. Its `runtime` object has `contract: braus-t2-single-path`, wired
`features`, `served_tools`, `tool_schema_sha256`, `tool_loading`, `guide_scope`,
`pending_experiments` and session-scoped
`tool_attempts`. Expectations can compare those fields before any provider request. A difference
stops the run; a matching declaration does not establish functional acceptance.

Each request writes `NN/runtime.json` with that runtime object. `tool_attempts` counts attempts over
the session lifetime, including refused attempts; it is not evidence of successful execution or
observed effects. Use the transcript and independent task checks to establish increment coverage.
The catalogue, actual execution and resulting evidence must agree; selecting a build is not a
substitute for those checks.

Product behavior is the delivered task cycle, prompt, compact results, Recall, batch policy,
structured pre-turn facts, state collection and uncertainty handling. There is no profile map for
selecting previous implementations. Authority, memory permissions, archive resources and supported
transport capabilities remain composition inputs. There are no runtime implementation switches. Individual gestures exclude `expect`; row and batch
expectations remain available. Scene differences use the bounded anchor/last-base policy with a
75 percent limit. `pending_experiments` stays empty for evidence-format compatibility. Scientific
comparisons use distinct patched sources and frozen builds, never a profile option. The preflight
hashes the actual served tool schema with sorted JSON keys and unescaped slashes before provider work.

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
and the Recall it runs, through the same host identity used by preflight), `/release`, `/help`, `/quit`.
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
  child process ownership and cancellation. No shell command interpolation. The
  command lines' own web searches and page reads become tool records
  (`WebToolRecords`), through the withholding the host passes (M07).
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

`ToolList` freezes the initial core and the composition's authority level. The core is
`open_session`, `observe`, `act`, `type_text`, `press_key`, `menu`, `batch`, `plan`, `end`, `find`, `call`.
Observe-only profiles serve their permitted subset. `find` searches the permitted catalogue and
returns complete schemas; `call` resolves the actual name before admission, validation and recording.
The dispatcher validates against the complete callable catalogue independently of the advertised
list. Mutating schemas include the task cycle's optional `step`; routing consumes it before provider
invocation. The group index comes from that same permitted catalogue.

Additional capabilities such as `status`, `windows`, `apps`, `select`, `insert_text`, `scroll`, `drag`,
`context_menu`, `press` and `close_session` are discovered and invoked through `find`/`call`. A known
capability can be invoked through `call` without repeating discovery. Directly naming an unadvertised
tool is refused. The product has no native provider-search adapter or loading selector: every provider
receives the same core and uses find/call. Runtime evidence retains `tool_loading: upfront` as a fixed
format field, not a configuration input. Native discovery remains an uncompleted EA5 study requiring
an attested client and separate source/build artifacts for full-list, native-search and find/call
comparisons. A synthetic invocation test is not evidence of native-client support.

`plan` opens or revises task rows and delivers compact procedure offers; gestures refer to their row
with `step`, and `end` closes the task with result checks. Internal after-turn learning does not depend
on a model call to the removed task API. `human_step` is absent from every model list.

A `.capabilityStep` uses `CapabilityCallRecorder` and schema 22: the start commits before effects and an
unsaved end suspends memory. Schema 19 returns typed unavailable failures; writes do not execute and
reads declare the recording gap. The delivered migration exposes the current schema only after its
shape has been verified. Historical schema identities remain meaningful for reading stored evidence.

`app_capabilities` and `app_call` reach an app's adapter (`AppAdapters`) with
no session, and exist only where the composition passes the adapters to
`AutomationTools`: the app and CLI chat do so when the `adapters` channel is enabled. CLI chat
does not install a per-call approver. An irreversible verb (`mail.send`, `messages.send_message`,
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
window on the seat neither holds nor reads back. Holds in other sessions of the same process are checked too (`SeatHolds`); a conflicting
adapter call is refused before it runs. An `app_call` keeps the values of its
verb's content parameters out of its record and transcript, and a verb's
content results out of the transcript line of its answer. Content is what a
person writes, reads or is called: a file's text, a mail's addresses, subject
and text, a message and its recipient, a note, a contact's name, phones,
addresses and birthday, an event's or a reminder's title, location and notes,
and the queries that search them. A content result key (`contentResults`) is
matched by name at any depth, so a list of messages withholds each subject;
ids, dates, states and counts stay. The call's content texts are also
withheld wherever its record repeats them, such as a message naming the note
it just created.

The model receives an adapter's compact text (`AdapterText`) and its structured result
(`structuredContent`). The app's tool loop preserves both. The call record and transcript apply
their separate minimization policy; that policy does not remove content from the live answer. The first line is the outcome's word (`ok`,
`unverified`, `noop`, `miss`, `ambiguous`, `refused`) and the message; a
top-level text the message already says whole is not repeated. Each field is
a `key: value` line, numbers and booleans bare, ISO 8601 instants as
`MM-DD HH:mm` in the Mac's time zone (the year first outside the current
one), a nested object's fields as `key.field`. A list of objects is one
`key: [k1, k2]` header and one `[v1, v2]` row per item, values separated by
`, `, `-` for a missing value, `\,`, `\]`, `\\` and `\n` inside a value (so
`Report 2026.md` stays one value); in a folder's listing, paths under the folder
are relative to it. A text with a line break, or longer than 120 characters,
comes last after its `key:` line, as it is. `app_capabilities` answers one
line for the adapter and its availability, each argument's meaning once, then
one line per verb, `adapter.verb argument optional? — summary [safety]`. The
`app_call` description states the format once (`AdapterText.legend`). On the
files dump scenario the text takes about half the JSON's bytes (capabilities
1,953 against 5,736).

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

Action tools use the host's current session implicitly. A stale session operand cannot select or
reopen another session, and an action with no current session is refused. Saved observations and
old identifiers grant no authority. Model-facing observations carry a revision and the current
text scene, or `changes` since an earlier revision (`since`) of the same window; operational session
IDs and capture times are omitted from that compact surface.
The existing engine observes afresh before acting; saved observations are not
coordinates or authority for later input.

Desktop results render scene and outcome text in tagged blocks and preserve applicable
`structuredContent`; adapters also retain their compact text and structured result. Hosts must keep
the fields their consumer needs rather than parsing display prose as evidence. Action results use
`gesture · effect · recovery` plus a bounded message, separating input delivery from effect. An uncertain
delivery can have a confirmed observed effect while remaining an uncertain delivery. Repeated identical
refusals on unchanged scene content return `do_not_repeat`. None of this is a measured token-saving claim.

AutomationMCP retains the last scene the model read for up to eight windows, by the seat's window
number or else by bundle identity and title; an untitled window of the same size can match its former
titled reading. Safe scene-text cuts are always used. `open_session` and `observe` with `full: true` send
the whole scene. The fixed difference policy compares anchor/last bases and uses a 75 percent limit, keeping at most
the anchor and latest scene dependencies. A comparison with chained differences is a separate study
and does not create a second implementation in the product. Baselines are reset at context boundaries and session
closure, and a call whose answer never reached the model restores the delivered baseline.

`SceneChanges` matches elements by identity and writes them in the lines of
`text()`, which prints sections and their elements in reading order so one screen
renders one text. Two readings of one screen still differ in their sections (pixel
seams move with the text that protects them, and a header read differently renames
a panel and renumbers each `region N`) and in learned group tags, so the update
ignores those, element order, and moves of elements and panel edges under 2% of
the window. An element now in another section is reported while its old section
name still exists, since `section:` targets by it; a section name that is gone is
reported once, in the new section lines.

Historical replay over one recorded Codex session on Resolve and Slack (89 Braus tool
results, 72 of them scenes, with no window numbers), the results come to 279
thousand characters against the 820 thousand that session printed; dropping the
duplicate alone gives 412 thousand. Half the scene stays the cut: two thirds turned
three more scenes into changes and saved 5% of the scene characters. These historical observations
do not qualify the current implementation or establish a measured winner for the difference-policy study.

The dedicated `batch` tool validates every step before effects and uses the shared policy for at
most 20 steps, one application and 15 seconds. It checks each target again as the sequence proceeds.
A failure, ambiguity, unavailable next target, unexpected surface or stop ends the sequence without
replay or rollback. An unknown effect can continue when the next target is available, or the step is
last; it is still counted as unverified. A committing step must be last, have an expectation and follow
confirmed earlier effects. Return and Command-Return are conservatively committing inputs. There is
no inline `then` variant of model gesture tools. The standalone CLI's `--then` separator remains its
command syntax. A batch reports attempted and verified counts separately; neither a tool attempt nor
an agent completion claim proves an effect.

The host follows new application windows using the Driver's existing window
tracking. Dropdown selection uses the same native/custom dropdown selector as
the terminal command. The archive retains the Engine's historical result vocabulary; the model-facing contract renders
typed gesture, effect and recovery fields rather than selecting an older result format.

`type_text` resolves and focuses a named field. `insert_text` keeps a focus and
selection already established, including a dialog's initially selected name,
and inserts one intact payload. Only exact native focused-field readback against
an explicit complete `expected_value` verifies that insertion. An opaque field
remains unverified. A batch cannot proceed from that uncertainty to a committing Return, even when
the final Return has an expectation. A separately authorized commit must be followed by verification
of its actual effect. Committing input is classified before dispatch on attested focus and the current
scene; a dry run does not bypass this check. Eligible unknown effects can receive a bounded second
look without delivering the input again. A seen passing effect keeps its evidence after a capped or
unwatched wait, with the wait limit attached.
The Seat path has no foreground fallback. Multi-app concurrent control and remote
ChatGPT connections remain separate work.

## Tool names at API boundaries

Capability IDs such as `demo.read` stay canonical in permissions, dispatch and
memory. ModelTransports gives API tools stable ASCII aliases when their names
contain other characters or exceed 64 bytes. Existing valid names stay unchanged.
Aliases use a SHA-256 digest of the canonical Unicode spelling; conflicting names
refuse the request before it is sent. Definitions and reconstructed history use
the same aliases, and streamed calls regain their canonical IDs before leaving
the transport. Tool arguments are unchanged. Native provider records keep their
wire names and signatures; Gemini responses match the names in those records,
including older records made before aliases. The CLI transports do not serve
these API tool turns.

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

Chat sends the user's prompts and the selected routes' live tool answers to the provider.
Adapter content can reach the model even when it is withheld from stored records. Desktop
window-to-text processing runs locally; this does not make remote model inference local.
Provider sign-in credentials remain with the provider CLI.

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

### Application guide delivery

Application guides belong only to the private composition. The open profile excludes their loading,
exposure and activation, including injected guide delivery. The open product must work without guides;
this is not a feature that the open user enables through a rollout option.

`AutomationMCP/Guides` reads profile-selected files with delimited JSON metadata, a short head and
complete Markdown sections. Loading and per-guide index construction run on the concurrent executor
before publishing `AppGuides`. There are no bundled guides. Without a guide, no guide block is added.
The profile loader composes attached delivery. Other delivery policies are private-library injection
points and are not selectable product rollout generations.

`GuideSearch` can share `DocumentSearch`, an immutable `CatalogueVectors` snapshot and an injected
embedding adapter with capability retrieval. Those injection seams do not establish that the profile
loader uses semantic retrieval. The current default profile loader supplies neither vectors nor an
embedder and uses equality for overlap checks; it must not be reported as tested hybrid search or
semantic overlap detection. Any private composition claiming those behaviors needs explicit wiring
and separate evidence.

The guide head is reserved first, memory next, and up to three complete sections last. Coverage
compares complete section text with same-app `MemoryPartSummary.text`; `GuideOverlap` retains unknown
contrast. The library's default limits are 1500 tokens and 0.85 similarity. The injected estimator rounds
character count divided by four upward. Delivered guide content can enter typed task state without
being mistaken for procedural memory or an observation of the current scene.

The resolver supplies locale, bundle identity and numeric app version. Formatting receives prepared
values and escapes guide content in a nonempty `<guide>` data block. Private guide wiring and selection
require their own tests; neither a runtime feature declaration nor a green open run certifies them.
