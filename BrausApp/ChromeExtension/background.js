// The Braus extension: one instance runs in each Chrome profile it is installed in.
//
// Identity: a random instance ID made once and kept in this profile's chrome.storage.local (never sync, so it does
// not follow an account into another profile). It names the instance, not Chrome's profile directory, which no
// extension API gives.
// Pairing: explicit. The instance acts only after the person confirmed it on its own page (pair.html, the toolbar
// button), in this profile, under a name they give; that name is what Braus shows. Revoking it there detaches
// everything and leaves the person's tabs as they are.
// Channel: the native host `dev.forte.braus.chrome_profiles`, registered by the person (see README.md), which relays
// to the Braus app. Commands come from that port alone, each naming this instance; any other ID, or an unpaired
// instance, is refused before anything is done.
// What Braus may do here: open a tab, drive it through chrome.debugger, and close it; a tab a page of Braus's opens
// (a popup) is Braus's too, closed with it but not driven. Nothing else: no cookies, passwords or other tabs.
//
// State: what the instance holds (its pairing, Braus's tabs) lives in memory and changes synchronously, so two
// commands in flight never overwrite each other; a copy of Braus's tabs goes to chrome.storage.session, in order,
// for a restart of the worker.
// Connection: the instance connects as its worker starts and says hello, with its pairing, and nothing else. While
// it is paired, a dropped port (Braus quit, or was not running yet) is connected again after RECONNECT_MS, and an
// alarm wakes the worker every half minute to do so once Braus listens again: the pairing stays as it was, and no
// command runs until Braus sends one. An unpaired instance only says hello as its worker starts, so Braus learns of
// a pairing revoked while it was closed.
// Revocation: clears the pairing and advances the epoch at once, before anything awaits. A command checks the
// epoch after each await, before any new effect: one that started before a revocation does nothing more, and
// undoes only what it had just acquired (the tab it created, the debugger it attached).

const HOST = "dev.forte.braus.chrome_profiles";
const PROTOCOL = "1.3";
const REVOKED = "refused: the pairing was revoked meanwhile";
/// How long after the port drops the paired instance connects again, while its worker lives.
const RECONNECT_MS = 5000;
const RECONNECT_ALARM = "braus-reconnect";

const state = { instanceId: null, pairing: null, epoch: 0, tabs: new Set(), popups: new Set() };
let port = null;
let saving = Promise.resolve();

const ready = (async () => {
  const stored = await chrome.storage.local.get(["instanceId", "pairing"]);
  let instanceId = stored.instanceId;
  if (!instanceId) {
    instanceId = crypto.randomUUID();
    await chrome.storage.local.set({ instanceId });
  }
  const { tabs = [], popups = [] } = await chrome.storage.session.get(["tabs", "popups"]);
  state.instanceId = instanceId;
  state.pairing = stored.pairing ?? null;
  for (const tabId of tabs) state.tabs.add(tabId);
  for (const tabId of popups) state.popups.add(tabId);
})();

/// Saves a copy of Braus's tabs as they are now; the writes go in order, so the last one is the latest state.
function persist() {
  const copy = { tabs: [...state.tabs], popups: [...state.popups] };
  saving = saving.then(() => chrome.storage.session.set(copy)).catch(() => {});
  return saving;
}

/// Braus no longer owns `tabId`. Returns whether it did.
function forget(tabId) {
  const wasTab = state.tabs.delete(tabId);
  const wasPopup = state.popups.delete(tabId);
  if (wasTab || wasPopup) persist();
  return wasTab || wasPopup;
}

/// Whether a command that started at `epoch` may still act: the pairing holds and was not revoked since.
function current(epoch) {
  return state.pairing !== null && state.epoch === epoch;
}

function post(message) {
  port?.postMessage(message);
}

async function connect() {
  await ready;
  if (port) return;
  port = chrome.runtime.connectNative(HOST);
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    port = null;
    setTimeout(reconnect, RECONNECT_MS);
  });
  port.onMessage.addListener((message) => {
    handle(message).catch((error) => {
      const text = String(error?.message ?? error);
      if (message.type === "cdp") {
        post({ type: "cdpResult", tabId: message.tabId, id: message.id, error: { message: text } });
      }
      else post({ type: "result", requestId: message.requestId, ok: false, error: text });
    });
  });
  const { instanceId, pairing } = state;
  post({ type: "hello", instanceId, paired: pairing !== null, label: pairing?.label ?? null });
}

/// Connects again only while paired: an unpaired instance waits for its pairing page.
function reconnect() {
  if (state.pairing !== null) connect();
}

async function handle(message) {
  await ready;
  if (message.instanceId !== state.instanceId) throw new Error("refused: this command names another instance");
  if (state.pairing === null) throw new Error("refused: this profile is not paired with Braus");
  const epoch = state.epoch;
  switch (message.type) {
    case "openTab":
      return openTab(message, epoch);
    case "closeTab":
      return closeTab(message, epoch);
    case "cdp": {
      if (!state.tabs.has(message.tabId)) throw new Error("refused: Braus does not drive that tab");
      const result = await chrome.debugger.sendCommand({ tabId: message.tabId }, message.method, message.params ?? {});
      post({ type: "cdpResult", tabId: message.tabId, id: message.id, result: result ?? {} });
      return;
    }
    default:
      throw new Error(`refused: unknown command ${message.type}`);
  }
}

/// Opens a tab and attaches the debugger to it. When attaching fails, or the pairing was revoked meanwhile, the tab
/// this command created is closed and the first error is the one reported.
async function openTab(message, epoch) {
  const tab = await chrome.tabs.create({ url: message.url ?? "about:blank", active: false });
  if (!current(epoch)) {
    await chrome.tabs.remove(tab.id).catch(() => {});
    throw new Error(`${REVOKED}: the tab it had just opened was closed`);
  }
  try {
    await chrome.debugger.attach({ tabId: tab.id }, PROTOCOL);
  } catch (error) {
    await chrome.tabs.remove(tab.id).catch(() => {});
    throw error;
  }
  if (!current(epoch)) {
    await chrome.debugger.detach({ tabId: tab.id }).catch(() => {});
    await chrome.tabs.remove(tab.id).catch(() => {});
    throw new Error(`${REVOKED}: the tab it had just opened was detached and closed`);
  }
  state.tabs.add(tab.id);
  persist();
  post({ type: "result", requestId: message.requestId, ok: true, tabId: tab.id });
}

/// Closes a tab Braus owns. Once the pairing is revoked, the tab is left open as the revocation leaves it.
async function closeTab(message, epoch) {
  const tabId = message.tabId;
  if (!forget(tabId)) throw new Error("refused: Braus did not open that tab");
  await chrome.debugger.detach({ tabId }).catch(() => {});
  if (!current(epoch)) throw new Error(`${REVOKED}: the tab was detached and left open`);
  await chrome.tabs.remove(tabId).catch(() => {});
  post({ type: "result", requestId: message.requestId, ok: true, tabId });
}

chrome.debugger.onEvent.addListener((source, method, params) => ready.then(() => {
  if (state.tabs.has(source.tabId)) post({ type: "cdpEvent", tabId: source.tabId, method, params: params ?? {} });
}));

// The person cancelled the debugging bar, or the tab went: Braus no longer drives it and no longer owns it.
chrome.debugger.onDetach.addListener((source, reason) => ready.then(() => {
  if (!state.tabs.has(source.tabId)) return;
  forget(source.tabId);
  post({ type: "detached", tabId: source.tabId, reason });
}));

chrome.tabs.onRemoved.addListener((tabId) => ready.then(() => {
  if (forget(tabId)) post({ type: "tabClosed", tabId });
}));

chrome.tabs.onCreated.addListener((tab) => ready.then(() => {
  if (state.pairing === null || tab.openerTabId === undefined || !state.tabs.has(tab.openerTabId)) return;
  state.popups.add(tab.id);
  persist();
  post({ type: "popup", tabId: tab.id, openerTabId: tab.openerTabId });
}));

// The pairing page: confirm under a name, or revoke.
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id) return false;
  (async () => {
    await ready;
    if (message?.type === "confirmPairing") {
      const label = typeof message.label === "string" ? message.label.trim() : "";
      if (label === "") return reply({ ok: false, error: "a name is needed" });
      state.pairing = { label, confirmedAt: new Date().toISOString() };
      await chrome.storage.local.set({ pairing: state.pairing });
      await connect();
      post({ type: "paired", instanceId: state.instanceId, label });
      return reply({ ok: true, label });
    }
    if (message?.type === "revokePairing") {
      // At once, before anything awaits: no command in flight does anything more, and no new one starts.
      state.pairing = null;
      state.epoch += 1;
      const attached = [...state.tabs];
      state.tabs.clear();
      state.popups.clear();
      persist();
      await chrome.storage.local.remove("pairing");
      post({ type: "revoked", instanceId: state.instanceId });
      for (const tabId of attached) await chrome.debugger.detach({ tabId }).catch(() => {});
      return reply({ ok: true });
    }
    if (message?.type === "status") {
      await connect();
      const { instanceId, pairing } = state;
      return reply({ ok: true, instanceId, label: pairing?.label ?? null, connected: port !== null });
    }
    reply({ ok: false, error: "unknown request" });
  })().catch((error) => reply({ ok: false, error: String(error) }));
  return true;
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM) ready.then(reconnect);
});

// Added to a profile for the first time, the instance opens its own pairing page, where the person names the profile;
// an update or a reload opens nothing.
chrome.runtime.onInstalled.addListener((details) => {
  if (details?.reason === "install") chrome.tabs.create({ url: chrome.runtime.getURL("pair.html") });
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.get(RECONNECT_ALARM).then((alarm) => {
  if (!alarm) chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
});
connect();
