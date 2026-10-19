# Web engine

Braus drives web pages with the same engine, the same tools and the same living memory it uses for
applications. A page is not captured as pixels: Braus starts its own Chrome, talks to it over the
DevTools protocol through a pipe, and reads each page's accessibility tree and layout. The engine
sees a tab the way it sees a window, and what a page teaches is filed under `web:<host>` the way an
application's knowledge is filed under its bundle id.

## Shape

| Module | What it owns |
|---|---|
| `WebDriver` (`Sources/Web`) | Chrome over its DevTools pipe, Foundation only: `ChromeProcess` starts Chrome with `--remote-debugging-pipe`, and `--headless` unless a window is asked for, with the pipe on descriptors 3 and 4; `CDPConnection` is the protocol connection (NUL-framed JSON, command ids, timeouts, flattened sessions, events by session); `WebBrowser` opens, lists and attaches pages; `WebPage` sends commands in its session, navigates and evaluates. `ChromeLaunchOptions.brausProfile` is Braus's own profile, never the user's everyday one |
| `WebDriving` (`Sources/Web`) | a page as the engine's roles see a window. `WebTabs` names each tab with a synthetic negative process id, because every role is keyed by one. `WebScenes` is `SceneProviding`: `Accessibility.getFullAXTree`, `DOMSnapshot.captureSnapshot` and `Page.getLayoutMetrics`, built into a scene by `WebSceneBuilder`. `WebActuator` is `Actuating` over `Input.dispatchMouseEvent`, `dispatchKeyEvent` and `insertText` (`WebKeys` maps macOS key codes to DOM keys). `WebControls` is `ControlPressing` over the page's DOM; `WebSettler` is `Settling` on a DOM signature; `WebWindows` is `WindowListing` for a tab |
| `WebSession` (`Sources/Integration`) | `WebEngineRuntime`, `EngineRuntime` over the web roles; `WebAutomationSession`, the session on one tab behind the tools; `RoutingAutomationSession`, which sends `web:` and URLs to the web session and every other name to the desktop one, so `AutomationTools` needs no change |

## The scene

`WebSceneBuilder` walks Chrome's tree from the root and keeps what is painted inside the viewport:

- **Roles.** Chrome's role names become the accessibility roles the engine already acts on:
  `button` is `AXButton` (`AXCheckBox` when it has `pressed`), `link` `AXLink`, `textbox` and
  `searchbox` `AXTextField` or `AXTextArea` (multiline), an editable `combobox` `AXComboBox` and a
  `<select>` `AXPopUpButton`, `checkbox` and `switch` `AXCheckBox`, `radio` and `tab`
  `AXRadioButton`, `menuitem` `AXMenuItem`, `slider` `AXSlider`, `row`, `treeitem` and `option`
  `AXRow`, a named `img` `AXImage`, `heading` and `StaticText` `AXStaticText`. State comes from
  `checked`, `pressed` and `selected`, availability from `disabled`, a field's text from its value.
- **Text.** Text a control, a heading or a `<label>` already says is not repeated. Whitespace runs
  read as one space; a text or a row longer than 80 characters is cut and ends with an ellipsis.
- **Sections and containers.** Landmarks (`banner` as header, `navigation`, `main`, `complementary`
  as sidebar, `contentinfo` as footer, `search`), dialogs, and named forms and regions are the
  scene's sections and the first steps of an element's container; named groups, toolbars, tab lists
  and menus add theirs. Tables, grids, trees and list boxes are collection paths.
- **Geometry.** Layout boxes are in document coordinates; the scroll offset moves them into the
  viewport, and every bound is normalized to it. The window is the viewport at the origin, so a
  scene's global point is a CSS pixel of the page, which is what the actuator sends.
- **Identity.** Ids are `SceneIdentity.key`, and twins read apart by ` #n` as in the desktop
  harvest. The scene's bundle id is `web:<host>` (`www.` dropped), `web:file` for a local file and
  `web:blank` for a page with no host.
- **Quality.** The tree is read whole, so the capture is complete unless the 600-element limit
  stopped it; the memory relies on that statement as it does on a desktop capture's.

## Native selects

Chrome draws a `<select>`'s list outside the page, where neither the scene nor a click reaches it.
`WebControls.pressControl` therefore opens a list Braus draws instead (`WebSelectPopup`): the scene
shows the options as `AXMenuItem` elements in a `pop-up (<name>)` section over what they cover, and
`WebWindows` lists a menu-layer window in front of the page. The engine then treats it as any open
pop-up: a click on an option goes to `pressMenuItem`, which chooses it the way browser-use does
(focus, set the value, dispatch `input` and `change`, blur) and reads the value back. Escape or a
click outside closes it. Custom ARIA dropdowns are ordinary page content and are clicked as such.

## Sessions and the memory

`open_session` with `web:<host>` or a URL starts Chrome on first use and loads the page; another
address loads in the same tab. Every call then goes through the same `ActionEngine` and the call's
`CallRecorder` as a desktop session's, so the living memory records the page's scenes, the agent's
actions and the task's procedure candidates under `web:<host>` with no change to its logic.
Opening an application closes the web session, and opening an address closes the desktop one.

`RoutingAutomationSession` sends `web:<host>` and `http(s)://` addresses to the web session and
every other name to the desktop (Seat) session; a window id below zero is a tab, listed by the web
session. A `file://` address goes to the web session too, which refuses it with a sentence unless it
was made with `allowsLocalFiles`: a local file opened in Chrome would be read into the scene, the
model's context and the memory, whatever it holds. Only the tests' local fixtures turn it on.

In the app the web is off unless the `computer.web` preference is on (a launch argument
`-computer.web YES` turns it on for one run). With it, every external MCP client and every worker
conversation drives a `RoutingAutomationSession`, and `open_session`'s description and the
instructions teach `web:<host>`; without it they say nothing of it and no Chrome is ever started.
The desktop side goes through the seat queue as before, the web side takes no seat. They all use
one Chrome profile, `chrome-web` in the app's directory, and Chrome lets one process at a time use a
profile, so a second web session is refused with a sentence until the first closes.

Each conversation has its own web session. A turn that starts in another conversation of the same
worker closes it, as do releasing the worker's computer and quitting. The inspector's Show Chrome
Window switch, kept per conversation, starts that conversation's Chrome visible instead of headless:
Chrome is started with `--no-startup-window` and its tab opened in the background in a new window,
so the window never takes the person's focus. A change applies the next time Chrome starts; a
Chrome idle between turns is closed at once.

## Tests

```bash
swift test --filter "WebDriverTests|WebDrivingTests|WebSessionTests"
BRAUS_WEB_LIVE_TESTS=1 swift test --filter "WebDriverTests|WebDrivingTests|WebSessionTests"
```

The live tests need Google Chrome in `/Applications`, use a throwaway profile and a local fixture,
reach no network and leave no Chrome running. One drives `open_session`, `type_text`, `act`,
`select` and `memory_task` through `AutomationTools` and reads the archive afterwards. The visible
window test (`BRAUS_WEB_WINDOW_TESTS=1`) opens a Chrome window on the person's screen and checks
that the frontmost application never changes.

## Limits

- Only the main frame is read: iframes are neither in the scene nor clickable by name.
- `<input list>` suggestions and the date, time and color pickers are drawn outside the page and are
  not handled yet.
- Nested scroll containers do not clip their content: an element scrolled out of an inner panel but
  inside the viewport is still in the scene.
