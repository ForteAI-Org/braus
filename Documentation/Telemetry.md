# Telemetry

The Braus app sends anonymous usage metrics to Forte, so we can see which tools work, which fail and how
long they take across the Macs that run Braus. This page lists everything that is sent. A metric or an
attribute that is not on this page is not sent.

## What is sent

Once a minute, while the app is running, one [OTLP/HTTP](https://opentelemetry.io/docs/specs/otlp/) export
in JSON is posted to `https://telemetry.forteutilities.com/v1/metrics`. The totals are cumulative since the app
started.

**About this copy of Braus** (the OTLP resource):

| Attribute | Example | |
| --- | --- | --- |
| `service.name` | `braus` | always `braus` |
| `service.version` | `1.2.0` | the app's version |
| `service.instance.id` | `3f1c…` | a random ID made on first launch and stored in Braus's preferences; it is not derived from the Mac, the person or an account |
| `os.type`, `os.version` | `darwin`, `26.0.1` | the macOS version |
| `host.arch` | `arm64` | the processor architecture |

**Metrics:**

| Metric | Kind | Attributes |
| --- | --- | --- |
| `braus.tool.calls` | counter | `tool`: the name of one of Braus's tools (`click`, `open_session`, `app_call`…); `outcome`: one of `found_acted`, `acted_unverified`, `acted_noop`, `ambiguous`, `honest_miss`, `refused`, `dry_run`, `ok`, `error`, `cancelled` |
| `braus.tool.duration` | histogram, seconds | `tool` |
| `braus.turns` | counter | `provider`: `codex`, `claudeCode`, `anthropic`, `gemini`, `ollama` or `other`; `ending`: `completed`, `failed` or `cancelled` |
| `braus.turn.duration` | histogram, seconds | `provider` |
| `braus.app.up` | gauge | none; 1 at every export |

## What is never sent

The arguments of a tool call, what it typed or read, its answer or its error message; the text of a
conversation; file names, paths and contents; page addresses and contents; the names of the apps and windows
a worker uses; the person's name, email, account or IP-derived location stored by us; anything from the
memory. The values above are bounded in code (`Sources/Telemetry/Telemetry.swift`): a tool name that is not
lower case letters, digits and underscores is sent as `other`, and an outcome, an ending or a provider
outside its list is replaced.

## Who sends

Only the Braus app. The `braus` command line, the test suites, the app's snapshot and check runs and an
isolated launch (`BRAUS_APP_SUPPORT_DIR`) never send. Nothing is sent before the app starts it, and the app
tells the person on the first launch that sends.

## Turning it off

Any of these turns it off:

- **Settings → General → Privacy → Share anonymous usage metrics**. Turning it off stops the export at once
  and forgets what was recorded.
- `DO_NOT_TRACK=1` in the app's environment ([Console Do Not Track](https://consoledonottrack.com)).
- `BRAUS_TELEMETRY=0` (also `false`, `off`, `no`).

`BRAUS_TELEMETRY_ENDPOINT=http://localhost:4318` sends to another OTLP collector instead, for example your
own while you work on Braus.

## How it is built

`Sources/Telemetry` is Foundation only: `TelemetryRecorder` keeps the cumulative totals under one lock,
`OTLPMetrics` writes them as an OTLP JSON body, and `Telemetry` bounds the values and runs the export loop.
`AutomationTools.call` counts every tool call; the app's `TeamModel` counts every worker turn;
`AppTelemetry` starts and stops the export from the person's choice and the environment. The collector holds
the credentials of the metrics store; the app carries none.
