using Toybox.WatchUi as Ui;

class ProgressView extends Ui.ProgressBar {
    hidden var _isActive;

    function initialize() {
      ProgressBar.initialize("", null);
      _isActive = false;
    }

    function isActive() {
        return _isActive;
    }

    function setDisplayString(text) {
        _isActive = true;
        ProgressBar.setDisplayString(text);
    }

    function onShow() {
        _isActive = true;
    }

    function onHide() {
        _isActive = false;
    }
}