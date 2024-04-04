using Toybox.Application as App;
using Toybox.Communications as Comm;
using Toybox.WatchUi as Ui;
using Hass;


class HassControlApp extends App.AppBase {
  static const SCENES_VIEW = "scenes";
  static const ENTITIES_VIEW = "entities";
  static const ENTITIES_SCENES_VIEW = "entities_scenes";
  static const STORAGE_KEY_START_VIEW = "start_view";

  var viewController;
  var menu;

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
      throw new Toybox.Lang.InvalidValueException();
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
    viewController = new ViewController();
    menu = new MenuController();

    Hass.initClient();
    Hass.loadStoredEntities();
    Hass.loadScenesFromSettings();

    if (isLoggedIn()) {
      Hass.refreshAllEntities(true);
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


    return [
      view,
      delegate
    ];
  }
}
