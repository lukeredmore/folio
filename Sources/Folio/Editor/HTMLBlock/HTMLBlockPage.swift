import AppKit
import Foundation

/// Theme values that change how an HTML block lays out and looks in its web view.
struct HTMLBlockPageStyle: Hashable, Sendable {
    let bodyFontFamily: String
    let codeFontFamily: String
    let fontSize: Double
    let lineHeight: Double
    let textColor: String
    let secondaryTextColor: String
    let linkColor: String
    let codeBackgroundColor: String
    let backgroundColor: String
    let borderColor: String
    let commentFill: String
    let activeCommentFill: String
    let draftFill: String
    let isDark: Bool

    init(theme: EditorTheme, typography: EditorTypographySettings) {
        let size = theme.baseFontSize * typography.fontSizeScale
        bodyFontFamily = Self.cssFamily(theme.bodyFont(size: size), fallback: "system-ui")
        codeFontFamily = Self.cssFamily(theme.codeFont(size: size), fallback: "ui-monospace")
        fontSize = Double(size)
        // NSParagraphStyle multiplies the natural line height, which is about 1.2 em.
        lineHeight = (Double(typography.lineHeightMultiple) * 1.2 * 100).rounded() / 100
        textColor = Self.css(theme.textNSColor)
        secondaryTextColor = Self.css(theme.secondaryTextNSColor)
        linkColor = Self.css(theme.linkNSColor)
        codeBackgroundColor = Self.css(theme.codeBackgroundNSColor)
        backgroundColor = Self.css(theme.editorBackgroundNSColor)
        borderColor = theme.isDark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)"
        let link = theme.linkNSColor
        commentFill = Self.css(link.withAlphaComponent(theme.isDark ? 0.16 : 0.11))
        activeCommentFill = Self.css(link.withAlphaComponent(theme.isDark ? 0.26 : 0.18))
        draftFill = Self.css(link.withAlphaComponent(theme.isDark ? 0.22 : 0.15))
        isDark = theme.isDark
    }

    static func css(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        let a = (Double(rgb.alphaComponent) * 1000).rounded() / 1000
        return "rgba(\(r),\(g),\(b),\(a))"
    }

    private static func cssFamily(_ font: NSFont, fallback: String) -> String {
        guard let family = font.familyName, !family.hasPrefix(".") else { return fallback }
        let escaped = family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\", \(fallback)"
    }
}

/// Builds the page and the bridge script that an `HTMLBlockWebView` loads.
enum HTMLBlockPage {
    /// URL scheme that serves files from the document's folder.
    static let assetScheme = "folio-doc"
    static let baseURL = URL(string: "\(assetScheme)://local/")!
    static let messageHandlerName = "folio"

    /// Blocks every subresource except images and media, so a block cannot load scripts,
    /// frames, fonts, or styles from the network.
    static let contentSecurityPolicy =
        "default-src 'none'; img-src * data: blob: \(assetScheme):; media-src * data: blob: \(assetScheme):; style-src 'unsafe-inline'; font-src data:"

    static func document(source: String, style: HTMLBlockPageStyle) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>\(stylesheet(style))</style>
        </head><body><div id="folio-root">\(HTMLBlockMarkup.annotatedMarkup(source))</div></body></html>
        """
    }

    static func stylesheet(_ style: HTMLBlockPageStyle) -> String {
        """
        :root { color-scheme: \(style.isDark ? "dark" : "light"); }
        html, body { margin: 0; padding: 0; background: \(style.backgroundColor); overflow: hidden; }
        body { font-family: \(style.bodyFontFamily); font-size: \(style.fontSize)px; line-height: \(style.lineHeight);
          color: \(style.textColor); overflow-wrap: break-word; -webkit-text-size-adjust: none; }
        #folio-root { display: flow-root; }
        #folio-root > :first-child { margin-top: 0; }
        #folio-root > :last-child { margin-bottom: 0; }
        a { color: \(style.linkColor); }
        code, kbd, pre, samp { font-family: \(style.codeFontFamily); font-size: 0.9em; }
        pre { background: \(style.codeBackgroundColor); padding: 8px 12px; border-radius: 6px; overflow: auto; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid \(style.borderColor); padding: 4px 10px; }
        hr { border: none; border-top: 1px solid \(style.borderColor); }
        img, video { max-width: 100%; }
        ::highlight(folio-comment) { background-color: \(style.commentFill); }
        ::highlight(folio-comment-active) { background-color: \(style.activeCommentFill); }
        ::highlight(folio-draft) { background-color: \(style.draftFill); }
        """
    }

    /// The bridge script. It runs in the client content world, so page scripts (which are off)
    /// cannot reach it. `source` is the block source that the `data-fs`/`data-fe` offsets index.
    static func bridgeScript(source: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [source], options: [])) ?? Data("[\"\"]".utf8)
        let sourceArray = String(decoding: data, as: UTF8.self)
        return """
            (() => {
              const SRC = \(sourceArray)[0];
              const post = (m) => window.webkit.messageHandlers.\(messageHandlerName).postMessage(m);
              const root = document.getElementById('folio-root');
              const maps = new WeakMap();
              const decoder = document.createElement('textarea');
              const entity = /^&(#[0-9]{1,8};|#[xX][0-9a-fA-F]{1,8};|[A-Za-z][A-Za-z0-9]{1,31};?)/;
              const wrappers = () => Array.from(root.querySelectorAll('[data-fs]'));
              const textOf = (w) => (w.firstChild && w.firstChild.nodeType === 3) ? w.firstChild : null;

              function mapFor(w) {
                let m = maps.get(w);
                if (m) return m;
                const fs = +w.dataset.fs, fe = +w.dataset.fe;
                const raw = SRC.slice(fs, fe);
                const node = textOf(w);
                const dom = node ? node.data : '';
                const d2s = new Array(dom.length + 1);
                let i = 0, j = 0;
                while (j < dom.length && i < raw.length) {
                  d2s[j] = i;
                  if (raw[i] === '&') {
                    const hit = entity.exec(raw.slice(i, i + 40));
                    if (hit) {
                      decoder.innerHTML = hit[0];
                      const dec = decoder.value;
                      if (dec.length > 0 && dec !== hit[0] && dom.startsWith(dec, j)) {
                        for (let k = 1; k < dec.length; k++) d2s[j + k] = i;
                        j += dec.length; i += hit[0].length; continue;
                      }
                    }
                  }
                  if (raw[i] === '\\r' && dom[j] === '\\n') { i += raw[i + 1] === '\\n' ? 2 : 1; j += 1; continue; }
                  i += 1; j += 1;
                }
                for (; j < dom.length; j++) d2s[j] = Math.min(i, raw.length);
                d2s[dom.length] = raw.length;
                m = { fs, fe, d2s, node };
                maps.set(w, m);
                return m;
              }

              function wrapperOf(node) {
                const p = node && node.nodeType === 3 ? node.parentElement : null;
                return p && p.hasAttribute('data-fs') ? p : null;
              }

              function toSource(container, offset, isStart) {
                const w = wrapperOf(container);
                if (w) { const m = mapFor(w); return m.fs + m.d2s[Math.min(offset, m.d2s.length - 1)]; }
                const r = document.createRange();
                r.setStart(container, offset);
                r.collapse(true);
                const ws = wrappers();
                if (isStart) {
                  for (const x of ws) if (r.comparePoint(x, 0) >= 0) return +x.dataset.fs;
                  return null;
                }
                for (let k = ws.length - 1; k >= 0; k--) {
                  const x = ws[k];
                  if (r.comparePoint(x, x.childNodes.length) <= 0) return +x.dataset.fe;
                }
                return null;
              }

              function toDom(offset, isStart) {
                const ws = wrappers();
                for (const w of ws) {
                  const m = mapFor(w);
                  if (!m.node || offset < m.fs || offset > m.fe) continue;
                  if (offset === m.fe && isStart) continue;
                  const rel = offset - m.fs;
                  let j = 0;
                  while (j + 1 < m.d2s.length && m.d2s[j + 1] <= rel) j++;
                  return [m.node, j];
                }
                if (isStart) {
                  for (const w of ws) { const m = mapFor(w); if (m.node && m.fs >= offset) return [m.node, 0]; }
                  return null;
                }
                for (let k = ws.length - 1; k >= 0; k--) {
                  const m = mapFor(ws[k]);
                  if (m.node && m.fe <= offset) return [m.node, m.node.length];
                }
                return null;
              }

              function rangeFor(start, end) {
                const a = toDom(start, true), b = toDom(end, false);
                if (!a || !b) return null;
                const r = document.createRange();
                try { r.setStart(a[0], a[1]); r.setEnd(b[0], b[1]); } catch (e) { return null; }
                return r.collapsed ? null : r;
              }

              function isBackward(sel) {
                if (sel.direction) return sel.direction === 'backward';
                if (sel.anchorNode === sel.focusNode) return sel.focusOffset < sel.anchorOffset;
                const r = document.createRange();
                r.setStart(sel.anchorNode, sel.anchorOffset);
                r.setEnd(sel.focusNode, sel.focusOffset);
                return r.collapsed;
              }

              function reportSelection() {
                const sel = document.getSelection();
                if (!sel || sel.rangeCount === 0 || sel.isCollapsed) { post({ type: 'selection', empty: true }); return; }
                const r = sel.getRangeAt(0);
                const s = toSource(r.startContainer, r.startOffset, true);
                const e = toSource(r.endContainer, r.endOffset, false);
                const whole = s === null || e === null || e <= s;
                const rects = Array.from(r.getClientRects())
                  .filter((x) => x.width > 0 && x.height > 0)
                  .map((x) => [x.left + window.scrollX, x.top + window.scrollY, x.width, x.height]);
                post({ type: 'selection', empty: false, start: whole ? 0 : s, end: whole ? SRC.length : e,
                       rects, backward: isBackward(sel) });
              }

              // A microtask, not an animation frame: WebKit pauses frames in occluded windows.
              let pending = false;
              document.addEventListener('selectionchange', () => {
                if (pending) return;
                pending = true;
                queueMicrotask(() => { pending = false; reportSelection(); });
              });

              // A click that only clears a selection, or that ends a drag selection, is not reported.
              let hadSelection = false;
              document.addEventListener('mousedown', () => {
                const sel = document.getSelection();
                hadSelection = !!sel && !sel.isCollapsed;
              }, true);
              document.addEventListener('click', (ev) => {
                const sel = document.getSelection();
                if (hadSelection || (sel && !sel.isCollapsed)) return;
                if (ev.target && ev.target.closest && ev.target.closest('a[href]')) return;
                const cr = document.caretRangeFromPoint(ev.clientX, ev.clientY);
                const offset = cr ? toSource(cr.startContainer, cr.startOffset, true) : null;
                post({ type: 'click', offset, count: ev.detail });
              }, true);

              let lastHeight = -1;
              const reportHeight = () => {
                const h = Math.ceil(root.getBoundingClientRect().height);
                if (h !== lastHeight) { lastHeight = h; post({ type: 'height', height: h }); }
              };
              new ResizeObserver(reportHeight).observe(root);
              document.addEventListener('load', reportHeight, true);
              window.addEventListener('load', reportHeight);

              window.__folioSetHighlights = (items) => {
                if (!(window.CSS && CSS.highlights && window.Highlight)) return;
                const groups = {};
                for (const it of items) {
                  const r = rangeFor(it.start, it.end);
                  if (r) (groups[it.kind] = groups[it.kind] || []).push(r);
                }
                for (const k of ['folio-comment', 'folio-comment-active', 'folio-draft']) {
                  if (groups[k]) CSS.highlights.set(k, new Highlight(...groups[k])); else CSS.highlights.delete(k);
                }
              };
              window.__folioSelect = (start, end) => {
                const r = rangeFor(start, end);
                const sel = document.getSelection();
                if (!r || !sel) return false;
                sel.removeAllRanges();
                sel.addRange(r);
                return true;
              };
              window.__folioClearSelection = () => { const s = document.getSelection(); if (s) s.removeAllRanges(); };
              window.__folioSetOpacity = (o) => { root.style.opacity = String(o); };
              window.__folioReportHeight = () => { lastHeight = -1; reportHeight(); };

              reportHeight();
              post({ type: 'ready' });
            })();
            """
    }
}
