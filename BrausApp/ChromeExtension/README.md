# Braus extension: your Chrome profiles in Braus

The Braus extension lets a conversation open its web pages in one of your
Chrome profiles, signed in as that profile, in tabs Braus opens and closes.
You choose the profile in each conversation (Inspector, Web, Chrome Profile).
The setting is off by default.

What it never does:

- read cookies or passwords, use the keychain, or copy a profile;
- touch a tab Braus did not open;
- find your Chrome profiles on its own. A profile appears in Braus only after
  you pair it, under a name you give it;
- name Chrome's profile directory, which no extension can know. Braus knows
  the extension instance's random ID (kept in that profile only) and your
  name for it;
- fall back to another profile, Braus's own Chrome or the desktop when the
  chosen profile cannot be used. Braus stops and tells the worker to ask you.

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Extension | `BrausApp/ChromeExtension` (ID `edkkpkeigbhcbmkpoglcgnklpmoemnje`) | One instance per profile you install it in: pairing, and Braus's tabs through `chrome.debugger` |
| Native host | `Braus.app/Contents/Helpers/braus-chrome-host` | Started by Chrome for each instance; relays to Braus and interprets nothing |
| Hub | Inside Braus, socket `~/Library/Application Support/Braus/ChromeProfiles/hub.sock` | Paired profiles, their connection, and which tab belongs to which conversation |

Braus listens only when its web channel is on (`computer.channels` includes
`web`, in Settings or with the launch argument `-computer.channels web`).

## 1. Register the native host (once per Chrome)

Chrome starts only the hosts registered in its own folder. Write this file,
replacing `HOST` with the absolute path of `braus-chrome-host` inside the
Braus.app you run:

```json
{
  "name": "dev.forte.braus.chrome_profiles",
  "description": "Braus: relays the Braus extension of a paired Chrome profile to the Braus app",
  "path": "HOST",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://edkkpkeigbhcbmkpoglcgnklpmoemnje/"]
}
```

Name the file `dev.forte.braus.chrome_profiles.json` and put it in one of
these folders:

| Chrome | Folder |
|---|---|
| Google Chrome | `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` |
| Chrome for Testing | `~/Library/Application Support/Google/Chrome for Testing/NativeMessagingHosts/` |
| Any Chrome started with `--user-data-dir=DIR` | `DIR/NativeMessagingHosts/` |

The registration covers every profile of that Chrome. A profile still does
nothing until the extension is installed and paired in it.

If Braus runs with `BRAUS_APP_SUPPORT_DIR`, its socket is under that folder.
In that case set `path` to a small script that runs
`braus-chrome-host --socket <that folder>/ChromeProfiles/hub.sock`. Chrome
passes the host no argument of yours.

## 2. Install the extension in a profile

In that profile, open `chrome://extensions`, turn on Developer mode, choose
Load unpacked, and select `BrausApp/ChromeExtension`.

Chrome asks you to accept these permissions:

- **Debugger:** drives the tabs Braus opens.
- **Tabs:** knows which tabs are Braus's.
- **Native messaging:** reaches Braus.
- **Storage:** keeps the instance's ID and your pairing.
- **Alarms:** connects again when Braus starts later.

The extension can only ask for these permissions. Accepting them is your
decision.

## 3. Pair the profile

Click the Braus button in the toolbar (pin it from the puzzle menu), or open
`chrome-extension://edkkpkeigbhcbmkpoglcgnklpmoemnje/pair.html`. Type the name
Braus should show, such as "Personale" or "Lavoro", and choose Confirm. The
page reads "Paired as … ; connected to Braus" once Braus is running.

Pair each profile you want on its own page. The instance keeps its ID and
pairing in that profile's local storage, which is never synced.

## 4. Choose it in a conversation

In Braus, open the Inspector, find Web, and pick the profile under Chrome
Profile. Each entry is shown as connected or Not Connected. The choice:

- applies to that conversation only, and is kept across launches;
- takes precedence over Use My Chrome and Show Chrome Window;
- if changed during a turn, stops what Braus was doing in the profile chosen
  before. Nothing more is sent there, and from the next turn pages open as
  you now chose.

While Braus drives a tab, Chrome shows its bar "Braus started debugging this
browser". Cancelling that bar takes the tab back from Braus.

## Revoke and remove

- **Revoke:** open the pairing page and choose Revoke. Braus stops at once,
  detaches from its tabs and leaves them open. The profile disappears from
  Braus, and a conversation that had chosen it is refused until you choose
  again.
- **Remove:** revoke first, then remove the extension in `chrome://extensions`
  and delete the host file from step 1. A profile whose extension was removed
  without revoking stays in Braus as Not Connected.

## Connection

The instance connects to Braus when Chrome starts, when you open its pairing
page, and while it is paired:

- a few seconds after Braus closes;
- every half minute while Braus is not running.

Connecting only says which instance it is and whether it is paired. Nothing
runs in the profile until Braus sends a command for a conversation that chose
it.

## Tests

`node --test Tests/ChromeExtension/background.test.mjs` runs the extension's
worker against a fake `chrome`: attach refused, two opens at once, revocation
during an open, and reconnection. The hub, the transport and the web session
are tested offline in `Tests/Web/ChromeProfilesTests` and
`Tests/Integration/WebSessionTests/ChromeProfileSessionTests.swift`. Neither
runs Chrome.
