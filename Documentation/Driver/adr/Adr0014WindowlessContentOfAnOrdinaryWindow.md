# An ordinary window takes the events of its windowless content

Accepted on 2026-10-02 at the owner's request. It adds one route to endpoint
discovery, for a surface with no attested modal relation only. Amended on
2026-10-14 for the web content of a sheet or a modal, see
[the amendment](#amendment-web-content-of-a-sheet-or-a-modal-2026-10-14).

## What was measured

Driving Safari through a seat, a click on the toolbar worked and nothing inside a
page did: every click and key on page content was refused with
`subtreeUnreadable`. A read-only probe of a person's Safari on macOS 27
(`_AXUIElementGetWindow`, `AXUIElementGetPid`) found:

- the `AXWindow`, the `AXToolbar` and its buttons answer the window's Window ID,
  with Safari's PID;
- the `AXWebArea` and every node under it (`AXLink`, `AXStaticText`, `AXGroup`,
  `AXImage`, `AXList` and the rest) answer `-25201`, no Window ID, and still
  Safari's own PID.

A second reading through the shipping adapter, on 27.0.1 (26A434) with Safari
27.0.1, walked from the node the hit test answered in the visible page:
`AXImage`, `AXGroup`, `AXWebArea`, `AXScrollArea` and `AXGroup` answered
`-25201`, all with Safari's PID, and the next `AXGroup` answered the window.
At that point `pointerEndpoint` refused with `subtreeUnreadable` and this route
answered the window itself.

The pointer descent therefore ends on a node with no Window ID and no remote
content window to name, and the keyboard discovery finds a focused control with
no window, or none at all, while `ordinaryKeyboardContext` meets the same
windowless nodes in its scan. Both refuse, as they were written to.

## The decision

`DialogEndpointResolver.windowlessContentEndpoint` answers the surface itself,
with evidence `windowlessContentOfSurface` and relation `logicalSurface`, when a
node of the surface's process with no Window ID has the surface as its nearest
ancestor naming a window. The recipe is the application's own, as for any
endpoint on its own window.

- **A click** is proved along the path its point names: from the node the hit
  test answered up through `AXParent` to the first node naming a window, and
  down by the smallest containing child to the innermost node under the point.
- **A key** is proved from the focused control up through `AXParent`. That
  control must answer no Window ID itself.
- **Every node on the path** belongs to the surface's process and names no window
  or the surface. A node naming another window, even one of the same process, a
  node of another process, a failed read, more than 64 steps or 300 ms refuse.
  `_AXUIElementGetWindow` is read with its outcomes kept apart: no window is a
  success with zero or `-25201`; any other error, or the symbol missing, is a
  failed read. `-25201` is also what a destroyed element answers, and the parent
  or children read that follows one fails and refuses.
- **For an ordinary surface.** `AgentSeat.inputEndpoint` asks when the surface
  has no attested modal relation and discovery refused with `subtreeUnreadable`.
  Since the 2026-10-03 follow-up, it also asks for keys when discovery inferred
  `remoteContentOfSurface` from a subtree while the focused control itself
  named no window. A positively proved own parent path wins over that inferred
  auxiliary destination. A failed proof leaves the original outcome in place;
  a focus directly naming another window never enters this path. A surface
  whose host is another window is never answered. Every modal path behaves as
  before.
- **Keys are proved twice.** At the boundary the same proof is taken again,
  because the focused control names no window and the plain focus reading would
  answer nil. A focus that left the page's content retires the context.

## Follow-up: auxiliary themed widgets in the subtree

Repeated owned Safari field edits through Braus on 2026-10-03 reached an
unclassified keyboard endpoint with evidence `remoteContentOfSurface`. Native
traces identified three successive 14×14 endpoints owned by
`ThemeWidgetControlViewService`, while accessibility reported Safari's PID.
The initial keyboard discovery had inferred a recipient from a named window
elsewhere under the focused surface because the focused control itself named
no Window ID. Containment of that auxiliary window did not establish it as the
text control's recipient.

The follow-up gives priority to the existing complete own-content parent proof
in this one nonmodal keyboard case. It adds no backend qualification for the
widget service. The proof is repeated at the posting boundary as before. Tests
cover the positive route, missing proof, a directly named foreign focus, modal
surfaces and proof loss before posting. App repeat results are tracked in
[stabilization rounds](../reports/StabilizationRounds.md).

## Follow-up: keys on a page that names no focused control (2026-10-09)

Driven through the app with Safari in the background, `AXFocusedUIElement` answered
`-25212` (no value) in every reading, even right after a click the seat had posted
into the page. The keyboard discovery, `ordinaryKeyboardContext` (whose scan meets the
windowless web nodes) and the focused-control path of `windowlessContentEndpoint`
all refused, so Tab, Shift-Tab, the arrows, `type_text` and `insert_text` failed with
`subtreeUnreadable` every time, while clicks, drags and scroll found their endpoint
through the point route above.

With no focused control the recipient is proved by the page instead, in a new route
asked after `ordinaryKeyboardContext` and only without an attested modal relation.
`DialogEndpointResolver.webAreaKeyboardContext` answers the surface itself, with
evidence `windowlessContentWithoutFocus` and relation `logicalSurface`, only when all
of these hold, and the first that does not refuses:

- the application reports no focused control (`absent`, not unreadable);
- its focused window is the surface, with the frame that framed the Command;
- an `AXWebArea` is found climbing from the node under a point of the surface, which
  is the centre of the surface when the Command carries none, and it names no window;
- from the web area to the first node naming a window, every node is of the surface's
  process and names no window or the surface, and that first node names the surface;
- no other visible window of the process is listed above the surface by the window
  server, read by the seat before and after the page's proof (`AgentSeat.isTopmost`);
  an unreadable list, or a list without the surface, refuses. A window the seat
  itself reads as a decoration or a tooltip does not count: the 66 by 20 point
  traffic light overlay macOS draws over every window it raises is listed above
  the surface for the whole session, on screen at alpha 1, and without this
  exception no key would ever be admitted;
- the two focus readings bracket the walk.

**The proof is repeated at the boundary.** The endpoint carries no focused node window,
since nothing was focused, so `endpointInvalidation` takes the whole proof again, the
modal relation and the window order included, and a window that opened above or a
modal that appeared retires the context with `focusedNodeChanged` before anything is
posted. A control that took the focus meanwhile is accepted only when it resolves back
to this exact surface, by the same routes that start from a focused control: a
windowless control of the page (the route above) or a control that names the surface
window itself, such as the toolbar's. This is not a loophole but the normal case of a
prepared Command: Safari reports no focus while it is inactive and reports the field
a click focused as soon as the preparation makes its window key, so a bulk insertion
(`insert_text`, prepared) saw the absence at resolution and the field at the boundary,
and was retired with `focusedNodeChanged` 5 of 5 times before this was added. A focus
that resolves to another window's content, or to nothing, still retires the context.

**What this does not claim.** Like the other routes it decides the recipient and never
proves an effect. A hosted surface, an attested modal (remote panels included) and any
route with a focused control keep their behavior: remote panels stay in the modal
branch and are refused as before. A person's other visible window of the same
application above the surface refuses too, which is stricter than necessary for a
window that cannot take keys; it fails closed and is the limit of this change.
The Driver unit tests cover the admission with every condition and the refusal when any one
is missing, in `WebAreaKeyRoutingTests` and `DialogEndpointResolverTests`.

The keys' delivery to a Safari page that is not active is a separate question, measured
in [ADR 0038](Adr0038SafariPreparationAndBriefNewWindow.md).

## Amendment: web content of a sheet or a modal (2026-10-14)

Decided by the owner on 2026-10-14 after the measurement below. It widens the route to a
sheet and a modal, for web content only.

**What was measured.** A fixture application, WebPopupProbe (AppKit, signed ad hoc, one
`WKWebView` showing a local page with a button, a link, a text field and a checkbox), was
driven through the seat in the background with click, link, `type_text`, `insert_text`,
Tab, scroll and drag, 5 times each. In a sheet (`AXSheet` on the main window) and in a
`runModal` window (`AXWindow`, subrole `AXDialog`, `AXModal` true) all 70 Commands were
refused before delivery with `subtreeUnreadable`; the page saw no event and the frontmost
application never changed. A read-only dump found Safari's shape inside both surfaces:
the surface and its first `AXGroup` answer the surface's Window ID, while the next
`AXGroup`, the `AXScrollArea`, the `AXWebArea` and every node under it answer none, all
with the application's PID. The modal's discovery, its keyboard routes and its leaf route
refused; this route was never asked, because the surface had an attested modal relation.

**The decision.** The web content of a sheet or a modal is that surface's own when the path
from the element up to its window crosses an `AXWebArea`, every node on the path belongs to
the seated process, the first node naming a window names the sheet or the modal the seat
attested, and two more facts hold that the path cannot give. The nodes of a remote view
answer the host's PID and no Window ID just as a page's do (Resolve's Go to Folder field,
`RemoteSheetContentTests`; the view services under Safari and Photoshop in the follow-ups
below and in ADR 0031), so the process on the path and the role of one node do not tell a
page of the seated process from content another process draws. What does, measured on
those panels, is a window of another process: the one a sibling names in accessibility
(Resolve, Photoshop), and the one the window server lists in front of the surface. Both
are required:

- the surface's own subtree, read whole without descending below an `AXWebArea`, names no
  window other than the surface (`namedWindows(... atMost: 0) == []`); a surface node not
  found, a named window, or a subtree that cannot be read whole refuses;
- the window server lists no visible window of another process in front of the surface
  and intersecting its frame, read before and after the path proof, with the seat's
  decorations and tooltips left out as `surfaceIsTopmost` leaves them out. The on-screen
  list runs front to back, so only the rows before the surface's own row are read: a
  read-only dump on 2026-10-14 showed every display carrying, behind all its windows and
  covering it whole, Finder's desktop, WindowManager's wallpaper and the window server's
  backstop, each of another process at alpha 1, which a reading of every intersecting row
  refused on. The rows the window server draws itself (the menu bar, the cursor and the
  status indicators in front of every window) are left out: nothing of another process
  is hosted in them, and the cursor crosses every surface at some point. Such a row is
  told by its owner PID, which the kernel must describe as the window server itself,
  `proc_pidpath` answering SkyLight's `WindowServer` executable and `proc_pidinfo` the
  `_windowserver` user, uid 88 (read on 2026-10-14: PID 169 on this Mac). A PID the
  kernel describes as anything else, or cannot describe, counts as another process's.
  The owner name a row carries is the application's own display name and decides
  nothing. A list that cannot be read, a surface not listed, or a row in front whose
  owner, frame or identity cannot be read refuses; such a row is never skipped.

- `DialogEndpointResolver.windowlessContentEndpoint(..., ofModalSurface: true)` proves the
  path as above, up from the node the hit test answered and down to the innermost node
  under the point, or up from the focused control, requires an `AXWebArea` on it, and then
  the subtree fact. A hosted surface, the sheet, is admitted. Evidence
  `windowlessContentOfSurface`, relation `logicalSurface`.
- `webAreaKeyboardContext(..., ofModalSurface: true)` admits a hosted surface, climbs
  through the web area as before, and requires the subtree fact. Evidence
  `windowlessContentWithoutFocus`. The window order condition is unchanged: no visible
  window of the process above the surface, decorations and tooltips aside.
- `AgentSeat.inputEndpoint` asks these variants, `EndpointDiscovery.modalWebContent` and
  `modalWebAreaKeyboardContext`, only when the observation has an attested modal relation
  and only after the routes before them answered `subtreeUnreadable`. A modal whose keys
  the discovery already sent to a remote content window keeps that window: the override of
  a `remoteContentOfSurface` answer by the surface's own content stays what the 2026-10-03
  follow-up made it, for a surface with no modal relation only. The ordinary routes, which
  need no web area, are still never asked of a modal. The seat reads the window server
  fact around each of these proofs, `SeatSensing.windowSurfaces(inFrontOf:)`.
- At the boundary the key proofs are taken again with the variant the surface's relation
  selects at that moment (a sheet on a host, a modal naming its host, an application
  modal), with the same two facts. A surface that a modal blocks still retires the context.

**The recipe.** The endpoint is the sheet or the modal window itself, of the driven process,
so the Command takes the application's own family (`SurfaceInputClassification`
`drivenApplication`): `AppKitPlatform` for the fixture, which prepares nothing and makes no
window key. No activation and no `AXPress` were added. Whether a `WKWebView` in a host
that is not active acts on events nobody prepared is the separate question of [ADR
0038](Adr0038SafariPreparationAndBriefNewWindow.md) and of the web popup recipe ticket.

**What stays refused, and on which fact.** Slack's panel controls name the service's
Window ID on the path (measured, 2026-10-02). Resolve's Go to Folder sheet and Photoshop's
Save As panel name the service's window in a sibling of the control, and the service's
window is listed in front of the sheet with the sheet's frame (both measured, 2026-09-29
and 2026-09-30): the subtree fact and the window server fact each refuse them, whatever
the roles on the path. Whether any of those paths carries an `AXWebArea` was not measured and
is not relied on; `RemoteSheetContentTests` puts one on Resolve's field's path and the
route still refuses. The same web tree with another process's PID, or naming another
process's window, refuses, and so do a failed read, more than 64 steps and 300 ms.

**Residual risk.** A remote view drawn by another process whose nodes answer the host's PID
and no Window ID, with no window of that process named anywhere in the surface's subtree and
none listed by the window server in front of the surface, would pass both facts and be
addressed to the host's sheet or modal. No such shape has been measured: every remote view
measured so far showed its process's window in at least one of the two readings. The window
server fact tells the window server's own rows by the kernel's description of their owner
PID, the SkyLight `WindowServer` executable run as uid 88, which no application chooses: a
process named "Window Server" is read as the application it is, and its windows in front
count. Where the events then go is not established either way: they are posted to
a window of the seated process, and a host window can forward what it receives into a remote
view it hosts, which is what ADR 0031's routed clicks into remote content rely on.

**What stays unproven.**

- Delivery on the live fixture. The Driver unit tests cover the fixture's own trees in
  `DialogEndpointResolverTests` and the routing in `ModalWebContentRoutingTests`.
- A sheet that was already open when the application was handed over. The seat holds no
  record for it (the take-in of pre-existing members skips a surface drawn inside a host,
  and the window follower keeps it in its baseline), so every Command on it is refused
  with `subtreeUnreadable` before any discovery runs, and this amendment does not change
  that. The measured sheet was one. A sheet opened from inside the seat is owned by the
  follower and takes this route.
- On the measured modal the window server listed the main window before the modal on the
  seat display, over part of the modal's frame. A hit test there answers the main window's
  node and refuses, and the keys route without a focused control refuses on the order.

## Why remote panel content stays refused

Remote panel content draws inside a modal: Slack's open panel, DaVinci Resolve's
Go to Folder sheet and Photoshop's Save As panel were all reached through a sheet
or an application-modal panel the seat attests. Until 2026-10-14 this route was
never asked there, and the modal attestation alone was the protection. Since the
amendment above it is asked of a sheet or a modal, after every other route
refused, and the protection is the two facts the amendment names, because the
path proof alone would not refuse every shape: on Resolve's sheet the text field
answered no Window ID with the host's PID, and the list beside it, not on the
path, named the remote window. The subtree fact reads that sibling; the window
server fact reads the service's window in front of the sheet. On the path itself,
Slack's panel controls named the panel service's Window ID, which refuses as it
always did. A standalone panel proxy whose modal relation the seat failed to
attest remains outside the modal routes, and the residual risk of the amendment
is the one it states.

## Amendment: Apple extension content (2026-10-15)

Decided by the owner. Remote content stays refused above, with one widening: an Apple extension
drawn inside an Apple native application (System Settings panes) is qualified for the
accessibility route only, by the signature of both bundles. Its clicks and remembered field text are
actuated; drags, scrolls and right clicks are refused, keys keep their routes, and nothing is posted into it. The
rule and its limits are in ADR 0031, follow-up of the same date.

## What stays unproven

- Safari beyond the controlled owned field and button used by the 2026-10-03
  follow-up. Their app-path results are recorded in stabilization rounds; the
  route itself decides the recipient and never proves the effect.
- Keys on a page whose application reports no focused control. The shipping
  reading above answered `-25212` (no value) for `AXFocusedUIElement`: with no
  focused control this route refuses, and so does `ordinaryKeyboardContext`,
  whose scan meets the windowless web nodes. Since 2026-10-09 the page's own proof
  above answers it for a surface with no modal relation; its live results are in
  ADR 0038.
- Any other application or browser engine, and any other build.
