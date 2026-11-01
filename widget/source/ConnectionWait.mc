using Toybox.Application as App;
using Toybox.System;
using Toybox.WatchUi as Ui;

// Launching without the phone used to fail every startup request, and the
// first "Phone not connected" error closed the app 2.5 s later. This waits
// for the phone instead and runs the startup requests once it is there
// (see HassControlApp.startStartupWork()).
//
// Meanwhile a "Waiting for phone" loader is shown - unless Wi-Fi/LTE
// execution is available (see WifiLte.mc): then the stored entities can be
// acted on right away, so nothing blocks them and the wait runs quietly.
// Back leaves the loader for the stored entities; the wait goes on in the
// background and refreshes them once the phone connects.
//
// :fullmem only, see monkey.jungle.
(:fullmem)
class ConnectionWait {
  // How often the connection is checked. Connect IQ has no event for it.
  static const POLL_INTERVAL = 1000; // ms

  // Delay of the first check, see start().
  static const FIRST_CHECK = 200; // ms

  hidden var _mLoaderShown;
  hidden var _mDismissed;

  function initialize() {
    _mLoaderShown = false;
    _mDismissed = false;
  }

  function start() {
    // The first check runs once the initial view is on screen: called from
    // getInitialView(), it is not pushed yet, and a loader pushed now would
    // end up beneath it (see Hass.importEntities()).
    Scheduler.schedule(:connWait, method(:onTick), FIRST_CHECK);
  }

  function onTick() {
    if (System.getDeviceSettings().phoneConnected) {
      hideLoader();
      App.getApp().runStartupWork();
      return;
    }

    if (WifiLte.shouldUse()) {
      hideLoader();
    } else if (!_mLoaderShown && !_mDismissed) {
      _mLoaderShown = true;
      App.getApp().viewController.showLoaderWithDelegate(
        "Waiting for\nphone",
        new ConnectionWaitDelegate(self)
      );
    }

    Scheduler.schedule(:connWait, method(:onTick), POLL_INTERVAL);
  }

  // Back on the loader: show the stored entities, keep waiting quietly.
  function dismiss() {
    _mDismissed = true;
    _mLoaderShown = false;
    App.getApp().viewController.dismissLoader();
  }

  hidden function hideLoader() {
    if (_mLoaderShown) {
      _mLoaderShown = false;
      App.getApp().viewController.removeLoaderImmediate();
    }
  }
}

(:fullmem)
class ConnectionWaitDelegate extends Ui.BehaviorDelegate {
  hidden var _mWait;

  function initialize(wait) {
    BehaviorDelegate.initialize();
    _mWait = wait;
  }

  function onBack() {
    App.getApp().resetInactivityTimer();
    _mWait.dismiss();
    return true;
  }
}
