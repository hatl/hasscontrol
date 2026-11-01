using Toybox.Application as App;
using Toybox.WatchUi as Ui;

// The loader. Ui.ProgressBar is not a View: it gets no onShow()/onHide(),
// so ViewController tracks whether it is on screen (isShowingLoader()).
class ProgressView extends Ui.ProgressBar {
    function initialize() {
      ProgressBar.initialize("", null);
    }

    function setDisplayString(text) {
        ProgressBar.setDisplayString(text);
    }
}

// The input of every loader but ConnectionWait's, which brings its own (see
// ViewController.showLoader()). Without a delegate the system pops a loader
// on back without telling anyone: _loaderActive then outlived it, and the
// next removal popped whatever was on top instead - an editor opened
// meanwhile, say. Back now goes through ViewController.dismissLoader().
class LoaderDelegate extends Ui.BehaviorDelegate {
  // Set by the first back. The second of a fast double back can reach this
  // delegate before the pop is done, and popping again would take off the
  // view beneath (ConnectionWait.dismiss() guards against the same).
  hidden var _mGone;

  function initialize() {
    BehaviorDelegate.initialize();
    _mGone = false;
  }

  function onBack() {
    if (_mGone) {
      return true;
    }

    if (App.getApp().viewController.dismissLoader()) {
      _mGone = true;
      return true;
    }

    // Nothing to pop on our side (see dismissLoader()): leave the back to
    // the system, as a loader without a delegate would.
    return false;
  }

  // A tap or select on a showing loader has nothing to do. It must not fall
  // through to the system either: an unhandled tap exits the app on some
  // devices (see the note on InputNumberEditDelegate.onTap()).
  function onTap(clickEvent) {
    return true;
  }

  function onSelect() {
    return true;
  }
}
