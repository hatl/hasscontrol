using Toybox.Application as App;
using Toybox.Communications as Comm;
using Toybox.WatchUi as Ui;
using Toybox.System;
using Hass;
using Utils;


class HassControlApp extends App.AppBase {
  static const SCENES_VIEW = "scenes";
  static const ENTITIES_VIEW = "entities";
  static const ENTITIES_SCENES_VIEW = "entities_scenes";
  static const STORAGE_KEY_START_VIEW = "start_view";

  var viewController;
  var menu;

  // The wait for a connection at launch, see startStartupWork(). :fullmem
  // only.
  (:fullmem)
  hidden var _connectionWait = null;

  function initialize() {
    AppBase.initialize();
  }

  /*
   * TODO:
   * - Move all strings to xml
   * - Create a custom menu that can rerender
   * - Take control over the view handeling to get rid of blinking views
   *
  */

  function launchInitialView() {
    var initialView = getStartView();

    if (initialView.equals(HassControlApp.ENTITIES_VIEW)) {
      return viewController.pushEntityView();
    }
    if (initialView.equals(HassControlApp.SCENES_VIEW)) {
      return viewController.pushSceneView();
    }
    if (initialView.equals(HassControlApp.ENTITIES_SCENES_VIEW)) {
      return viewController.pushEntityScenesView();
    }

    return viewController.pushSceneView();
  }

  function onSettingsChanged() {
    Hass.loadScenesFromSettings();
    Hass.client.onSettingsChanged();
    onLockSettingsChanged();

    // Restart inactivity timer with new setting value
    resetInactivityTimer();

    Ui.requestUpdate();
  }

  // A different lock PIN ends a PIN lockout (LockConfirm.onSettingsChanged()).
  // :fullmem only, like the lock confirmation itself.
  (:fullmem)
  hidden function onLockSettingsChanged() {
    LockConfirm.onSettingsChanged();
  }

  (:lowmem)
  hidden function onLockSettingsChanged() {
  }

  function logout() {
    Hass.client.logout();
  }

  function onLoggedIn(error, data) {
    if (error != null) {
      viewController.showError(error);
    }
  }

  function login() {
    var callback = method(:onLoggedIn);

    // TODO: should move validation into client
    if (Hass.client.validateSettings(callback) != null) {
        return;
    }

    Hass.client.login(callback);
  }

  function getStartView() {
    var startView = App.Storage.getValue(HassControlApp.STORAGE_KEY_START_VIEW);

    if (startView != null && startView.equals(HassControlApp.SCENES_VIEW)) {
      return HassControlApp.SCENES_VIEW;
    } else if (startView != null && startView.equals(HassControlApp.ENTITIES_VIEW)) {
      return HassControlApp.ENTITIES_VIEW;
    } else if (startView != null &&
               startView.equals(HassControlApp.ENTITIES_SCENES_VIEW)) {
      return HassControlApp.ENTITIES_SCENES_VIEW;
    }

    return HassControlApp.ENTITIES_VIEW;
  }

  function setStartView(newStartView) {
    if (newStartView.equals(HassControlApp.ENTITIES_VIEW)) {
      App.Storage.setValue(
        HassControlApp.STORAGE_KEY_START_VIEW,
        HassControlApp.ENTITIES_VIEW
      );
    } else if (newStartView.equals(HassControlApp.SCENES_VIEW)) {
      App.Storage.setValue(
        HassControlApp.STORAGE_KEY_START_VIEW,
        HassControlApp.SCENES_VIEW
      );
    } else if (newStartView.equals(HassControlApp.ENTITIES_SCENES_VIEW)) {
      App.Storage.setValue(
        HassControlApp.STORAGE_KEY_START_VIEW,
        HassControlApp.ENTITIES_SCENES_VIEW
      );
    } else {
      throw new Toybox.Lang.InvalidValueException("Invalid start view value");
    }
  }

  function isLoggedIn() {
    return Hass.client.isLoggedIn();
  }

  function onStart(state) {}

  function onStop(state) {}

  function getGlanceView() {
    return [
      new AppGlance()
    ];
  }

  // The system calls this when the display changes between its Day and
  // Night mode (Edge units): the glance has to follow with its text colour
  // (see AppGlance.onUpdate()). The widget's own views are dark in both.
  // No 64 KB device has such a mode.
  (:fullmem)
  function onNightModeChanged() {
    Ui.requestUpdate();
  }

  // Return the initial view of your application here
  function getInitialView() {
    Utils.logMem("init:0 enter", null);
    viewController = new ViewController();
    Utils.logMem("init:1 viewController", null);
    menu = new MenuController();
    Utils.logMem("init:2 menu", null);

    Hass.initClient();
    Utils.logMem("init:3 client", null);

    // Before the entities are loaded: see Utils.measureIconCost().
    Utils.measureIconCost();
    Hass.loadStoredEntities();
    Utils.logMem("init:4 stored n", Hass._entities);
    Hass.loadScenesFromSettings();
    Utils.logMem("init:5 scenes n", Hass._entities);

    var deviceSettings = System.getDeviceSettings();
    var view = null;
    var delegate = null;

    if (deviceSettings has :isGlanceModeEnabled) {
      if (deviceSettings.isGlanceModeEnabled) {
        var initialView = getStartView();

        if (initialView.equals(HassControlApp.ENTITIES_VIEW)) {
          var entityView = viewController.getEntityView();
          view = entityView[0];
          delegate = entityView[1];
        }
        if (initialView.equals(HassControlApp.SCENES_VIEW)) {
          var sceneView = viewController.getSceneView();
          view = sceneView[0];
          delegate = sceneView[1];
        }
        if (initialView.equals(HassControlApp.ENTITIES_SCENES_VIEW)) {
          var sceneView = viewController.getEntitySceneView();
          view = sceneView[0];
          delegate = sceneView[1];
        }
      }
    }

    if (view == null || delegate == null) {
      view = new BaseView();
      delegate = new BaseDelegate();
    }

    // Only now that the view is chosen: BaseView (devices without glances)
    // is the widget's own page in the widget loop. A "Waiting for
    // connection" loader pushed over it would take up/down and so block
    // scrolling on through the loop - the wait runs without one there (see
    // ConnectionWait).
    startStartupWork(!(view instanceof BaseView));

    // Start inactivity timer if configured
    resetInactivityTimer();

    Utils.logMem("init:7 done", null);

    return [
      view,
      delegate
    ];
  }

  // The requests every launch starts with: the state refresh (or the group
  // import) and the battery report. Called from getInitialView() - or, on
  // :fullmem, by ConnectionWait once there is a connection.
  function runStartupWork() {
    if (isLoggedIn()) {
      if (Hass.getEntities().size() == 0 && Hass.getGroup() != null) {
        // Nothing stored (fresh install, or a storage format change dropped
        // the cache): a state refresh walks an empty list and completes
        // instantly without a single request, so import the group instead.
        // importEntities() ends by starting the same refresh, so this also
        // covers the state fill the call below would have done. When this
        // runs from getInitialView() no view has been pushed yet, so the
        // loader must stay off - see importEntities()'s comment.
        Hass.importEntities(false);
      } else {
        Hass.refreshAllEntities(true);
      }
      Utils.logMem("startupWork: refreshStarted", null);
    }

    var battery_entity_id = Utils.getProperty("report_battery_id", "");
    if (battery_entity_id != null && battery_entity_id.length() > 0) {
      Hass.reportBatteryValue(battery_entity_id);
    }
  }

  // Without a connection every startup request fails, and the "Phone not
  // connected" error closes the app 2.5 s later. Instead, wait for one - the
  // phone, or Wi-Fi up outside a sync as on Edge units
  // (WifiLte.hasDirectConnection()) - and start once it is there (see
  // ConnectionWait), behind a "Waiting for connection" loader unless
  // `showLoader` is false (see getInitialView()).
  //
  // First of all, this is also the sweep at launch for a Wi-Fi/LTE command
  // left over from a sync that never ran (WifiLte.dropStaleCommand()).
  (:fullmem)
  hidden function startStartupWork(showLoader) {
    if (WifiLte.dropStaleCommand()) {
      // A command stored seconds ago: most likely this launch is the
      // sync-mode relaunch startSync2() may do (see WifiLte.mc). Wi-Fi reads
      // as connected in a sync, so the startup requests would go out right
      // away, next to the sync's own and in a process that ends with it.
      return;
    }

    var batteryId = Utils.getProperty("report_battery_id", "");

    if (!isLoggedIn() && (batteryId == null || batteryId.length() == 0)) {
      // Nothing to send, nothing to wait for.
      return;
    }

    if (WifiLte.hasDirectConnection()) {
      runStartupWork();
      return;
    }

    _connectionWait = new ConnectionWait(showLoader);
    _connectionWait.start();
  }

  (:lowmem)
  hidden function startStartupWork(showLoader) {
    runStartupWork();
  }

  // Whether the wait for a connection at launch is still going on. Meanwhile
  // a "Phone not connected" error must not close the app (see
  // Error.initialize()): that would end the wait, which refreshes once the
  // phone is back. False once connected or once the wait has given up - and
  // when there was none (connected at launch, sync mode).
  (:fullmem)
  function isWaitingForPhone() {
    return _connectionWait != null && _connectionWait.isPending();
  }

  (:lowmem)
  function isWaitingForPhone() {
    return false;
  }

  // Wi-Fi/LTE execution (see WifiLte.mc). startSync2() is documented to
  // relaunch the app in sync mode, where the system then asks for this - in
  // practice the app can also stay alive and be asked without a relaunch.
  // Presumably the system asks before the automatic syncs as well, e.g.
  // while charging; that is not verified (the SDK does not say), so
  // HassSyncDelegate.isSyncNeeded() declines any sync unless a command is
  // pending - and a command never outlives the sync it was meant for.
  (:fullmem)
  function getSyncDelegate() {
    if (!WifiLte.isEnabled()) {
      return null;
    }
    return new HassSyncDelegate();
  }

  // Reset the inactivity timer - call this on any user interaction
  function resetInactivityTimer() {
    var seconds = Utils.getProperty("autoCloseSeconds", 0);
    if (seconds == null || seconds == 0) {
      // Feature disabled, drop any pending timeout
      Scheduler.cancel(:inactivity);
      return;
    }

    // Rescheduling the same key only moves the deadline: no new timer.
    Scheduler.schedule(:inactivity, method(:onInactivityTimeout), seconds * 1000);
  }

  // Called when inactivity timer expires
  function onInactivityTimeout() {
    System.exit();
  }
}