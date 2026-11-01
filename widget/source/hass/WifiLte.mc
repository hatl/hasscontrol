using Toybox.Application as App;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.System;
using Toybox.Time;
using Toybox.WatchUi as Ui;
using Hass;
using Utils;

// Wi-Fi/LTE execution, after GarminHomeAssistant's
// (https://github.com/house-of-abbey/GarminHomeAssistant/blob/main/Wi-Fi.md).
//
// A Connect IQ app reaches the network through the phone. On watches, Wi-Fi
// and LTE are only switched on by the system "sync" (the one that uploads
// activities), and only for as long as it runs. So when the phone is not
// connected, an action is stored, a sync is requested, and HassSyncDelegate
// sends it to Home Assistant from inside that sync.
//
// Edge head units differ: their Wi-Fi is up outside a sync too, whenever no
// activity is recording. Requests then simply go out over it, as through
// the phone, and none of this is needed - see hasDirectConnection() and the
// :directwifi build annotation in monkey.jungle that selects those units.
//
// startSync2()/startSync() are documented to exit the app and relaunch it
// in sync mode. In practice the app can stay alive under the system sync
// screen instead (GarminHomeAssistant keeps its command in a static and
// relies on that, on a Venu 2). Both have to work: the command is kept in
// Application.Storage, prepare() builds what a fresh sync-mode process
// lacks, and an app that stayed alive keeps its own timed work still while
// the sync is pending (isSyncPending()).
//
// A stored command must never be left for some later sync to send unasked
// - a manual one from the controls menu, an automatic one while charging.
// It is cleared when the sync is cancelled (HassSyncDelegate.onStopSync()),
// once it is older than COMMAND_MAX_AGE (getPendingCommand(), and the
// watchdog expire()), and at the next normal launch (dropStaleCommand()).
//
// Limits, the same as GarminHomeAssistant's:
//  * Actions only. Entity states are not refreshed over Wi-Fi/LTE - the
//    stored ones are shown and acted on.
//  * Slow: the watch first has to join the access point (or LTE network).
//  * https only, and the watch then does TLS itself: some models offer no
//    cipher suite with forward secrecy, which many servers refuse.
//    A loopback http:// host (a proxy on the phone) cannot be reached.
//  * Whether an access point is in range only turns out in the sync.
//    Communications.checkWifiConnection() (CIQ 3.2.0) could find out
//    beforehand, but is not used: it is a round trip of its own, so the
//    question would only come up after yet more waiting.
//
// :fullmem only, see monkey.jungle.
(:fullmem)
module WifiLte {
  const STORAGE_KEY = "Hass/wifiLteCommand";

  // A stored command older than this is dropped instead of sent. The sync
  // starts right after the user confirms, and joining Wi-Fi takes 5-8 s, so
  // anything older belongs to one that never ran - and must not, say,
  // unlock a door later on some automatic sync (e.g. while charging).
  const COMMAND_MAX_AGE = 60; // seconds

  // How young a command has to be to survive the sweep at launch, see
  // dropStaleCommand().
  const LAUNCH_GRACE = 15; // seconds

  // Exiting right after notifySyncComplete() makes the system report the
  // sync as failed; GarminHomeAssistant settled on this delay.
  const EXIT_DELAY = 5000; // ms

  // How often launchSync() waits another MIN_DELAY for the Confirmation to
  // be gone before starting the sync anyway.
  const LAUNCH_TRIES = 10;

  // The "... via Wi-Fi/LTE?" question on screen, see launchSync().
  var _confirmation = null;
  var _launchTries = 0;

  var _syncActive = false;
  var _syncPending = false;

  // True when the sync runs in a process started in sync mode just for it,
  // see prepare() and onSyncFinished().
  var _headless = false;

  function isEnabled() {
    return Utils.getProperty("wifiLteExecution", false) == true;
  }

  // True when a request can go out right away, without a sync: the phone is
  // connected - or, on the units built with :directwifi (monkey.jungle),
  // Wi-Fi is. Those are the Edge head units, which keep Wi-Fi up whenever
  // no activity is recording: their device models list `wifiExclusions:
  // ['fitRecording']`, Garmin staff say so on the forum, and
  // makeWebRequest() "can be used when connected to WiFi". Verified only
  // that far - not on an Edge.
  //
  // On watches Wi-Fi reads as connected during a system sync, and for a
  // moment after one. Counting that would end the launch wait and start the
  // refresh over a link that is about to drop - and the first failure would
  // then close the app ("Phone not connected"). So there only the phone
  // counts.
  function hasDirectConnection() {
    return hasDirectConnectionIn(System.getDeviceSettings());
  }

  // hasDirectConnection() for a System.DeviceSettings already at hand:
  // every getDeviceSettings() call builds a new one.
  (:directwifi)
  function hasDirectConnectionIn(settings) {
    if (settings.phoneConnected) {
      return true;
    }

    if (!(settings has :connectionInfo) || settings.connectionInfo == null) {
      return false;
    }

    var wifi = settings.connectionInfo[:wifi];

    return wifi != null && wifi.state == System.CONNECTION_STATE_CONNECTED;
  }

  (:nodirectwifi)
  function hasDirectConnectionIn(settings) {
    return settings.phoneConnected;
  }

  // Whether this unit's Wi-Fi is usable outside a sync at all (see
  // hasDirectConnection()). Where it is, a sync never helps: the Edge
  // switches Wi-Fi off exactly while an activity records, so a sync could
  // not use it either - and none of these units has LTE.
  (:directwifi)
  function hasStandingWifi() {
    return true;
  }

  (:nodirectwifi)
  function hasStandingWifi() {
    return false;
  }

  // True when an action has to go out over Wi-Fi/LTE: there is no direct
  // connection (then that is used instead), the user allowed it, and the
  // watch has a radio for it.
  function shouldUse() {
    var settings = System.getDeviceSettings();

    if (!isEnabled() || hasDirectConnectionIn(settings)) {
      return false;
    }

    if (hasStandingWifi()) {
      // An Edge: either its Wi-Fi is up and used directly, or it is off for
      // the activity - and a sync could not switch it on.
      return false;
    }

    if (!(Communications has :startSync2) && !(Communications has :startSync)) {
      return false;
    }

    if (Hass.client == null || !Hass.client.isLoggedIn() || !Hass.client.isHttpsUrl()) {
      return false;
    }

    return hasRadio(settings);
  }

  // Whether Wi-Fi or LTE is set up on the watch - not whether it will work.
  // An access point in range only turns out in the sync (see the top of
  // this file). And some firmware reports a Wi-Fi that is switched off as
  // NOT_CONNECTED rather than NOT_INITIALIZED, so the question can come up
  // with Wi-Fi off - the sync then fails.
  function hasRadio(settings) {
    if (!(settings has :connectionInfo) || settings.connectionInfo == null) {
      return false;
    }

    var info = settings.connectionInfo;
    var keys = info.keys();

    for (var i = 0; i < keys.size(); i++) {
      if (keys[i] != :bluetooth && info[keys[i]].state != System.CONNECTION_STATE_NOT_INITIALIZED) {
        return true;
      }
    }

    return false;
  }

  function isSyncActive() {
    return _syncActive;
  }

  function setSyncActive(active) {
    _syncActive = active;
  }

  // True from start() until the sync has finished (onSyncFinished()) or the
  // watchdog has given up on it (expire()). If the app stays alive under the
  // system sync screen (see the top of this file), its own timed work has
  // to keep still meanwhile: no loader, no startup requests (see
  // ConnectionWait.onTick()) - view pushes during a sync are reported on
  // Garmin's forum to fail on the device.
  function isSyncPending() {
    return _syncPending;
  }

  // Asks before switching the radio on: it is slow, costs battery, and the
  // system sync screen takes over the watch meanwhile.
  //
  // `command` is what HassSyncDelegate.onStartSync() sends: "id" and
  // "domain", plus either "action" (a Client.ENTITY_ACTION_*, sent through
  // Client.setEntityState()) or "service" and "params" (sent through
  // Client.callService()). Optionally "exit" => true: "Close App after
  // successful action" applies (see onSyncFinished()). `text` says what is
  // about to happen, e.g. "Unlocking\nFront Door"; it is also shown on the
  // sync screen.
  function offer(command, text) {
    command["msg"] = text;

    _confirmation = new Ui.Confirmation(text + "\nvia Wi-Fi/LTE?");

    Ui.pushView(_confirmation, new WifiLteConfirmDelegate(command), Ui.SLIDE_IMMEDIATE);
  }

  // offer() for the select/input_number style service calls.
  function offerService(entity, service, params, text) {
    offer({
      "id" => entity.getId(),
      "domain" => entity.getServiceDomain(),
      "service" => service,
      "params" => params
    }, text);
  }

  // The user confirmed `command`: stores it now, and starts the sync a
  // moment later (see WifiLteConfirmDelegate.onResponse()).
  function start(command) {
    command["at"] = Time.now().value();

    // Stored, not just kept in memory: startSync2() may restart the app in
    // sync mode, where only Application.Storage carries over.
    App.Storage.setValue(STORAGE_KEY, command);
    _syncPending = true;

    // Neither the inactivity auto-close nor any other timed exit may end
    // the app halfway through.
    Scheduler.cancel(:inactivity);
    Scheduler.cancel(:exitPhoneLost);
    Scheduler.cancel(:exitAfterAction);

    // Should the sync never get to this app, nothing else would end the
    // wait - see expire().
    Scheduler.schedule(:wifiLteExpire, new Lang.Method(WifiLte, :expire), COMMAND_MAX_AGE * 1000);

    _launchTries = 0;
    Scheduler.schedule(:wifiLteStart, new Lang.Method(WifiLte, :launchSync), Scheduler.MIN_DELAY);
  }

  // The second half of start(), off the Scheduler.
  function launchSync() {
    var command = getPendingCommand();

    if (command == null) {
      return;
    }

    // The system pops the Confirmation only after onResponse() returned, and
    // the sync screen is to come up over the app's own view, not over the
    // question. Where the current view can be read (CIQ 3.4.0+), wait until
    // the Confirmation is gone - as LockConfirmDelegate does - but not for
    // ever: on firmware that keeps it up longer, go ahead anyway.
    if (_confirmation != null && (Ui has :getCurrentView) && _launchTries < LAUNCH_TRIES) {
      var current = Ui.getCurrentView();

      if (current != null && current[0] == _confirmation) {
        _launchTries++;
        Scheduler.schedule(:wifiLteStart, new Lang.Method(WifiLte, :launchSync), Scheduler.MIN_DELAY);
        return;
      }
    }

    _confirmation = null;

    if (Communications has :startSync2) {
      Communications.startSync2({ :message => command["msg"] });
    } else {
      // Below CIQ 4.0.4: the sync screen shows the system's own text.
      Communications.startSync();
    }
  }

  // The watchdog start() schedules. By now the sync should long be over, so
  // if it has not started at all - the system did not start it, or it was
  // cancelled before it got to this app - the command is dropped, so that no
  // later sync can send it, and the app may close on inactivity again. A
  // request still out is left alone: its response, or onStopSync(), ends
  // the sync.
  function expire() {
    if (isSyncActive()) {
      return;
    }

    clearPendingCommand();
    _syncPending = false;
    App.getApp().resetInactivityTimer();
  }

  // The command waiting for a sync, or null. Expired ones are dropped.
  function getPendingCommand() {
    var command = App.Storage.getValue(STORAGE_KEY);

    if (command == null) {
      return null;
    }

    var age = _ageOf(command);

    if (age == null || age > COMMAND_MAX_AGE) {
      clearPendingCommand();
      return null;
    }

    return command;
  }

  // The sweep at launch (HassControlApp.startStartupWork()). A normal launch
  // that finds a command stored means the sync it was meant for never ran -
  // the system did not start it, or the app was closed first - so it is
  // dropped. Only one younger than LAUNCH_GRACE is kept: the SDK does not
  // say whether a sync-mode relaunch (which startSync2() may do) calls
  // getInitialView(). If it does, that comes right after start(), and the
  // sync still has to find the command. Returns true when one was kept.
  function dropStaleCommand() {
    var command = App.Storage.getValue(STORAGE_KEY);

    if (command == null) {
      return false;
    }

    var age = _ageOf(command);

    if (age != null && age < LAUNCH_GRACE) {
      return true;
    }

    clearPendingCommand();
    return false;
  }

  // Seconds since `command` was stored, or null when that cannot be told:
  // no time stamp, or the clock has gone back since.
  function _ageOf(command) {
    var at = command["at"];
    var age = at != null ? Time.now().value() - at : null;

    return age != null && age >= 0 ? age : null;
  }

  function hasStoredCommand() {
    return App.Storage.getValue(STORAGE_KEY) != null;
  }

  function clearPendingCommand() {
    App.Storage.deleteValue(STORAGE_KEY);
  }

  // onStartSync() may run in a process where getInitialView() never did:
  // startSync2() may restart the app in sync mode. Builds what the request
  // path relies on - and notes whether that was the case (_headless).
  function prepare() {
    var app = App.getApp();

    noteHeadless();

    if (_headless) {
      // OAuthClient reports every token response to it (showLoginView()).
      app.viewController = new ViewController();
    }

    if (Hass.client == null) {
      Hass.initClient();
    }

    if (Hass.getEntities().size() == 0) {
      Hass.loadStoredEntities();
    }
  }

  // Shows the state the action produced, the same way
  // Hass.onToggleEntityStateCompleted(), onSelectOptionCompleted() and
  // onSetInputNumberValueCompleted() do for a request sent via the phone.
  // States that only a refresh can tell (e.g. a toggled cover) are left as
  // they are: there is no refresh over Wi-Fi/LTE.
  function applyResult(data) {
    if (data == null || data[:context] == null || data[:context][:entityId] == null) {
      return;
    }

    var context = data[:context];
    var entity = Hass.getEntity(context[:entityId]);

    if (entity == null) {
      return;
    }

    var params = context[:extraParams];

    if (context[:state] != null) {
      var state = context[:state];

      if (entity.getType() == Hass.TYPE_SCRIPT || entity.getType() == Hass.TYPE_BUTTON) {
        state = Hass.STATE_OFF;
      }

      entity.setState(state);
    } else if (params != null && params["option"] != null) {
      entity.setState(params["option"]);
    } else if (params != null && params["value"] != null) {
      entity.setState(Utils.formatNumberForStep(params["value"], entity.getStep()));
    } else {
      return;
    }

    Hass.storeEntities();
  }

  // For notifySyncComplete(): the reason, with the response code where
  // there is one - e.g. 0, usually a TLS handshake the server refused.
  function describeError(error) {
    if (error instanceof Error) {
      var text = error.toShortString();

      if (error.responseCode != null) {
        text += " (" + error.responseCode + ")";
      }

      return text;
    }

    return error.toString();
  }

  // Whether this process was started in sync mode just for the sync (then
  // getInitialView() never ran and there is no UI). Noted at every entry
  // from the system, not only in prepare(): the paths that end a sync
  // before prepare() runs ("Nothing to send", a cancel) read it too.
  function noteHeadless() {
    _headless = App.getApp().viewController == null;
  }

  // Called when a sync starts. Should a sync-mode relaunch have run
  // getInitialView() after all (undocumented), that armed the inactivity
  // auto-close in this very process; in an app that stayed alive a timed
  // exit may still be pending. Neither may end the app halfway through.
  function quiesce() {
    Scheduler.cancel(:inactivity);
    Scheduler.cancel(:exitPhoneLost);
    Scheduler.cancel(:exitAfterAction);
    Scheduler.cancel(:exitAfterSync);
  }

  // After notifySyncComplete(). `success`: the action was carried out.
  // `exitAfter`: the command was a toggle, which "Close App after successful
  // action" applies to - as via the phone, where it does not apply to select
  // options or number values either (see Hass._offerWifiLte()).
  function onSyncFinished(success, exitAfter) {
    _syncPending = false;
    Scheduler.cancel(:wifiLteExpire);

    if (_headless) {
      // A process started in sync mode just for this sync ends on its own:
      // there is no view to update, and no app to close.
      return;
    }

    if (success && exitAfter && Utils.getProperty("closeAfterAction", false)) {
      Scheduler.schedule(:exitAfterSync, new Lang.Method(Hass, :exitApplication), EXIT_DELAY);
    } else {
      App.getApp().resetInactivityTimer();
    }

    Ui.requestUpdate();
  }
}

(:fullmem)
class WifiLteConfirmDelegate extends Ui.ConfirmationDelegate {
  hidden var _mCommand;

  function initialize(command) {
    ConfirmationDelegate.initialize();
    _mCommand = command;
  }

  function onResponse(response) {
    App.getApp().resetInactivityTimer();

    if (response == Ui.CONFIRM_YES) {
      // The command is stored right away, but start() leaves startSync2()
      // to the Scheduler, which waits until this Confirmation is off the
      // screen (see WifiLte.launchSync()), as LockConfirmDelegate does with
      // its toggle. GarminHomeAssistant calls startSync2() right from here,
      // which works on a Venu 2; how a widget fares on CIQ 3.x is untested.
      WifiLte.start(_mCommand);
    }

    return true;
  }
}

// Sends the command WifiLte.start() stored, from inside the sync.
(:fullmem)
class HassSyncDelegate extends Communications.SyncDelegate {
  hidden var _mDone;
  hidden var _mExit;

  function initialize() {
    SyncDelegate.initialize();
    _mDone = false;
    _mExit = false;
  }

  // Asked before a sync - presumably before the automatic ones too, which
  // the SDK does not say: only a pending command needs one.
  function isSyncNeeded() {
    return WifiLte.getPendingCommand() != null;
  }

  function onStartSync() {
    WifiLte.noteHeadless();
    WifiLte.quiesce();

    if (_mDone) {
      // This delegate's sync is over already (onStopSync() came first), so
      // nothing may go out any more. getSyncDelegate() hands out a new
      // delegate whenever it is asked; should the system reuse one for a
      // further sync, that sync sends nothing - the safe way to fail - and
      // is ended right away so that its screen does not wait.
      WifiLte.clearPendingCommand();
      Communications.notifySyncComplete(null);
      return;
    }

    // Whatever fails in here, the system has to hear that the sync is over:
    // its screen waits for notifySyncComplete().
    try {
      var expired = WifiLte.hasStoredCommand();
      var command = WifiLte.getPendingCommand();

      // Off the store before anything can fail, so that no later sync can
      // ever send it a second time.
      WifiLte.clearPendingCommand();

      if (command == null) {
        // A stored but expired command means the sync took too long to
        // start.
        finish(expired ? "Request expired" : "Nothing to send", false);
        return;
      }

      _mExit = command["exit"] == true;

      WifiLte.prepare();

      if (!Hass.client.isLoggedIn()) {
        finish("Not logged in", false);
        return;
      }

      WifiLte.setSyncActive(true);
      Communications.notifySyncProgress(10);

      var callback = method(:onResponse);

      if (command["service"] != null) {
        Hass.client.callService(command["domain"], command["service"], command["id"], command["params"], callback);
      } else {
        Hass.client.setEntityState(command["id"], command["domain"], command["action"], callback);
      }
    } catch (e) {
      // Unless it was finish() itself that failed.
      if (!_mDone) {
        var message = e.getErrorMessage();
        finish(message != null ? message : "Sync failed", false);
      }
    }
  }

  function onResponse(error, data) {
    if (_mDone) {
      return;
    }

    if (error != null) {
      var code = data != null ? data[:responseCode] : null;

      // The request went out and Home Assistant answered - only the answer
      // could not be read: too large, or not what was expected. Home
      // Assistant replies to an action with every state it changed, which
      // can be more than the watch can take. So the action has most likely
      // been carried out; what it changed is unknown.
      if (
        code == Communications.NETWORK_RESPONSE_OUT_OF_MEMORY
        || code == Communications.NETWORK_RESPONSE_TOO_LARGE
        || code == Communications.INVALID_HTTP_BODY_IN_NETWORK_RESPONSE
      ) {
        finish("Sent, reply\nunreadable", true);
        return;
      }

      finish(WifiLte.describeError(error), false);
      return;
    }

    WifiLte.applyResult(data);
    finish(null, true);
  }

  // The user cancelled the sync, or the system ended it.
  function onStopSync() {
    // Whatever else happens: the command must not be left for the next sync
    // to send unasked.
    WifiLte.clearPendingCommand();
    WifiLte.noteHeadless();

    if (_mDone) {
      return;
    }

    // Do not let a cancelled unlock still go through.
    Communications.cancelAllRequests();

    if (Hass.client != null) {
      Hass.client.onRequestsCancelled();
    }

    finish("Cancelled", false);
  }

  // `error` is shown by the system sync screen (null: no error); `success`
  // tells whether the action was carried out.
  hidden function finish(error, success) {
    _mDone = true;
    WifiLte.setSyncActive(false);

    Communications.notifySyncProgress(100);
    Communications.notifySyncComplete(error);

    // Caught: the app's own follow-up must not take the sync down with it.
    try {
      WifiLte.onSyncFinished(success, _mExit);
    } catch (e) {
      Utils.debugLog("onSyncFinished: ", e.getErrorMessage(), null);
    }
  }
}
