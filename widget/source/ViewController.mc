using Toybox.WatchUi as Ui;
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
    _loaderView = new ProgressView();
    _errorView = new ErrorView();
    _errorDelegate = new ErrorDelegate();
    _loginView = new LoginView();
    _loginDelegate = new LoginDelegate();
    _loaderActive = null;
    _loaderTimer = new Timer.Timer();
  }


  // TODO:
  // Delay to close the loader
  // What happens if the user closes the loader before the app closes the loader?


  // Since the progress bar is not a normal view,
  // We need to work around that it doesnt have onHide and onShow
  function isShowingLoader() {
    return _loaderActive != null && !_errorView.isActive() && !_loginView.isActive();
  }

  function getSceneView() {
    var controller = new EntityListController(
      [Hass.TYPE_SCENE]
    );

    return [
      new EntityListView(controller),
      new EntityListDelegate(controller)
    ];
  }

  function getEntityView() {
    var controller = new EntityListController(
      [
        Hass.TYPE_LIGHT,
        Hass.TYPE_SWITCH,
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

    return [
      new EntityListView(controller),
      new EntityListDelegate(controller)
    ];
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

  function showLoginView(show) {
    System.println("Show login? " + show);
    if (!_loginView.isActive() && show == true) {
      Ui.pushView(_loginView, _loginDelegate, Ui.SLIDE_IMMEDIATE);

      Ui.requestUpdate();
    }

    if (_loginView.isActive() && show == false) {
      Ui.popView(Ui.SLIDE_IMMEDIATE);

      Ui.requestUpdate();
    }

  }

  function showLoader(text) {
    if (isShowingLoader()) {
      Ui.popView(Ui.SLIDE_IMMEDIATE);
    }

    _loaderView.setDisplayString(text);

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

    var message = Rez.Strings.Error_Unknown;

    if (error instanceof Error) {
      message = error.toShortString();

      if (error.code == Error.ERROR_UNKNOWN && error.responseCode != null) {
        message += "\ncode ";
        message += error.responseCode;

        if (error instanceof Hass.OAuthError) {
          message += "\nauth ";
        }
      }

      if (error.context != null) {
        message += "\n" + error.context;
      }
    } else if (error instanceof String) {
      message = error;
    }

    if (_errorView.isActive()) {
      Ui.popView(Ui.SLIDE_IMMEDIATE);
    }

    _errorView.setMessage(message);

    Ui.pushView(_errorView, _errorDelegate, Ui.SLIDE_IMMEDIATE);

    System.println(error);
    Ui.requestUpdate();
  }

  function removeError() {
    if (_errorView.isActive()) {
      Ui.popView(Ui.SLIDE_IMMEDIATE);
    }
  }
}
