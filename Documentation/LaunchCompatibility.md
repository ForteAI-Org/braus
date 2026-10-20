# Compatibility and limitations

Braus runs on macOS 15+ on Apple silicon and Intel. Supported frameworks are
AppKit, Chromium, Electron and Qt, plus DFW, DUI and BUI for [Pro Tools 2026.4+](Driver/platforms/ProTools.md#ui-frameworks). Pro Tools combines Qt6 with these proprietary Avid/Digidesign UI frameworks; coverage is scoped to the controls and workflows documented in its guide. UXP support is in development (Adobe apps).
Flutter is an area for contributions, not a claim of launch support.

Optional native, web and adapter routes are configured separately from the virtual desktop.
A native route uses Mac controls where available and can hand an application to the desktop
route. The web route works in Chrome. The local adapter set covers System Settings, Calendar,
Reminders, files, Contacts, Mail, Messages and Notes; each exposes specific operations, not every
feature of that app. Check [route configuration](Engine/README.md#advanced-channel-configuration)
and each adapter's availability and permissions before choosing a workflow.

## Check the workflow you need

Record the Braus version and source revision, macOS version and build, Mac model,
application version, starting window state, requested actions and observed result.
Separate a complete result from a partial result, a refusal and an uncertain effect.

A Safari workflow is evidence about Safari and that workflow. It does not validate
Chromium or every browser. A DaVinci Resolve workflow does not validate all Qt apps.

For the video workflow, inspect the exported video and ZIP, then confirm that the
correct attachment arrived in Slack. For the X workflow, inspect the draft,
record the person's approval and confirm the scheduled entry on X, including its
text, date, time and timezone. Scheduling a post does not mean it has been published.

## Background work

The Driver gives the agent a virtual display within the current Mac session.
Work that uses this virtual desktop takes turns: additional workers wait for access. Native and web routes do not acquire a Seat, but retain their own app/profile ownership and permission checks; enabling them does not create another unrestricted desktop. The display does
not create a virtual machine or another user account, and does not restrict the
agent to a separate filesystem. Keep the physical display awake.

macOS build validation, runtime checks and workflow compatibility are separate.
An unvalidated build is not proof of compatibility. A failed runtime check must
not be treated as permission to proceed. Follow the instructions for your release
and the [Driver guide](Driver/README.md#validating-a-macos-build).

Stopping a response does not undo delivered edits or submissions. After an
interruption, inspect the app, any files and the last reported action before retrying.

## Perception, Brain and Memory

Perception builds structured text from the current interface. Some controls may be
missed or ambiguous. Report the expected control and the actual observation,
with a small sanitized capture if needed. Avoid sharing unrelated window content.

Brain maps each app's controls, relationships and transitions. Memory stores
experience from past interactions and their outcomes for later recall. Both draw
on observations and action evidence. Procedures can include interface and adapter operations, with current inputs and results bound
for the new task. A remembered operation is not evidence that the new task succeeded. Saved
knowledge still needs to be checked against the current interface; it does not retrain the model.

The desktop window-to-text pipeline runs on your Mac. Model requests may include
window text, task context and recalled knowledge. Remote inference remains remote
even when the client is local. Review the [data guide](README.md#permissions-and-data)
for the tools and model connection you use.

## Pro Tools checks

The [Pro Tools guide](Driver/platforms/ProTools.md#live-seat-verification-19-october-2026)
records the team's 19 October checks of menu opening, rename fields, return from dialogs and
selection counters. These are accessibility/broker/Seat checks on named software and hardware,
not a model-driven end-to-end DAW workflow or a new benchmark. Read-back remains necessary
where a tool result is unverified.

## Report a result

Use the existing [bug report](https://github.com/ForteAI-Org/braus/issues/new?template=bug_report.yml)
for workflow failures or the [Seat compatibility report](https://github.com/ForteAI-Org/braus/issues/new?template=seat_validation.yml)
for a macOS build or hardware configuration. Follow the
[contribution workflow](../CONTRIBUTING.md). Share test content and remove private data.
