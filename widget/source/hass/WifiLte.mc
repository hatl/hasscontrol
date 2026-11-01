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
// A Connect IQ app reaches the network through the phone. Wi-Fi and LTE are
// only switched on by the system "sync" (the one that uploads activities),
// and only for as long as it runs. So when the phone is not connected, an
// action is stored, a sync is requested, and HassSyncDelegate sends it to
// Home Assistant from inside that sync.
//
// Limits, the same as GarminHomeAssistant's:
//  * Actions only. Entity states are not refreshed over Wi-Fi/LTE - the
//    stored ones are shown and acted on.
//  * Slow: the watch first has to join the access point (or LTE network).
//  * https only, and the watch then does TLS itself: some models offer no
//    cipher suite with forward secrecy, which many servers refuse.
//    A loopback http:// host (a proxy on the phone) cannot be reached.
//
// :fullmem only, see monkey.jungle.
(:fullmem)
module WifiLte {
  const STORAGE_KEY = "Hass/wifiLteCommand";

  // A stored command older than this is dropped instead of sent. The sync
  // starts right after the user confirms, so anything older belongs to one
  // that never ran - and must not, say, unlock a door hours later on some
  // automatic sync (e.g. while charging).
  const COMMAND_MAX_AGE = 120; // seconds

  // Exiting right after notifySyncComplete() makes the system report the
  // sync as failed; GarminHomeAssistant settled on this delay.
  const EXIT_DELAY = 5000; // ms

  var _syncActive = false;

  function isEnabled() {
    return App.Properties.getValue("wifiLteExecution") == true;
  }

  // True when an action has to go out over Wi-Fi/LTE: the phone is not
  // connected, the user allowed it, and the watch has a radio for it.
  function shouldUse() {
    if (!isEnabled() || System.getDeviceSettings().phoneConnected) {
      return false;
    }

    if (!(Communications has :startSync2) && !(Communications has :startSync)) {
      return false;
    }

    if (Hass.client == null || !Hass.client.isLoggedIn() || !Hass.client.isHttpsUrl()) {
      return false;
    }

    return hasRadio();
  }

  // Whether Wi-Fi or LTE is set up on the watch. Whether an access point is
  // in range cannot be checked from here - only the sync finds out.
  function hasRadio() {
    var settings = System.getDeviceSettings();

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

  // Asks before switching the radio on: it is slow, costs battery, and the
  // system sync screen takes over the watch meanwhile.
  //
  // `command` is what HassSyncDelegate.onStartSync() sends: "id" and
  // "domain", plus either "action" (a Client.ENTITY_ACTION_*, sent through
  // Client.setEntityState()) or "service" and "params" (sent through
  // Client.callService()). `text` says what is about to happen, e.g.
  // "Unlocking\nFront Door"; it is also shown on the sync screen.
  function offer(command, text) {
    command["msg"] = text;

    Ui.pushView(
      new Ui.Confirmation(text + "\nvia Wi-Fi/LTE?"),
      new WifiLteConfirmDelegate(command),
      Ui.SLIDE_IMMEDIATE
    );
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

  function start(command) {
    command["at"] = Time.now().value();

    // Stored, not just kept in memory: startSync2() restarts the app in
    // sync mode, where only Application.Storage carries over.
    App.Storage.setValue(STORAGE_KEY, command);

    // The inactivity auto-close must not end the app halfway through.
    Scheduler.cancel(:inactivity);

    if (Communications has :startSync2) {
      Communications.startSync2({ :message => command["msg"] });
    } else {
      Communications.startSync();
    }
  }

  // The command waiting for a sync, or null. Expired ones are dropped.
  function getPendingCommand() {
    var command = App.Storage.getValue(STORAGE_KEY);

    if (command == null) {
      return null;
    }

    var at = command["at"];
    var age = at != null ? Time.now().value() - at : null;

    if (age == null || age < 0 || age > COMMAND_MAX_AGE) {
      clearPendingCommand();
      return null;
    }

    return command;
  }

  function hasStoredCommand() {
    return App.Storage.getValue(STORAGE_KEY) != null;
  }

  function clearPendingCommand() {
    App.Storage.deleteValue(STORAGE_KEY);
  }

  // startSync2() restarts the app in sync mode: onStartSync() may then run
  // in a process where getInitialView() never did. Builds what the request
  // path relies on.
  function prepare() {
    var app = App.getApp();

    if (app.viewController == null) {
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
  // there is one - e.g. 0 for a TLS handshake the server refused.
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

  function onSyncFinished(success) {
    if (success && App.Properties.getValue("closeAfterAction")) {
      Scheduler.schedule(:exit, new Lang.Method(Hass, :exitApplication), EXIT_DELAY);
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
      WifiLte.start(_mCommand);
    }

    return true;
  }
}

// Sends the command WifiLte.start() stored, from inside the sync.
(:fullmem)
class HassSyncDelegate extends Communications.SyncDelegate {
  hidden var _mDone;

  function initialize() {
    SyncDelegate.initialize();
    _mDone = false;
  }

  // Asked before every sync, the automatic ones included: only a pending
  // command needs one.
  function isSyncNeeded() {
    return WifiLte.getPendingCommand() != null;
  }

  function onStartSync() {
    var expired = WifiLte.hasStoredCommand();
    var command = WifiLte.getPendingCommand();

    // Off the store before anything can fail, so that no later sync can
    // ever send it a second time.
    WifiLte.clearPendingCommand();

    if (command == null) {
      // A stored but expired command means the sync took too long to start.
      finish(expired ? "Request expired" : null, false);
      return;
    }

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
  }

  function onResponse(error, data) {
    if (_mDone) {
      return;
    }

    if (error != null) {
      finish(WifiLte.describeError(error), false);
      return;
    }

    WifiLte.applyResult(data);
    finish(null, true);
  }

  // The user cancelled the sync, or the system ended it.
  function onStopSync() {
    if (_mDone) {
      return;
    }

    // Do not let a cancelled unlock still go through.
    Communications.cancelAllRequests();

    if (Hass.client != null) {
      Hass.client.onRequestsCancelled();
    }

    finish(null, false);
  }

  // `error` is shown by the system sync screen (null: no error); `success`
  // tells whether the action was carried out.
  hidden function finish(error, success) {
    _mDone = true;
    WifiLte.setSyncActive(false);

    Communications.notifySyncProgress(100);
    Communications.notifySyncComplete(error);

    WifiLte.onSyncFinished(success);
  }
}
