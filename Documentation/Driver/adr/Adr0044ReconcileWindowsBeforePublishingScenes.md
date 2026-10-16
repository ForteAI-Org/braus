# ADR 0044: Reconcile windows before publishing scenes

A Pro Tools I/O Setup opened beside an untitled Output palette exposed two
separate moments in one response: the command's window check saw the new dialog,
while the attached scene still described Edit. The palette took the display-crop
path, which did not refresh the selected window. The dialog was first listed on
a physical display and was adopted during perception.

The scene provider now observes through the Seat before enumerating surfaces.
That observation supplies the window identity and the frame used by either
capture path. A display crop checks the exact outstanding observation reference after capture.
The recipient may be an auxiliary window while the session keeps its primary
window selected. A superseded, consumed or invalidated observation still refuses
the crop. Menu and
dialog commands bracket perception with window signatures, including window
numbers, and reread at most twice if those signatures change. No command is
repeated. A continually changing census returns an unverified action without
attaching a stale scene.

Opening another exact window title of the already held application selects it
through the existing target transfer and returns a fresh scene. The broker
retains its lease and session ID, including when selection is refused. An
ambiguous title, an unowned window or a stopped Seat is not permission to move
an arbitrary window. Opening a different application retains the existing
session lifecycle.

Containment may use the normal detected-window transaction for a verified,
preexisting member of the assigned process whose direct move was refused.
The exception applies only while containment is the sole selection suspension,
the target is inactive, and no action, user intent or stopped focus recovery
prevents it. Input stays subject to its existing gate.

A stable resize inside the Seat can be reconciled without confirming a prior
unknown command. Two AX bodies, each bracketed by agreeing WindowServer readings
of the same identity, must agree across the settlement interval. This path writes
no geometry or input. The command keeps its original confirmation and old
observation coordinates are invalidated. Other unknown-effect recovery still
fails closed.

On return, an application-owned size that explicitly refuses AXSize may remain
at its settled size while returning to its recorded origin and Space. The same
two-source settlement is required. Driver adaptations and fullscreen provenance
keep their original resize obligations. A refusal does not trigger repeated
attempts to write the read-only size.

Offline regressions cover observation ordering, changing window signatures,
containment waits and user intent, lease retention, resize reconciliation and
read-only-size return. These are contract tests; live compatibility requires a
separate run on the target application.

A local run on 16 October 2026 retained one session through Edit, Mix and Edit.
With Output already open, a separate run returned I/O Setup in the menu command's
immediate scene and in the following observation. Cancel and release preserved
foreground application and cursor position. The first combined run stopped with
`frameUnusable` after Output opened; it did not reach I/O Setup. That intermittent
capture path was not qualified by that run. This does not establish every popup or
third-party plug-in as supported.

The Output capture refusal was reproduced offline with an auxiliary recipient and
an unchanged primary window. Its untitled layer-three palette also matched the
geometric dropdown heuristic. That heuristic now applies only to normal-layer
windows; floating windows remain windows, and menu-layer detection is unchanged.
An existing popup cannot overwrite an observed window-title change, a control
state change or a closure with a fabricated menu-opening effect.

Every modal input can arm an expected closure, including editing a field. A later
command replaces that unused expectation with fresh pre-command evidence. Once
activation recovery or disappearance starts, its deadline and two-request budget
remain shared across the episode, including across returns during a Turn. No
command is replayed. Controlled regressions cover the recorded timing; this
change still needs a live run to measure application focus behavior.
