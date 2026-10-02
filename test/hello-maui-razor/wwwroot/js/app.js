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
  // the reference, JS sees the marshalled {"__dotNetObject": id} shape, and the returned
  // string travels back to the component (probe: dotnet-ref ok).
  window.blzProbe = function (reference) {
    var id = reference && reference.__dotNetObject;
    return id ? 'dotnet-ref ok' : 'dotnet-ref missing';
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
