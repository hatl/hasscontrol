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
                Rez.Strings.Generic_Scenes,
                "",
                MenuController.MENU_SWITCH_TO_SCENES,
                {}
            ));
            menu.addItem(new Ui.MenuItem(
                Rez.Strings.Generic_Entities,
                "",
                MenuController.MENU_SWITCH_TO_ENTITIES,
                {}
            ));
            menu.addItem(new Ui.MenuItem(
                Rez.Strings.Generic_Settings,
                "",
                MenuController.MENU_ENTER_SETTINGS,
                {}
            ));
        } else {
            menu.addItem(new Ui.MenuItem(
                Rez.Strings.Generic_Login,
                "",
                MenuController.MENU_LOGIN,
                {}
            ));
        }

        Ui.pushView(menu, _delegate, Ui.SLIDE_IMMEDIATE);
        }

    function showSettingsMenu() {
        var menu = new Ui.Menu2({
            :title => Rez.Strings.Generic_Settings
        });

        menu.addItem(new Ui.MenuItem(
            Rez.Strings.SettingsMenu_Start_View,
            App.getApp().getStartView(),
            MenuController.MENU_SELECT_START_VIEW,
            {}
        ));
        menu.addItem(new Ui.MenuItem(
            Rez.Strings.SettingsMenu_Refresh_Entities,
            Hass.getGroup(),
            MenuController.MENU_REFRESH_ENTITIES,
            {}
        ));
        menu.addItem(new Ui.MenuItem(
            Rez.Strings.Generic_Logout,
            "",
            MenuController.MENU_LOGOUT,
            {}
        ));

        Ui.pushView(menu, _delegate, Ui.SLIDE_IMMEDIATE);
    }

    function showSelectStartViewMenu() {
        var menu = new Ui.Menu2({
            :title => Rez.Strings.SettingsMenu_Start_View
        });

        var currentStartView = App.getApp().getStartView();
        var entitiesSubtitle = "";
        var scenesSubtitle = "";

        if (currentStartView == HassControlApp.ENTITIES_VIEW) {
            entitiesSubtitle = "selected";
        }

        if (currentStartView == HassControlApp.SCENES_VIEW) {
            scenesSubtitle = "selected";
        }

        menu.addItem(new Ui.MenuItem(
            Rez.Strings.Generic_Entities,
            entitiesSubtitle,
            MenuController.MENU_SELECT_START_VIEW_ENTITIES,
            {}
        ));

        menu.addItem(new Ui.MenuItem(
            Rez.Strings.Generic_Scenes,
            scenesSubtitle,
            MenuController.MENU_SELECT_START_VIEW_SCENES,
            {}
        ));

        menu.addItem(new Ui.MenuItem(
            Rez.Strings.Generic_Back,
            "",
            MenuController.MENU_BACK,
            {}
        ));

        Ui.pushView(menu, _delegate, Ui.SLIDE_IMMEDIATE);
    }
}