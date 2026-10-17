//
//  SyntheticPage.swift
//  Braus
//

import CoreGraphics
import Foundation
import JavaScriptCore
import WebDriver

/// SyntheticPage is a page without a browser for Braus's web roles: it answers the DevTools commands they
/// send for a form of fields described here. Scripts run in JavaScriptCore on a small DOM written in
/// JavaScript (`dom`); the accessibility tree and the DOM snapshot are built from the same fields at each
/// request, so a typed value shows in the next scene. A press focuses the field under the point (three
/// presses select its text), a key with text types it, the `selectAll` command selects it.
///
/// The tree reports a field's DOM value as its value, password fields included: the worst a browser
/// could do, so a test proves what Braus does with it. Layout, real events and frames' own trees are not
/// imitated; what needs them belongs to the Chrome tier.
///
/// The engine's scripts reach the page through its isolated world (`SyntheticWorld`), which here shares the page's
/// one script context; the page's own world answers no script. A script evaluated without `returnByValue` answers
/// a remote object, which `DOM.describeNode` names by
/// its backend id (an element's numeric `id`), node name and `type`, and `Runtime.callFunctionOn` runs a
/// function on; `DOM.getDocument` answers the document's backend id. `DOM.resolveNode` resolves a node by its backend
/// id, and the click's hit test (`braus:hit-test`), called in the world with the nodes so resolved, answers from the
/// boxes: a cover on top of the point, the field, or a field gone. A test can
/// change the page (`Change`) now, once right after the next press, or once every read of the n-th scene
/// was answered (the tree, the snapshot, the metrics and the document of one perception): a field replaced
/// by a new node in the same place under the same name, a field's type changed, the document replaced, or a cover
/// laid over a box. A
/// scene's reads go out together, so a change is never made in the middle of one.
///
/// Isolation: `lock` guards the context, the fields, the document and the schedule, the only mutable
/// state; each message is answered whole under it.
final class SyntheticPage: CDPTransporting, @unchecked Sendable {

    struct Field: Sendable {
        var backendID: Int
        /// The input's `type` attribute: `password` or `text`.
        var type     : String
        let name     : String
        let value    : String
        let box      : CGRect
    }

    /// A change of the page a test schedules.
    enum Change: Sendable {
        /// The field `id` is replaced by a new node `by`, in the same place, under the same name, with no value.
        case replace(Int, by: Int, type: String? = nil)
        /// The field's `type` attribute becomes `type`, the node kept.
        case setType(Int, String)
        /// The document is replaced by another, the fields kept: a navigation to the same form.
        case navigate
        /// The document node can no longer be read: `DOM.getDocument` answers none.
        case loseDocument
        /// An element named `name` is laid over `box`, on top of the fields: a press there reaches it, not a field.
        case cover(CGRect, name: String)
    }

    /// The DOM the scripts run on: fields, `document` with the focus, `location`, the viewport, and the
    /// helpers the page's input events call.
    static let dom = """
    var __fields = [];
    function __input(id, type, name, value, box) {
      var e = { tagName: 'INPUT', id: id, type: type, name: name, value: value, box: box,
                shadowRoot: null, contentDocument: null, isContentEditable: false };
      __fields.push(e);
      return e;
    }
    var document = {
      readyState: 'complete', activeElement: null, body: { innerText: 'Form' },
      getElementsByTagName: function () { return __fields; },
      querySelectorAll: function () { return __fields; }
    };
    var location = { href: 'https://fixture.test/login' };
    var innerWidth = 1280, innerHeight = 720;
    var __selected = false;
    var __covers = [];
    function __press(x, y, count) {
      var hit = null;
      for (var c = 0; c < __covers.length; c++) {
        var k = __covers[c];
        if (x >= k[0] && x <= k[0] + k[2] && y >= k[1] && y <= k[1] + k[3]) { document.activeElement = null; return; }
      }
      for (var i = 0; i < __fields.length; i++) {
        var b = __fields[i].box;
        if (x >= b[0] && x <= b[0] + b[2] && y >= b[1] && y <= b[1] + b[3]) { hit = __fields[i]; }
      }
      document.activeElement = hit;
      __selected = count >= 3;
    }
    function __type(text) {
      var e = document.activeElement;
      if (!e) { return; }
      if (__selected) { e.value = ''; __selected = false; }
      e.value += text;
    }
    function __command(name) { if (name === 'selectAll') { __selected = true; } }
    """

    let incoming: AsyncStream<Data>
    private let feed   : AsyncStream<Data>.Continuation
    private var fields : [Field]
    private let lock    = NSLock()
    private let context: JSContext
    private var documentID = 1
    private var documentReadable = true
    private var covers: [(box: CGRect, name: String)] = []
    private var texts      = 0
    private var presses    = 0
    private var afterPress : [Change] = []
    private var afterScene : [Int: [Change]] = [:]
    /// How many times each of a scene's four reads was answered.
    private var reads: [String: Int] = [:]
    private static let sceneReads = ["Accessibility.getFullAXTree", "DOMSnapshot.captureSnapshot",
                                     "Page.getLayoutMetrics", "DOM.getDocument"]

    init(fields: [Field]) {
        self.fields = fields
        (incoming, feed) = AsyncStream<Data>.makeStream()
        context = JSContext()
        context.evaluateScript(Self.dom)
        for field in fields {
            let box = "[\(field.box.minX), \(field.box.minY), \(field.box.width), \(field.box.height)]"
            context.evaluateScript("__input(\(field.backendID), \(Self.literal(field.type)), \(Self.literal(field.name)), "
                                   + "\(Self.literal(field.value)), \(box));")
        }
    }

    /// How many mouse presses and how many typed texts (keys with text, insertions) reached the page.
    var pressCount: Int { lock.withLock { presses } }
    var textCount: Int { lock.withLock { texts } }

    /// The value a field holds in the page now.
    func value(of backendID: Int) -> String? {
        lock.withLock { context.evaluateScript("(__fields.find(f => f.id === \(backendID)) || {}).value")?.toString() }
    }

    /// How many text events reached the page: a key with text, an inserted text.
    var textEvents: Int { lock.withLock { texts } }

    /// Applies `changes` now.
    func change(_ changes: [Change]) {
        lock.withLock { for change in changes { apply(change) } }
    }

    /// The scenes read whole so far: the fewest answers any of a scene's four reads had.
    var scenesRead: Int {
        lock.withLock { Self.sceneReads.map { reads[$0] ?? 0 }.min() ?? 0 }
    }

    /// Applies `changes` once the `scene`-th scene, counting from 1, was read whole, before any read of the next.
    func schedule(_ changes: [Change], afterScene scene: Int) {
        lock.withLock { afterScene[scene, default: []] += changes }
    }

    /// Applies `changes` once, right after the next press.
    func schedule(afterPress changes: [Change]) {
        lock.withLock { afterPress += changes }
    }

    /// Runs a script on the page's DOM now, as a test's setup: a focus, a shadow root.
    func run(_ script: String) {
        lock.withLock { _ = context.evaluateScript(script) }
    }

    private func apply(_ change: Change) {
        switch change {
            case .replace(let id, let newID, let type):
                guard let index = fields.firstIndex(where: { $0.backendID == id }) else { return }
                let old = fields[index]
                fields[index] = Field(backendID: newID, type: type ?? old.type, name: old.name, value: "", box: old.box)
                context.evaluateScript("""
                    (function () {
                      var i = __fields.findIndex(function (f) { return f.id === \(id); });
                      var old = __fields[i];
                      var e = { tagName: 'INPUT', id: \(newID), type: \(Self.literal(type ?? old.type)), name: old.name,
                                value: '', box: old.box, shadowRoot: null, contentDocument: null, isContentEditable: false };
                      __fields[i] = e;
                      if (document.activeElement === old) { document.activeElement = null; }
                    })();
                    """)
            case .setType(let id, let type):
                guard let index = fields.firstIndex(where: { $0.backendID == id }) else { return }
                fields[index].type = type
                context.evaluateScript("(__fields.find(function (f) { return f.id === \(id); }) || {}).type = \(Self.literal(type));")
            case .navigate:
                documentID += 100
            case .loseDocument:
                documentReadable = false
            case .cover(let box, let name):
                covers.append((box, name))
                context.evaluateScript("__covers.push([\(box.minX), \(box.minY), \(box.width), \(box.height)]);")
        }
    }

    func send(_ message: Data) throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: message)
        guard let id = request["id"] else { return }
        let result = lock.withLock {
            let method = request["method"]?.stringValue ?? ""
            let answered = answer(method, request["params"] ?? .object([:]))
            if Self.sceneReads.contains(method) {
                reads[method, default: 0] += 1
                let whole = Self.sceneReads.map { reads[$0] ?? 0 }.min() ?? 0
                for scene in afterScene.keys.sorted() where scene <= whole {
                    for change in afterScene.removeValue(forKey: scene) ?? [] { apply(change) }
                }
            }
            return answered
        }
        var reply: [String: JSONValue] = ["id": id, "result": result]
        if let session = request["sessionId"] { reply["sessionId"] = session }
        var data = try JSONEncoder().encode(JSONValue.object(reply))
        data.append(0)
        feed.yield(data)
    }

    func close() { feed.finish() }

    // MARK: Commands

    private func answer(_ method: String, _ params: JSONValue) -> JSONValue {
        if let world = SyntheticWorld.answer(method, params, loaderID: "loader-\(documentID)") { return world }
        if let expression = SyntheticWorld.expression(method, params) {
            if expression.contains("braus:hit-test") { return hit(params) }
            return params["returnByValue"]?.boolValue == false ? remoteObject(expression) : evaluate(expression)
        }
        switch method {
            case "DOM.describeNode":
                return describe(params["objectId"]?.stringValue ?? "")
            case "DOM.resolveNode":
                // A node replaced since is still resolved, as Chrome resolves one it keeps: the hit test finds it gone.
                return ["object": ["type": "object", "objectId": .string("field-\(params["backendNodeId"]?.intValue ?? 0)")]]
            case "Runtime.callFunctionOn":
                return call(params["functionDeclaration"]?.stringValue ?? "", on: params["objectId"]?.stringValue ?? "")
            case "DOM.getDocument" where !documentReadable:
                return ["root": ["nodeName": "#document"]]
            case "DOM.getDocument":
                return ["root": ["backendNodeId": .number(Double(documentID)), "nodeName": "#document"]]
            case "Accessibility.getFullAXTree":
                return tree()
            case "DOMSnapshot.captureSnapshot":
                return snapshot()
            case "Page.getLayoutMetrics":
                return ["cssLayoutViewport": ["clientWidth": 1280, "clientHeight": 720]]
            case "Input.dispatchMouseEvent" where params["type"]?.stringValue == "mousePressed":
                let x = params["x"]?.doubleValue ?? 0, y = params["y"]?.doubleValue ?? 0
                let count = params["clickCount"]?.intValue ?? 1
                presses += 1
                context.evaluateScript("__press(\(x), \(y), \(count));")
                let changes = afterPress
                afterPress = []
                for change in changes { apply(change) }
                return .object([:])
            case "Input.dispatchKeyEvent" where params["type"]?.stringValue == "keyDown":
                if let text = params["text"]?.stringValue {
                    texts += 1
                    context.evaluateScript("__type(\(Self.literal(text)));")
                }
                return .object([:])
            case "Input.dispatchKeyEvent" where params["type"]?.stringValue == "rawKeyDown":
                for command in params["commands"]?.arrayValue ?? [] {
                    context.evaluateScript("__command(\(Self.literal(command.stringValue ?? "")));")
                }
                return .object([:])
            case "Input.insertText":
                texts += 1
                context.evaluateScript("__type(\(Self.literal(params["text"]?.stringValue ?? "")));")
                return .object([:])
            default:
                return .object([:])
        }
    }

    /// The script's value as `Runtime.evaluate` returns it by value, or its exception.
    private func evaluate(_ expression: String) -> JSONValue {
        context.exception = nil
        let text = context.evaluateScript("(function () { var v = (\(expression)); return v === undefined ? "
                                          + "'{\"undefined\":true}' : JSON.stringify(v); })()")?.toString()
        if let exception = context.exception {
            return ["exceptionDetails": ["text": .string(exception.toString() ?? "exception")]]
        }
        guard let text, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return ["result": ["type": "undefined"]] }
        if value["undefined"]?.boolValue == true { return ["result": ["type": "undefined"]] }
        return ["result": ["type": "object", "value": value]]
    }

    /// The script's value as a remote object, kept in the page's registry under its objectId, or null.
    private func remoteObject(_ expression: String) -> JSONValue {
        context.exception = nil
        let index = context.evaluateScript("""
            (function () {
              var v = (\(expression));
              if (v === null || v === undefined) { return -1; }
              if (typeof __objects === 'undefined') { __objects = []; }
              __objects.push(v);
              return __objects.length - 1;
            })()
            """)?.toInt32() ?? -1
        if let exception = context.exception {
            return ["exceptionDetails": ["text": .string(exception.toString() ?? "exception")]]
        }
        if index < 0 { return ["result": ["type": "object", "subtype": "null", "value": .null]] }
        return ["result": ["type": "object", "objectId": .string("obj-\(index)")]]
    }

    /// The registry's script for the object `objectID` names.
    private static func registered(_ objectID: String) -> String? {
        guard objectID.hasPrefix("obj-"), let index = Int(objectID.dropFirst(4)) else { return nil }
        return "__objects[\(index)]"
    }

    /// The node a remote object is, as `DOM.describeNode` answers it: its backend id, name and attributes.
    private func describe(_ objectID: String) -> JSONValue {
        guard let object = Self.registered(objectID),
              let text = context.evaluateScript("""
                  (function (o) {
                    if (o === document) { return JSON.stringify({ doc: true }); }
                    return JSON.stringify({ id: typeof o.id === 'number' ? o.id : null, tag: o.tagName || '#text',
                                            type: typeof o.type === 'string' ? o.type : null });
                  })(\(object))
                  """)?.toString(),
              let node = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else { return ["exceptionDetails": ["text": "no such object"]] }
        if node["doc"]?.boolValue == true {
            return ["node": ["backendNodeId": .number(Double(documentID)), "nodeName": "#document", "attributes": []]]
        }
        let attributes: [JSONValue] = node["type"]?.stringValue.map { ["type", .string($0)] } ?? []
        return ["node": ["backendNodeId": .number(node["id"]?.doubleValue ?? 9000), "nodeName": node["tag"] ?? "#text",
                         "attributes": .array(attributes)]]
    }

    /// The click's hit test on a field, its first node argument, from the boxes: a cover holding the point is on top;
    /// else the field there.
    private func hit(_ params: JSONValue) -> JSONValue {
        let arguments = params["arguments"]?.arrayValue ?? []
        let id = Int((arguments.dropFirst(2).first?["objectId"]?.stringValue ?? "").dropFirst("field-".count)) ?? 0
        let point = CGPoint(x: arguments.first?["value"]?.doubleValue ?? -1,
                            y: arguments.dropFirst().first?["value"]?.doubleValue ?? -1)
        let answer: JSONValue
        if !fields.contains(where: { $0.backendID == id }) {
            answer = ["kind": "gone"]
        } else if let cover = covers.last(where: { $0.box.contains(point) }) {
            answer = ["kind": "covered", "cover": .string("dialog '\(cover.name)'")]
        } else if fields.first(where: { $0.box.contains(point) })?.backendID == id {
            answer = ["kind": "target"]
        } else {
            answer = ["kind": "covered", "cover": "document"]
        }
        return ["result": ["type": "object", "value": answer]]
    }

    /// A function run on a remote object, its value answered by value.
    private func call(_ function: String, on objectID: String) -> JSONValue {
        guard let object = Self.registered(objectID) else { return ["exceptionDetails": ["text": "no such object"]] }
        context.exception = nil
        let text = context.evaluateScript("JSON.stringify({ v: (\(function)).call(\(object)) })")?.toString()
        if let exception = context.exception {
            return ["exceptionDetails": ["text": .string(exception.toString() ?? "exception")]]
        }
        guard let text, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            return ["result": ["type": "undefined"]]
        }
        return ["result": ["type": "string", "value": value["v"] ?? .null]]
    }

    /// The accessibility tree of the form: the root and one text box per field, with its DOM value.
    private func tree() -> JSONValue {
        var nodes: [JSONValue] = [[
            "nodeId": "root", "ignored": false, "role": ["value": "RootWebArea"], "name": ["value": "Form"],
            "childIds": .array(fields.map { .string("field-\($0.backendID)") }), "backendDOMNodeId": 1,
        ]]
        for field in fields {
            nodes.append([
                "nodeId": .string("field-\(field.backendID)"), "parentId": "root", "ignored": false,
                "role": ["value": "textbox"], "name": ["value": .string(field.name)],
                "value": ["value": .string(value(inLock: field.backendID) ?? "")],
                "childIds": [], "backendDOMNodeId": .number(Double(field.backendID)),
            ])
        }
        return ["nodes": .array(nodes)]
    }

    /// The snapshot of one document: the root and the fields, with their `type` attributes and boxes.
    private func snapshot() -> JSONValue {
        var strings = ["", "#document", "INPUT", "type", "Form", "https://fixture.test/login"]
        func index(_ text: String) -> JSONValue {
            if let found = strings.firstIndex(of: text) { return .number(Double(found)) }
            strings.append(text)
            return .number(Double(strings.count - 1))
        }
        var names: [JSONValue] = [index("#document")]
        var attributes: [JSONValue] = [[]]
        var backendIDs: [JSONValue] = [1]
        var layoutIndex: [JSONValue] = [0]
        var bounds: [JSONValue] = [[0, 0, 1280, 720]]
        for (position, field) in fields.enumerated() {
            names.append(index("INPUT"))
            attributes.append([index("type"), index(field.type)])
            backendIDs.append(.number(Double(field.backendID)))
            layoutIndex.append(.number(Double(position + 1)))
            bounds.append([.number(field.box.minX), .number(field.box.minY),
                           .number(field.box.width), .number(field.box.height)])
        }
        let document: JSONValue = [
            "documentURL": index("https://fixture.test/login"), "title": index("Form"),
            "scrollOffsetX": 0, "scrollOffsetY": 0,
            "nodes": ["nodeName": .array(names), "attributes": .array(attributes), "backendNodeId": .array(backendIDs)],
            "layout": ["nodeIndex": .array(layoutIndex), "bounds": .array(bounds)],
        ]
        return ["documents": [document], "strings": .array(strings.map { .string($0) })]
    }

    private func value(inLock backendID: Int) -> String? {
        context.evaluateScript("(__fields.find(f => f.id === \(backendID)) || {}).value")?.toString()
    }

    /// A JavaScript string literal for `text`.
    static func literal(_ text: String) -> String {
        let data = (try? JSONEncoder().encode([text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
