using Toybox.Application as App;
using Toybox.System;
using Toybox.WatchUi as Ui;

// Launching without the phone used to fail every startup request, and the
// first "Phone not connected" error closed the app 2.5 s later. This waits
// for the phone instead and runs the startup requests once it is there
// (see HassControlApp.startStartupWork()). While it waits, a "Phone not
// connected" error does not close the app (HassControlApp.isWaitingForPhone(),
// Error.initialize()).
//
// Meanwhile a "Waiting for phone" loader is shown - except when:
//  * Wi-Fi/LTE execution is available (see WifiLte.mc): then the stored
//    entities can be acted on right away, so nothing blocks them;
//  * the initial view is BaseView (devices without glances): that is the
//    widget's page in the widget loop, and a loader over it would take
//    up/down and so block scrolling on through the loop.
// The wait then runs quietly, and still refreshes once the phone connects.
// Back leaves the loader for the stored entities; the wait goes on quietly
// the same way.
//
// It gives up after MAX_WAIT: the loader goes, the stored states stay, and
// a "Phone not connected" error closes the app again, as without the wait.
//
// :fullmem only, see monkey.jungle.
(:fullmem)
class ConnectionWait {
  // How often the connection is checked - Connect IQ has no event for it.
  // Every POLL_INTERVAL during the first FAST_PHASE, so a phone that is
  // just reconnecting is picked up at once; every SLOW_POLL_INTERVAL after
  // that, as a phone still away by then is rarely about to come back.
  static const POLL_INTERVAL = 1000; // ms
  static const FAST_PHASE = 30000; // ms
  static const SLOW_POLL_INTERVAL = 5000; // ms

  // How long the wait goes on in total before it gives up (see above).
  static const MAX_WAIT = 180000; // ms

  // Delay of the first check, see start().
  static const FIRST_CHECK = 200; // ms

  hidden var _mLoaderShown;
  hidden var _mDismissed;
  hidden var _mPending;
  hidden var _mStartedAt; // System.getTimer() ms

  // `showLoader` false: no loader at all, the wait runs quietly from the
  // start (see above).
  function initialize(showLoader) {
    _mLoaderShown = false;
    _mDismissed = !showLoader;
    _mPending = true;
    _mStartedAt = System.getTimer();
  }

  function start() {
    // The first check runs once the initial view is on screen: called from
    // getInitialView(), it is not pushed yet, and a loader pushed now would
    // end up beneath it (see Hass.importEntities()).
    Scheduler.schedule(:connWait, method(:onTick), FIRST_CHECK);
  }

  // True until the phone has connected or the wait has given up.
  function isPending() {
    return _mPending;
  }

  function onTick() {
    if (System.getDeviceSettings().phoneConnected) {
      _mPending = false;
      hideLoader();

      // Errors built while waiting did not schedule the exit (see
      // Error.initialize()), so normally there is none to drop - but one
      // still pending must not close the app as the refresh starts.
      Scheduler.cancel(:exitPhoneLost);

      App.getApp().runStartupWork();
      return;
    }

    // System.getTimer() wraps around: the difference stays right where a
    // direct comparison of the two moments would not.
    var elapsed = System.getTimer() - _mStartedAt;

    if (elapsed >= MAX_WAIT) {
      // Give up: the stored states stay on screen, and from now on a
      // "Phone not connected" error closes the app as before.
      _mPending = false;
      hideLoader();
      return;
    }

    if (WifiLte.shouldUse()) {
      // Decided once: should shouldUse() turn false later on (e.g. after
      // Settings -> Logout), a loader pushed then would land on top of
      // whatever is on screen by that time.
      _mDismissed = true;
      hideLoader();
    } else if (!_mLoaderShown && !_mDismissed) {
      _mLoaderShown = true;
      App.getApp().viewController.showLoaderWithDelegate(
        "Waiting for\nphone",
        new ConnectionWaitDelegate(self)
      );
    }

    Scheduler.schedule(
      :connWait,
      method(:onTick),
      elapsed < FAST_PHASE ? POLL_INTERVAL : SLOW_POLL_INTERVAL
    );
  }

  // Back on the loader: show the stored entities, keep waiting quietly.
  //
  // Only while the loader is up: a fast double back, or a back still queued
  // when onTick() has already taken the loader down, would otherwise pop a
  // second view - the entity view, or the widget's base page, where
  // popView() throws OperationNotAllowedException.
  function dismiss() {
    if (!_mLoaderShown) {
      return;
    }

    _mDismissed = true;
    _mLoaderShown = false;
    App.getApp().viewController.dismissLoader();
  }

  // Takes the loader down from here rather than from a back key the loader
  // received: removeLoaderImmediate() only pops while a loader is showing.
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
