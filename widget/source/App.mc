using Toybox.Application as App;
using Toybox.Communications as Comm;
using Toybox.WatchUi as Ui;
using Toybox.Timer;
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
  var _inactivityTimer;

  function initialize() {
    AppBase.initialize();
    _inactivityTimer = new Timer.Timer();
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

    // Restart inactivity timer with new setting value
    resetInactivityTimer();

    Ui.requestUpdate();
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

  // Return the initial view of your application here
  function getInitialView() {
    Utils.logMem("init:0 enter", null);
    viewController = new ViewController();
    Utils.logMem("init:1 viewController", null);
    menu = new MenuController();
    Utils.logMem("init:2 menu", null);

    Hass.initClient();
    Utils.logMem("init:3 client", null);
    Hass.loadStoredEntities();
    Utils.logMem("init:4 stored n", Hass.getEntities().size());
    Hass.loadScenesFromSettings();
    Utils.logMem("init:5 scenes n", Hass.getEntities().size());

    if (isLoggedIn()) {
      Hass.refreshAllEntities(true);
      Utils.logMem("init:6 refreshStarted", null);
    }

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

    var battery_entity_id = App.Properties.getValue("report_battery_id");
    if (battery_entity_id != null && battery_entity_id.length() > 0) {
      Hass.reportBatteryValue(battery_entity_id);
    }

    // Start inactivity timer if configured
    resetInactivityTimer();

    Utils.logMem("init:7 done", null);

    return [
      view,
      delegate
    ];
  }

  // Reset the inactivity timer - call this on any user interaction
  function resetInactivityTimer() {
    var seconds = App.Properties.getValue("autoCloseSeconds");
    if (seconds == null || seconds == 0) {
      // Feature disabled, stop any running timer
      _inactivityTimer.stop();
      return;
    }

    var timeoutMs = seconds * 1000;
    _inactivityTimer.stop();
    _inactivityTimer.start(method(:onInactivityTimeout), timeoutMs, false);
  }

  // Called when inactivity timer expires
  function onInactivityTimeout() {
    System.exit();
  }
}