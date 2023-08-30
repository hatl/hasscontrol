using Toybox.WatchUi as Ui;
using Toybox.Application as App;

class ErrorDelegate extends Ui.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onSelect() {
        App.getApp().viewController.removeError();
        return true;
    }

    function onBack() {
        App.getApp().viewController.removeError();
        return true;
    }
}

class ErrorView extends Ui.View {
    hidden var _message;
    hidden var _isActive;
    function initialize() {
        View.initialize();
        _isActive = false;
    }

    // Load your resources here
    function onLayout(dc) {
        setLayout(Rez.Layouts.ErrorLayout(dc));
    }

    function setMessage(message) {
        _message = message;
    }

    function onShow() {
        _isActive = true;
    }

    function onHide() {
        _isActive = false;
    }

    function isActive() {
        return _isActive;
    }

    function onUpdate(dc) {
        var titleEl = View.findDrawableById("Title");
        var messageEl = View.findDrawableById("Message");

        titleEl.setText(Rez.Strings.Error_Failed);
        messageEl.setText(_message.toString());

        View.onUpdate(dc);
    }
}