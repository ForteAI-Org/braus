# MacDriver: how Braus works on the Mac in the background

Status: **draft for Simone's review**, 14 October 2026. Design only: no code until Simone approves it.
One document for everything decided and measured on 14 October; it replaces the earlier "Mac
channels" and "probes" drafts (in git history). Companions: [the web engine](../WebDriver.md), [what
four open projects do](2026-10-14-mac-background-prior-art.md) and [the channel seed](2026-10-14-mac-channel-seed.json),
the per-app recipes measured on this Mac.

## Simone's decisions

- **Background first.** Braus works behind the person's apps. Every choice below prefers the route that
  needs no screen, no focus and no seat, and that can read its result back.
- **The web before native apps when both can do the task.** Google Maps, not Maps. What the person
  usually uses does not decide it; we choose the route that works best for us. If the person names an
  app ("l'app Mappe", "Mappe di Apple", "Apple Maps"), we use that app. A kind of thing is not a name
  (15 Oct): "mappe", "meteo", "traduttore", "calendario", even "con Mappe", take the default route, so
  maps go to Google Maps on the web (no login, safer than a Mac app).
- **Missing login: tell the person how to connect.** The route does not change silently.
- **Routing rules are general**, the same for everyone: nothing assumed from one person's habits or
  country (iMessage in one place, WhatsApp in another).
- **One MacDriver for native apps, adapters inside it.** The app's API is the MacDriver's first rung.
- **Mode order 2, then 1, then 3** (round 1 plan): in place in the background, then Braus's seat,
  then the foreground.
- **The seat contains the apps that want the front** (15 Oct). The MacDriver keeps the apps that stay
  behind. An app that comes in front of the person's (at launch or during a step) goes to the seat
  (mode 1), and Braus remembers it, so the next session opens it on the seat directly. Every time it
  happens is recorded, so test runs list them all. This is a general rule for Braus.
- **The current Driver stays as it is** for apps the accessibility tree cannot describe. Not redesigned
  here.
- Tommaso's living memory records every action, whatever the route, with no change to its logic.

## 1. Why

"Passa al tema chiaro" (Boss, 14 Oct, 20:47) took two minutes and failed four times: `open_session`
could not launch System Settings by bundle id or by its Italian name; Settings took the focus and the
seat stopped (`SeatInterruption(targetActivated)`); the pane had no window recipe
(`surfaceFamilyUnclassified`); and nothing read the result back. The same day's measurements (section
9) showed that the pane was in the accessibility tree all along, that its "Chiaro" button can be pressed
with Settings behind, and that the setting has a one-line API. The Driver treats every window as
pixels on a seat. A native app is a typed tree with actions, values and an API, and Braus should use
them.

## 2. Routing a task

Braus picks the route **per task**, not per app. `RoutingAutomationSession` (WebDriver branch) already
sends `web:<host>` and URLs to the web session and every other name to the desktop one; it routes by
address only. Choosing between Maps and Google Maps is done by nobody today: the agent opens whatever it
thinks of. The router below is new and small.

### The rules

1. **Named wins.** When the person names an app or a service, that one is used. The agent says so with
   `open_session(..., named: true)`; the router does not redirect it. Naming an app means "the X app" or
   its brand ("Mappe di Apple", "Apple Maps"); a kind of thing ("mappe", "meteo", "traduttore",
   "calendario", "con Mappe") is not a name, so `named` stays false and the default route applies. The
   wording lives in `SharedRoutes.namedApp`, which `open_session` shows every client.
2. **Where the data lives.** Ask where the thing the task acts on really is.
   - **A service on the network** (a map, a Gmail message, a Google Calendar event, a Notion page): the
     Mac app is only a window onto it. Go to the source, the website, through the WebDriver.
   - **The Mac itself** (appearance, volume, Wi-Fi, a file in Downloads, a local note, an open app): no
     website exists. Use the Mac's API (an adapter) or its interface (the MacDriver).
   - **A store the Mac syncs** (Calendar and Reminders accounts through EventKit, Contacts): both the web
     and an adapter reach it. The adapter wins: no login, background, typed read-back.
3. **Background order.** Web → adapter → MacDriver accessibility → MacDriver mode 2 → seat (mode 1) →
   foreground (mode 3). A route is skipped only with a reason (section 4, rule 5).
4. **Irreversible steps need a read-back.** Send, delete, pay: only on a route that can confirm the
   effect (an adapter verb, or a page the WebDriver reads back). Never the native scene: on 14 Oct Mail's
   "Invia" reported success, closed its window and saved a draft.
5. **People are reached the way that works with them.** The channel for writing to someone (WhatsApp,
   iMessage, mail, ...) is learned per contact from the memory: the one that worked last time. It is
   never inferred from country or language. Unknown: ask once, remember the answer.
6. **A catalogue of default services** per kind of task, the same for everyone; a country matters only
   where a service is unavailable there.
7. **Missing login.** A web route that needs an account not connected in Braus's Chrome profile
   (`chrome-web`) answers with how to connect it, once, in a sentence the agent passes on. It does not
   switch route by itself.

### The catalogue (first entries)

| Kind of task | Default route | Native app it replaces | Login |
| --- | --- | --- | --- |
| Places, directions, travel time | `web:google.com/maps` | Maps | no |
| Search, facts | `web:google.com` | Safari, Spotlight | no |
| Translation | `web:translate.google.com` | (none) | no |
| Weather, stocks, news | `web:` the service's page | Weather, Stocks, News | no |
| Video | `web:youtube.com` | TV | for a library |
| Mail | the account's web mail (Gmail, Outlook) | Mail | yes |
| Calendar, reminders | adapter (EventKit) | Calendar, Reminders | no (Mac account) |
| Notes | adapter (Notes, AppleScript) | Notes | no |
| Files | adapter (FileManager, Finder) | Finder | no |
| Mac settings | adapter (System) | System Settings | no |
| Messages to a person | per contact, from the memory (rule 5) | Messages, WhatsApp | per service |

The catalogue is data in the engine, not code. The memory corrects it per app as outcomes come in.

### Where it lives

Not in the MacDriver: it chooses *between* the WebDriver, the MacDriver and the current Driver, so it
sits above all three, next to the one place every session already goes through.
`Sources/Integration/TaskRouting/` (target `TaskRouting`): `TaskRouter` (the rules, pure and unit-tested) and `RouteCatalogue` (the
catalogue, data), consulted by the tools' `open_session` before any session opens (`AutomationTools.router`). A native app name with a catalogue entry
and no `named: true` is answered with the route to use (`"Maps: use web:google.com/maps"`), so the
agent opens that instead; `app_capabilities` lists the adapter verbs for the task. The router never
opens anything by itself and holds no state; per-contact channels (rule 5) come from the memory. It
lands with or after the WebDriver branch, which brings `RoutingAutomationSession`.

## 3. The MacDriver

### Shape

Same roles as the WebDriver, filled from the Mac's own interfaces. `ActionEngine` and
`AutomationTools` do not change; the routing session gains a third destination and two tools.

| Module | What it owns |
| --- | --- |
| `MacAdapters` (`Sources/Mac`) | the API rung: `AppAdapting`, the adapters, their transports, the catalogue of verbs (section 5) |
| `MacDriver` (`Sources/Mac`) | the accessibility API: `MacApplication` (an `AXUIElement` per pid, timeouts, the Electron and Catalyst switches), `MacTreeReader` (batched reads, visible rows only), `MacObserver` (an `AXObserver` per pid on its own run loop thread), `MacLauncher` (section 7), `MacDelivery` (mode 2: keys by `postToPid`, the seat's key-window preparation, SkyLight clicks; through `PrivateSymbols`, refused on builds the ledger does not list) |
| `MacDriving` (`Sources/Mac`) | a window as the engine's roles see it: `MacScenes` (`SceneProviding`, built by `MacSceneBuilder`), `MacActuator` (`Actuating`, the ladder), `MacControls` (`ControlPressing` over the live tree), `MacSettler` (`Settling` on notifications), `MacWindows` (`WindowListing` from `AXWindows`) |
| `MacSession` (`Sources/Integration`) | `MacEngineRuntime`, `MacAutomationSession`; `RoutingAutomationSession` (with the `TaskRouter`, section 2) sends web routes to the WebDriver, native apps with a usable tree to the MacDriver, the rest to the current Driver |

`AccessibilityFacts`, `AccessibilityActions` and `WorkspaceActivation` are reused, not copied. The
seat's `AppKitStatePreparation` and `UserFocusRestorer` (`Sources/Driver/SeatInput/Preparation`) are
reused for mode 2: they are the measured recipes.

### Which apps it takes

1. The memory's channel table names a driver for the bundle id: use it.
2. Otherwise the front window's tree is read once: share of the window covered by elements with a role
   other than group or unknown, and the count of elements with an action. Over 50% and 10 actions: the
   MacDriver; under: the current Driver. Thresholds to tune.
3. Electron and Chromium apps (detected by the Electron or Chromium Embedded framework in the bundle)
   get `AXManualAccessibility`, then the same check. Only their key window has a rich tree.
4. A window that later reads sparse (a canvas, another Space) says so in the scene's quality; the call
   falls to the events rungs. The engine never switches drivers inside a call.

### The ladder

Intent requests (`app_call`) run on the API rung only. Scene requests (`act`, `select`, `type_text`,
`press_key`, `scroll`, `run_menu`) climb, stopping at the first rung that delivers:

0. **API (adapter).** When the request maps to a verb (a setting, a send, a file operation), the verb
   runs instead of the scene. A setting an adapter covers never goes through the screen: its Settings
   pane is `api` only in the channel table, and a scene request there is answered with the verb.
1. **Accessibility action, no focus.** Only actions the element lists (14 Oct: `AXPress` on an element
   without it returned success and did nothing). `AXPress` on roles where the press is the click
   (`AXButton`, `AXLink`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`, `AXDisclosureTriangle`,
   `AXSlider`, `AXSwitch`, menu items); `AXPick` for pop-up and menu buttons; `AXConfirm`, `AXCancel`,
   `AXIncrement`, `AXDecrement`; rows by `AXSelected` on the row or `AXSelectedRows` on the container
   (Settings' sidebar, measured); a click on a group or a row goes to its one actionable descendant with
   a matching label; scroll by `AXScroll…ByPage`, then the scroll bar's `AXValue`. Menu items: only when
   `AXEnabled` is true. Not on this rung: `AXShowMenu`, `AXShowAlternateUI`, `AXRaise` (they bring the
   app to the front), and `AXValue` on a text field (L10). A request resolved on a scene that no longer
   matches the live element is refused (`stale_target`).
2. **Mode 2, in place.** The window stays where it is and the person's app stays in front:
   - *Key window when needed.* Commands that need the window key (New Folder, Close, a menu item with
     `AXEnabled` false) first get the seat's preparation records on **the target window**: activation
     plus the two key-window records. Measured: Finder's New Folder went from disabled to enabled in
     0.9 s. The activation record alone did not enable it. Restored right after.
   - *Keys.* `AXMain` on the window, `AXFocused` on the field, then `keyboardSetUnicodeString` and
     `postToPid`; modifiers as flags on the key event. Keys land in the app's key window, hence the
     preparation. Read-back: the field's value.
   - *Clicks.* Focus without raise, then `SLEventPostToPid` with stamped fields and a primer click for
     Chromium (prior art, section 1). Measured on Settings' sidebar.
   - *Scroll.* Wheel events in pixels to the pid, or to the `com.apple.WebKit.WebContent` helper for a
     web view.
3. **Mode 1, the seat.** Drag, canvas, apps that accept input only in their focused window: the window
   is adopted on Braus's virtual display and driven there. Perception stays the MacDriver's tree.
4. **Mode 3, foreground.** Brought in front with an announcement and restored, when the person's
   machine policy allows it.

### Rules on every rung

1. **Read-back on every rung.** After the settler the engine reads the scene again, and the MacDriver
   adds the element's own value, state or existence. No readable effect: `actedUnverified`. On
   Electron, Catalyst and web views an AX value alone is `actedUnverified` unless the scene also
   changed (they report values they never applied). A window title is not a read-back (Settings'
   Generali has none).
2. **Never write a field's value through accessibility** (L10). Text goes through an adapter or keys.
3. **No replay of an uncertain effect.** A step whose effect is unknown is not retried on the next rung;
   the agent observes and decides. A press the app did not answer in time is `uncertain`, and so is
   a control press that timed out: `pressControl` answers true, so the engine does not click it again.

   The accessibility calls themselves follow three rules in every app (#45, #47):
   - **Off the caller's actor, enforced by the compiler.** `MacTreeReading` and `MacAccessibilityActing`
     are `async` and `LiveMacTreeReader` implements them `@concurrent`, so every caller awaits and no
     live call runs on the caller's actor: launcher, background opener, scenes, actuator, controls and
     the window list (`WindowListing` is `async` engine-wide). `AccessibilityController`, its menu press
     (`DropdownOpening`) and `LiveAccessibilityReader` are not tied to the main actor either. Live on
     Notes before #47, one click held the main actor about 10 s (#49).
   - **An explicit messaging timeout on every element.** 1 s on the application and the window,
     0.25 s on every other element. Nothing waits on the system default (about 6 s).
   - **A read that did not succeed is no absence (M2, T2B4).** Every answer is classified
     (`MacReadFailure`).
     - Only `noValue` and `attributeUnsupported` of one attribute are absent.
     - A whole request that fails, a timeout, `notImplemented`, `invalidUIElement` or a malformed answer is
       unread.
     - What did not answer is marked on its node (`MacUnread`). An element that answered nothing becomes an
       `AXUnknown` placeholder at its slot, a table header too, so every sibling keeps its path.
     - A node may also be marked for unread attributes, children or action names.
     - The window answering nothing, or not listing its children, throws `windowUnreadable`.
     - `MacTreeRead.unread` counts distinct nodes, each kind apart; what lay below a branch nobody listed is not
       counted.
     - The scene builder reads a marked tree as partial, with no limit named. `MacControls` attests no single match
       over it. No retry and no new timing.
     - The walk (`MacTreeWalk`) is generic over a source of decoded reads (`MacElementSource`). The address
       resolution shares its child rule (`MacChildList`).
   - **No unbounded walk.** `pressControl` runs before every click, so it matches against the scene the
     engine just read and costs no read on a miss. The other control reads use one bounded read
     (`MacTreeLimits.standard`), and `AccessibilityController` walks within `WalkBudget` (600 elements,
     depth 10, 3 s).

4. **No rung change inside an irreversible step.** If the rung that typed cannot also send and confirm,
   the task stops and asks.
5. **Every fallback has a reason**: `no adapter verb`, `element has no AXPress`, `menu item disabled`,
   `mode 2 refused on this build`, `stale_target`. The outcome names the rung that ran and why each one
   above it was skipped. That text feeds the channel table.
6. **The person comes first.** A listen-only event tap (or `InteractionListener`) sees real clicks and
   keys; events posted to a pid do not pass it. When the person touches the session's app, the next call
   is refused with "the person changed the app; read it again".
   An app that activates itself during our own step is not the person touching it. Keys the person
   typed while it was in front did reach it, so rule 6 still refuses after them.
7. **Apps never driven.** Password managers (1Password, Bitwarden, Dashlane, LastPass, NordPass, Proton
   Pass, Passwords) are refused at `open_session` by bundle id.
8. **Only the window the scene was read from** (defect A of the closure audit, N03 and N04).
   - **What it covers:** an app may reorder `AXWindows` between a scene and the action without any input from the
     person. A second document holding the same control at the same path would then take the press.
   - **The identity:**
     - Every live read keeps the identity of the window element it walked (`MacTreeRead.windowIdentity`, a
       `MacWindowIdentity` compared with `CFEqual`).
     - The scene cache keeps it (`MacSceneCache.Entry.windowIdentity`).
     - Every address made from the scene carries it (`MacElementAddress.window`): the actuator's, and
       `pressControl`'s.
   - **The check:** before any accessibility request (perform, select, focus, scroll, and read-back too), the
     window at the address's index must be that window (`MacElementAddress.admits`,
     `LiveMacTreeReader.attestedWindow`). Otherwise the result is `stale_target`: nothing is sent, nothing falls to
     rung 2, and the engine reads again.
   - **Identity rules:**
     - An address that names a window refuses a current window with no identity.
     - Synthetic identities, for readers that are not live, never equal live ones.
     - An address without one is legacy and acts by index as before: `MacBackgroundOpener`'s, which come from its
       own window list, not from a scene.
   - **Not covered:**
     - **No atomicity:** the check and the request are separate accessibility calls.
     - **The read itself:** `MacScenes` lists the windows, then reads one by index, so a reorder between the two
       reads another window than the summary chose. The identity follows the window actually read.
     - **Rung 2:** it attests its own `windowNumber`, which is matched by frame.

## 4. Scene and settling

`MacSceneBuilder` walks the window from its `AXWindow`:

- **Roles** pass through (the engine's roles are accessibility roles); meaningful subroles kept
  (`AXSwitch`, `AXToggle`, `AXSearchField`, `AXSecureTextField`); state from `AXValue`, `AXSelected`,
  `AXExpanded`; availability from `AXEnabled`; never a secure field's value.
- **Names**: `AXTitle`, `AXDescription`, `AXTitleUIElement`, `AXHelp`, the placeholder. Mail's fields
  have no name of their own: the preceding static text ("A:", "Oggetto:") names them.
- **Sections**: toolbar, sidebar, content, sheets, popovers, dialogs; tables, outlines and browsers as
  collections. The menu bar on demand. Settings panes are in the host window's tree (measured), though
  each pane runs in its own extension process.
- **Speed is a requirement.** Batched reads (`AXUIElementCopyMultipleAttributeValues`), visible rows only
  (`AXVisibleRows`, `AXVisibleChildren`), the 600-element limit, timeouts of 1 s for the app, 0.25 s per
  element, 0.05 s for frames in dense tables. Measured with one read per attribute: Notes 28 s, Mail
  104 s, Contacts 11 s; Settings and Calculator under 0.4 s.
- **Quality**: complete, cut by the limit or a timeout, or sparse (coverage check failed, another Space).
- **Pixels only where the tree is blind**: a per-window capture crop for unnamed images and buttons.

`MacSettler` listens for value, focus, selection, creation, destruction, window, sheet, menu and layout
notifications: it returns 150 ms after the last one, or at 2 s; nothing within the first 150 ms means
"no change", which the engine confirms by reading. Notifications end the wait; they never decide the
outcome.

## 5. Adapters

### Contract

```swift
/// AppAdapting is one app's (or family's) API rung.
public protocol AppAdapting: Sendable {
    var bundleIDs: Set<String> { get }
    /// The verbs it offers; fixed at build time, so the catalogue costs no discovery.
    var verbs: [AdapterVerb] { get }
    /// Whether it can run now: app installed, permission granted, transport alive. Never prompts.
    func availability() async -> AdapterAvailability
    /// Runs one verb and reads its effect back.
    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome
}
```

- `AdapterVerb`: `<app>.<verb>`, a one-line description, a JSON schema, a safety class (`read`, `write`,
  `irreversible`) and the read-back it promises.
- `AdapterAvailability`: `ready`, `needsPermission(String)`, `unavailable(String)`.
- `AdapterOutcome`: the engine's outcome kinds plus a small JSON result.
- **A verb ships only with its read-back.** Measured on 14 Oct: Mail's send through AppleScript, read
  back in the sent mailbox by subject and date, confirmed what the scene could not.

### Transports

| Transport | Apps | Permission |
| --- | --- | --- |
| EventKit | Calendar, Reminders | Calendars / Reminders |
| Contacts framework | Contacts | Contacts |
| AppleScript (`NSAppleScript`), fixed scripts, arguments as Apple event parameters | Notes, Mail, Messages, Finder, Music, any app with a dictionary | Automation, per app |
| `NSWorkspace`, `FileManager` | files, Finder | none or Full Disk Access |
| System frameworks (CoreWLAN, CoreAudio, IOBluetooth, Intents) and fixed command lines (`shortcuts`, `defaults`) through `Process`, never a shell | System | none, or per shortcut |

The engine never runs a script the agent wrote. The long tail is reached by adding verbs.

### First adapters

| Adapter | Verbs |
| --- | --- |
| System | `get/set_appearance` (light, dark, auto; read-back `defaults read -g AppleInterfaceStyle`), `get/set_wifi` (CoreWLAN), `get/set_bluetooth` (IOBluetooth; setting needs a private call), `get/set_volume` (CoreAudio, level and mute), `get/set_focus` (fixed Shortcuts; only on/off is readable), `open_settings_pane` (launch by bundle id, then the `x-apple.systempreferences:` link; read-back the selected sidebar row) |
| Calendar, Reminders (EventKit) | `list_calendars`, `find_events`, `create_event`, `update_event`, `delete_event`; `list_lists`, `find_reminders`, `create_reminder`, `complete_reminder` |
| Notes (AppleScript) | `list_folders`, `find_notes`, `read_note`, `create_note`, `append_to_note` (text escaped as HTML; each change read back by the note's id) |
| Mail (AppleScript) | `find_messages` (inbox, words of subject or sender, unread only), `read_message` (inbox or sent mailbox by Message-ID), `create_draft` (read-back in the drafts mailbox), `send` (irreversible; read-back in the sent mailbox by subject, date and recipient) |
| Files (FileManager, NSWorkspace) | `list`, `make_folder`, `move`, `reveal`, `open_with`, `move_to_trash` (irreversible) |
| Messages (AppleScript) | `send_message` (irreversible); history is not in its dictionary, reading stays on the scene. Read-back in `~/Library/Messages/chat.db` (read-only) by handle and time when Braus has Full Disk Access, else `acted_unverified` |
| Contacts (Contacts framework) | `find_contacts` (name to phones and emails), `read_contact` (plus postal addresses and birthday); read only |

Setters return the value they replaced, so the agent can put it back. `irreversible` verbs follow the
engine's destructive policy (`allowsDestructive`, and in Boss the person's yes).

### Tools the agent sees

- `app_capabilities(app, query?)`: availability and the verbs matching `query`, with schema and safety
  class.
- `app_call(app, verb, arguments)`: one verb through the same guarded path as `act`. No session and no
  seat needed.

### Writing an adapter

One file under `Sources/Mac/Adapters/<App>Adapter.swift` (target `AppAdapters`), one test file, one line in
`AppAdapters.standard`.
`braus adapters` lists them and their availability; `braus adapters call <verb> <json>` runs one. `braus adapters grant [<app>]`
asks the permissions with the system's prompts, for the app it runs in; a host embedding Braus offers
the same through `AppAdapters.requestPermissions`, behind an action of the person. It is the one path
that may prompt: an adapter that never prompts never appears in the Automation or Contacts panes, so
the person could not grant it there. Unit
tests use a fake transport; live tests (`BRAUS_ADAPTER_LIVE_TESTS=1`) use throwaway data named `Braus
test`, and never send for real except to the developer's own address.

## 6. Opening apps

- `open_session` takes a bundle id, an English or localized name, or a path; it consults the router
  first (section 2).
- `MacLauncher` launches with `activates = false` and waits for the first window in the tree.
- Measured on 46 stock apps: **FaceTime, Phone, System Information and Safari activate themselves**
  anyway. The launcher lets them, then `UserFocusRestorer` puts back the person's app, unless the person
  clicked or typed since.
- **Six apps open a first-run sheet** (Maps, Music, Books, Home, Journal, Reminders). The launcher
  reports it; the agent dismisses it with the non-committal button, never one that migrates data
  ("Aggiorna ora" in Reminders). Home, Books and Journal ignore a quit while the sheet is up.
- **Some show no window within 12 s** (Mail, Messages, TextEdit, QuickTime, Automator): document apps
  open an out-of-process file panel, Mail its viewer later. The launcher waits for a window or opens a
  new document (TextEdit's File > New works in the background).

## 7. Sessions and the memory

- A MacDriver session takes **no seat** for the API, accessibility and mode 2 rungs; it queues only for
  mode 1, and asks the foreground policy only for mode 3. Sessions on different apps can run together.
- Every call goes through `ActionEngine` and the call's `CallRecorder`, keyed by bundle id. Each recorded
  action carries its route and rung.
- **The channel table is the memory's.** [The seed](2026-10-14-mac-channel-seed.json) holds the 14 Oct
  recipes per app (which rung works, which element to use, the traps); the memory replaces it with what
  outcomes teach. Raw records: `docs/probes/2026-10-14.jsonl` (personal, not committed).

## 8. Measured on this Mac (14 Oct 2026)

macOS 26.6 (25G5028f), it-IT, a throwaway tool (`macspike`) with the person working in Chrome and
Claude. Every private symbol resolved.

| Check, app behind | Result |
| --- | --- |
| Settings pane in the host tree | yes: 267 and 209 elements, one process, under 0.4 s |
| Settings sidebar | `AXSelected` on the row: **works**; `AXPress` on its label: false success |
| Notes, TextEdit: typing by `postToPid` | **works**, read back exactly |
| Settings: SkyLight click on the sidebar | **works**, cursor not moved |
| Calculator 7 × 6 by `AXPress` | **works**, 42 |
| Reminders: toolbar button, focus the new row, type, Return | **works** |
| Reminders, TextEdit, Finder: menu commands on the current window | disabled while inactive, `AXPress` lies |
| Finder New Folder with the seat's key-window records | **works** (in the key window: aim the records) |
| TextEdit: close by the window's button, then "Elimina" in the sheet | **works** |
| Mail: compose by the scene | fields **work**; "Invia" saved a draft and reported success |
| Mail: send through AppleScript | **works**, confirmed in the sent mailbox |
| 46 stock apps launched without activating | 4 activated themselves, 6 first-run sheets, 5 without a window in 12 s |

Not done on purpose: pressing "Chiaro" and any switch in Settings (real system settings).

Seat probe, same evening (`MacLaunchProbeLiveTests`, `BRAUS_MAC_LIVE_TESTS=1`, the real `AutomationSession`):

| Check, app on the seat (mode 1) | Result |
| --- | --- |
| Settings already running, `open_session`, then `x-apple.systempreferences:` links (Sound, Keyboard) | **works**: the window stays on the seat, the scene reads the new pane and its selected sidebar row, **no activation**, the person's front app unchanged; on close the window returns |
| Finder: open a folder with `activates = false` | no activation, but the window appears **on the person's screen** first |
| Finder: `open_session` on that window | **works** when the person is not clicking; with the person clicking it failed `windowNotAttested` (see Driver report ExpandedApplicationChecks) |
| Finder on the seat: `NSWorkspace.selectFile` (reveal) | the file's folder opens on the seat, but Finder **activates** and the restorer gives the focus back: a visible flash |
| TextEdit not running: open a file with it, `activates = false` | the window appears on the person's screen; the probe process then ended without a report: not concluded |

Decision (Simone, 14 Oct): opening a Settings pane, `reveal` and `open_with` wait for phase 2 and run as
background MacDriver operations (launch or link without activation, read back from the accessibility
tree, as the 14 Oct sidebar rows show), with the seat as the fallback when the window cannot stay out of
the person's way. Still to measure there: whether System Settings activates itself on a cold launch;
`selectFile` activates Finder and is not used.

Phase 2 reader, 15 Oct (`braus mac read`, `LiveMacTreeReader`: one batched request per element,
`AXVisibleRows` / `AXVisibleChildren`, children clipped to their scroll area, app behind):

| Window, app behind | Before (one request per attribute) | Phase 2 reader | Coverage |
| --- | --- | --- | --- |
| Notes, all notes (484) | 28 s | 234 read, 0.12 s | 84%, 70 actionable: MacDriver |
| Settings, Keyboard pane | under 0.4 s | 123 read, 0.12-0.17 s | 57%, 27 actionable: MacDriver |
| Finder, column view | not measured | 87 read, 0.05 s (2,162 off-screen rows read and dropped before the clip: 3 s, cut) | 26%: sparse (empty folder) |
| Calculator | not measured | 37 read, 0.03 s | 72%, 25 actionable: MacDriver |
| Calculator, cold launch without activation | | window in 0.45 s, Chrome kept the front | |
| Mail, inbox (50,340 messages) | 104 s | 246 read, 30 visible rows, 0.14 s | 73%, 101 actionable: MacDriver |
| Mail, a restored draft window | not measured | 56 read, 0.04 s | 26%: sparse |
| Mail, cold launch without activation | no window in 12 s (14 Oct) | first window in 2.05 s, the person's app kept the front | |

Mail was opened for that row and quit after. The coverage threshold went from 60% to 50%:
Settings, a rich window, covers 57%.

Background operations, 15 Oct (`braus mac pane|reveal|open-with`, `MacBackgroundOpener`), person in
Chrome, Chrome in front before and after every row:

| Operation | Route | Result |
| --- | --- | --- |
| Settings pane by name ("Suono"), Settings running | `x-apple.systempreferences:` link, `activates = false` | **verified** by the selected sidebar row, 1.33 s |
| Settings pane by id (Keyboard) | same | **verified**, 0.60 s |
| Reveal a file, Finder column view | `AXSelected` on the item, then `AXSelectedChildren` on its list | refused (`-25205`, attribute unsupported); column view has no selection state in the tree |
| Reveal a file | Finder's scripted `reveal` without `activate` (Automation already granted, checked without prompting) | **verified** by Finder's selection, 0.22 s, Finder stayed behind, existing window reused |
| Open a .txt with TextEdit, not running | `NSWorkspace.open(_:withApplicationAt:)`, `activates = false` | **verified** by the window, 0.28 s, TextEdit behind |

Rungs 1 and 2, 15 Oct (`braus mac act|type|key|scroll`: `MacScenes` with its cache, `MacActuator`,
`MacSettler`, `MacInPlaceDelivery`), the person's app in front before and after every row:

| Gesture, app behind | Rung | Result |
| --- | --- | --- |
| Calculator: AC, 7, ×, 6, = | 1, `AXPress` | **42**; each 5-25 ms to deliver, about 170 ms to settle |
| Calculator: key "5", then "3" twice | 2, `postToPid` with the key-window records | **533** on the display |
| TextEdit: click the text area, type | 1 focus (`AXMain`, `AXFocused`), then 2 text | typed text read back from the area |
| Finder: ⌘⇧N in the test folder's window | 2 with the key-window records | **new folder** in that folder, Finder behind |
| Settings sidebar: scroll a page | 1, scroll bar `AXValue` | 0 → 0.25 → 0.5 |
| Settings sidebar: click a row | 1, `AXSelected` | right row after the path fix; see below |
| Settings pane by name, cold launch | link after paging the sidebar | **verified** ("Generali" 0.96 s, "Suono" 1.74 s); no self-activation |

Found on the way:
- SwiftUI's sidebar lists `AXScroll…ByPage`, answers `-25205` (unsupported), scrolls anyway and the
  wrong way (Up moves down). Scrolls set the scroll bar's `AXValue` whenever there is a bar.
- SwiftUI's outline holds only the rows it draws: a pane's name is found by paging the sidebar.
- A path must count every child as read, skipped ones included: counting only recorded children
  selected a row two below the one asked (rows clipped at the top of the sidebar). Fixed; a row's
  stale check compares its texts, since it has no name of its own.
- Path ids shift when a sibling appears or goes (Calculator's display line): acting resolves the path
  again and refuses `stale_target` on another role or name.
- While the person used System Settings, row selections landed on other rows and Settings closed;
  with the desktop free and the path fix, 11 of 11 row selections landed right (6 rows, then 4 after
  two page scrolls with rows clipped at the top; a row out of sight is refused).
- Rule 6 (the person first): `LiveMacPersonWatch`, a listen-only tap on the annotated session stream,
  notes the person's clicks, keys and scrolls per target process (Input Monitoring, preflighted, never
  prompted). The person's clicks in System Settings were noted under its pid; events Braus posts to a
  pid and accessibility actions are not. `MacActuator` refuses a gesture with `personActed` when the
  person touched the app after its scene was read. Since T2B3 (M1, 16/10/2026) `MacControls`'s fast paths do too,
  with the same watch (the runtime passes it) and the same comparison (`lastTouch >= readAt`, whether or not the
  watch says it is running):
  - `pressControl` sends no `AXPress`, and the engine's click is then refused by the actuator, nothing sent;
  - `pressMenuItem` does not call the menu controller;
  - `chooseMenuItem` is refused, so the engine tries no keys. It checks on entry and again right before the
    delegation, and a touch found only at that last check refuses it too, never answers "not handled".

  The last check is made right before the press; a touch between it and the press is not seen. Proved with fakes
  only, no live run: `MacControlsTests`; `MacSessionTests.personFirstOnTheFastPath` (a closed pop-up, through the
  session) and `personFirstInTheOpenMenu` (an open menu, through the engine), both reading the archive.

Finder windows carry no `AXDocument`; the opener finds them by a title equal to the folder's name.
Not measured: a cold launch of System Settings (it was running and is the person's), the
accessibility rung of reveal in list view, a self-activating app (focus restore).

## 9. Decisions taken

1. Electron and Chromium apps go to the MacDriver after their tree is turned on, behind the coverage
   check.
2. Text: keys only, no `AXValue` writes on fields (L10), though two of the four projects write them.
3. Private SkyLight calls (`SLPSPostEventRecordTo`, `SLEventPostToPid`, `CGEventSetWindowLocation`) are
   used through `PrivateSymbols` behind the build ledger, fail-closed: a missing symbol is a refusal
   with its reason, then mode 1.
4. Stores the Mac syncs (EventKit, Contacts) go through adapters even when a website exists (rule 2).
5. The mode 2 live test also checks the person's front app: still active, same key window, no key loss.
6. Every gesture runs inside `MacFocusGuard` (15 Oct, issue #42). When the app came in front, the
   person's app is brought back unless they used the keyboard or mouse meanwhile. The outcome says
   so, and the next call hands the app to the seat (`MacHandoff.cameInFront`). Nothing is kept across
   sessions; at launch, `revert` (issue #51) sends a self-activating app back first. The whole call is
   guarded too, so the engine's own control and menu presses are covered. The router takes the handoff
   at the start of the next call: the seat opens the app and the same call runs there (issue #53).
   `revert` leaves a dialog or a sheet in front (a login, a permission prompt) and the seat takes the
   app (`MacHandoff.dialogInFront`). Every launch is logged to `mac-launches.jsonl` in the knowledge
   directory, to choose the launch style from data. Live case: Notes' "Nuova nota" press took
   6 s and left Notes in front, and the next `type_text` was refused by rule 6.

## 10. Open questions, with the default

For Tommaso (memory):

1. Can `app_call` be a step of a D2 procedure? Default: yes, recorded like `act`.
2. Which observed-effect kind is an adapter's read-back? Default: `valueChanged`, label the verb's key
   field.
3. Can each action record its route and rung? Default: yes, so the channel table is learned.
4. Where do rules decided by people live (rule 1, the catalogue), apart from measured facts?

Others:

5. Bluetooth power has no public setter. Default: the private call through `PrivateSymbols`, otherwise
   `unavailable`.
6. Which Focus mode is on has no public read. Default: on/off only.
7. Thresholds of the coverage check. Default: 60% and 10 actions.

## 11. Tests

- Unit: `MacSceneBuilder` on recorded trees (Notes, Settings, Finder, Calendar), the coverage check, the
  rung choice with a fake tree and a fake event sink, the router's rules, each adapter on a fake
  transport.
- Live (`BRAUS_MAC_LIVE_TESTS=1`): an AppKit fixture app driven while another app is in front, then the
  rows of section 8 rerun on throwaway data. Evidence for each PR: that table before and after.

## 12. Phases

1. **Router and adapters**: `TaskRouter` with the catalogue, `app_capabilities` / `app_call`, the
   System, EventKit and Files adapters, `braus adapters`.
   Built on `agent/5-mac-driver` (ForteAI-Org/braus#5). Not yet: the router's wiring into
   `RoutingAutomationSession` (waits for the web branch); System's Bluetooth and Focus verbs (questions 5
   and 6). Opening a Settings pane and Files' `reveal` and `open_with` moved to phase 2 (section 8). `app_call` is recorded like `act` with its outcome, under the
   adapter's bundle id, but is not a procedure step until question 1 is answered.
2. **MacDriver scene**: launcher (bundle id, localized names, self-activation, first-run sheets),
   batched visible-rows reader, windows, routing to the MacDriver; opening a Settings pane, `reveal` and
   `open_with` as background operations with the seat as fallback.
   On `agent/6-mac-scene` (ForteAI-Org/braus#6): targets `MacDriver` (`LiveMacTreeReader`,
   `MacLauncher`, `LiveMacWorkspace`) and `MacDriving` (`MacSceneBuilder`, `MacCoverage`, `MacScenes`,
   `MacWindows`), `braus mac open|windows|read|record`; `MacBackgroundOpener` for the Settings pane,
   `reveal` (Finder's script when permitted, else accessibility) and `open_with`, `braus mac
   pane|reveal|open-with`. The seat fallback for a window that appears on the person's screen, and
   routing to the MacDriver, wait for the session wiring (web branch).
3. On `agent/7-mac-actions` (ForteAI-Org/braus#7): `MacRungPlanner` (pure), `MacActuator` (`Actuating`),
   `MacSettler` (`Settling`, `LiveMacNotificationSource`), `MacInPlaceDelivery` (target `MacDelivery`,
   the seat's `InputDriver` aimed at a window in place), `MacAccessibilityActing` on the live reader.
   Rule 6: `LiveMacPersonWatch` and `personActed`. Not yet: `MacControls` (the engine's `AccessibilityController`
   is reused), the runtime that hands these roles to `ActionEngine`.
   Wiring on `agent/25-mac-wiring` (ForteAI-Org/braus-testing#25): `MacSession` (`MacEngineRuntime`,
   `MacAutomationSession`, `DriverRoutingAutomationSession`); `open_session` asks the `TaskRouter` first
   (`named` for rule 1); a native app goes to the MacDriver and comes back (`MacHandoff`) to the current
   Driver when its window reads sparse, is not the focused one, or stays in front of the person's (mode 1);
   web addresses are refused until the web session is merged. Rule 6 in the engine: an `ActuationRefusal`
   answers `refused` with its reason, or uncertain after part of an input, never retried. `braus chat`
   uses the routing session; the app's `BrokeredAutomationSession` does not yet, nor do `reveal` and
   `open_with`, which are no tools yet (their reports carry `focus.leftInFront`).
3. **Rungs 1 and 2**: accessibility actions with the guards above, the settler, mode 2 with the seat's
   preparation records, keys and SkyLight clicks.
4. **Mail, Notes, Messages adapters**, irreversible verbs with Boss's confirmation.
   On `agent/63-mac-adapters`: `MailAdapter`, `NotesAdapter`, `MessagesAdapter` on `AppleScriptRunner` (one
   fixed script per app, handlers called with Apple event parameters, the app started hidden, Automation
   checked without prompting), and `ContactsAdapter` on `MacContactsStore` (CNContactStore, never asks).
   A name where an address or a number belongs is refused, so a send never goes to a guess. Not yet:
   Mail replies and attachments; Messages over SMS or to a group; a live run with Automation granted
   to the host (on 16 Oct only availability and the scripts' compilation were checked live). Each adapter
   has `requestPermission()` (EventKit, Contacts, Automation), run by `braus adapters grant`.
5. **Modes 1 and 3** wired to the round 1 plan; the channel table learned from recorded outcomes.

Each phase is one issue and one `agent/<N>-<slug>` branch; Simone merges.
