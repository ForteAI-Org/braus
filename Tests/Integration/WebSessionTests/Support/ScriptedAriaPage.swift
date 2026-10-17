//
//  ScriptedAriaPage.swift
//  Braus
//

import CoreGraphics
import Foundation
import WebDriver

/// ScriptedAriaPage is a page without a browser holding one ARIA combo box, "Colore", whose list "Colori" opens in
/// the page itself (W05), and a button "Aiuto" that opens nothing: no window is drawn for either. It answers the
/// DevTools commands the web roles send:
/// - the accessibility tree and the snapshot, from the state (the list closed or open, the control's value);
/// - a press, which opens the list on the control and chooses an option on the list;
/// - the scripts by their markers, sent to its isolated world (`SyntheticWorld`), with what a test scripted: the
///   ARIA options' answer, the values the control reads back one read after another. The options' function, given
///   a node resolved in the world (`DOM.resolveNode`), finds the list only on "Colore" while it is open; the
///   page-wide script of before (`17c9147`) finds it from anywhere, which is the wrong-owner case this page
///   reproduces.
///
/// The DOM's own behaviour (the ARIA attributes, the option's name) is the Chrome tier's: here the scripts' answers
/// are given, so what is tested is what the session and the engine do with them.
///
/// Isolation: `lock` guards every mutable value; each message is answered whole under it.
final class ScriptedAriaPage: CDPTransporting, @unchecked Sendable {

    struct Option: Sendable {
        let backendID: Int
        let name     : String
        let box      : CGRect
    }

    static let control = CGRect(x: 100, y: 100, width: 200, height: 30)
    static let help    = CGRect(x: 400, y: 100, width: 100, height: 30)
    static let list    = CGRect(x: 100, y: 130, width: 200, height: 90)
    static let options = [
        Option(backendID: 21, name: "Rosso", box: CGRect(x: 100, y: 130, width: 200, height: 30)),
        Option(backendID: 22, name: "Blu",   box: CGRect(x: 100, y: 160, width: 200, height: 30)),
        Option(backendID: 23, name: "Verde", box: CGRect(x: 100, y: 190, width: 200, height: 30)),
    ]
    /// Twins: two options named "Blu", which share their scene id.
    static let twins = [
        Option(backendID: 21, name: "Rosso", box: CGRect(x: 100, y: 130, width: 200, height: 30)),
        Option(backendID: 22, name: "Blu",   box: CGRect(x: 100, y: 160, width: 200, height: 30)),
        Option(backendID: 23, name: "Blu",   box: CGRect(x: 100, y: 190, width: 200, height: 30)),
    ]

    let options: [Option]

    let incoming: AsyncStream<Data>
    private let feed: AsyncStream<Data>.Continuation
    private let lock = NSLock()

    private var isOpen = false
    private var value  = "Rosso"
    /// Whether a press on the control opens its list; false for a control that opens nothing.
    private let opensOnPress: Bool
    /// The answer to the options' script while the list is open; nil finds the option `found`.
    private let optionsAnswer: JSONValue?
    private let found: Int
    /// What the control reads back after a choice, one read after another, the last one kept; nil reads the value.
    private var readBacks: [JSONValue]
    private(set) var presses: [CGPoint] = []
    private(set) var optionQueries = 0

    init(options: [Option] = ScriptedAriaPage.options, opensOnPress: Bool = true, startsOpen: Bool = false,
         optionsAnswer: JSONValue? = nil, found: Int = 22, readBacks: [JSONValue] = []) {
        self.options       = options
        self.isOpen        = startsOpen
        self.opensOnPress  = opensOnPress
        self.optionsAnswer = optionsAnswer
        self.found         = found
        self.readBacks     = readBacks
        (incoming, feed) = AsyncStream<Data>.makeStream()
    }

    var pressCount: Int { lock.withLock { presses.count } }
    var optionQueryCount: Int { lock.withLock { optionQueries } }
    var shownValue: String { lock.withLock { value } }

    func send(_ message: Data) throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: message)
        guard let id = request["id"] else { return }
        let result = lock.withLock {
            answer(request["method"]?.stringValue ?? "", request["params"] ?? .object([:]))
        }
        var reply: [String: JSONValue] = ["id": id, "result": result]
        if let session = request["sessionId"] { reply["sessionId"] = session }
        var data = try JSONEncoder().encode(JSONValue.object(reply))
        data.append(0)
        feed.yield(data)
    }

    func close() { feed.finish() }

    private func answer(_ method: String, _ params: JSONValue) -> JSONValue {
        if let world = SyntheticWorld.answer(method, params) { return world }
        if let expression = SyntheticWorld.expression(method, params) {
            if expression.contains("braus:aria-options") {
                optionQueries += 1
                // Only the control "Colore" (node 10), its last argument, opens the list.
                guard params["arguments"]?.arrayValue?.last?["objectId"]?.stringValue == "node-10", isOpen else {
                    return ["result": ["type": "object", "value": ["kind": "none"]]]
                }
                return ["result": ["type": "object", "value": optionsAnswer ?? foundAnswer()]]
            }
            if params["returnByValue"]?.boolValue == false {
                return ["result": ["type": "object", "subtype": "node", "objectId": "aria-option"]]
            }
            return ["result": ["type": "object", "value": evaluate(expression)]]
        }
        switch method {
            case "DOM.describeNode":
                return ["node": ["backendNodeId": .number(Double(found)), "nodeName": "DIV", "attributes": []]]
            case "DOM.resolveNode":
                return ["object": ["type": "object", "objectId": .string("node-\(params["backendNodeId"]?.intValue ?? 0)")]]
            case "DOM.getDocument":
                return ["root": ["backendNodeId": 1, "nodeName": "#document"]]
            case "Accessibility.getFullAXTree":
                return tree()
            case "DOMSnapshot.captureSnapshot":
                return snapshot()
            case "Page.getLayoutMetrics":
                return ["cssLayoutViewport": ["clientWidth": 1280, "clientHeight": 720]]
            case "Input.dispatchMouseEvent" where params["type"]?.stringValue == "mousePressed":
                press(CGPoint(x: params["x"]?.doubleValue ?? 0, y: params["y"]?.doubleValue ?? 0))
                return .object([:])
            default:
                return .object([:])
        }
    }

    /// The options' answer for the option `found`, with its box as the page measures it.
    private func foundAnswer() -> JSONValue {
        guard let option = options.first(where: { $0.backendID == found }) else { return ["kind": "found"] }
        return ["kind": "found", "rect": [.number(option.box.minX), .number(option.box.minY), .number(option.box.width),
                                          .number(option.box.height)]]
    }

    private func press(_ point: CGPoint) {
        presses.append(point)
        if Self.help.contains(point) { return }
        if !isOpen, Self.control.contains(point) {
            isOpen = opensOnPress
            return
        }
        if isOpen, let option = options.first(where: { $0.box.contains(point) }) {
            value  = option.name
            isOpen = false
        }
    }

    private func evaluate(_ expression: String) -> JSONValue {
        if expression.contains("braus:aria-options") {
            optionQueries += 1
            guard isOpen else { return ["kind": "none"] }
            return optionsAnswer ?? foundAnswer()
        }
        if expression.contains("braus:aria-value") {
            guard !readBacks.isEmpty else { return .string(value) }
            return readBacks.count > 1 ? readBacks.removeFirst() : readBacks[0]
        }
        if expression.contains("__brausSelect") { return false }
        // The settler's signature: a page that holds still.
        return ["complete", "https://fixture.test/order", 7, 0, -1]
    }

    /// The tree: the root, the combo box, and with the list open, the list and its options.
    private func tree() -> JSONValue {
        var children: [JSONValue] = ["control", "help"]
        if isOpen { children.append("list") }
        var nodes: [JSONValue] = [
            ["nodeId": "root", "ignored": false, "role": ["value": "RootWebArea"], "name": ["value": "Ordine"],
             "childIds": .array(children), "backendDOMNodeId": 1],
            ["nodeId": "control", "parentId": "root", "ignored": false, "role": ["value": "combobox"],
             "name": ["value": "Colore"], "value": ["value": .string(value)], "childIds": [], "backendDOMNodeId": 10,
             "properties": [["name": "expanded", "value": ["value": .bool(isOpen)]]]],
            ["nodeId": "help", "parentId": "root", "ignored": false, "role": ["value": "button"],
             "name": ["value": "Aiuto"], "childIds": [], "backendDOMNodeId": 30],
        ]
        if isOpen {
            nodes.append(["nodeId": "list", "parentId": "root", "ignored": false, "role": ["value": "listbox"],
                          "name": ["value": "Colori"], "childIds": .array(options.map { .string("option-\($0.backendID)") }),
                          "backendDOMNodeId": 20])
            for option in options {
                nodes.append(["nodeId": .string("option-\(option.backendID)"), "parentId": "list", "ignored": false,
                              "role": ["value": "option"], "name": ["value": .string(option.name)], "childIds": [],
                              "backendDOMNodeId": .number(Double(option.backendID)),
                              "properties": [["name": "selected", "value": ["value": .bool(option.name == value)]]]])
            }
        }
        return ["nodes": .array(nodes)]
    }

    /// The snapshot of the document: the root, the control, and with the list open, the list and its options.
    private func snapshot() -> JSONValue {
        var strings = ["", "#document", "DIV", "Ordine", "https://fixture.test/order"]
        func index(_ text: String) -> JSONValue {
            if let found = strings.firstIndex(of: text) { return .number(Double(found)) }
            strings.append(text)
            return .number(Double(strings.count - 1))
        }
        var boxes: [(Int, CGRect)] = [(1, CGRect(x: 0, y: 0, width: 1280, height: 720)), (10, Self.control), (30, Self.help)]
        if isOpen { boxes += [(20, Self.list)] + options.map { ($0.backendID, $0.box) } }
        let document: JSONValue = [
            "documentURL": index("https://fixture.test/order"), "title": index("Ordine"),
            "scrollOffsetX": 0, "scrollOffsetY": 0,
            "nodes": ["nodeName": .array(boxes.map { $0.0 == 1 ? index("#document") : index("DIV") }),
                      "attributes": .array(boxes.map { _ in [] }),
                      "backendNodeId": .array(boxes.map { .number(Double($0.0)) })],
            "layout": ["nodeIndex": .array(boxes.indices.map { .number(Double($0)) }),
                       "bounds": .array(boxes.map { [.number($0.1.minX), .number($0.1.minY), .number($0.1.width),
                                                     .number($0.1.height)] })],
        ]
        return ["documents": [document], "strings": .array(strings.map { .string($0) })]
    }
}
