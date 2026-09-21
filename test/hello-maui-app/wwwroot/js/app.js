// OpenHarmony bridge smoke test (S1/R1), page half. See index.html for the device
// expectations and the checklist. No dependencies; every failure is reported in the page.
//
// What this script does:
//   1. prints typeof probes for the bridge globals and refreshes them for 15 seconds
//      (the shell injects its shim after the page load event),
//   2. sends a JSON ping on click through window.external.sendMessage, falling back to
//      window.dotnetHost.postMessage, window.__ohosDotNet.postMessage and
//      window.HybridWebView.SendRawMessage,
//   3. logs every inbound message it can observe: calls of
//      window.__dispatchMessageCallback (the original callback is preserved and still
//      runs; the shell's fan-out to __receiveMessageCallbacks keeps working) and
//      HybridWebViewMessageReceived events (the hybrid shim's dispatch).
//
// The hook takes window.__dispatchMessageCallback over with a setter when the property
// is configurable, so the shell's later assignment is wrapped before the first delivery;
// a periodic re-check covers a non-configurable (var-declared) global. A ping with no
// reply is a normal result: the stock Blazor IPC ignores payloads without the "__bwv:"
// prefix, so only an app-provided echo answers. The send itself is the page -> host half.

(function () {
  'use strict';

  var HOOK_CHECK_INTERVAL_MS = 250;
  var PROBE_REFRESH_EVERY_TICKS = 2; // probes every 500 ms
  var SETTLE_TICKS = 60; // 60 * 250 ms = 15 s of shell-injection settling
  var MESSAGE_LIMIT = 50;
  var MESSAGE_MAX_CHARS = 400;

  var pingCount = 0;
  var messagesShown = 0;
  var diagWrapper = null;

  function byId(id) { return document.getElementById(id); }

  function setValue(id, value) {
    var node = byId(id);
    if (node) { node.textContent = value; }
  }

  function setStatus(text) { setValue('status', text); }

  function memberType(value, name) {
    if (value === null || typeof value === 'undefined') { return 'undefined'; }
    if (typeof value !== 'object' && typeof value !== 'function') { return 'undefined'; }
    try { return typeof value[name]; } catch (error) { return 'error'; }
  }

  function refreshProbes() {
    var external = window.external;
    var dotnetHost = window.dotnetHost;
    var hybrid = window.HybridWebView;
    setValue('probe-external', typeof external);
    setValue('probe-external-send', memberType(external, 'sendMessage'));
    setValue('probe-external-receive', memberType(external, 'receiveMessage'));
    setValue('probe-dotnet-host', typeof dotnetHost);
    setValue('probe-dotnet-host-post', memberType(dotnetHost, 'postMessage'));
    setValue('probe-dispatch', typeof window.__dispatchMessageCallback);
    setValue('probe-hybrid', typeof hybrid);
    setValue('probe-hybrid-send', memberType(hybrid, 'SendRawMessage'));
    setValue('probe-blazor', typeof window.Blazor);
    setValue('probe-ohos-dotnet', typeof window.__ohosDotNet);
  }

  function refreshLocation() {
    setValue('location', 'origin: ' + window.location.origin +
      ' | href: ' + window.location.href +
      ' | readyState: ' + document.readyState);
  }

  function formatMessage(message) {
    var text;
    if (typeof message === 'string') {
      text = message;
    } else {
      try { text = JSON.stringify(message); } catch (error) { text = String(message); }
    }
    if (typeof text !== 'string') { text = String(text); }
    return text.length > MESSAGE_MAX_CHARS ? text.substring(0, MESSAGE_MAX_CHARS) + '... [truncated]' : text;
  }

  function appendMessage(channel, message) {
    var container = byId('messages');
    if (!container) { return; }
    if (messagesShown === 0) { container.textContent = ''; }
    while (messagesShown >= MESSAGE_LIMIT && container.firstChild) {
      container.removeChild(container.firstChild);
      messagesShown--;
    }
    var line = document.createElement('div');
    line.className = 'message';
    line.textContent = '[' + new Date().toLocaleTimeString() + '] ' + channel + ': ' + formatMessage(message);
    container.appendChild(line);
    messagesShown++;
    setStatus('inbound via ' + channel + ': ' + formatMessage(message));
  }

  function safeJson(value, fallbackId) {
    try { return JSON.stringify(value); }
    catch (error) { return '{"kind":"ohos-bridge-ping","id":' + fallbackId + '}'; }
  }

  // Wrap the shell's fan-out callback: report the message, then run the original so
  // blazor.webview.js callbacks registered through external.receiveMessage still fire.
  function makeWrapper(original) {
    var wrapped = function () {
      try { appendMessage('__dispatchMessageCallback', arguments.length > 0 ? arguments[0] : undefined); }
      catch (reportError) { /* never break the shell's callback */ }
      if (typeof original === 'function') { return original.apply(this, arguments); }
      return undefined;
    };
    diagWrapper = wrapped;
    return wrapped;
  }

  function interceptDispatch() {
    try {
      var stored = window.__dispatchMessageCallback;
      Object.defineProperty(window, '__dispatchMessageCallback', {
        configurable: true,
        enumerable: true,
        get: function () { return stored; },
        set: function (value) { stored = typeof value === 'function' ? makeWrapper(value) : value; }
      });
      if (typeof stored === 'function') { window.__dispatchMessageCallback = stored; }
      return true;
    } catch (error) {
      return false;
    }
  }

  function ensureDispatchHook() {
    var current = window.__dispatchMessageCallback;
    if (typeof current !== 'function' || current === diagWrapper) { return; }
    try { window.__dispatchMessageCallback = makeWrapper(current); } catch (error) { /* keep polling */ }
  }

  function sendVia(channel, send, payload) {
    try {
      send();
      setStatus('sent #' + pingCount + ' via ' + channel + '\n' + payload +
        '\nwaiting for a reply (the stock Blazor IPC does not answer plain JSON)');
    } catch (error) {
      setStatus('send #' + pingCount + ' FAILED via ' + channel + ': ' + error);
      appendMessage(channel + ' threw', String(error));
    }
  }

  function sendPing() {
    refreshProbes();
    refreshLocation();
    pingCount++;
    var ping = {
      kind: 'ohos-bridge-ping',
      id: pingCount,
      page: 'wwwroot/index.html',
      origin: window.location.origin,
      href: window.location.href,
      at: new Date().toISOString()
    };
    var payload = safeJson(ping, pingCount);

    var external = window.external;
    if (external && typeof external.sendMessage === 'function') {
      sendVia('window.external.sendMessage', function () { external.sendMessage(payload); }, payload);
      return;
    }
    var dotnetHost = window.dotnetHost;
    if (dotnetHost && typeof dotnetHost.postMessage === 'function') {
      sendVia('window.dotnetHost.postMessage', function () { dotnetHost.postMessage(payload); }, payload);
      return;
    }
    var ohosDotNet = window.__ohosDotNet;
    if (ohosDotNet && typeof ohosDotNet.postMessage === 'function') {
      sendVia('window.__ohosDotNet.postMessage', function () { ohosDotNet.postMessage(payload); }, payload);
      return;
    }
    var hybrid = window.HybridWebView;
    if (hybrid && typeof hybrid.SendRawMessage === 'function') {
      sendVia('window.HybridWebView.SendRawMessage', function () { hybrid.SendRawMessage(payload); }, payload);
      return;
    }
    setStatus('no bridge function found; ping #' + pingCount + ' was not sent (see the probe table)');
  }

  function selfTest() {
    var callback = window.__dispatchMessageCallback;
    if (typeof callback !== 'function') {
      setStatus('self test skipped: window.__dispatchMessageCallback is not a function yet ' +
        '(the shell injects it after the load event)');
      return;
    }
    var probe = {
      kind: 'ohos-bridge-loopback',
      source: 'page self test',
      id: pingCount,
      at: new Date().toISOString()
    };
    try {
      callback(safeJson(probe, 0));
      setStatus('self test: called window.__dispatchMessageCallback locally; the log line above ' +
        'is the page loopback, not a host reply');
    } catch (error) {
      setStatus('self test failed: ' + error);
    }
  }

  function init() {
    var pingButton = byId('ping');
    if (pingButton) { pingButton.addEventListener('click', sendPing); }
    var selfTestButton = byId('selftest');
    if (selfTestButton) { selfTestButton.addEventListener('click', selfTest); }

    // Hybrid path: the shell's receiveMessage shim dispatches this event when no
    // dedicated callback registration exists.
    window.addEventListener('HybridWebViewMessageReceived', function (event) {
      var detail = event && event.detail ? event.detail.message : undefined;
      appendMessage('HybridWebViewMessageReceived', detail);
    });

    refreshLocation();
    refreshProbes();
    interceptDispatch();
    ensureDispatchHook();

    var ticks = 0;
    var settleTimer = window.setInterval(function () {
      ticks++;
      ensureDispatchHook();
      if (ticks % PROBE_REFRESH_EVERY_TICKS === 0) { refreshProbes(); }
      if (ticks >= SETTLE_TICKS) {
        window.clearInterval(settleTimer);
        refreshLocation();
        refreshProbes();
      }
    }, HOOK_CHECK_INTERVAL_MS);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
