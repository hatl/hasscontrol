using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Hass;

class MenuController {
    enum {
        MENU_SWITCH_TO_SCENES,
        MENU_SWITCH_TO_ENTITIES,
        MENU_ENTER_SETTINGS,
        MENU_LOGIN,

        MENU_SELECT_START_VIEW,
        MENU_REFRESH_ENTITIES,
        MENU_LOGOUT,

        MENU_SELECT_START_VIEW_ENTITIES,
        MENU_SELECT_START_VIEW_SCENES,
        MENU_SELECT_START_VIEW_ENTITIES_SCENES,

        MENU_BACK
    }

    hidden var _delegate;

    function initialize() {
            _delegate = new MenuDelegate();
    }

    function showRootMenu() {
        var menu = new Ui.Menu2({
            :title => "HassControl"
        });

        if (App.getApp().isLoggedIn()) {
            menu.addItem(new Ui.MenuItem(
                "Scenes",
                "",
                MenuController.MENU_SWITCH_TO_SCENES,
                {}
            ));
            menu.addItem(new Ui.MenuItem(
                "Entities",
                "",
                MenuController.MENU_SWITCH_TO_ENTITIES,
                {}
            ));
            menu.addItem(new Ui.MenuItem(
                "Settings",
                "",
                MenuController.MENU_ENTER_SETTINGS,
                {}
            ));
        } else {
            menu.addItem(new Ui.MenuItem(
                "Login",
                "",
                MenuController.MENU_LOGIN,
                {}
            ));
        }

        Ui.pushView(menu, _delegate, Ui.SLIDE_IMMEDIATE);
        }

    function showSettingsMenu() {
        var menu = new Ui.Menu2({
            :title => "Settings"
        });

        menu.addItem(new Ui.MenuItem(
            "Start View",
            App.getApp().getStartView(),
            MenuController.MENU_SELECT_START_VIEW,
            {}
        ));
        menu.addItem(new Ui.MenuItem(
            "Refresh entities",
            Hass.getGroup(),
            MenuController.MENU_REFRESH_ENTITIES,
            {}
        ));
        menu.addItem(new Ui.MenuItem(
            "Logout",
            "",
            MenuController.MENU_LOGOUT,
            {}
        ));

        Ui.pushView(menu, _delegate, Ui.SLIDE_IMMEDIATE);
    }

    function showSelectStartViewMenu() {
        var menu = new Ui.Menu2({
            :title => "Start view"
        });

        var currentStartView = App.getApp().getStartView();
        var entitiesSubtitle = "";
        var scenesSubtitle = "";
        var entitiesScenesSubtitle = "";

        if (currentStartView == HassControlApp.ENTITIES_VIEW) {
            entitiesSubtitle = "selected";
        }

        if (currentStartView == HassControlApp.SCENES_VIEW) {
            scenesSubtitle = "selected";
        }
        if (currentStartView == HassControlApp.ENTITIES_SCENES_VIEW) {
            entitiesScenesSubtitle = "selected";
        }

        menu.addItem(new Ui.MenuItem(
            "Entities",
            entitiesSubtitle,
            MenuController.MENU_SELECT_START_VIEW_ENTITIES,
            {}
        ));

        menu.addItem(new Ui.MenuItem(
            "Scenes",
            scenesSubtitle,
            MenuController.MENU_SELECT_START_VIEW_SCENES,
            {}
        ));

        menu.addItem(new Ui.MenuItem(
            "Entities and Scenes",
            entitiesScenesSubtitle,
            MenuController.MENU_SELECT_START_VIEW_ENTITIES_SCENES,
            {}
        ));

        menu.addItem(new Ui.MenuItem(
            "Back",
            "",
            MenuController.MENU_BACK,
            {}
        ));

        Ui.pushView(menu, _delegate, Ui.SLIDE_IMMEDIATE);
    }
}