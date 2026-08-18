// dsh-shell bridge — injected at documentStart into the dsh SPA.
// Provides:
//   window.__dshShell.do(action, arg)   — native -> web commands
//   window.__dshShell.setCssShim(on)    — toggle the titlebar-safe-area CSS shim
//   web -> native events via window.webkit.messageHandlers.dshBridge
//
// Everything here must be defensive: the SPA's DOM is not guaranteed to match
// any assumption, so every lookup is guarded and failures are silent. Probe
// events are posted so the native side can tune selectors from real pages.
(function () {
  'use strict';
  if (window.__dshShell) { return; }

  var bridge = {};

  function post(type, payload) {
    try {
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dshBridge;
      if (h) { h.postMessage(JSON.stringify({ type: type, payload: payload || null })); }
    } catch (e) { /* never throw */ }
  }

  function cls(el) { return el && el.className ? String(el.className) : ''; }
  function attr(el, name) { return el ? el.getAttribute(name) : null; }

  // ---- composer detection: the main message input ----
  function findComposer() {
    var q = document.querySelector('textarea[data-testid], textarea, [contenteditable="true"]');
    return q || null;
  }

  function focusComposer() {
    var el = findComposer();
    if (el) { el.focus(); return { ok: true }; }
    return { ok: false };
  }

  // React-controlled textarea value setter trick: bypasses React's value
  // tracker while still firing a bubbled `input` event React listens to.
  function setNativeValue(el, text) {
    var proto = el.tagName === 'TEXTAREA'
      ? window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement.prototype;
    var setter = Object.getOwnPropertyDescriptor(proto, 'value');
    if (setter && setter.set) { setter.set.call(el, text); }
    else { el.value = text; }
    el.dispatchEvent(new Event('input', { bubbles: true }));
  }

  function sendMessage() {
    var el = findComposer();
    if (!el) { return { ok: false }; }
    el.focus();
    var e = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
    el.dispatchEvent(new KeyboardEvent('keydown', e));
    el.dispatchEvent(new KeyboardEvent('keyup', e));
    return { ok: true };
  }

  // ---- button lookup helpers ----
  function buttonByPattern(patterns) {
    var buttons = document.querySelectorAll('button, [role="button"]');
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      var hay = ((attr(b, 'aria-label') || '') + ' ' + (attr(b, 'title') || '') + ' ' + cls(b)).toLowerCase();
      for (var j = 0; j < patterns.length; j++) {
        if (hay.indexOf(patterns[j]) !== -1) { return b; }
      }
    }
    return null;
  }

  function newSession() {
    var b = buttonByPattern(['new chat', 'new conversation', '新建', '新对话', 'new-session', 'create session']);
    if (b) { b.click(); return { ok: true, method: 'click' }; }
    return { ok: false };
  }

  function openWorkspace() {
    var b = buttonByPattern(['workspace', 'folder', 'directory', '工作区', '目录', '文件夹']);
    if (b) { b.click(); return { ok: true, method: 'click' }; }
    return { ok: false };
  }

  // ---- CSS shim: keep the SPA's top chrome clear of the traffic lights ----
  var cssShimId = 'dsh-shell-css-shim';
  function applyCssShim(on) {
    try {
      var style = document.getElementById(cssShimId);
      if (on && !style) {
        style = document.createElement('style');
        style.id = cssShimId;
        style.textContent = 'body > #root, #root { padding-top: 30px !important; }';
        (document.head || document.documentElement).appendChild(style);
      } else if (!on && style) {
        style.parentNode && style.parentNode.removeChild(style);
      }
      return { ok: true };
    } catch (e) { return { ok: false }; }
  }

  // ---- probe: report DOM candidates for native-side selector tuning ----
  function probeCandidates() {
    var out = { headings: [], buttons: [], inputs: [], running: false };
    try {
      var hs = document.querySelectorAll('h1, h2, h3');
      for (var i = 0; i < Math.min(hs.length, 10); i++) {
        var t = hs[i].textContent ? hs[i].textContent.trim().slice(0, 120) : '';
        if (t) { out.headings.push({ tag: hs[i].tagName, cls: cls(hs[i]).slice(0, 100), text: t }); }
      }
      var bs = document.querySelectorAll('button');
      for (var j = 0; j < Math.min(bs.length, 40); j++) {
        out.buttons.push({
          aria: attr(bs[j], 'aria-label'),
          title: attr(bs[j], 'title'),
          cls: cls(bs[j]).slice(0, 100)
        });
      }
      var ins = document.querySelectorAll('textarea, [contenteditable="true"]');
      for (var k = 0; k < Math.min(ins.length, 5); k++) {
        out.inputs.push({
          tag: ins[k].tagName,
          placeholder: attr(ins[k], 'placeholder'),
          cls: cls(ins[k]).slice(0, 100)
        });
      }
    } catch (e) { /* ignore */ }
    return out;
  }

  // ---- observation: agent running state + document title ----
  var runningState = null;
  var lastTitle = null;
  function scanRunning() {
    try {
      var buttons = document.querySelectorAll('button');
      var running = false;
      for (var i = 0; i < buttons.length; i++) {
        var b = buttons[i];
        var hay = ((attr(b, 'aria-label') || '') + ' ' + (attr(b, 'title') || '') + ' ' + cls(b)).toLowerCase();
        if (hay.indexOf('stop') !== -1 || hay.indexOf('interrupt') !== -1 || hay.indexOf('中断') !== -1 || hay.indexOf('停止') !== -1) {
          running = true; break;
        }
      }
      if (running !== runningState) {
        runningState = running;
        post('agentState', { running: running });
      }
      var t = (document.title || '').trim();
      if (t !== lastTitle) {
        lastTitle = t;
        post('title', { text: t });
      }
    } catch (e) { /* ignore */ }
  }

  function scheduleScan() {
    clearTimeout(scheduleScan._t);
    scheduleScan._t = setTimeout(function () { scanRunning(); }, 400);
  }

  try {
    var mo = window.MutationObserver ? new MutationObserver(scheduleScan) : null;
    if (mo) { mo.observe(document.documentElement, { childList: true, subtree: true }); }
  } catch (e) { /* ignore */ }

  // ---- public surface ----
  bridge.do = function (action, arg) {
    var result;
    switch (action) {
      case 'focusComposer': result = focusComposer(); break;
      case 'sendMessage': result = sendMessage(); break;
      case 'newSession': result = newSession(); break;
      case 'openWorkspace': result = openWorkspace(); break;
      case 'setCssShim': result = applyCssShim(!!arg); break;
      case 'injectText': { var el = findComposer(); result = el ? (setNativeValue(el, String(arg || '')), { ok: true }) : { ok: false }; break; }
      default: result = { ok: false, reason: 'unknown action' };
    }
    var ack = { action: action, ok: !!result.ok };
    if (result && result.reason) { ack.reason = result.reason; }
    post('ack', ack);
    return result;
  };

  window.__dshShell = bridge;

  // initial probe once the app shell has a chance to mount
  setTimeout(function () {
    post('probe', probeCandidates());
    scanRunning();
  }, 2500);
  setTimeout(function () {
    post('probe', probeCandidates());
    scanRunning();
  }, 8000);
})();
