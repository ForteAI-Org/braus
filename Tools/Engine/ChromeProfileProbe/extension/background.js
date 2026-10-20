// Braus profile probe, a test fixture: one instance of this extension runs in each Chrome profile it is loaded in.
//
// Identity: a random instance ID made once and kept in this profile's chrome.storage.local (never sync, so it does
// not follow an account into another profile). It names the instance, not Chrome's profile directory, which no
// extension API gives.
// Pairing: explicit. The instance acts only after the person confirmed the pairing on its own page (pair.html), in
// this profile, with a name they assign; the name is what Braus shows, never a site's account.
// Channel: the native messaging host `dev.forte.braus.profile_probe`, which the probe run installs in its temporary
// user data directory only. Commands come from that port alone; each names the instance it is for, and any other
// instance ID, or an unpaired instance, is refused before anything is opened.
// Scope: it opens pages on 127.0.0.1 only, reads their visible text, and closes only the tabs it opened. It reads no
// cookie and copies nothing.

const HOST = "dev.forte.braus.profile_probe";
const LOCAL_PAGE = /^http:\/\/127\.0\.0\.1:\d+\//;
const LOAD_TIMEOUT_MS = 15000;

let port = null;

/// The instance's ID, made once and kept in this profile's local storage; and its pairing, if confirmed.
async function identity() {
  const stored = await chrome.storage.local.get(["instanceId", "pairing"]);
  if (stored.instanceId) return { instanceId: stored.instanceId, pairing: stored.pairing ?? null };
  const instanceId = crypto.randomUUID();
  await chrome.storage.local.set({ instanceId });
  return { instanceId, pairing: null };
}

/// The tabs this instance opened, kept for the service worker's lifetime and across its restarts in this session.
async function openedTabs() {
  return (await chrome.storage.session.get("opened")).opened ?? [];
}

async function setOpenedTabs(tabs) {
  await chrome.storage.session.set({ opened: tabs });
}

async function connect() {
  if (port) return;
  port = chrome.runtime.connectNative(HOST);
  port.onDisconnect.addListener(() => {
    port = null;
  });
  port.onMessage.addListener((message) => {
    const requestId = message.requestId;
    handle(message).then(
      (answer) => port?.postMessage({ type: "result", requestId, ok: true, ...answer }),
      (error) => port?.postMessage({ type: "result", requestId, ok: false, error: String(error.message ?? error) })
    );
  });
  const { instanceId, pairing } = await identity();
  port.postMessage({ type: "hello", instanceId, paired: pairing !== null, label: pairing?.label ?? null });
}

/// One command from the run. Every command but `openPairing` names this instance and needs its pairing.
async function handle(message) {
  const { instanceId, pairing } = await identity();
  if (message.type === "openPairing") {
    const tab = await chrome.tabs.create({ url: chrome.runtime.getURL("pair.html"), active: false });
    return { tabId: tab.id };
  }
  if (message.instanceId !== instanceId) throw new Error("refused: this command names another instance");
  if (pairing === null) throw new Error("refused: this instance is not paired");
  switch (message.type) {
    case "open":
      return open(message.url);
    case "close":
      return close(message.tabId);
    default:
      throw new Error(`refused: unknown command ${message.type}`);
  }
}

async function open(url) {
  if (typeof url !== "string" || !LOCAL_PAGE.test(url)) throw new Error("refused: only 127.0.0.1 pages are opened");
  const tab = await chrome.tabs.create({ url, active: false });
  await setOpenedTabs([...(await openedTabs()), tab.id]);
  await loaded(tab.id);
  const [read] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: () => (document.body ? document.body.innerText : ""),
  });
  return { tabId: tab.id, text: read?.result ?? "" };
}

async function close(tabId) {
  const opened = await openedTabs();
  if (!opened.includes(tabId)) throw new Error("refused: this instance did not open that tab");
  await chrome.tabs.remove(tabId);
  await setOpenedTabs(opened.filter((id) => id !== tabId));
  return { tabId };
}

/// Resolves once the tab finished loading, or rejects after LOAD_TIMEOUT_MS.
function loaded(tabId) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => finish(new Error("the page did not load in time")), LOAD_TIMEOUT_MS);
    function listener(id, change) {
      if (id === tabId && change.status === "complete") finish();
    }
    function finish(error) {
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      if (error) reject(error);
      else resolve();
    }
    chrome.tabs.onUpdated.addListener(listener);
    chrome.tabs.get(tabId).then((tab) => {
      if (tab.status === "complete") finish();
    }, () => {});
  });
}

// The pairing page's confirmation, from this profile only (an extension page of this instance).
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message?.type !== "confirmPairing" || sender.id !== chrome.runtime.id) return false;
  const label = typeof message.label === "string" ? message.label.trim() : "";
  if (label === "") {
    reply({ ok: false, error: "a name is needed" });
    return false;
  }
  (async () => {
    const { instanceId } = await identity();
    await chrome.storage.local.set({ pairing: { label, confirmedAt: new Date().toISOString() } });
    await connect();
    port?.postMessage({ type: "paired", instanceId, label });
    reply({ ok: true, instanceId, label });
  })().catch((error) => reply({ ok: false, error: String(error) }));
  return true;
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
