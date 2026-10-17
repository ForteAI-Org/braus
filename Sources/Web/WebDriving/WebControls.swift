//
//  WebControls.swift
//  Braus
//

import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore
import WebDriver

/// WebControls is `ControlPressing` for tabs: it reads controls through the page's own DOM, from the
/// tab's isolated world (`WebTabs.evaluate`), so the page's scripts cannot change what it reads.
///
/// A native `<select>` is pressed by name: Chrome draws its list outside the page, so Braus opens
/// a `WebSelectPopup` instead of clicking, and `chooseMenuItem` chooses in it, by the row the scene
/// showed and the option node the page kept, and reads the select back once the page settled. Every
/// read answers nil or false when the page cannot say.
public struct WebControls: ControlPressing {

    let tabs: WebTabs
    /// The one deadline of a choice in a select's list: its dispatch and its read-back after the page settled.
    let choiceBudget: Duration
    /// How long the select must hold one state (its option node, index, value and text) before a choice is judged.
    let choiceWindow: Duration

    public init(tabs: WebTabs, choiceBudget: Duration = .seconds(3), choiceWindow: Duration = .milliseconds(300)) {
        self.tabs         = tabs
        self.choiceBudget = choiceBudget
        self.choiceWindow = choiceWindow
    }

    /// Opens the list of the one select named `label`, by its accessible name or its current
    /// option; a trailing ordinal ` #n` picks the n-th of several. False for anything else, which
    /// the engine then clicks.
    public func pressControl(labelled label: String, in processID: pid_t) async -> Bool {
        let (name, ordinal) = Self.splitOrdinal(label)
        let script = Self.render(Self.openSelectScript,
                                 ["LABEL": Self.jsString(LabelText.normalize(name)), "ORDINAL": String(ordinal)])
        guard await evaluate(script, in: processID)?.boolValue == true,
              let popup = await openPopup(in: processID)
        else { return false }
        tabs.setPopup(popup, for: processID)
        return true
    }

    /// Chooses the one row of the open list whose label, as the scene shows it (` #n` included), is `title`,
    /// as `chooseMenuItem` does. False when no list is open, no row or several carry that label, or the
    /// choice was refused; true once it went out.
    public func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
        guard let window = tabs.window(of: processID), let popup = window.popup else { return false }
        let rows = Self.rows(of: popup, in: window.viewport).filter { $0.label == title }
        guard rows.count == 1, let row = rows.first else { return false }
        switch await chooseMenuItem(row, within: menuFrame, in: processID) {
            case .sent, .possiblySent: return true
            case .notHandled, .refused: return false
        }
    }

    /// The open list's rows as the scene shows them, labels read apart by ordinal as the scene builder does.
    static func rows(of popup: WebSelectPopup, in viewport: CGSize) -> [SceneElement] {
        var rows = popup.elements(in: viewport)
        var seen: [String: Int] = [:]
        for index in rows.indices {
            let key = rows[index].kind.rawValue + "\n" + (rows[index].container ?? "") + "\n" + rows[index].label
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            if count > 1 { rows[index].label += " #\(count)" }
        }
        return rows
    }

    /// Chooses `item`, a row of the open select's list as the scene showed it (W2, W3). The row is found by its
    /// place in the list the tab holds (its bounds), never by its label, which only has to agree, and stands for
    /// one option: its index, value and full
    /// text. The page chooses it only when the select is the node the list was opened on, still there and
    /// enabled, and the option at that index is the node it kept, with that value and text, enabled in an
    /// enabled group; otherwise the choice is refused and no event is sent. Once dispatched, the select is watched
    /// until it held one state (its selected option node, index, value and full text) for `choiceWindow`, within the
    /// time left of one deadline for the whole choice (`choiceBudget`); a select that does not hold still in time is
    /// unread. The list Braus drew closes either way, and its closing confirms nothing. A change the page makes after
    /// the window it was watched for is not seen: the receipt says what held then, not what will.
    public func chooseMenuItem(_ item: SceneElement, within menuFrame: CGRect, in processID: pid_t) async -> MenuItemPress {
        guard let window = tabs.window(of: processID), let popup = window.popup else { return .notHandled }
        // A row is its place in the list: a labelled element's scene id is its kind and label, which two options
        // of the same text share. The label as the scene shows it must agree.
        let rows = Self.rows(of: popup, in: window.viewport)
        let places = rows.indices.filter { rows[$0].bounds == item.bounds }
        guard places.count == 1, let place = places.first, rows[place].label == item.label else {
            tabs.setPopup(nil, for: processID)
            return .refused(places.count > 1 ? "\(places.count) options of the list share its place"
                            : "the open list shows no such option where the scene showed it")
        }
        let option = popup.shownOptions(in: window.viewport)[place]
        guard option.index >= 0, option.isEnabled else {
            tabs.setPopup(nil, for: processID)
            return .refused(option.index < 0 ? "the option's place in its select is not known" : "the option is disabled")
        }
        let clock = ContinuousClock()
        let deadline = clock.now + choiceBudget
        func remaining() -> Double {
            let left = (deadline - clock.now).components
            return max(0.05, Double(left.seconds) + Double(left.attoseconds) / 1e18)
        }
        let dispatched: JSONValue
        do {
            dispatched = try await tabs.evaluate(
                Self.script(Self.chooseOptionScript, option),
                in            : processID,
                timeoutSeconds: remaining()
            )
        } catch {
            tabs.setPopup(nil, for: processID)
            return .possiblySent("the page did not answer the choice (\(error))")
        }
        switch dispatched["status"]?.stringValue {
            case "refused"?:
                tabs.setPopup(nil, for: processID)
                return .refused(dispatched["reason"]?.stringValue ?? "the option changed since the list was read")
            case "sent"?:
                break
            default:
                tabs.setPopup(nil, for: processID)
                return .possiblySent("the page answered the choice with nothing Braus reads")
        }
        tabs.setPopup(nil, for: processID)
        guard !Task.isCancelled else { return .sent(.unread(expected: option.text, reason: "the call was cancelled")) }
        let watched = Self.milliseconds(choiceWindow)
        let limit = Int(remaining() * 1000) - 100
        guard limit >= watched else {
            return .sent(.unread(expected: option.text, reason: "the choice's deadline leaves no time to watch the select"))
        }
        let watch = Self.script(Self.readBackScript, option, ["WINDOW": String(watched), "LIMIT": String(limit)])
        do {
            let read = try await tabs.evaluate(watch, in: processID, timeoutSeconds: remaining())
            switch read["state"]?.stringValue {
                case "read"?:
                    break
                case "unsettled"?:
                    return .sent(.unread(expected: option.text,
                                         reason: "the select did not hold still for \(watched) ms before the deadline"))
                default:
                    return .sent(.unread(expected: option.text, reason: "the select left the page"))
            }
            let observed = read["text"]?.stringValue
            return read["holds"]?.boolValue == true
                ? .sent(.confirmed(expected: option.text, observed: observed ?? option.text))
                : .sent(.contradicted(expected: option.text, observed: observed))
        } catch {
            return .sent(.unread(expected: option.text, reason: "the page did not answer the read-back in time"))
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    /// A choice's script with the option it names (its index, value and full text) and `more` placeholders.
    static func script(_ template: String, _ option: WebSelectPopup.Option, _ more: [String: String] = [:]) -> String {
        render(template, ["INDEX": String(option.index), "VALUE": jsString(option.value), "TEXT": jsString(option.text)]
            .merging(more) { first, _ in first })
    }

    /// `template` with each `$NAME` placeholder of it replaced by `values[NAME]`, in one pass over the template as
    /// written: a value is inserted as it is and never searched again, so data that looks like a placeholder
    /// (`$TEXT` in an option's value) stays data. A placeholder with no value is left as it is.
    static func render(_ template: String, _ values: [String: String]) -> String {
        var rendered = ""
        var rest = template[...]
        while let dollar = rest.firstIndex(of: "$") {
            rendered += rest[..<dollar]
            let name = rest[rest.index(after: dollar)...].prefix { $0.isASCII && ($0.isUppercase || $0.isNumber) }
            if !name.isEmpty, let value = values[String(name)] {
                rendered += value
                rest = rest[name.endIndex...]
            } else {
                rendered.append("$")
                rest = rest[rest.index(after: dollar)...]
            }
        }
        rendered += rest
        return rendered
    }

    /// Closes an open list without choosing, as Escape or a click outside it does.
    func closePopup(in processID: pid_t) async {
        guard tabs.window(of: processID)?.popup != nil else { return }
        tabs.setPopup(nil, for: processID)
        _ = await evaluate(Self.closeScript, in: processID)
    }

    /// The open select's list as the page has it now; nil when none is open or it left the page.
    func openPopup(in processID: pid_t) async -> WebSelectPopup? {
        guard let answer = await evaluate(Self.popupScript, in: processID),
              let rect = answer["rect"]?.arrayValue?.compactMap(\.doubleValue), rect.count == 4
        else { return nil }
        let options = (answer["options"]?.arrayValue ?? []).map {
            WebSelectPopup.Option(text: $0["text"]?.stringValue ?? "", isSelected: $0["selected"]?.boolValue ?? false,
                                  isEnabled: !($0["disabled"]?.boolValue ?? false), index: $0["index"]?.intValue ?? -1,
                                  value: $0["value"]?.stringValue ?? "", group: $0["group"]?.stringValue)
        }
        return WebSelectPopup(name: answer["name"]?.stringValue ?? "select",
                              anchor: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), options: options)
    }

    // MARK: ARIA lists in the page (W05)

    /// AriaOption is what the ARIA list a control opened in the page itself offers for one item: no window is
    /// drawn for it, unlike a native select's list, so the choice cannot depend on a window appearing.
    public enum AriaOption: Sendable, Equatable {
        /// No ARIA list is open in the page: nothing to choose in.
        case noList
        /// A list is open, and none of its options is named so: nothing is sent.
        case missing(String)
        /// The option cannot be chosen safely (several lists open, several options of that name, a disabled
        /// option): nothing is sent.
        case refused(String)
        /// The one option to click, by the identity `WebScenes` gives its node.
        case option(WebNodeIdentity)
    }

    /// The option named `item` of the ARIA list that the control `owner` opened: the control the session clicked,
    /// by the identity its scene gave it, never another control expanded in the page. Its list is the one it names
    /// by `aria-controls` or `aria-owns`, else the only list shown when no other control is expanded. A trailing
    /// ` #n` picks the n-th option of that name, as the scene reads twins apart; with several and no ordinal, it
    /// refuses. The control and the option are kept on the isolated world's window for `ariaReadBack`, out of the
    /// DOM and of the page's globals. A control the page no longer has, or one that cannot be read, is refused.
    public func ariaOption(named item: String, owner: WebNodeIdentity, in processID: pid_t) async -> AriaOption {
        guard let page = try? tabs.page(for: processID) else { return .noList }
        guard let document = try? await WebScenes.documentNode(of: page),
              let node = WebScenes.node(of: owner, page: page, document: document)
        else { return .refused("the control is no longer the one that was read: the page changed") }
        let (name, ordinal) = Self.explicitOrdinal(item)
        // The function runs in the isolated world, on the control's node resolved there.
        let answer: JSONValue
        do {
            answer = try await tabs.call(
                Self.ariaOptionFunction,
                in            : processID,
                arguments     : [.string(LabelText.normalize(name)), .number(Double(ordinal ?? 0))],
                nodes         : [node],
                timeoutSeconds: 5
            )
        } catch {
            return .refused("the control could not be found or read in the page")
        }
        let reason = answer["reason"]?.stringValue ?? ""
        switch answer["kind"]?.stringValue {
            case "found"?:
                break
            case "missing"?:
                return .missing(reason)
            case "refused"?:
                return .refused(reason)
            default:
                return .noList
        }
        // The option is kept on the isolated world's window, so it is named from there.
        guard let backend = (try? await tabs.node(of: "window.__brausAriaOption", in: processID)) ?? nil else {
            return .refused("the option could not be named in the page")
        }
        return .option(WebScenes.identity(page: page, document: document, node: backend))
    }

    /// AriaReadBack is what the control of an ARIA list reads after an option was clicked and the page settled.
    public enum AriaReadBack: Sendable, Equatable {
        /// It reads the option's name.
        case confirmed(String)
        /// It reads something else.
        case contradicted(String)
        /// It could not be read (gone, or a secure field), or did not hold one value before the deadline.
        case unread(String)
    }

    /// What the control `ariaOption` kept reads, once it has held one value for `choiceWindow`, within
    /// `choiceBudget`: its input's value, else its `aria-valuetext`, else its text. A secure field
    /// (`WebSecureFields`) is never read.
    /// The limit, stated: a twin (an option of the same name) reads the same, so the read-back cannot tell twins
    /// apart; a change after the window is not seen.
    public func ariaReadBack(expecting item: String, in processID: pid_t) async -> AriaReadBack {
        guard (try? tabs.page(for: processID)) != nil else { return .unread("the tab is gone") }
        let expected = LabelText.normalize(Self.explicitOrdinal(item).0)
        let clock = ContinuousClock()
        let deadline = clock.now + choiceBudget
        var last: JSONValue?
        var since = clock.now
        while clock.now < deadline {
            let read = try? await tabs.evaluate(Self.ariaValueScript, in: processID, timeoutSeconds: 2)
            let now = clock.now
            if let read, read == last {
                if now - since >= choiceWindow {
                    guard let value = read.stringValue else { return .unread("the control is gone or cannot be read") }
                    return LabelText.normalize(value) == expected ? .confirmed(value) : .contradicted(value)
                }
            } else {
                last  = read
                since = now
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return .unread("the control did not hold one value before the deadline")
    }

    /// A label and the ordinal its trailing ` #n` names, nil when it names none.
    static func explicitOrdinal(_ label: String) -> (String, Int?) {
        guard let hash = label.range(of: " #", options: .backwards),
              let ordinal = Int(label[hash.upperBound...]), ordinal > 0
        else { return (label, nil) }
        return (String(label[..<hash.lowerBound]), ordinal)
    }

    /// A label and the ordinal its trailing ` #n` names, 1 when it has none.
    static func splitOrdinal(_ label: String) -> (String, Int) {
        guard let hash = label.range(of: " #", options: .backwards),
              let ordinal = Int(label[hash.upperBound...]), ordinal > 0
        else { return (label, 1) }
        return (String(label[..<hash.lowerBound]), ordinal)
    }

    static func jsString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode([text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    public func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? {
        let values = await evaluate(Self.controlValuesScript, in: processID)?.arrayValue?.compactMap(\.stringValue) ?? []
        let matches = Set(values.filter { labels.contains(LabelText.normalize($0)) })
        return matches.count == 1 ? matches.first : nil
    }

    public func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? {
        let script = Self.render(Self.toggleStateScript, ["X": String(Double(point.x)), "Y": String(Double(point.y))])
        switch await evaluate(script, in: processID)?.stringValue {
            case "true"? : return .on
            case "false"?: return .off
            case "mixed"?: return .mixed
            default      : return nil
        }
    }

    public func focusedFieldValue(in processID: pid_t) async -> String? {
        await evaluate(Self.focusedFieldScript, in: processID)?.stringValue
    }

    /// The script's value from the tab's isolated world; nil when the page cannot say, which every read
    /// answers as not knowing.
    private func evaluate(_ script: String, in processID: pid_t) async -> JSONValue? {
        try? await tabs.evaluate(script, in: processID, timeoutSeconds: 5)
    }

    // MARK: Scripts

    /// The select a person would call `$LABEL`, in the document or an open shadow root: normalized like
    /// `LabelText.normalize`, matched on its accessible name, then its current option. The chosen one is kept on
    /// the isolated world's window, out of the DOM and of the page's globals, so the page sees no change at all.
    /// Closed shadow roots and frames are not searched.
    static let openSelectScript = """
    (() => {
      const norm = s => (s || '').toLowerCase().replace(/[^\\p{L}\\p{M}\\p{N}]/gu, '');
      const nameOf = e => e.getAttribute('aria-label')
        || (e.getAttribute('aria-labelledby') || '').split(/\\s+/).map(id => (e.getRootNode().getElementById(id) || {}).textContent || '').join(' ').trim()
        || (e.labels && e.labels[0] ? e.labels[0].textContent : '') || e.title || '';
      const visible = e => { const r = e.getBoundingClientRect(); return r.width > 1 && r.height > 1
        && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth; };
      const deep = (root, selector) => [...root.querySelectorAll(selector)]
        .concat(...[...root.querySelectorAll('*')].filter(e => e.shadowRoot).map(e => deep(e.shadowRoot, selector)));
      const selects = deep(document, 'select').filter(e => !e.multiple && e.size <= 1 && visible(e));
      let found = selects.filter(e => norm(nameOf(e)) === $LABEL);
      if (!found.length) found = selects.filter(e => e.selectedOptions[0] && norm(e.selectedOptions[0].textContent) === $LABEL);
      const target = found[$ORDINAL - 1];
      if (!target || target.disabled) return false;
      Object.defineProperty(window, '__brausSelect', { value: target, configurable: true, writable: true });
      Object.defineProperty(window, '__brausOptions', { value: [...target.options], configurable: true, writable: true });
      target.focus();
      return true;
    })()
    """

    /// The open select's name, box and options, each with its index, value, group and whether it or its group
    /// is disabled; or null.
    static let popupScript = """
    (() => {
      const e = window.__brausSelect;
      if (!e || !e.isConnected) return null;
      const r = e.getBoundingClientRect();
      const name = e.getAttribute('aria-label') || (e.labels && e.labels[0] ? e.labels[0].textContent.trim() : '') || e.title || e.name || '';
      return { name, rect: [r.x, r.y, r.width, r.height],
               options: [...e.options].map((o, index) => {
                 const group = o.closest ? o.closest('optgroup') : null;
                 return { text: o.text.trim(), selected: o.selected, disabled: o.disabled || !!(group && group.disabled),
                          index, value: o.value, group: group ? group.label : null };
               }) };
    })()
    """

    /// Chooses the option at `$INDEX` the way a person's choice reaches a framework: focus, the selection by
    /// index (two options may share a value), `input`, `change`, blur. Only when the select is the node the list
    /// was opened on, still there and enabled, its options are the nodes kept then in the same order, and that
    /// option still has the value `$VALUE` and the text `$TEXT` and is enabled in an enabled group; otherwise it
    /// refuses, with no event.
    static let chooseOptionScript = """
    (() => {
      /* braus:choose */
      const e = window.__brausSelect, kept = window.__brausOptions || [];
      if (!e || !e.isConnected) return { status: 'refused', reason: 'the select is no longer the one the list was opened on' };
      if (e.disabled) return { status: 'refused', reason: 'the select is disabled' };
      const now = [...e.options];
      if (now.length !== kept.length || now.some((o, i) => o !== kept[i]))
        return { status: 'refused', reason: "the list's options changed since it was read" };
      const option = now[$INDEX];
      if (!option || option.value !== $VALUE || option.text.trim() !== $TEXT)
        return { status: 'refused', reason: 'the option changed since the list was read' };
      const group = option.closest ? option.closest('optgroup') : null;
      if (option.disabled || (group && group.disabled)) return { status: 'refused', reason: 'the option is disabled' };
      e.focus();
      option.selected = true;
      e.selectedIndex = $INDEX;
      e.dispatchEvent(new Event('input', { bubbles: true }));
      e.dispatchEvent(new Event('change', { bubbles: true }));
      e.blur();
      Object.defineProperty(window, '__brausChosen', { value: option, configurable: true, writable: true });
      return { status: 'sent' };
    })()
    """

    /// Watches the select after a choice, every 25 ms, until it held one state (the selected option node, its
    /// index, the value and the full text) for `$WINDOW` ms, within `$LIMIT` ms; then answers whether that state
    /// is the chosen option as it was chosen: the same node, at its index, with the value and the full text read
    /// when the list opened (an option the page changed after the choice is not the one chosen), and the text it
    /// holds. `unsettled` when it did not hold still in time.
    static let readBackScript = """
    (async () => {
      /* braus:read-back */
      const e = window.__brausSelect, option = window.__brausChosen, step = 25;
      const state = () => {
        if (!e || !e.isConnected) return null;
        const held = e.selectedOptions[0] || null;
        return { index: e.selectedIndex, value: e.value, text: held ? held.text.trim() : null, node: held };
      };
      const same = (a, b) => !!a && !!b && a.index === b.index && a.value === b.value && a.text === b.text && a.node === b.node;
      await Promise.resolve();
      let last = state(), held = 0, waited = 0;
      while (last && held < $WINDOW && waited + step <= $LIMIT) {
        await new Promise(resolve => setTimeout(resolve, step));
        waited += step;
        const now = state();
        if (same(now, last)) { held += step; } else { last = now; held = 0; }
      }
      delete window.__brausSelect; delete window.__brausChosen; delete window.__brausOptions;
      if (!last) return { state: 'gone' };
      if (held < $WINDOW) return { state: 'unsettled', held };
      return { state: 'read', held,
               holds: last.index === $INDEX && last.node === option && last.value === $VALUE && last.text === $TEXT,
               text: last.text };
    })()
    """

    // One expression, not two statements: a world's script is evaluated as the value of a function.
    static let closeScript = "delete window.__brausSelect, delete window.__brausOptions"

    /// Run in the isolated world on the control the session clicked (`control`, resolved there): the option
    /// `label` (normalized like `LabelText.normalize`) of the ARIA list that control opened, `ordinal` the n-th of
    /// that name or 0 for the only one. The control is the node clicked, or the element around or inside it that
    /// carries `aria-expanded`; a control that is not expanded opened nothing, whatever else is open in the page.
    /// Its list is the one it names by `aria-controls` or `aria-owns`, else the only list shown when no other
    /// control is expanded. Answers what it found, and keeps the control and the option on the world's window when
    /// it found one. The lists it names are looked up in its own root, a shadow root's or the document's; the others
    /// in the document and every open shadow root. Closed shadow roots and frames are not searched.
    static let ariaOptionFunction = """
    function (label, ordinal, control) {
      /* braus:aria-options */
      if (!(control instanceof Element)) return { kind: 'none' };
      const norm = s => (s || '').toLowerCase().replace(/[^\\p{L}\\p{M}\\p{N}]/gu, '');
      const visible = e => { const r = e.getBoundingClientRect(); return r.width > 1 && r.height > 1
        && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth; };
      const owner = control.matches('[aria-expanded]') ? control
        : (control.closest('[aria-expanded]') || control.querySelector('[aria-expanded]'));
      if (!owner || owner.getAttribute('aria-expanded') !== 'true') return { kind: 'none' };
      const deep = (root, selector) => [...root.querySelectorAll(selector)]
        .concat(...[...root.querySelectorAll('*')].filter(e => e.shadowRoot).map(e => deep(e.shadowRoot, selector)));
      const root = owner.getRootNode();
      const named = ((owner.getAttribute('aria-controls') || '') + ' ' + (owner.getAttribute('aria-owns') || ''))
        .split(/\\s+/).filter(Boolean).map(id => root.getElementById(id)).filter(e => e && visible(e));
      let lists = named;
      if (!lists.length) {
        const others = deep(document, '[aria-expanded="true"]').filter(e => e !== owner && visible(e));
        if (others.length) return { kind: 'refused', reason: 'the control names no list, and another control is expanded' };
        lists = deep(document, '[role=listbox], [role=menu]').filter(visible);
      }
      if (lists.length !== 1) return { kind: 'refused', reason: 'the list the control opened cannot be told from another' };
      const options = [...lists[0].querySelectorAll('[role=option], [role=menuitem], [role=menuitemradio], [role=menuitemcheckbox]')]
        .filter(visible);
      const nameOf = o => o.getAttribute('aria-label') || o.textContent || '';
      const matches = options.filter(o => norm(nameOf(o)) === label);
      if (!matches.length) return { kind: 'missing', reason: 'the open list has no option of that name' };
      if (matches.length > 1 && ordinal === 0) {
        return { kind: 'refused', reason: 'several options have that name; name one as the scene shows it, with its ordinal' };
      }
      const chosen = matches[Math.max(ordinal, 1) - 1];
      if (!chosen) return { kind: 'missing', reason: 'the open list has fewer options of that name' };
      if (chosen.closest('[aria-disabled="true"]')) return { kind: 'refused', reason: 'that option is disabled' };
      Object.defineProperty(window, '__brausAriaOwner', { value: owner, configurable: true, writable: true });
      Object.defineProperty(window, '__brausAriaOption', { value: chosen, configurable: true, writable: true });
      return { kind: 'found' };
    }
    """

    /// What the control `ariaOptionFunction` kept reads now: its input's value (its own, or the one it holds), else its
    /// `aria-valuetext`, else its text; null when it is gone or is a secure field (`WebSecureFields`).
    static let ariaValueScript = """
    (() => {
      /* braus:aria-value */
      const secure = \(WebSecureFields.function);
      const o = window.__brausAriaOwner;
      if (!o || !o.isConnected) return null;
      const input = o.matches('input, textarea') ? o : o.querySelector('input, textarea');
      if (input && secure(input)) return null;
      const shown = input ? input.value : (o.getAttribute('aria-valuetext') || o.textContent || '');
      return shown.trim();
    })()
    """

    /// The current value of every select, combo box and text field in the main document; a secure
    /// field's value (`WebSecureFields`) is never read.
    static let controlValuesScript = """
    (() => {
      const secure = \(WebSecureFields.function);
      const out = [];
      for (const e of document.querySelectorAll('select, input, [role=combobox]')) {
        if (secure(e)) continue;
        if (e.tagName === 'SELECT') { const o = e.selectedOptions[0]; if (o) out.push(o.textContent.trim()); }
        else if ('value' in e && typeof e.value === 'string') out.push(e.value);
        else out.push((e.getAttribute('aria-valuetext') || e.textContent || '').trim());
      }
      return out;
    })()
    """

    /// The checked state of the checkbox, radio or switch under a viewport point, through labels.
    static let toggleStateScript = """
    (() => {
      let e = document.elementFromPoint($X, $Y);
      while (e && e.shadowRoot) { const inner = e.shadowRoot.elementFromPoint($X, $Y); if (!inner || inner === e) break; e = inner; }
      if (!e) return null;
      const label = e.closest('label');
      const input = label ? (label.control || label.querySelector('input')) : null;
      const target = (e.matches('input[type=checkbox], input[type=radio]') ? e : null) || input
        || e.closest('[role=checkbox], [role=switch], [role=radio], [role=menuitemcheckbox], [aria-pressed]');
      if (!target) return null;
      if (target.tagName === 'INPUT') return target.indeterminate ? 'mixed' : String(target.checked);
      return target.getAttribute('aria-checked') || target.getAttribute('aria-pressed');
    })()
    """

    /// The text of the field that holds the focus, through shadow roots and same-origin frames; null for
    /// a secure field (`WebSecureFields`), whose value is never read.
    static let focusedFieldScript = """
    (() => {
      const secure = \(WebSecureFields.function);
      let e = document.activeElement;
      for (;;) {
        if (e && e.shadowRoot && e.shadowRoot.activeElement) { e = e.shadowRoot.activeElement; continue; }
        if (e && (e.tagName === 'IFRAME' || e.tagName === 'FRAME')) {
          try { const inner = e.contentDocument && e.contentDocument.activeElement; if (inner) { e = inner; continue; } } catch (_) {}
        }
        break;
      }
      if (!e || secure(e)) return null;
      if (e.tagName === 'TEXTAREA') return e.value;
      if (e.tagName === 'INPUT' && !['checkbox','radio','button','submit','reset','image','file','range','color'].includes(e.type)) return e.value;
      if (e.isContentEditable) return e.innerText.replace(/\\n$/, '');
      return null;
    })()
    """
}
