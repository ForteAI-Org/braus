# Prepare TextEdit menu commands

Status: candidate, 2026-10-04. Qualification is recorded in
[the stabilization rounds](../reports/StabilizationRounds.md).

## Evidence

Release `60979ddf` completes three TextEdit Unicode replacements and three
single-character selection replacements through Braus. Independent scenes
preserve two leading spaces, the final LF and UTF-16 selection. In each fresh
session, Edit > Undo Typing and Edit > Redo read disabled; both refuse, and the
text remains unchanged. This does not establish that other native hosts need
the same preparation.

## Decision

The broker uses the existing bounded menu-command foreground scope for the
positively identified `com.apple.TextEdit` bundle, as well as Adobe UXP. It
reads readiness while both foreground witnesses agree, resolves the menu
again and dispatches once before verified handback. Missing, destructive or
listing-only paths never activate; cancellation, changed identity and failed
handback retain the existing refusal and uncertain-effect semantics.

Ordinary text insertion and key delivery keep their existing route. Other
AppKit hosts retain their existing menu path until separately qualified.

Native qualification on `10989743` observes Undo restoring the exact text,
but Redo refuses before dispatch: its cold `Redo` title validates into
`Redo Typing` during activation. A bare terminal English `Undo` or `Redo`
therefore admits exactly one current title with that verb and a word-boundary
suffix. An exact title always wins, including a disabled exact item. Multiple
matching titles refuse as ambiguous; all other commands retain exact matching.
This qualification does not extend to localized dynamic titles.

## Verification

The existing menu and brief-activation tests cover dispatch ordering, current
item identity, deadline, refused readiness, no replay and failed handback.
Signed Release `3512aee9` completes three fresh TextEdit sessions through
Braus. Each replaces the text with two leading spaces, Unicode and a final LF,
selects the first UTF-16 unit, inserts Z, restores the original text and
selection with Undo, then restores Z and the caret with bare Redo. Independent
observations establish every text effect. All three sessions close with null
status. Menu verdicts remain conservative when the window signature is
unchanged; their attached scenes are not replaced by an assertion of success.

The dynamic-title regressions fail before the correction and pass afterwards;
the clean complete offline baseline passes 2332 executed tests, 93 skipped,
2425 reported in 28 runs. This qualification does not repair Photoshop's
independently observed outstanding native menu tracking loop.

## Amendment, 2026-10-14: Chromium browsers

**Evidence.** Measured on macOS 27 with an own Chrome on a scratch profile, in the
background and after a brief activation, 5 runs each: View > Always Show Bookmarks
Bar read disabled in the background 5 of 5 and enabled in front 5 of 5, and a
press in front toggled the bookmarks toolbar in the window's accessibility tree
6 of 6. Window-scoped items stay disabled while Chrome has no key window
(File 7 of 12, Edit 8 of 17, View 1 of 17 enabled in the background); File > New
Window and New Tab stay enabled. A single read at the moment the front was
confirmed still saw the item disabled twice: Chrome revalidates a few ms after it
becomes active, and the existing poll found it enabled within 0 to 1 ms of the
front being confirmed in 5 runs, and after 734 ms in 1 run where the activation
itself took 863 ms. Through the benchmark server the bookmarks item refused
6 of 6 as disabled, and File > New Window pressed in the background made Chrome
take the front 3 of 3 in the second run, leaving it in front once.

**Decision.** A browser found by its renderer helper, inside a framework's `Helpers`
as Chrome ships it or directly in `Contents/Frameworks`
(`TargetPlatform.embeddedRenderer(.rendererHelper)`), joins
`BrokeredAutomationSession.preparesMenuInFront`: its menu commands are read and
pressed in the brief activation, the item is polled every 20 ms until it reads
enabled, bounded by `UserFocusRecovery.briefActivationLimitNanoseconds`, and an item
that never enables refuses as before. Electron and CEF hosts, found by their
framework, keep the background path until measured. The reply sentences are the
other in-front applications' own.

The activation is paid only when it is needed: the browser's item is read once in
the background, and one that reads enabled is pressed there as before, with no
activation (`BrokeredAutomationSession.pressesMenuInFront`). Only a disabled item
takes the brief activation and its poll. The other in-front applications keep
pressing every item in front, because an enabled reading proves nothing for them:
Adobe's enabled items are stale (ADR 0020), TextEdit's titles validate only in front
(above), and Safari's enabled File > New Window opens nothing in the background
(ADR 0038). An enabled File > New Window pressed in the background still makes Chrome
take the front by itself, which the ordinary recovery answers (next paragraph).

**Focus after a window taken in.** The run that left Chrome in front logged "No
prepared action was held when this activation arrived" 0.8 s after the seat finished
taking in a window of Chrome's. The end of a window transfer ends its focus operation,
which drops the preparation, and only the next one-second heartbeat rebuilt it, so a
target that took the front inside that gap met nothing armed and the seat waited with
it in front. The seat now asks for a preparation at the end of every transfer, as it
already did on a window's creation and on the beat. This is the shared path: it covers
a window a brief activation's Command opens, and any transfer outside one. A Turn's
release drops its preparation the same way and is not changed here.

**Verification.** Unit tests only: the decision on Chrome's layout and its family,
the poll that presses once on the first enabled read, an item that never enables and
is never pressed with the front given back, and the target taking the front just
after its new window was taken in, which failed before the change with the logged
refusal. The live re-measurement through the server is pending.
