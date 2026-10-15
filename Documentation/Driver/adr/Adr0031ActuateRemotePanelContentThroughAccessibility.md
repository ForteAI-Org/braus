# Actuate remote panel content through accessibility

Status: implemented, 2026-10-05. Offline seam tests only; the app path has no
live run yet.

## Evidence

A file panel opened by any host, as an AppKit sheet or as the application-modal
`runModal` Qt and Adobe UXP use, draws its content in
`com.apple.appkit.xpc.openAndSavePanelService`, one process per host. The seat
addressed that content as `InputEndpointRelation.remoteContent` and posted
routed mouse events to it (ADR 0014 records why its endpoint is discovered).

A probe using exactly that route, on 27 and 2026-10-05, found:

- a routed click into the content activated the host application in 75 to
  525 ms: DaVinci Resolve's sidebar row 3 of 3, the Where popup 3 of 3 in a
  modal and 3 of 3 in a sheet. On a sidebar row the click was also eaten, the
  first click on an inactive window: the selection did not change, while the
  same click with the host already active worked. The seat read that as the
  application taking the person's focus, recovered it, found no effect, and
  the agent retried into a second activation and a `waiting` seat;
- opening the panel did not activate the host (an AXPress menu item and a
  click on Resolve's Qt Import button, 0 activations);
- accessibility did the work with the host in the background and no
  activation, 3 of 3 each: AXPress on a popup opens its menu and on a menu item
  picks it; `AXSelected` on a sidebar row navigates; `AXSelectedTextRange` on
  the Save As field selects (an `AXFocused` write does not take);
  `AXSelectedText` replaces the selection as typing does; AXPress on Save or
  Cancel completes, answering -25204 because the panel closes first. All of
  these elements answer in the host application's own tree, with true screen
  coordinates;
- the popup's menu window is owned by the panel service, not the host, so the
  seat's dropdown path never saw it open and chose items with keys to the host;
- a full path typed in the Save As field is a file name: AppKit saved
  `~:Downloads:x.txt` in the current folder.

## Decision

A pointer Command whose endpoint is qualified remote panel content
(`SurfaceInputClassification.remotePanelContent`, a different process that is
the panel service) posts no event. `RemoteContentActuator` hit-tests the host
application's tree at the Command's point and
`DialogEndpointResolver.remoteContentPath` proves the element: from the node
under the point up to the first naming the surface, every node belongs to the
surface's or the content's process and names the content's window or none, and
the path names the content's window unless the endpoint itself was attested
from the surface's subtree. Anything else refuses.

A row bounds what a click reaches. In an Open panel the file name is a text
field inside its row's cell, with the size and kind as static text beside it
(Resolve, 2026-10-05), so a click there is a click on the file:

| Click | Element | Accessibility |
|---|---|---|
| left, 1 | anything inside a row but a control | `AXSelected` on the row |
| left, 2 | anything inside a row | AXOpen on the innermost element offering it, the row last |
| left, 1 | button, check box, radio, disclosure triangle, menu item, also inside a row | AXPress |
| left, 1 | text field, text area, combo box outside a row | caret at the end through `AXSelectedTextRange` |
| left, 3 or more | text field, text area, combo box outside a row | `AXSelectedTextRange` over the whole value |
| right, 1 | the nearest offering it | AXShowMenu |

A popup or a menu button refuses with `opensMenu`: pressed, it opens a menu
window the panel service owns that nothing in the seat follows, and the menu
stays open. `select` opens, chooses and closes it in one action. Any other
click refuses with `RemoteContentActuationRefusal.unsupportedRole` naming the
role. A drag or a scroll refuses with `gestureUnmeasured`: no
accessibility counterpart was measured, and whether a routed one activates the
host was not measured either. Nothing falls back to posting.

A click that leaves a caret or a selection outside a row remembers the field with the
surface, the content window and the selection generation it was proved under.
`.text` and `.insertText` on that surface, under that generation, with the
content window's identity unchanged and the field still answering, set
`AXSelectedText` and read `AXValue` back for the log. Any other Command forgets
the field; without one, text keeps the key route. `.key` Commands keep
`RemoteKeyboardPlatform` and its host priming.

The actuation keeps the posting boundary: the gate's preparation is awaited as
the driver awaits it, the reference and the endpoint are checked again after
it, and the closure expectation is unchanged. The Receipt counts no event and
names `PostRoute.accessibilityAction`; the trace records the accessibility call
as the send. -25204 from an action is a delivery, verified like any Receipt by
what follows it. A refused action or write may still have taken effect and is
never repeated: the broker reports it as an action whose effect is unknown, and
the engine as acted but unverified.

Every refusal carries one sentence telling the worker what to do instead, as
its `description`, which the broker's error mapper also answers with: the
engine prints a thrown error as it comes.

A dropdown's menu is looked for among the menus of the host and of the panel
service drawing a held remote file panel. The pixel dropdown opener, a routed
click, refuses while such a panel is held. The integration's `select` opens the
popup with its native action and reads the menu's items in the host's tree, or
else the service's. Titles are compared without the bidi isolates and marks
U+2066 to U+2069, U+200E and U+200F, ignoring case: Where read
`⁨Desktop⁩ — iCloud` and `iCloud Drive` twice. The one enabled item of that title
is pressed; none or several is a miss, which names the enabled titles, a repeated
one once with its count, and closes the menu with AXCancel on its AXMenu, which
answered 0 and closed the service's menu on Resolve on 2026-10-05. The popup's
native value is verified afterwards.

## Follow-up: a Save sheet (TextEdit, 2026-10-05)

A live worker saved from TextEdit, whose Save panel is a sheet on the document
window. No activation and no `waiting` occurred, and the accessibility route
ran. Four defects followed from the sheet:

- `holdsRemoteFilePanel` answered false, so the engine replaced the name with
  a click and selecting keys, and a key forgets the remembered field: the name
  was appended. A sheet has no `AXWindows` entry; accessibility lists it under
  its host's entry. The foreign content of a held modal is now read from that
  entry too, and attested as an endpoint is attested, drawn inside the surface.
  The seat and a Command's classification share one rule,
  `SurfaceInputClassification.isRemotePanelContent`.
- A target copied from the scene's `label = value` form, with the value in
  bidi isolates, named nothing. Resolution accepts that form when both halves
  name the element, and compares labels without isolates and marks.
- The engine pressed the Where popup by its label before the seat saw the
  click, opening the service's menu outside the scene. With a remote file
  panel held, the engine refuses a click on a popup or a menu button in the
  `opensMenu` words and presses no control by label.
- Once expanded, the sheet extended left of its document window. The picture
  covers both, while the integration admitted a point only inside the host's
  frame. A point inside a hosted sheet's picture region is now kept, and the
  seat admits it against the sheet or refuses it.

Not fixed here: the sheet's held record keeps the frame it was adopted at.
`AgentSeat.preflight` checks the requested window, the sheet, through
`currentIssues(for:)` against the window server, finds the expanded frame and
reports `geometryChanged`. The recovery that follows runs on `seatGuard`, which
`preflight` leaves on the host because a sheet owes no return; the host is
where it was, the episode finishes, and the sheet's record is never updated.
Every later Command on the sheet repeats it. The repair belongs to the
recovery, which accepts a settled resize only for the guarded window
(`acceptOperationalGeometry`).

## Follow-up: native menus of an ordinary window (Finder, 2026-10-06)

A worker opened Finder's contextual menu with a right click and then clicked
its item. The engine picks an item of an open menu with keys, and the seat sent
them through keyboard endpoint discovery, which refused: Finder's list answers
no Window ID for its focus (ADR 0014). A later `context_menu` then refused with
`contextMenuAlreadyOpen`, and the worker stopped.

- While a menu window of an ordinary window's process is open, its tracking
  takes every key. A key or text Command then asks no focused control and is
  posted to the window with the unprepared recipe, since a preparation's
  restore is what dismisses a menu.
- The engine first presses the menu's own `AXMenuItem` of that title, compared
  by `LabelText.menuTitleKey` (case, bidi controls, typographic quotes, a
  trailing ellipsis): Finder titles `Compress “carla_video_bn”` with curly
  quotes. Keys pick only where no item answers.
- A menu already open when `withContextMenu` starts cannot be told whose it is.
  It is closed with the action's own levers, the preparation cycle and then
  Escape, and the action opens its own; `contextMenuAlreadyOpen` remains for a
  menu that does not close.

## Follow-up: Finder's own windows (owner decision, 2026-10-06)

In a Finder window held by the seat, a click on the sidebar's Downloads row
changed nothing, single or double, and `/` did not open Go to Folder. The owner
decided that the ordinary windows of the applications listed in
`EndpointDiscovery.accessibilityClickedApplications`, Finder alone for now,
take their clicks through accessibility as a remote panel's content does.

- `DialogEndpointResolver.ownContentPath` proves the element: from the node
  under the point up to the window's own `AXWindows` entry, every node is the
  window's process and names the window or no window. The mapping is this
  ADR's; a click on empty space refuses with the role it reached.
- Scroll and drag keep their posted route: no activation is known for them,
  and a drag is how files move.
- A row selected in such a window also has its list (`AXOutline`, `AXTable`,
  `AXBrowser`) given the focus a pointer click would give it, so a key such as
  `/` reaches the file list. The answer is reported in the trace, never
  retried.
- Keys keep their route. The `/` failure was the focus: the seat routed the
  key by the focused control, which named the window (`attestedSurfaceItself`),
  while Finder's file list answers no Window ID, so the focus was not in the
  list, after two posted clicks on the sidebar. Commit `b84a7ca` changed only
  the guidance and measured nothing.
- A menu item named by the start of its title, "Compress" for Finder's
  `Compress “file.mov”`, is the unique enabled item whose key begins with it
  and a space or a quote (`LabelText.menuItemMatch`); an exact title wins.

Measured once with a probe on 2026-10-06: AXPress on Finder's
`File > New Finder Window` brought Finder in front within 573 ms and took its
other window out of Stage Manager's strip. The probe window was closed through
its close button and the front given back; nothing else was measured. Whether
a posted click on Finder's sidebar is eaten as a first click, whether the
focus write takes and whether `/` then opens Go to Folder are not measured.

## Follow-up: an open panel's icon view (2026-10-06)

Resolve's Import Media panel opened in icon view, and every click on a file
refused at its `AXImage`. Measured the same day with the probe on an
`NSOpenPanel` in icon view, its host in the background:

- the tree is the host's `AXList 'icon view'`, whose `AXSelectedChildren` alone
  is settable, the service's inner `AXList`, an `AXGroup` per item with nothing
  settable and no action, and its `AXImage` offering AXOpen and AXShowMenu;
- writing `AXSelected` on the group or the image, `AXSelectedChildren` of the
  inner list to the group, or of the outer list to the image, answered 0 and
  changed nothing: Open stayed disabled;
- `AXSelectedChildren` of the outer list set to the group selected the file:
  the list read one selected child, the image read `AXSelected`, Open became
  enabled, and AXPress on Open returned the file, with no activation (0 of 1);
- AXOpen on the image completed the panel but activated the host (1 of 1);
  AXOpen on the list view's name field did not (0 of 2).

So a click on an item outside any row or control, under a list whose selected
children are settable, writes that selection with each item between the hit
and the list, the list's nearest first, and keeps only a selection read back:
the list holding exactly that item, or the hit becoming selected. A write that
answers 0 without that is passed by; none verifying refuses with
`selectionNotVerified`. A double click selects the same way and then presses
the default button the list or the window names (`AXDefaultButton`); where none
is named it uses AXOpen, the one route measured to activate the host. Whether
the panel's window names its default button through the host is not measured.

Column view (`AXBrowser`) was not measured: a click there refuses with
`columnView`, which says to switch to list view. `select` now opens a menu
button, the view-mode control among them, with AXPress like a popup.

## Follow-up: Finder's rows and its contextual menu (2026-10-06)

A worker drove Finder's own window on a release built from this tree. Four
defects followed.

- A click on the sidebar's Downloads row was acted as `AXSelected` on the row,
  and the window stayed on Recents. Measured afterwards on a Finder window with
  Finder in the background: `AXSelected` on the sidebar row answers 0 and
  selects it without navigating; the row offers only AXShowDefaultUI and
  AXShowAlternateUI, and AXOpen answers -25206; `[row]` written to the
  `AXSelectedRows` of the sidebar's `AXOutline` (description "sidebar"), which
  is settable, navigates with no activation, 2 of 2 (Documents, then back to
  Downloads). A row is now selected through the nearest outline or table above
  it whose `AXSelectedRows` is settable, and the write counts only once the
  list reads back exactly that row. The row's own `AXSelected`, which navigated
  in a file panel's sidebar 3 of 3, is the fallback, read back on the row or on
  the list; neither reading back refuses with `selectionNotVerified`, in a
  sentence for a row. The list's focus write stays.
- A double click on the same row answered AXOpen with -25205 from an element
  under the row, and the window then showed Downloads. A double click now
  selects the row as one click does, then uses AXOpen on the innermost element
  of the path offering it, the row last, or else on the nearest of the row's
  descendants offering it, three levels down: a file list offers it on the
  name field wherever in the row the click lands. Where nothing offers it, or
  AXOpen answers anything but success or -25204, the click refuses with
  `selectedNotOpened`, which may have taken effect and says that a sidebar row
  opens its folder on selection. -25206, on any action, now reads as nothing
  done ("not supported"); every other answer, -25205 included, may have acted.
- The menu a right click opened (AXShowMenu on the file's name field) was
  chosen with keys: the accessibility press answered no item, three keys
  reached the window, and the engine answered `found_acted` for a Compress that
  never happened; the next observation showed Finder's share popover instead.
  The press missed because `DropdownOpening.select`
  walked from the application element, and Finder's contextual menu is under
  neither it nor its windows: measured for `WindowReader.contextMenu`, the
  application's children are a window, the menu bar and the desktop's scroll
  area, and only the hit test at the menu window's centre reaches the `AXMenu`.
  When nothing under the application paints an item in the menu's frame, the
  `AXMenu` drawn at that centre, owned by the process, is now read. A pick by
  type-ahead answers `acted_unverified`: the menu closed but the effect is not
  confirmed. The seat-scoped choice `context_menu` makes was not wired into
  `act`: the seat tracks a menu only inside `withContextMenu`, so a menu a
  plain right click opened is never the seat's tracked menu.
- A right click and `context_menu` on `carla_video_bw` were ambiguous between
  the share popover's title text and the file's row. With
  `preferNativeControls`, resolution now counts an `AXRow` as a native target,
  and a right click asks for it as a click does.

These change the table's first two rows: one click selects through the row's
list first, and two select the row before AXOpen. Not measured: whether the hit
test reaches Finder's menu when AXShowMenu opened it on the seat's display,
whether AXPress on its item then compresses the file, and whether a file
panel's sidebar outline has settable selected rows. Where it does, its rows are
now selected through `AXSelectedRows` instead of the measured `AXSelected`.

## Follow-up: Apple native applications, accessibility first (owner decision, 2026-10-15)

The scope of "Finder's own windows" is widened from one bundle identifier to every Apple native
application, and a click that accessibility declines is posted instead of refused.

- **Which applications.** `AppleNativeApplications` decides by the bundle's code signature, not
  by its identifier, which anything can claim: the bundle satisfies `anchor apple`
  (`SecStaticCodeCheckValidity` with `kSecCSBasicValidateOnly`, which names the signer without
  hashing the resources: 3 to 16 ms on Finder and Safari against 74 to 98 ms in full), and it is
  not Mac Catalyst (its Info.plist names no `UIDeviceFamily` and no slice of its main executable
  has an `LC_BUILD_VERSION` for platform 6). A signature or a binary that cannot be read is not
  Apple's native: the click keeps its posted route. The answer is kept per bundle path.
  `EndpointDiscovery.accessibilityClickedApplications` is gone. `TargetPlatform.appleNative` keeps
  its `com.apple.` prefix: it chooses a preparation recipe and a menu preparation, not this.
- **Which elements.** Only one that offers the action. AXPress is asked only of an element that
  lists it, a caret only of a field whose `AXSelectedTextRange` is settable, a right click only
  of one that lists AXShowMenu. A row that neither its list nor its own `AXSelected` can take
  (the write answers -25205 or -25206 with no write before it) is declined too. An element under
  an `AXWebArea` keeps its posted click (`RemoteContentActuationRefusal.webContent`). None of
  this changes a panel's remote content, which still never posts.
- **The fallback.** A refusal decided before anything was written or performed is posted as the
  click it was (`RemoteContentActuationRefusal.wasDeclinedBeforeActing`): no element, an
  unmapped role, a popup, web content, a read that failed, and AXPress or a write answered
  unsupported (-25206). `AgentSeat` then runs the posted route as it would for any other
  window, with the recipe the window's platform chose. What may have acted is never posted
  on top: a success with no visible effect, a selection that did not read back, a double click
  whose AXOpen was refused, and any other error. Those answer as before, an action whose effect
  is unknown, and the engine as `acted_unverified`.
- **The reply.** `Actuating.lastDeliveryRoute` tells the engine a click went out as an
  accessibility action, and a reply that found no effect says "through accessibility, no click
  posted", so the worker does not click it again on top of it.

Not measured: whether the gate's preparation, awaited once before the accessibility attempt and
again before a fallback post, costs anything in the second pass; whether every Apple application
answers `AXPress` on its toolbar and sidebar controls as Finder's do; and which Apple
applications ship AppKit controls that list AXPress and ignore it. No live run was made.

## Follow-up: a field in a row, and text after its caret (2026-10-15, live trial of the above)

A trial of the previous section on Reminders and Notes (10:19 to 10:28, the Braus log and the
worker's tool activity) found two faults and one cost.

- **A field in a row took the row.** Reminders draws a reminder's title as a text field inside a
  row, and the click mapping let the row win: `AXSelectedRows` was written, its list focused, and
  no caret was left, so the next text read `''` (10:26:31, "acted ... by accessibility:
  AXSelectedRows, its list focused on AXRow", and again for a click at 10:26:43). A text element above the row whose
  `AXSelectedTextRange` and `AXValue` are both settable now takes the caret (one click) or its
  whole value (three), and is remembered for text; a control nearer than it is still pressed. A
  file's name in a Finder list keeps the row: it is not editable, so its value is not writable.
  The value is checked as well as the range because a non-editable text field may still answer
  its range as settable; that is not measured, the stricter rule keeps ADR 0031's table as it was.
- **The end key forgot the field.** `type_text` with `replace: false` sends click, Command-Down,
  then the text, and the seat forgets the remembered field at any Command that is not text
  (Notes, 10:23:12 to 10:23:35: the caret by `AXSelectedTextRange`, then two posted key Commands).
  The click already left the caret at the end of the value, so the engine does not send that key
  after a click that went out through accessibility onto a text field, and the text takes
  `AXSelectedText`. The conditions of `rememberedRemoteTextField` (same surface, same selection
  generation, same window identity, the element still answering) were not the cause. Not
  measured: whether Notes' text area keeps its element between the click and the text; if it
  does not, the field no longer answers and the text is posted as before.
- **Cost of a key.** In Reminders and Notes the seat's share of a `press_key` is under 70 ms
  (the key posts 2 to 6 ms after its log line, no preparation, no admission wait). What an input
  costs is two scene readings, 0.9 s in Reminders (68 elements) and 1.4 s in Notes (142), and
  the settle, 0.2 to 0.3 s: 2.1 s per key in the 13-key batch, 3.4 s for a type_text. A text typed
  by 13 `press_key` steps cost 27 s. The worker did it after `type_text` failed twice, with
  nothing in the instructions telling it text goes in one call: the instructions, the
  `press_key` description and its reply (while a field has the focus) now say so.

## Follow-up: Apple extension content in an Apple application (owner decision, 2026-10-15)

A live trial on System Settings, Appearance, answered a click on "Light" with
`surfaceFamilyUnclassified`. The pane is a remote view of an extension process hosted by System
Settings, and the classification took it for unknown because only the Open and Save panel
service qualified remote content, so the Command was refused before the accessibility route above
was reached. The owner chose all Apple extension panes.

- Remote content is also qualified when its host is an Apple native application (ADR 0031's
  2026-10-15 scope: `anchor apple`, not Mac Catalyst) and the remote process's bundle satisfies
  `anchor apple` too. The signature is the evidence, never the bundle identifier; an unreadable
  signature or bundle is not qualified. The answer is kept per bundle path.
- The qualification is `RemoteContentQualification`: `filePanelService` keeps everything above,
  its posted recipes included; `appleExtension` is accessibility only. A click, or the text of a
  remembered field, is actuated through `RemoteContentActuator`; a drag, a scroll and a right click
  are refused, keys keep the routes they had (the qualified keyboard recipe stays the file
  panel service's), and nothing is posted into the extension. The destructive and closing guards are unchanged. A third-party extension, or any
  extension in a third-party host, is refused as before.
- Not measured live: that the click on a pane's control resolves through `AXPress` in the
  extension's tree. Test: GestureEndpointRoutingTests, AppleNativeApplicationsTests.

## Limits

- No live run was made for this change. The table above is the probe's, on one
  build, with the elements named; other roles, other panels, other builds and
  other frameworks' own dialogs are unqualified.
- Whether the AX caret makes the name field the panel's first responder, so
  that a following `/` key still opens Go to Folder, is not measured.
- AXCancel closing the service's menu was measured once, on Resolve. A menu it
  does not close is reported `contextMenuLeftOpen`, the loudest failure, since
  neither a host preparation cycle nor an Escape to the host is known to close
  the service's menu.
- A right click's AXShowMenu opens a menu nothing in the seat follows either,
  as a popup's press would; it is kept as specified and not measured.
- The closure expectation of `UserFocusRecovery` is still armed for every
  Command on a modal surface, including actions that cannot close it.
