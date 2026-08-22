using Toybox.WatchUi as Ui;
using Toybox.Application as App;
using Toybox.Timer;
using Toybox.Time;

using Hass;

class ViewController {
  hidden var _currentView;
  hidden var _loaderView;
  hidden var _errorView;
  hidden var _errorDelegate;
  hidden var _loginView;
  hidden var _loginDelegate;
  hidden var _loaderActive;
  hidden var _loaderTimer;
  hidden var _sceneController;

  function initialize() {
    _loaderActive = null;
    _loaderTimer = new Timer.Timer();
  }

  // The progress, error and login views are built on first use. Allocating all
  // five eagerly cost 1360 bytes - measured at startup on Instinct 2X, where
  // the whole heap is about 11 KB - and a session that neither errors nor logs
  // in never needs four of them.
  hidden function loaderView() {
    if (_loaderView == null) {
      _loaderView = new ProgressView();
    }
    return _loaderView;
  }

  hidden function errorView() {
    if (_errorView == null) {
      _errorView = new ErrorView();
      _errorDelegate = new ErrorDelegate();
    }
    return _errorView;
  }

  hidden function loginView() {
    if (_loginView == null) {
      _loginView = new LoginView();
      _loginDelegate = new LoginDelegate();
    }
    return _loginView;
  }

  // Null-safe: a view that was never built cannot be on screen.
  hidden function isErrorActive() {
    return _errorView != null && _errorView.isActive();
  }

  hidden function isLoginActive() {
    return _loginView != null && _loginView.isActive();
  }


  // TODO:
  // Delay to close the loader
  // What happens if the user closes the loader before the app closes the loader?


  // Since the progress bar is not a normal view,
  // We need to work around that it doesnt have onHide and onShow
  function isShowingLoader() {
    return _loaderActive != null && !isErrorActive() && !isLoginActive();
  }

  // Returns true when the "useListView" setting is enabled, selecting the
  // 3-row list view instead of the classic single-card view.
  function useListEntityView() {
    return App.Properties.getValue("useListView");
  }

  // Rebuilds the entity view matching the configured start view in the
  // currently selected style (list or classic) and switches to it.
  // Used to apply a changed "useListView" setting immediately.
  function switchCurrentEntityView() {
    var startView = App.getApp().getStartView();

    if (startView.equals(HassControlApp.SCENES_VIEW)) {
      switchSceneView();
    } else if (startView.equals(HassControlApp.ENTITIES_SCENES_VIEW)) {
      switchEntitySceneView();
    } else {
      switchEntityView();
    }
  }

  // Builds the [view, delegate] pair for the given entity types, honoring the
  // "useListView" setting: EntityListView (list) or EntityCardView (classic).
  (:fullmem)
  hidden function buildEntityView(types) {
    var controller = new EntityListController(types);
    var view = useListEntityView()
      ? new EntityListView(controller)
      : new EntityCardView(controller);

    return [
      view,
      new EntityListDelegate(controller)
    ];
  }

  // Lean build (64 KB widget devices): EntityListView is not compiled in, so
  // the classic card is the only style available and "useListView" is ignored.
  (:lowmem)
  hidden function buildEntityView(types) {
    var controller = new EntityListController(types);

    return [
      new EntityCardView(controller),
      new EntityListDelegate(controller)
    ];
  }

  function getSceneView() {
    return buildEntityView(
      [Hass.TYPE_SCENE]
    );
  }

  function getEntityView() {
    return buildEntityView(
      [
        Hass.TYPE_LIGHT,
        Hass.TYPE_SWITCH,
        Hass.TYPE_VALVE,
        Hass.TYPE_AUTOMATION,
        Hass.TYPE_SCRIPT,
        Hass.TYPE_LOCK,
        Hass.TYPE_COVER,
        Hass.TYPE_FAN,
        Hass.TYPE_BINARY_SENSOR,
        Hass.TYPE_INPUT_BOOLEAN,
        Hass.TYPE_BUTTON,
        Hass.TYPE_INPUT_BUTTON,
        Hass.TYPE_SENSOR
      ]
    );
  }

  function getEntitySceneView()
  {
    return buildEntityView(
      [
        Hass.TYPE_SCENE,
        Hass.TYPE_LIGHT,
        Hass.TYPE_SWITCH,
        Hass.TYPE_VALVE,
        Hass.TYPE_AUTOMATION,
        Hass.TYPE_SCRIPT,
        Hass.TYPE_LOCK,
        Hass.TYPE_COVER,
        Hass.TYPE_FAN,
        Hass.TYPE_BINARY_SENSOR,
        Hass.TYPE_INPUT_BOOLEAN,
        Hass.TYPE_BUTTON,
        Hass.TYPE_INPUT_BUTTON,
        Hass.TYPE_SENSOR
      ]
    );
  }

  function pushSceneView() {
    var view = getSceneView();

    Ui.pushView(
      view[0],
      view[1],
      Ui.SLIDE_IMMEDIATE
    );
  }

  function switchSceneView() {
    var view = getSceneView();

    Ui.switchToView(
      view[0],
      view[1],
      Ui.SLIDE_IMMEDIATE
    );
  }

  function pushEntityView() {
    var view = getEntityView();

    Ui.pushView(
      view[0],
      view[1],
      Ui.SLIDE_IMMEDIATE
    );
  }

  function switchEntityView() {
    var view = getEntityView();

    Ui.switchToView(
      view[0],
      view[1],
      Ui.SLIDE_IMMEDIATE
    );
  }

  function pushEntityScenesView() {
    var view = getEntitySceneView();

    Ui.pushView(
      view[0],
      view[1],
      Ui.SLIDE_IMMEDIATE
    );
  }

  function switchEntitySceneView() {
    var view = getEntitySceneView();

    Ui.switchToView(
      view[0],
      view[1],
      Ui.SLIDE_IMMEDIATE
    );
  }

  function showLoginView(show) {
    System.println("Show login? " + show);
    if (!isLoginActive() && show == true) {
      Ui.pushView(loginView(), _loginDelegate, Ui.SLIDE_IMMEDIATE);

      Ui.requestUpdate();
    }

    if (isLoginActive() && show == false) {
      Ui.popView(Ui.SLIDE_IMMEDIATE);

      Ui.requestUpdate();
    }

  }

  function showLoader(text) {
    if (isShowingLoader()) {
      Ui.popView(Ui.SLIDE_IMMEDIATE);
    }

    loaderView().setDisplayString(text);

    Ui.pushView(_loaderView, null, Ui.SLIDE_BLINK);

    _loaderActive = Time.now();

    Ui.requestUpdate();
  }


  function removeLoader() {
    if (isShowingLoader()) {
      // if loader is about to close too soon, we need to delay it
      if (Time.now().add(new Time.Duration(-1)).lessThan(_loaderActive)) {
        _loaderTimer.start(method(:removeLoader), 500, false);
        return;
      }

      Ui.popView(Ui.SLIDE_BLINK);
    }

    _loaderActive = null;
  }

  function removeLoaderImmediate() {
    if (isShowingLoader()) {
      Ui.popView(Ui.SLIDE_BLINK);
    }

    _loaderActive = null;
  }

  function showError(error) {
    removeLoaderImmediate();

    var message = "Unknown Error";

    if (error instanceof Error) {
      message = error.toShortString();

      if (error.code == Error.ERROR_UNKNOWN && error.responseCode != null) {
        message += "\ncode ";
        message += error.responseCode;

        if (error instanceof Hass.OAuthError) {
          message += "\nauth ";
        }

        if(error.code == Error.ERROR_PHONE_NOT_CONNECTED) {
          Ui.popView(Ui.SLIDE_IMMEDIATE);
          }
      }

      if (error.context != null) {
        message += "\n" + error.context;
      }
    } else if (error instanceof String) {
      message = error;
    }

    if (isErrorActive()) {
      Ui.popView(Ui.SLIDE_IMMEDIATE);
    }

    errorView().setMessage(message);

    Ui.pushView(_errorView, _errorDelegate, Ui.SLIDE_IMMEDIATE);

    System.println(error);
    Ui.requestUpdate();
  }

  function removeError() {
    if (isErrorActive()) {
      Ui.popView(Ui.SLIDE_IMMEDIATE);
    }
  }
}
