//
//  SyntheticSelectPage.swift
//  Braus
//

import CoreGraphics
import Foundation
import JavaScriptCore
import WebDriver

/// SyntheticSelectPage is a page without a browser holding native selects, for W2 and W3: it answers the DevTools
/// commands Braus's web roles send, and runs `WebControls`'s own scripts, sent to its isolated world
/// (`SyntheticWorld`), in JavaScriptCore on a small DOM of selects, options and option groups written here (`dom`). A select keeps its options in order, picks by index, fires the
/// listeners a page adds, and counts every `input` and `change` event; timers and a frame run on a virtual clock, so
/// a script that awaits them (`awaitPromise`) is answered once they have run, as Chrome would. The tree shows each
/// select as a combo box named by its label, with its current option as value; the snapshot gives its box.
///
/// A test changes the page through `run` (a listener that puts the value back synchronously, in a microtask or on a
/// timer; a select replaced; options reordered or changed), and can make the page stop answering a script that holds
/// a given text (`hangs`), as a page that never answers, or close the connection (`close`).
///
/// Isolation: `lock` guards the context, the only mutable state; each message is answered whole under it.
final class SyntheticSelectPage: CDPTransporting, @unchecked Sendable {

    static let dom = """
    var window = this;
    var innerWidth = 1280, innerHeight = 720;
    var location = { href: 'https://fixture.test/form' };
    var __events = { input: 0, change: 0 };
    var __timers = [], __now = 0, __seq = 0;
    function setTimeout(fn, ms) { __timers.push({ at: __now + (ms || 0), seq: __seq++, fn: fn }); return __seq; }
    function requestAnimationFrame(fn) { return setTimeout(fn, 16); }
    function __runTimer() {
      if (!__timers.length) { return false; }
      __timers.sort(function (a, b) { return a.at - b.at || a.seq - b.seq; });
      var t = __timers.shift(); __now = Math.max(__now, t.at); t.fn(); return true;
    }
    function Event(type, init) { this.type = type; this.bubbles = !!(init && init.bubbles); }
    function __optgroup(label, disabled) { return { tagName: 'OPTGROUP', label: label, disabled: !!disabled }; }
    function __option(text, value, disabled, group) {
      return { tagName: 'OPTION', text: text, get textContent() { return this.text; },
               value: value === undefined ? text : value, disabled: !!disabled, group: group || null, owner: null,
               get index() { return this.owner ? this.owner.options.indexOf(this) : -1; },
               get selected() { return !!this.owner && this.owner.options[this.owner.selectedIndex] === this; },
               set selected(on) { if (on && this.owner) { this.owner.selectedIndex = this.index; } },
               closest: function (selector) { return selector === 'optgroup' ? this.group : null; } };
    }
    var __selects = [];
    function __select(id, name, options, box, selected) {
      var s = { tagName: 'SELECT', id: id, name: name, multiple: false, size: 0, disabled: false, isConnected: true,
                labels: [], title: '', box: box, options: [], selectedIndex: selected || 0, listeners: {},
                getAttribute: function (n) { return n === 'aria-label' ? this.name : null; },
                getBoundingClientRect: function () { var b = this.box; return { x: b[0], y: b[1], width: b[2], height: b[3],
                  left: b[0], top: b[1], right: b[0] + b[2], bottom: b[1] + b[3] }; },
                focus: function () {}, blur: function () {},
                addEventListener: function (t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); },
                dispatchEvent: function (ev) { __events[ev.type] = (__events[ev.type] || 0) + 1;
                  (this.listeners[ev.type] || []).forEach(function (f) { f.call(this, ev); }, this); return true; },
                get value() { var o = this.options[this.selectedIndex]; return o ? o.value : ''; },
                set value(v) { this.selectedIndex = this.options.findIndex(function (o) { return o.value === v; }); },
                get selectedOptions() { var o = this.options[this.selectedIndex]; return o ? [o] : []; } };
      options.forEach(function (o) { o.owner = s; s.options.push(o); });
      __selects.push(s);
      return s;
    }
    var document = { readyState: 'complete', activeElement: null, body: { innerText: 'Form' },
                     getElementById: function (id) { return __selects.find(function (s) { return s.id === id && s.isConnected; }) || null; },
                     querySelectorAll: function (sel) { return sel === 'select' ? __selects.filter(function (s) { return s.isConnected; }) : []; },
                     getElementsByTagName: function () { return __selects; } };
    """

    let incoming: AsyncStream<Data>
    private let feed   : AsyncStream<Data>.Continuation
    private let lock    = NSLock()
    private let context: JSContext
    private var hanging: [String] = []
    private var keys    = 0

    /// `setup` is the page's script: the selects it holds, built with `__select`, `__option` and `__optgroup`.
    init(setup: String) {
        (incoming, feed) = AsyncStream<Data>.makeStream()
        context = JSContext()
        context.evaluateScript(Self.dom)
        context.evaluateScript(setup)
    }

    /// Runs a script on the page now: a listener, a replaced select, reordered options.
    func run(_ script: String) {
        lock.withLock { _ = context.evaluateScript(script) }
    }

    /// The value of an expression on the page, as JSON text.
    func read(_ expression: String) -> String {
        lock.withLock { context.evaluateScript("JSON.stringify(\(expression))")?.toString() ?? "null" }
    }

    /// How many events of that type the selects received.
    func events(_ type: String) -> Int {
        lock.withLock { Int(context.evaluateScript("__events['\(type)'] || 0")?.toInt32() ?? 0) }
    }

    /// How many key events reached the page.
    var keyEvents: Int { lock.withLock { keys } }

    /// From now on, a script holding `text` gets no answer, as a page that stopped answering.
    func hangs(on text: String) {
        lock.withLock { hanging.append(text) }
    }

    func send(_ message: Data) throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: message)
        guard let id = request["id"] else { return }
        let reply: JSONValue? = lock.withLock {
            let method = request["method"]?.stringValue ?? ""
            let params = request["params"] ?? .object([:])
            if let expression = SyntheticWorld.expression(method, params), hanging.contains(where: expression.contains) {
                return nil
            }
            return answer(method, params)
        }
        guard let result = reply else { return }
        var envelope: [String: JSONValue] = ["id": id, "result": result]
        if let session = request["sessionId"] { envelope["sessionId"] = session }
        var data = try JSONEncoder().encode(JSONValue.object(envelope))
        data.append(0)
        feed.yield(data)
    }

    func close() { feed.finish() }

    private func answer(_ method: String, _ params: JSONValue) -> JSONValue {
        if let world = SyntheticWorld.answer(method, params) { return world }
        if let expression = SyntheticWorld.expression(method, params) { return evaluate(expression) }
        switch method {
            case "Accessibility.getFullAXTree":
                return tree()
            case "DOMSnapshot.captureSnapshot":
                return snapshot()
            case "Page.getLayoutMetrics":
                return ["cssLayoutViewport": ["clientWidth": 1280, "clientHeight": 720]]
            case "DOM.getDocument":
                return ["root": ["backendNodeId": 1, "nodeName": "#document"]]
            case "Input.dispatchKeyEvent", "Input.insertText":
                keys += 1
                return .object([:])
            default:
                return .object([:])
        }
    }

    /// The script's value by value; a promise is answered once it settled, the timers it waits for run first.
    private func evaluate(_ expression: String) -> JSONValue {
        context.exception = nil
        let first = context.evaluateScript("""
            (function () {
              var v = (\(expression));
              if (v && typeof v.then === 'function') {
                __async = { done: false };
                v.then(function (r) { __async.done = true; __async.value = r; },
                       function (e) { __async.done = true; __async.error = String(e); });
                return '"__async__"';
              }
              return v === undefined ? '{"undefined":true}' : JSON.stringify(v);
            })()
            """)?.toString()
        if let exception = context.exception {
            return ["exceptionDetails": ["text": .string(exception.toString() ?? "exception")]]
        }
        var text = first
        if first == "\"__async__\"" {
            var turns = 0
            while context.evaluateScript("__async.done")?.toBool() != true, turns < 1000 {
                guard context.evaluateScript("__runTimer()")?.toBool() == true else { break }
                turns += 1
            }
            guard context.evaluateScript("__async.done")?.toBool() == true else {
                return ["exceptionDetails": ["text": "the promise never settled"]]
            }
            if let error = context.evaluateScript("__async.error")?.toString(), error != "undefined" {
                return ["exceptionDetails": ["text": .string(error)]]
            }
            text = context.evaluateScript("JSON.stringify(__async.value === undefined ? {undefined: true} : __async.value)")?.toString()
        }
        guard let text, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            return ["result": ["type": "undefined"]]
        }
        if value["undefined"]?.boolValue == true { return ["result": ["type": "undefined"]] }
        return ["result": ["type": "object", "value": value]]
    }

    /// The selects as the tree shows them: combo boxes named by their label, their current option as value.
    private func tree() -> JSONValue {
        let count = Int(context.evaluateScript("__selects.length")?.toInt32() ?? 0)
        var children: [JSONValue] = []
        var nodes: [JSONValue] = []
        for index in 0..<count {
            guard context.evaluateScript("__selects[\(index)].isConnected")?.toBool() == true else { continue }
            let name = context.evaluateScript("__selects[\(index)].name")?.toString() ?? ""
            let value = context.evaluateScript("(__selects[\(index)].selectedOptions[0] || { text: '' }).text")?.toString() ?? ""
            let id = "select-\(index)"
            children.append(.string(id))
            nodes.append(["nodeId": .string(id), "parentId": "root", "ignored": false, "role": ["value": "combobox"],
                          "name": ["value": .string(name)], "value": ["value": .string(value)], "childIds": [],
                          "backendDOMNodeId": .number(Double(100 + index))])
        }
        let root: JSONValue = ["nodeId": "root", "ignored": false, "role": ["value": "RootWebArea"], "name": ["value": "Form"],
                               "childIds": .array(children), "backendDOMNodeId": 1]
        return ["nodes": .array([root] + nodes)]
    }

    /// The document and each select's box.
    private func snapshot() -> JSONValue {
        var strings = ["", "#document", "SELECT", "Form", "https://fixture.test/form"]
        let count = Int(context.evaluateScript("__selects.length")?.toInt32() ?? 0)
        var names: [JSONValue] = [1], backend: [JSONValue] = [1], layout: [JSONValue] = [0]
        var bounds: [JSONValue] = [[0, 0, 1280, 720]], attributes: [JSONValue] = [[]]
        for index in 0..<count {
            guard context.evaluateScript("__selects[\(index)].isConnected")?.toBool() == true else { continue }
            let box = (0..<4).map { context.evaluateScript("__selects[\(index)].box[\($0)]")?.toDouble() ?? 0 }
            names.append(2); backend.append(.number(Double(100 + index))); attributes.append([])
            layout.append(.number(Double(names.count - 1)))
            bounds.append(.array(box.map { .number($0) }))
        }
        strings.append("")
        let document: JSONValue = [
            "documentURL": 4, "title": 3, "scrollOffsetX": 0, "scrollOffsetY": 0,
            "nodes": ["nodeName": .array(names), "attributes": .array(attributes), "backendNodeId": .array(backend)],
            "layout": ["nodeIndex": .array(layout), "bounds": .array(bounds)],
        ]
        return ["documents": [document], "strings": .array(strings.map { .string($0) })]
    }
}
