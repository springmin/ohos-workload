// hello-maui-razor host page script (opt-in Razor path).
//
// Deliberately small: this page exists to give BlazorCounter.razor a host document and the #app
// mount point, not to repeat the demo's full bridge probe table
// (test/hello-maui-app/wwwroot/js/app.js). The ArkTS shell injects
// _framework/blazor.webview.js and calls Blazor.start() after the load event, so this file must
// not load the framework itself. It only reports the bridge state so a device run shows whether
// the shell injection happened.

(function () {
  'use strict';

  // FIX-JSCALL self-check endpoint: BlazorCounter.razor invokes blzProbe with a
  // DotNetObjectReference argument to reproduce the WebRenderer's attach interop
  // serialization. The probe was left undefined in kit #40, so the call crossed the wire
  // and then threw a JSException ("blzProbe is not defined"), which made the sample's own
  // probe line useless. Defining it here makes the whole round trip land: .NET serializes
  // the reference ({"__dotNetObject": id} on the wire), the interop reviver materializes the
  // DotNetObject instance for the function, and the returned string travels back to the
  // component (probe: dotnet-ref ok).
  window.blzProbe = function (reference) {
    if (!reference) { return 'dotnet-ref missing'; }
    // The interop reviver replaces the wire form {"__dotNetObject": id} with the DotNetObject
    // instance before the JS function runs, so the instance API is the reliable check; the raw
    // property is kept as a fallback for a different runtime version.
    if (typeof reference.invokeMethodAsync === 'function' || typeof reference.invokeMethod === 'function') {
      return 'dotnet-ref ok';
    }
    if (reference.__dotNetObject) { return 'dotnet-ref ok'; }
    var keys = Object.keys(reference).join(',');
    return keys ? 'dotnet-ref unknown:' + keys : 'dotnet-ref missing';
  };

  var status = document.getElementById('status');
  if (!status) { return; }

  function describe() {
    var external = window.external;
    return 'shell bridge: window.external=' + (typeof external) +
      ', sendMessage=' + (external ? typeof external.sendMessage : 'undefined') +
      ', receiveMessage=' + (external ? typeof external.receiveMessage : 'undefined') +
      ', Blazor=' + (typeof window.Blazor);
  }

  status.textContent = 'host page loaded; ' + describe();

  // The shell injects after the page load event; re-check once the injection window passed.
  setTimeout(function () {
    status.textContent = 'host page loaded; ' + describe();
  }, 3000);
})();
