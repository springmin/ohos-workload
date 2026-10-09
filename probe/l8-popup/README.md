# L8 probe: ArkWeb `onWindowNew` -> cross-window `setWebController` (2026-10-09)

Scratch probe on branch `feat/l8-popup-probe` (not for merge). The four preview packs'
`templates/ets` sources are replaced by a pure-ArkTS probe app (the host hap's managed payload
is never started, the EntryAbility is minimal), so one install exercises the real two-window
ArkWeb hand-off on the device:

- `pages/Index.ets`: opener Web (`multiWindowAccess(true)` + `allowWindowOpenMethod(true)`),
  `onWindowNew` handler. Scenario by targetUrl: `?mode=s1` sync bind + URL target (engine
  delivers the popup document), `s2` `about:blank` written by the opener through the window
  proxy (official sample), `s3` the popup page loads the URL itself through the bound
  controller, `null` honest reject, `none` no `setWebController` call (blocking control, last).
- `pages/SubWindow.ets`: popup page (`@Entry({ routeName: 'l8probe-popup' })`). Reads the
  main-created `WebviewController` from the `L8Bridge` module static (same UI instance/ArkTS VM)
  and builds its Web with that object; `onWindowExit` asks the main page to destroy the child.
- `entryability/EntryAbility.ui.ets`: minimal pure-ArkTS ability.

Findings (HAD-W32 / OH 7.0.0.109 / API 26, scratch rounds 1-6, 2026-10-09):

- WORKING FORM: create the controller and call `handler.setWebController(controller)`
  SYNCHRONOUSLY inside `onWindowNew` (before any await), hand the same object to the popup page
  through a shared page module, then create the subwindow asynchronously. `window.open` returns
  a WindowProxy (`closed=false`); popup content renders in the second window; opener->popup
  PING and popup->opener PONG both arrive; `window.name` is the requested name; page
  `window.close()` -> `onWindowExit` -> `destroyWindow`; the main window keeps its heartbeat
  (0 fault).
- NOT WORKING: (a) the window `LocalStorage` (loadContentByName) does not reach the named-route
  popup page - mode/url read back empty, popup blank, renderer stayed blocked (round 1);
  (b) binding after the popup controller attached (popup-created controller published through
  the bridge) makes `window.open` return null and delivers no content (round 2).
- NAME REUSE: `window.open(url, sameName)` while the bound popup is open re-used the child and
  navigated it (no new window, same window id); `onActivateContent` was not observed (the child
  was frontmost) - do not depend on it for "bring to front".
- CONTROLS: no `setWebController` call -> the renderer blocks (`window.open` never returns,
  heartbeat stops); `setWebController(null)` -> `window.open` returns null and the opener keeps
  running.

Raw evidence (scratch, not in the repo): `/data/storage/el2/base/tmp/opencode/l8-probe/`
(round scripts 1-6, `device*/` captures, `repack-N/` haps, `logs/` builds/signing).
