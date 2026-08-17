using Toybox.WatchUi as Ui;
using Toybox.Application as App;
using Toybox.System;
using Hass;

class MenuDelegate extends Ui.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        App.getApp().resetInactivityTimer();
        var itemId = item.getId();

        if (itemId == MenuController.MENU_SWITCH_TO_ENTITIES) {
            Ui.popView(Ui.SLIDE_IMMEDIATE);

            App.getApp().viewController.switchEntityView();
            return true;
        }
        if (itemId == MenuController.MENU_SWITCH_TO_SCENES) {
            Ui.popView(Ui.SLIDE_IMMEDIATE);

            App.getApp().viewController.switchSceneView();
            return true;
        }
        if (itemId == MenuController.MENU_SWITCH_TO_ENTITIES_SCENES) {
            Ui.popView(Ui.SLIDE_IMMEDIATE);

            App.getApp().viewController.switchEntitySceneView();
            return true;
        }
        if (itemId == MenuController.MENU_LOGOUT) {
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            App.getApp().logout();
            return true;
        }
        if (itemId == MenuController.MENU_LOGIN) {
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            App.getApp().login();
            return true;
        }
        if (itemId == MenuController.MENU_ENTER_SETTINGS) {
            App.getApp().menu.showSettingsMenu();
            return true;
        }
        if (itemId == MenuController.MENU_SELECT_START_VIEW) {
            App.getApp().menu.showSelectStartViewMenu();
            return true;
        }
        if (itemId == MenuController.MENU_TOGGLE_LIST_VIEW) {
            var toggle = item as Ui.ToggleMenuItem;
            var useList = toggle.isEnabled();

            // Persist to the app property store so it syncs with the
            // companion app settings and survives restarts.
            App.Properties.setValue("useListView", useList);

            // Rebuild the current entity view in the selected style.
            // Pop settings menu AND root menu first, so the view gets
            // replaced instead of the root menu - otherwise the back
            // button would reveal the old view underneath.
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            App.getApp().viewController.switchCurrentEntityView();
            return true;
        }
        if (itemId == MenuController.MENU_REFRESH_ENTITIES) {
            Hass.importEntities();
            return true;
        }

        if (itemId == MenuController.MENU_SELECT_START_VIEW_ENTITIES) {
            App.getApp().setStartView(HassControlApp.ENTITIES_VIEW);

            // TOTO: This is a dirty hack to get the parent menu to re render
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            App.getApp().menu.showSettingsMenu();
            return true;
        }
        if (itemId == MenuController.MENU_SELECT_START_VIEW_SCENES) {
            App.getApp().setStartView(HassControlApp.SCENES_VIEW);

            // TOTO: This is a dirty hack to get the parent menu to re render
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            App.getApp().menu.showSettingsMenu();
            return true;
        }
        if (itemId == MenuController.MENU_SELECT_START_VIEW_ENTITIES_SCENES) {
            App.getApp().setStartView(HassControlApp.ENTITIES_SCENES_VIEW);

            // TOTO: This is a dirty hack to get the parent menu to re render
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            App.getApp().menu.showSettingsMenu();
            return true;
        }

        /*
         * GLOBAL MENU OPTIONS
        */
        if (itemId == MenuController.MENU_BACK) {
            Ui.popView(Ui.SLIDE_IMMEDIATE);
            return true;
        }

        return false;
    }
}