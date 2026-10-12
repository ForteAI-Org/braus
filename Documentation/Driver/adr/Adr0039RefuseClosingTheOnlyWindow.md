# ADR 0039: Refuse the key or press that closes the only window of an application

Status: accepted, 2026-10-12. Measured on macOS 27.0.1 with DaVinci Resolve and Prism
Launcher through Accessibility, then live through `BrokeredAutomationSession` against
Resolve at its Project Manager; no Escape ever reached it there. Ticket "Escape inviato
dal seat fa uscire Resolve", phase 2. The fact is app path only: `BrokeredAutomationSession`
computes it, the CLI never sets it. The refusal of control characters in text holds on
every path.

## Evidence

| Window | AX windows | Main window | Subrole | Cancel / close button | Seat role |
| --- | --- | --- | --- | --- | --- |
| Resolve, no project open (Project Manager) | 1 | none (`-25212`) | `AXUnknown` | neither | interactive panel |
| Resolve, a project open (editor) | 1 | itself | `AXStandardWindow` | close button | document |
| Prism Launcher, its only window | 1 | itself | `AXStandardWindow` | close button | document |

The Project Manager is the only window the application has, it is not a document, and
Escape on it closes it: Resolve exits normally (`AtExit`, status 0), twice out of two
earlier probes. The key was delivered correctly; the window it closed was the
application. The window server shows one on-screen window for the process (layer 4 in
front, 0 behind) and about a hundred pre-allocated off-screen Qt windows.

The editor is also the only accessibility window of Resolve: it is kept out of the rule
by its document role, not by a window count.

Live, with the fixed build, Resolve (PID 66791) at its Project Manager: `press_key escape`
was refused five times out of five with the sentence "... the only window of DaVinci
Resolve ... Nothing was sent.", and the process was alive after every attempt and at the
end. An act on "Cancel" was an honest miss, because the window has no such control, and
sent nothing. A Close menu command could not be shown live: Resolve's File menu has no
Close or Close Window item. In the editor (PID 48131) Escape was not refused, as the rule
says; its delivery then failed with `focusedNodeChanged`, a behavior of the seat that
predates this decision.

A second live run after the `press` and text corrections, same process: Escape refused
five times out of five ("Escape would close 'Project Manager' ... Nothing was sent."),
`press` "Cancel" an honest miss that sent nothing (the Project Manager has no such
button), Resolve alive at its Project Manager afterwards with one accessibility window.

## Decisions

**One fact, computed from evidence and never from a name.** `WindowClosureFacts` says
closing the target window may end its application when all of these hold: the
application is a regular one; the seat role of the window is not document; the window
is the only one, by `AXWindows` (at most one, and a target outside the list counts as
one more) and by the window server (at most one visible window of the process at a level
below the menu bar, any display, the virtual one included, at least 120 points on a
side); and the application has no main window or the window has an `AXCancelButton`.
A count, the main window or the activation policy that could not be read is taken as
the dangerous answer, unless the role is document: an application that
`NSRunningApplication` cannot find is treated as regular. Stage Manager and windows on
other Spaces are not in the on-screen list, so they under-count, which errs toward
refusing.

**The engine refuses three things under the fact**, unless `allowsDestructive` is set
and never while a pop-up is open (Escape then closes the pop-up, which the engine's own
dismissal also does): `press_key` Escape with any modifiers and any `times`; an act on
the window's own `AXCancelButton` or `AXCloseButton` (their frames travel in
`ActionPermissions.windowClosure`) or on an element whose normalized label is exactly
cancel, close, annulla or chiudi; and a Close or Close Window menu command, matched
whole. `press` refuses a dialog button under the same fact, by the same label rule or
when the button is its window's `AXCancelButton` or `AXCloseButton`. "Cancel download",
"Close sidebar" and "Cancelled" are other controls. Command-Q and Command-W stay refused
always. The sentence names the window, says nothing was
sent and offers real buttons of the scene, never a Cancel the window does not have.

**The facts are read only for an input that can close the window**: `press_key` with
Escape, every act (a click can land on the window's own closing control whatever its
label), and `menu` and `press` only once the item or button named is a closing one.
Scrolls, drags, context menus, text and other keys read nothing. In the second live run
six readings on the Project Manager took 2.1, 2.8, 3.5 and 5.5 ms, and 230 and 504 ms for
the first and the fourth: each act pays one, and the slow ones are not yet attributed to
a single reading. A document window reads nothing at all: its role is held by the seat and
already rules the fact out, so most acts pay no reading.

**Text never carries a key.** `type_text` and `insert_text` refuse text holding a C0
control character other than tab, line feed and carriage return, always and on every
path, before any event: the input layer posts the text as a key's Unicode payload, and
U+001B there reads as Escape to AppKit and Qt. No tool documents control characters in
text today, and the others are refused because each reads as a key of its own. DEL
(U+007F) is not C0 and still goes out. This refusal is input validation in the engine,
so unlike the fact it holds on the CLI path too. A terminal fallback that types a control
character (the kitty ticket's U+0015 for Control-U) would need it narrowed to U+001B or
made specific to terminals, by its own decision.

## Limits

- Command-period cannot be sent: key chords name a to z, 0 to 9, slash and tilde.
- The menu path does not know whether a pop-up is open and refuses a Close command
  whenever the fact holds.
- The Lab planner (`ActionExecutor`) sends `key:escape` unchecked and has no app caller.
- A "Close" item of a context menu is not covered.
- The window server count ignores windows at negative levels (a desktop window like
  Finder's) and at the menu level and above.
- An accessory application is never at risk, and one whose activation policy cannot be
  read is treated as regular.
- A drag that starts and ends on a closing control is not checked.
