# WebPopupProbe

An AppKit fixture for measuring input into web content hosted by a native app. A main
window has four buttons; each opens the same bundled local page (`probe.html`, no network:
a button, a link, a text input, a checkbox, a drag box and a scroll filler) in one surface:
an `NSPanel`, a sheet, an app-modal `runModal` window or an `NSPopover` (kept open until
Close or Escape).

## Build

    make web-popup-probe          # or Tools/Driver/WebPopupProbe/build.sh [output-dir]

Writes `.build/web-popup-probe/WebPopupProbe.app`, signed ad hoc. The signature is needed:
a `WKWebView` in an unsigned bare executable is killed with 137.

## Run

    open -n .build/web-popup-probe/WebPopupProbe.app --args --open sheet --token run1

- `--open panel|sheet|modal|popover` opens that surface at launch, without a click.
- `--token <token>` (or `WEBPOPUP_PROBE_TOKEN`, default `default`) names the log; letters,
  digits, `-` and `_` only.
- `--self-test` (needs `--open`) fires synthetic in-page events and a scroll, then exits 0
  (3 if no scroll was logged, 2 after a 20 s timeout). The events
  are untrusted (`isTrusted: false`), so the log shows what the page logs for untrusted input.

## Read the log

`/tmp/webpopup-probe-<token>.json` is one JSON array, truncated at launch and rewritten
after every event, so it is always valid. Entry 0 is `launch` (pid, requested surface).
Page events are `mousedown`, `mouseup`, `click`, `keydown`, `input`, `focusin`, `scroll`
and `mousemove` while a button is down. Each carries `surface`, `isTrusted`, `target`,
`activeElement` (`document.activeElement` as `tag#id[type]`), `hasFocus`, `x`/`y`, `key`,
`value`, `checked`, `scrollY`, `scrollTop` (scrolled element; `target` is null for a
viewport scroll), plus `time` (epoch seconds), `appActive` (is the app
frontmost) and `keyWindow` (title of the key window, or null), added by the app.

    python3 -c "import json;[print(e['seq'],e['type'],e.get('isTrusted'),e.get('activeElement')) for e in json.load(open('/tmp/webpopup-probe-run1.json'))]"
