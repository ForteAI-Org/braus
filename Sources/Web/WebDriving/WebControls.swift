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
/// It does not press a closed `<select>`: Chrome draws that list outside the page, where neither
/// the scene nor a click reaches, so `pressControl` answers false and the engine falls back to the
/// keyboard. Every read answers nil or false when the page cannot say.
public struct WebControls: ControlPressing {

    let tabs: WebTabs

    public init(tabs: WebTabs) {
        self.tabs = tabs
    }

    public func pressControl(labelled label: String, in processID: pid_t) async -> Bool {
        false
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
