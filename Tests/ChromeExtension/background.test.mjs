// The Braus extension's background worker, offline: a fake `chrome` stands in for the browser, and the test decides
// when each tab creation and debugger attach completes. No Chrome runs.
//
//   node --test Tests/ChromeExtension/background.test.mjs
//
// BRAUS_BACKGROUND names another background.js to run the same cases against.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const source = process.env.BRAUS_BACKGROUND
  ?? fileURLToPath(new URL("../../BrausApp/ChromeExtension/background.js", import.meta.url));

function event() {
  const listeners = [];
  return {
    addListener: (listener) => listeners.push(listener),
    fire: (...values) => listeners.forEach((listener) => listener(...values)),
  };
}

/// A fake `chrome` for one profile's instance, paired as "Personale". `tabs.create` and `debugger.attach` wait
/// until the test settles them, in `waiting`; every other call completes at once and is recorded in `calls`.
function fakeChrome() {
  const local = { instanceId: "instance-A", pairing: { label: "Personale", confirmedAt: "2026-10-17T09:00:00Z" } };
  const session = {};
  const calls = [];
  const posted = [];
  const waiting = { create: [], attach: [] };
  const port = { messages: event() };
  const ports = [];
  const timers = [];
  const alarms = {};
  const area = (store) => ({
    get: async (keys) => Object.fromEntries(
      keys.filter((key) => key in store).map((key) => [key, structuredClone(store[key])]),
    ),
    set: async (items) => { Object.assign(store, structuredClone(items)); },
    remove: async (key) => { delete store[key]; },
  });
  const held = (kind, value) => new Promise((resolve, reject) => waiting[kind].push({ value, resolve, reject }));
  const fake = {
    local, session, calls, posted, waiting, port, ports, timers, alarms, alarmEvents: event(),
    pageMessages: event(), detaches: event(),
    chrome: {
      storage: { local: area(local), session: area(session) },
      runtime: {
        id: "braus-extension",
        getURL: (path) => `chrome-extension://braus-extension/${path}`,
        connectNative: (host) => {
          const native = { host, postMessage: (message) => posted.push(structuredClone(message)),
                           onDisconnect: event(), onMessage: port.messages };
          ports.push(native);
          return native;
        },
        onStartup: event(),
        onInstalled: event(),
      },
      tabs: {
        create: (options) => { calls.push(["tabs.create", options.url ?? null]); return held("create", options); },
        remove: async (tabId) => { calls.push(["tabs.remove", tabId]); },
        onRemoved: event(),
        onCreated: event(),
      },
      debugger: {
        attach: (target) => { calls.push(["debugger.attach", target.tabId]); return held("attach", target); },
        detach: async (target) => { calls.push(["debugger.detach", target.tabId]); },
        sendCommand: async (target, method) => {
          calls.push(["debugger.sendCommand", target.tabId, method]);
          return {};
        },
        onEvent: event(),
      },
    },
  };
  fake.chrome.alarms = {
    get: async (name) => alarms[name],
    create: async (name, info) => { alarms[name] = { name, ...info }; },
    onAlarm: fake.alarmEvents,
  };
  fake.chrome.runtime.onMessage = fake.pageMessages;
  fake.chrome.debugger.onDetach = fake.detaches;
  return fake;
}

async function settle() {
  for (let turn = 0; turn < 20; turn += 1) await new Promise((resolve) => setImmediate(resolve));
}

async function load(fake) {
  const context = vm.createContext({
    chrome: fake.chrome, crypto: globalThis.crypto, console,
    setTimeout: (callback, delay) => fake.timers.push({ callback, delay }),
  });
  vm.runInContext(readFileSync(source, "utf8"), context, { filename: source });
  await settle();
}

/// A command from Braus, through the native port, to this instance.
function command(fake, message) {
  fake.port.messages.fire({ instanceId: "instance-A", ...message });
}

/// A request from the instance's own pairing page; resolves with its reply.
function ask(fake, message) {
  return new Promise((resolve) => {
    fake.pageMessages.fire(message, { id: "braus-extension" }, (answer) => resolve(structuredClone(answer)));
  });
}

function resultOf(fake, requestId) {
  const results = fake.posted.filter((message) => message.type === "result" && message.requestId === requestId);
  assert.equal(results.length, 1, `one result for ${requestId}: ${JSON.stringify(fake.posted)}`);
  return results[0];
}

/// Whether the instance drives `tabId` now: a DevTools command to it is relayed, not refused.
async function drives(fake, tabId, id) {
  command(fake, { type: "cdp", tabId, id, method: "Runtime.evaluate", params: { expression: "1" } });
  await settle();
  const answer = fake.posted.find((message) => message.type === "cdpResult" && message.id === id);
  return answer !== undefined && answer.error === undefined;
}

const called = (fake, ...call) => fake.calls.some((entry) => JSON.stringify(entry) === JSON.stringify(call));

test("an attach the browser refuses: the tab just opened is closed, and that error is the one reported", async () => {
  const fake = fakeChrome();
  await load(fake);
  command(fake, { type: "openTab", requestId: "r1", url: "about:blank" });
  await settle();
  fake.waiting.create.shift().resolve({ id: 5 });
  await settle();
  fake.waiting.attach.shift().reject(new Error("Cannot attach to this target"));
  await settle();
  assert.deepEqual(resultOf(fake, "r1"),
                   { type: "result", requestId: "r1", ok: false, error: "Cannot attach to this target" });
  assert.ok(called(fake, "tabs.remove", 5), "the tab this command created is closed");
  assert.deepEqual(fake.session.tabs ?? [], []);
  assert.equal(await drives(fake, 5, 1), false);
});

test("two opens at once keep both tabs, and a tab detached meanwhile is not owned again", async () => {
  const fake = fakeChrome();
  fake.session.tabs = [3];
  fake.session.popups = [];
  await load(fake);
  command(fake, { type: "openTab", requestId: "r1" });
  command(fake, { type: "openTab", requestId: "r2" });
  await settle();
  const [first, second] = fake.waiting.create.splice(0);
  first.resolve({ id: 5 });
  await settle();
  // The person cancels the debugging bar of Braus's earlier tab while both opens are under way.
  fake.detaches.fire({ tabId: 3 }, "canceled_by_user");
  await settle();
  second.resolve({ id: 6 });
  await settle();
  const [attachFirst, attachSecond] = fake.waiting.attach.splice(0);
  attachSecond.resolve();
  await settle();
  attachFirst.resolve();
  await settle();
  assert.equal(resultOf(fake, "r1").tabId, 5);
  assert.equal(resultOf(fake, "r2").tabId, 6);
  assert.deepEqual([...fake.session.tabs].sort(), [5, 6], "the saved copy keeps both and not the detached tab");
  assert.equal(await drives(fake, 5, 1), true);
  assert.equal(await drives(fake, 6, 2), true);
  assert.equal(await drives(fake, 3, 3), false, "the detached tab stays the person's");
});

test("a revocation during an open: nothing more is done, and only what the open had acquired is undone", async () => {
  const fake = fakeChrome();
  await load(fake);

  // While the tab is being created: no debugger is attached to it, and it is closed.
  command(fake, { type: "openTab", requestId: "r1" });
  await settle();
  assert.deepEqual(await ask(fake, { type: "revokePairing" }), { ok: true });
  fake.waiting.create.shift().resolve({ id: 5 });
  await settle();
  assert.equal(called(fake, "debugger.attach", 5), false, "no new effect after the revocation");
  assert.ok(called(fake, "tabs.remove", 5));
  assert.equal(resultOf(fake, "r1").ok, false);
  assert.match(resultOf(fake, "r1").error, /revoked/);

  // While the debugger is attaching, after the person paired the profile again: it is detached and the tab closed.
  assert.deepEqual(await ask(fake, { type: "confirmPairing", label: "Personale" }), { ok: true, label: "Personale" });
  command(fake, { type: "openTab", requestId: "r2" });
  await settle();
  fake.waiting.create.shift().resolve({ id: 6 });
  await settle();
  assert.deepEqual(await ask(fake, { type: "revokePairing" }), { ok: true });
  fake.waiting.attach.shift().resolve();
  await settle();
  assert.ok(called(fake, "debugger.detach", 6) && called(fake, "tabs.remove", 6));
  assert.equal(resultOf(fake, "r2").ok, false);
  assert.deepEqual(fake.session.tabs ?? [], []);
  assert.equal(fake.local.pairing, undefined);
  assert.equal(fake.posted.filter((message) => message.type === "revoked").length, 2);
  assert.equal(await drives(fake, 6, 1), false);
});

test("a paired instance connects again after a drop or on its alarm; a revoked one waits", async () => {
  const fake = fakeChrome();
  await load(fake);
  assert.equal(fake.ports.length, 1);
  assert.equal(fake.ports[0].host, "dev.forte.braus.chrome_profiles");
  assert.equal(fake.alarms["braus-reconnect"]?.periodInMinutes, 0.5);
  const hello = { type: "hello", instanceId: "instance-A", paired: true, label: "Personale" };

  // Braus quit: the port drops, and the instance connects again after a pause.
  fake.ports[0].onDisconnect.fire();
  await settle();
  assert.equal(fake.timers.length, 1, "one reconnection is scheduled");
  fake.timers.shift().callback();
  await settle();
  assert.equal(fake.ports.length, 2);
  assert.deepEqual(fake.posted.filter((message) => message.type === "hello").at(-1), hello);

  // Braus was still closed, and the worker idled: its alarm connects again, without a new pairing.
  fake.ports[1].onDisconnect.fire();
  await settle();
  fake.timers.length = 0;
  fake.alarmEvents.fire({ name: "braus-reconnect" });
  await settle();
  assert.equal(fake.ports.length, 3);
  assert.deepEqual(fake.posted.filter((message) => message.type === "hello").at(-1), hello);
  assert.equal(fake.calls.length, 0, "connecting again does nothing in the browser");

  // Once revoked, neither the pause nor the alarm connects.
  assert.deepEqual(await ask(fake, { type: "revokePairing" }), { ok: true });
  fake.ports[2].onDisconnect.fire();
  await settle();
  fake.timers.splice(0).forEach((timer) => timer.callback());
  fake.alarmEvents.fire({ name: "braus-reconnect" });
  await settle();
  assert.equal(fake.ports.length, 3);
});

test("added to a profile, the instance opens its pairing page once; an update or a reload opens nothing", async () => {
  const fake = fakeChrome();
  await load(fake);
  fake.chrome.runtime.onInstalled.fire({ reason: "update" });
  await settle();
  assert.equal(called(fake, "tabs.create", "chrome-extension://braus-extension/pair.html"), false);
  fake.chrome.runtime.onInstalled.fire({ reason: "install" });
  await settle();
  assert.equal(fake.calls.filter((call) => call[0] === "tabs.create").length, 1);
  assert.ok(called(fake, "tabs.create", "chrome-extension://braus-extension/pair.html"));
});
