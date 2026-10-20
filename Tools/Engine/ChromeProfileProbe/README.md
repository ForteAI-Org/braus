# Chrome profile probe (test fixture)

**What it is:** a prototype of route B in the closure evidence's `handoffs/chrome-profile-selection-proposal.md`. It
lets Braus choose among several Chrome profiles through an extension paired in each profile, and native messaging.
**It is a test fixture, not product code:** nothing in Braus's runtime or app uses it.

## Pieces

| File | Role |
|---|---|
| `extension/` | an MV3 extension, one instance per profile; see below |
| `profile_probe_host.py` | the native messaging host; see below |
| `run_probe.py` | the two-profile probe, and `--self-check` |

**The extension:**
- **Identity:** a random instance ID made once in that profile's `chrome.storage.local`, never `sync`.
- **Pairing:** only when the person confirms on the instance's own page (`pair.html`), under a name they give there.
- **Commands:** only through its native port, and only those naming its own ID once paired.
- **What it does:** it opens `127.0.0.1` pages, reads their visible text, and closes only the tabs it opened.
- **What it never does:** read cookies or copy anything.

**The host:** a relay between Chrome's stdio framing and the run's Unix socket, kept in a 0700 directory. It
interprets nothing.

**The probe:**
- **Chrome:** a test build, on a temporary user data directory, with profiles `Alfa` and `Beta`.
- **Ground truth:** a local site gives each profile a synthetic account (carla, dario), set through Chrome's own
  `--profile-directory` routing.
- **The person:** played by the harness, which confirms each pairing page as "Fixture Alfa" or "Fixture Beta" through
  the fixture Chrome's DevTools pipe.

## The probe's checks

1. Two instances say hello with two IDs.
2. Each profile is paired under its own name to its own instance.
3. Choosing "Fixture Beta", then "Fixture Alfa", then "Fixture Beta" again: the page and the site each time show the
   account of the profile chosen (dario, carla, dario). The pairing name is never the account.
4. An ID no instance has is refused by the run with nothing sent to Chrome and nothing opened, so it can make no
   profile. A listing of the user data directory's top-level directories is kept only as an observation: while
   Chrome runs, a profile's files (such as `Preferences`) may not be written yet, so the listing does not attest
   which profiles exist.
5. An instance asked to act for another instance's ID refuses.
6. Each instance closes only its own tabs. The browser keeps running, and every tab it had before stays.

## Commands

**No Chrome at all:** the files, the extension ID, the host's manifest and framing.

```bash
python3 -I Tools/Engine/ChromeProfileProbe/run_probe.py --self-check
```

**The probe:** headless by default, with a test build of Chrome. Run it only with the host coordinated.

```bash
python3 -I Tools/Engine/ChromeProfileProbe/run_probe.py --chrome "/Users/ronaldozefi/.cache/puppeteer/chrome/mac_arm-152.0.7977.42/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
```

**Options:**
- `--headed` shows the fixture's windows;
- `--keep` keeps the temporary directory and its `report.json`.

**Exit codes:**
- 0: every check passed;
- 1: a check failed, or an error no check expected ended the run (the report then says `ERROR`);
- 2: blocked, meaning Chrome did not do what the fixture needs.

## Safety

- **The personal Chrome:** `/Applications/Google Chrome.app` is refused as the browser, so it stays untouched.
- **Profiles and data:** everything is in a new temporary directory. No personal profile, account or data is used,
  and the keychain is mocked (`--use-mock-keychain`).
- **The native host:** its manifest is written to `<temporary user data dir>/NativeMessagingHosts`, where Chrome
  looks for a user's hosts (`chrome/common/chrome_paths.cc`, `DIR_USER_NATIVE_MESSAGING`). Nothing is registered in
  `~/Library` or system-wide.
- **The fixture's Chrome** is ended by its own process ID only.

## Limits (what a pass does not show)

- **A test build is not the person's Chrome.** Chrome for Testing 152 is not Chrome 155. Branded Chrome builds may
  ignore `--load-extension`, so the person's Chrome needs the extension installed another way, which is not covered
  here.
- **The ID names the instance, not Chrome's profile directory.** No extension API gives the directory. The probe
  attests "the instance paired as X", and its ground truth is the site account set through `--profile-directory`.
- **Isolation between instances** is shown only for this fixture's two profiles.
- **Possible blocks, reported as `BLOCKED` with no workaround:**
  - `--load-extension` not applied to a profile opened by a forwarded launch;
  - a forwarded launch not reaching a headless browser.
