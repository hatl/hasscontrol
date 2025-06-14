using Toybox.WatchUi as Ui;
using Toybox.Application as App;

class BaseDelegate extends Ui.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onSelect() {
        App.getApp().launchInitialView();
        return true;
    }

    function onHold(clickEvent) {
        // Handle long press gesture to open menu
        App.getApp().menu.showRootMenu();
        return true;
    }
}