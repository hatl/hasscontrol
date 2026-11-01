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
    if (!_mGone) {
      _mGone = true;
      App.getApp().viewController.dismissLoader();
    }

    return true;
  }
}
