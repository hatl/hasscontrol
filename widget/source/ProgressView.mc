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