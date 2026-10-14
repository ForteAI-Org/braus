//
//  WebControls.swift
//  Braus
//

import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore
import WebDriver

/// WebControls is `ControlPressing` for tabs: it reads controls through the page's own DOM.
///
/// A native `<select>` is pressed by name: Chrome draws its list outside the page, so Braus opens
/// a `WebSelectPopup` instead of clicking, and `pressMenuItem` chooses in it. Every read answers
/// nil or false when the page cannot say.
public struct WebControls: ControlPressing {

    let tabs: WebTabs

    public init(tabs: WebTabs) {
        self.tabs = tabs
    }

    /// Opens the list of the one select named `label`, by its accessible name or its current
    /// option; a trailing ordinal ` #n` picks the n-th of several. False for anything else, which
    /// the engine then clicks.
    public func pressControl(labelled label: String, in processID: pid_t) async -> Bool {
        guard let page = try? tabs.page(for: processID) else { return false }
        let (name, ordinal) = Self.splitOrdinal(label)
        let script = Self.openSelectScript
            .replacingOccurrences(of: "$LABEL", with: Self.jsString(LabelText.normalize(name)))
            .replacingOccurrences(of: "$ORDINAL", with: String(ordinal))
        guard (try? await page.evaluate(script, timeoutSeconds: 5))?.boolValue == true,
              let popup = await Self.openPopup(on: page)
        else { return false }
        tabs.setPopup(popup, for: processID)
        return true
    }

    /// Chooses the option titled `title` in the open select's list and closes it. False, with the
    /// list left open, when no option has that title or no list is open.
    public func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
        guard let page = try? tabs.page(for: processID), tabs.window(of: processID)?.popup != nil else { return false }
        let script = Self.chooseOptionScript
            .replacingOccurrences(of: "$TITLE", with: Self.jsString(LabelText.menuTitleKey(Self.splitOrdinal(title).0)))
        let answer = try? await page.evaluate(script, timeoutSeconds: 5)
        guard answer?["found"]?.boolValue == true else { return false }
        tabs.setPopup(nil, for: processID)
        return true
    }

    /// Closes an open list without choosing, as Escape or a click outside it does.
    func closePopup(in processID: pid_t) async {
        guard tabs.window(of: processID)?.popup != nil else { return }
        tabs.setPopup(nil, for: processID)
        if let page = try? tabs.page(for: processID) { _ = try? await page.evaluate(Self.closeScript) }
    }

    /// The open select's list as the page has it now; nil when none is open or it left the page.
    static func openPopup(on page: WebPage) async -> WebSelectPopup? {
        guard let answer = try? await page.evaluate(popupScript, timeoutSeconds: 5),
              let rect = answer["rect"]?.arrayValue?.compactMap(\.doubleValue), rect.count == 4
        else { return nil }
        let options = (answer["options"]?.arrayValue ?? []).map {
            WebSelectPopup.Option(text: $0["text"]?.stringValue ?? "", isSelected: $0["selected"]?.boolValue ?? false,
                                  isEnabled: !($0["disabled"]?.boolValue ?? false))
        }
        return WebSelectPopup(name: answer["name"]?.stringValue ?? "select",
                              anchor: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), options: options)
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
        let script = Self.toggleStateScript.replacingOccurrences(of: "$X", with: String(Double(point.x)))
            .replacingOccurrences(of: "$Y", with: String(Double(point.y)))
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

    private func evaluate(_ script: String, in processID: pid_t) async -> JSONValue? {
        guard let page = try? tabs.page(for: processID) else { return nil }
        return try? await page.evaluate(script, timeoutSeconds: 5)
    }

    // MARK: Scripts

    /// The select a person would call `$LABEL`: normalized like `LabelText.normalize`, matched on
    /// its accessible name, then its current option. The chosen one is kept on the window, out of
    /// the DOM, so the page sees no attribute change.
    static let openSelectScript = """
    (() => {
      const norm = s => (s || '').toLowerCase().replace(/[^\\p{L}\\p{M}\\p{N}]/gu, '');
      const nameOf = e => e.getAttribute('aria-label')
        || (e.getAttribute('aria-labelledby') || '').split(/\\s+/).map(id => (document.getElementById(id) || {}).textContent || '').join(' ').trim()
        || (e.labels && e.labels[0] ? e.labels[0].textContent : '') || e.title || '';
      const visible = e => { const r = e.getBoundingClientRect(); return r.width > 1 && r.height > 1
        && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth; };
      const selects = [...document.querySelectorAll('select')].filter(e => !e.multiple && e.size <= 1 && visible(e));
      let found = selects.filter(e => norm(nameOf(e)) === $LABEL);
      if (!found.length) found = selects.filter(e => e.selectedOptions[0] && norm(e.selectedOptions[0].textContent) === $LABEL);
      const target = found[$ORDINAL - 1];
      if (!target || target.disabled) return false;
      Object.defineProperty(window, '__brausSelect', { value: target, configurable: true, writable: true });
      target.focus();
      return true;
    })()
    """

    /// The open select's name, box and options, or null.
    static let popupScript = """
    (() => {
      const e = window.__brausSelect;
      if (!e || !e.isConnected) return null;
      const r = e.getBoundingClientRect();
      const name = e.getAttribute('aria-label') || (e.labels && e.labels[0] ? e.labels[0].textContent.trim() : '') || e.title || e.name || '';
      return { name, rect: [r.x, r.y, r.width, r.height],
               options: [...e.options].map(o => ({ text: o.text.trim(), selected: o.selected, disabled: o.disabled })) };
    })()
    """

    /// Chooses the option whose title is `$TITLE`, compared like `LabelText.menuTitleKey`, the way
    /// a person's choice reaches a framework: focus, value, `input`, `change`, blur. `stuck` says
    /// whether the value held.
    static let chooseOptionScript = """
    (() => {
      const e = window.__brausSelect;
      if (!e || !e.isConnected) return { found: false };
      const key = s => (s || '').replace(/[\\u2066-\\u2069\\u200e\\u200f]/g, '').replace(/[\\u201c\\u201d]/g, '"')
        .replace(/[\\u2018\\u2019]/g, "'").trim().replace(/(\\u2026|\\.\\.\\.)$/, '').trim().toLowerCase();
      const option = [...e.options].find(o => !o.disabled && key(o.text) === $TITLE);
      if (!option) return { found: false };
      e.focus();
      e.value = option.value;
      option.selected = true;
      e.selectedIndex = option.index;
      e.dispatchEvent(new Event('input', { bubbles: true }));
      e.dispatchEvent(new Event('change', { bubbles: true }));
      e.blur();
      delete window.__brausSelect;
      return { found: true, stuck: e.value === option.value };
    })()
    """

    static let closeScript = "delete window.__brausSelect"

    /// The current value of every select, combo box and text field in the main document.
    static let controlValuesScript = """
    (() => {
      const out = [];
      for (const e of document.querySelectorAll('select, input, [role=combobox]')) {
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

    /// The text of the field that holds the focus, through shadow roots and same-origin frames.
    static let focusedFieldScript = """
    (() => {
      let e = document.activeElement;
      for (;;) {
        if (e && e.shadowRoot && e.shadowRoot.activeElement) { e = e.shadowRoot.activeElement; continue; }
        if (e && (e.tagName === 'IFRAME' || e.tagName === 'FRAME')) {
          try { const inner = e.contentDocument && e.contentDocument.activeElement; if (inner) { e = inner; continue; } } catch (_) {}
        }
        break;
      }
      if (!e) return null;
      if (e.tagName === 'TEXTAREA') return e.value;
      if (e.tagName === 'INPUT' && !['checkbox','radio','button','submit','reset','image','file','range','color'].includes(e.type)) return e.value;
      if (e.isContentEditable) return e.innerText.replace(/\\n$/, '');
      return null;
    })()
    """
}
