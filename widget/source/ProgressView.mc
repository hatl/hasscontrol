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
// meanwhile, say. The system still pops the bar on back with a delegate in
// place (see ViewController.loaderDismissedByBack()); this one just keeps
// the bookkeeping in step and must not pop anything itself.
class LoaderDelegate extends Ui.BehaviorDelegate {
  function initialize() {
    BehaviorDelegate.initialize();
  }

  function onBack() {
    App.getApp().viewController.loaderDismissedByBack();
    // false: the system takes the bar down, as it does for a loader without
    // a delegate.
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
