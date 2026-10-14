# Prepare Preview menu commands

Status: candidate, 2026-10-14. Proposed by Tommaso from the Brain/Memory canary,
to be reviewed by Elio together with the follow-up of
[ADR 0031](Adr0031ActuateRemotePanelContentThroughAccessibility.md).

## Evidence

Preview 11.0, macOS 27, Italian. In two fresh processes of the canary re-run of
14 October 2026 (build `e08e99a`), the seat launched Preview, which showed its
Open panel; the agent opened a PNG from the panel, and the document's window was
taken in. With that window open and Preview in the background:

- File read `Apri…` and `Chiudi tutto` enabled and every document command
  disabled: `Chiudi finestra`, `Salva`, `Salva col nome…`, `Duplica`,
  `Esporta come…`, `Stampa…`;
- Strumenti read every command disabled, `Ruota a sinistra` and `Ruota a destra`
  included;
- `File > Salva col nome…`, `File > Esporta come…` and `Strumenti > Ruota a destra`
  were refused as disabled, and Shift-Command-S changed nothing.

The window's own Rotate button worked, so the document was live: the menu bar
still described the Open panel without a document, the state ADR 0013 measured
in Photoshop after a dialog. Nothing in the run could export the result, so the
task failed in both parts.

## Decision

The broker uses the bounded menu-command foreground scope of ADR 0013 and 0029
for the positively identified `com.apple.Preview` bundle, as for TextEdit: the
item is read while both foreground witnesses agree, resolved again and
dispatched once before the verified handback. Missing, destructive and
listing-only paths never activate; a listing keeps its warning that its enabled
flags may be stale. Cancellation, a changed identity and a failed handback keep
their refusal and uncertain-effect semantics.

Text, keys and clicks keep their routes. Other AppKit hosts keep their menu path
until separately qualified.

## Verification

`TargetPlatformTests` admits Preview and still refuses Finder, Chromium and an
unmeasured target.

Live, canary of 14 October 2026 11:11–11:20 (build `e300fc0`, two fresh Preview
processes): `Strumenti > Ruota a destra` (both parts), `File > Salva col nome…` and
`File > Esporta…` read enabled within 34 to 1019 ms in front, were pressed once, and
each moment gave the front back to the person's window in 50 to 220 ms. Two moments
dispatched nothing: in one the person brought ChatGPT forward, which was left in front;
in the other the agent named "Esporta come…", the title the stale background menu read,
which Preview shows as "Esporta…" once active. Both now say why
([ADR 0043](Adr0043SayWhyACommandWasNotSent.md)). The background listing's titles are
as stale as its enabled flags: its warning covers both.
