using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.Timer;
using Hass;
using Utils;

class EntityListController {
  hidden var _mEntities;
  hidden var _mTypes;
  hidden var _mHassModel;
  hidden var _mIndex;

  function initialize(types) {
    _mTypes = types;
    _mIndex = 0;

    refreshEntities();
  }

  function refreshEntities() {
    if (_mTypes != null) {
      _mEntities = Hass.getEntitiesByTypes(_mTypes);
    } else {
      _mEntities = Hass.getEntities();
    }

    // Ensure index is within valid bounds
    if (_mEntities.size() == 0) {
      _mIndex = 0;
    } else if (_mIndex >= _mEntities.size()) {
      _mIndex = _mEntities.size() - 1;
    } else if (_mIndex < 0) {
      _mIndex = 0;
    }
  }

  function getCurrentEntity() {
    if (_mEntities.size() == 0) {
      return null;
    }

    return _mEntities[_mIndex];
  }

  function setIndex(index) {
    if (!(index instanceof Number)) {
      throw new Toybox.Lang.InvalidValueException("Index must be a number");
    }
    _mIndex = index;
  }

  function getIndex() {
    return _mIndex;
  }

  function getCount() {
    return _mEntities.size();
  }

  function toggleEntity(entity) {
    Hass.toggleEntityState(entity);
  }
}

class EntityListDelegate extends Ui.BehaviorDelegate {
  hidden var _mController;

  function initialize(controller) {
    BehaviorDelegate.initialize();
    _mController = controller;
  }

  function onMenu() {
    App.getApp().resetInactivityTimer();
    App.getApp().menu.showRootMenu();

    return true;
  }

  function onSelect() {
    App.getApp().resetInactivityTimer();
    var entity = _mController.getCurrentEntity();

    if (entity != null) {
      _mController.toggleEntity(entity);
    } else {
      App.getApp().menu.showRootMenu();
      App.getApp().viewController.showError("No entity to toggle,\nplease refresh group\nfrom settings");
    }

    return true;
  }

  function onHold(clickEvent) {
    App.getApp().resetInactivityTimer();
    // Handle long press gesture to open menu
    App.getApp().menu.showRootMenu();
    return true;
  }

  function onNextPage() {
    App.getApp().resetInactivityTimer();
    var index = _mController.getIndex();
    var count = _mController.getCount();

    if (count == 0) {
      return true;
    }

    index += 1;

    if (index > count - 1) {
      index = 0;
    }

    _mController.setIndex(index);
    Ui.requestUpdate();

    return true;
  }

  function onPreviousPage() {
    App.getApp().resetInactivityTimer();
    var index = _mController.getIndex();
    var count = _mController.getCount();

    if (count == 0) {
      return true;
    }

    index -= 1;

    if (index < 0) {
      index = count - 1;
    }

    _mController.setIndex(index);
    Ui.requestUpdate();

    return true;
  }
}

class EntityListView extends Ui.View {
  hidden var _mController;
  hidden var _mLastIndex;
  hidden var _mTimer;
  hidden var _mTimerActive;
  hidden var _mShowBar;
  hidden var _mMdiMap; // lazily-built "mdi:*" -> drawable lookup, cached

  function initialize(controller) {
    View.initialize();
    _mController = controller;
    _mLastIndex = null;
    _mTimer = new Timer.Timer();
    _mTimerActive = false;
    _mShowBar = false;
    _mMdiMap = null;
  }

  function onLayout(dc) {
    setLayout([]);
  }

  function onShow() {
    if (App.Properties.getValue("refresh")) {
      Hass.refreshAllEntities(true);
    }
  }

  function onHide() {
    // Stop timer when view is hidden to prevent orphaned timer callbacks
    if (_mTimerActive) {
      _mTimer.stop();
      _mTimerActive = false;
    }
  }

  function drawNoEntityText(dc) {
    var vh = dc.getHeight();
    var vw = dc.getWidth();

    var cvh = vh / 2;
    var cvw = vw / 2;

    // Adjust sad smiley position for rectangular screens
    var iconVertPosition = Utils.isRectangularScreen() ? 0.25 : 0.3;

    var SmileySad = Ui.loadResource(Rez.Drawables.SmileySad);

    dc.drawBitmap(
      cvw - (SmileySad.getHeight() / 2),
      (vh * iconVertPosition) - (SmileySad.getHeight() / 2),
      SmileySad
    );

    var font = Graphics.FONT_MEDIUM;
    var text = Ui.loadResource(Rez.Strings.NoEntities);
    text = Graphics.fitTextToArea(text, font, vw * 0.9, vh * 0.9, true);

    // Adjust text position for rectangular screens
    if (Utils.isRectangularScreen()) {
      dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
      dc.drawText(cvw, vh * 0.4, font, text, Graphics.TEXT_JUSTIFY_CENTER);
    } else {
      dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
      dc.drawText(cvw, cvh, font, text, Graphics.TEXT_JUSTIFY_CENTER);
    }
  }

  function drawEntityText(dc, entity) {
    var vh = dc.getHeight();
    var vw = dc.getWidth();

    var cvh = vh / 2;
    var cvw = vw / 2;

    var fontHeight = vh * 0.3;
    var fontWidth = vw * 0.80;

    var text = entity.getName();

    var fonts = [Graphics.FONT_MEDIUM, Graphics.FONT_TINY, Graphics.FONT_XTINY];
    var font = fonts[0];

    for (var i = 0; i < fonts.size(); i++) {
        var truncate = i == fonts.size() - 1;

        var tempText = Graphics.fitTextToArea(text, fonts[i], fontWidth, fontHeight, truncate);

        if (tempText != null) {
            text = tempText;
            font = fonts[i];
            break;
        }
    }

    // Adjust text position for rectangular screens
    if (Utils.isRectangularScreen()) {
      dc.drawText( cvw, cvh, font, text, Graphics.TEXT_JUSTIFY_CENTER);
    } else {
      dc.drawText(cvh, cvw * 1.1, font, text, Graphics.TEXT_JUSTIFY_CENTER);
    }
  }

  function drawIcon(dc, entity) {
    var vh = dc.getHeight();
    var vw = dc.getWidth();

    var cvw = vw / 2;

    // Adjust icon position for rectangular screens
    var iconVertPosition = Utils.isRectangularScreen() ? 0.25 : 0.3;

    var drawable = getDrawableForEntity(entity);

    dc.drawBitmap(
      cvw - (drawable.getHeight() / 2),
      (vh * iconVertPosition) - (drawable.getHeight() / 2),
      drawable
    );
  }

  // Resolve an entity to its icon drawable. A Home Assistant `icon` attribute
  // (mdi:*) that we have a matching bitmap for takes precedence; otherwise we
  // fall back to the entity type/state, and finally to the Unknown icon.
  function getDrawableForEntity(entity) {
    var icon = entity.getIcon();

    if (icon != null) {
      var mdiId = getMdiMap().get(icon);
      if (mdiId != null) {
        return WatchUi.loadResource(mdiId);
      }
    }

    var drawable = null;

    var type = entity.getType();
    var state = entity.getState();
    var sensorClass = entity.getSensorClass();

    if (type == Hass.TYPE_LIGHT) {
        if (state == Hass.STATE_ON) {
            drawable = WatchUi.loadResource(Rez.Drawables.LightOn);
        } else if (state == Hass.STATE_OFF) {
            drawable = WatchUi.loadResource(Rez.Drawables.LightOff);
        }
    } else if (type == Hass.TYPE_SWITCH) {
        if (state == Hass.STATE_ON) {
            drawable = WatchUi.loadResource(Rez.Drawables.SwitchOn);
        } else if (state == Hass.STATE_OFF) {
            drawable = WatchUi.loadResource(Rez.Drawables.SwitchOff);
        }
    } else if (type == Hass.TYPE_VALVE) {
        if (state == Hass.STATE_OPEN) {
            drawable = WatchUi.loadResource(Rez.Drawables.ValveOpen);
        } else if (state == Hass.STATE_CLOSED) {
            drawable = WatchUi.loadResource(Rez.Drawables.ValveClosed);
        }
    } else if (type == Hass.TYPE_INPUT_BOOLEAN) {
        if (state == Hass.STATE_ON) {
            drawable = WatchUi.loadResource(Rez.Drawables.CheckboxOn);
        } else if (state == Hass.STATE_OFF) {
            drawable = WatchUi.loadResource(Rez.Drawables.CheckboxOff);
        }
    } else if (type == Hass.TYPE_AUTOMATION) {
        if (state == Hass.STATE_ON) {
            drawable = WatchUi.loadResource(Rez.Drawables.AutomationOn);
        } else if (state == Hass.STATE_OFF) {
            drawable = WatchUi.loadResource(Rez.Drawables.AutomationOff);
        }
    } else if (type == Hass.TYPE_LOCK) {
        if (state == Hass.STATE_LOCKED) {
            drawable = WatchUi.loadResource(Rez.Drawables.LockLocked);
        } else if (state == Hass.STATE_UNLOCKED) {
            drawable = WatchUi.loadResource(Rez.Drawables.LockUnlocked);
        } else if  (state == Hass.STATE_LOCKING || state == Hass.STATE_UNLOCKING) {
            drawable = WatchUi.loadResource(Rez.Drawables.LockChanging);
        }
    } else if (type == Hass.TYPE_COVER || type == Hass.TYPE_VALVE) {
        if (state == Hass.STATE_OPEN) {
            drawable = WatchUi.loadResource(Rez.Drawables.CoverOpen);
        } else if (state == Hass.STATE_OPENING) {
            drawable = WatchUi.loadResource(Rez.Drawables.CoverOpening);
        } else if (state == Hass.STATE_CLOSED) {
            drawable = WatchUi.loadResource(Rez.Drawables.CoverClosed);
        } else if (state == Hass.STATE_CLOSING) {
            drawable = WatchUi.loadResource(Rez.Drawables.CoverClosing);
        }
    } else if (type == Hass.TYPE_FAN) {
        if (state == Hass.STATE_ON) {
            drawable = WatchUi.loadResource(Rez.Drawables.FanOn);
        } else if (state == Hass.STATE_OFF) {
            drawable = WatchUi.loadResource(Rez.Drawables.FanOff);
        }
    } else if (type == Hass.TYPE_BINARY_SENSOR) {
        if (state == Hass.STATE_ON) {
            drawable = WatchUi.loadResource(Rez.Drawables.BinaryOn);
        } else if (state == Hass.STATE_OFF) {
            drawable = WatchUi.loadResource(Rez.Drawables.BinaryOff);
        }
    } else if (type == Hass.TYPE_BUTTON || type == Hass.TYPE_INPUT_BUTTON) {
        drawable = WatchUi.loadResource(Rez.Drawables.Button);
    } else if (type == Hass.TYPE_SCRIPT) {
      drawable = WatchUi.loadResource(Rez.Drawables.ScriptOff);
    } else if (type == Hass.TYPE_SCENE) {
      drawable = WatchUi.loadResource(Rez.Drawables.Scene);
    } else if (type == Hass.TYPE_SENSOR) {
      if (sensorClass == Hass.SENSOR_TEMPERATURE) {
        drawable = WatchUi.loadResource(Rez.Drawables.Temperature);
      } else if (sensorClass == Hass.SENSOR_HUMIDITY) {
        drawable = WatchUi.loadResource(Rez.Drawables.Humidity);
      } else if (sensorClass == Hass.SENSOR_CO2) {
        drawable = WatchUi.loadResource(Rez.Drawables.CO2);
      } else if (sensorClass == Hass.SENSOR_PM) {
        drawable = WatchUi.loadResource(Rez.Drawables.AirPM);
      } else if (sensorClass == Hass.SENSOR_ENERGY) {
        drawable = WatchUi.loadResource(Rez.Drawables.EnergyMeter);
      } else if (sensorClass == Hass.SENSOR_WATER) {
        drawable = WatchUi.loadResource(Rez.Drawables.WaterMeter);
      } else if (sensorClass == Hass.SENSOR_GAS) {
        drawable = WatchUi.loadResource(Rez.Drawables.GasMeter);
      } else if (sensorClass == Hass.SENSOR_OTHER) {
        drawable = WatchUi.loadResource(Rez.Drawables.Unknown);
      }
    }

    if (drawable == null) {
        drawable = WatchUi.loadResource(Rez.Drawables.Unknown);
    }

    return drawable;
  }

  // Cached "mdi:*" (Home Assistant icon attribute) -> drawable lookup. Built once
  // on first use. Unmapped icons fall through to type/state selection. Extend by
  // adding a bitmap in drawables.xml and mapping the mdi name(s) here.
  function getMdiMap() {
    if (_mMdiMap == null) {
      _mMdiMap = {
        "mdi:movie" => Rez.Drawables.MdiMovie,
        "mdi:movie-open" => Rez.Drawables.MdiMovie,
        "mdi:movie-outline" => Rez.Drawables.MdiMovie,
        "mdi:movie-open-outline" => Rez.Drawables.MdiMovie,
        "mdi:filmstrip" => Rez.Drawables.MdiMovie,
        "mdi:television-play" => Rez.Drawables.MdiMovie,
        "mdi:movie-off" => Rez.Drawables.MdiMovieOff,
        "mdi:movie-open-off" => Rez.Drawables.MdiMovieOff,
        "mdi:movie-off-outline" => Rez.Drawables.MdiMovieOff,
        "mdi:bluetooth" => Rez.Drawables.MdiBluetooth,
        "mdi:bluetooth-connect" => Rez.Drawables.MdiBluetooth,
        "mdi:bluetooth-audio" => Rez.Drawables.MdiBluetooth,
        "mdi:bluetooth-settings" => Rez.Drawables.MdiBluetooth,
        "mdi:music" => Rez.Drawables.MdiMusic,
        "mdi:music-note" => Rez.Drawables.MdiMusic,
        "mdi:music-circle" => Rez.Drawables.MdiMusic,
        "mdi:playlist-music" => Rez.Drawables.MdiMusic,
        "mdi:spotify" => Rez.Drawables.MdiMusic,
        "mdi:sleep" => Rez.Drawables.MdiSleep,
        "mdi:power-sleep" => Rez.Drawables.MdiSleep,
        "mdi:bed" => Rez.Drawables.MdiSleep,
        "mdi:bed-outline" => Rez.Drawables.MdiSleep,
        "mdi:bed-empty" => Rez.Drawables.MdiSleep,
        "mdi:robot-vacuum" => Rez.Drawables.MdiVacuum,
        "mdi:robot-vacuum-variant" => Rez.Drawables.MdiVacuum,
        "mdi:radiator" => Rez.Drawables.MdiRadiator,
        "mdi:heating-coil" => Rez.Drawables.MdiRadiator,
        "mdi:restart" => Rez.Drawables.MdiRestart,
        "mdi:restart-alert" => Rez.Drawables.MdiRestart,
        "mdi:reload" => Rez.Drawables.MdiRestart,
        "mdi:refresh" => Rez.Drawables.MdiRestart,
        "mdi:sync" => Rez.Drawables.MdiRestart,
        "mdi:lightbulb" => Rez.Drawables.MdiLightbulb,
        "mdi:lightbulb-outline" => Rez.Drawables.MdiLightbulb,
        "mdi:lightbulb-on" => Rez.Drawables.MdiLightbulb,
        "mdi:lightbulb-on-outline" => Rez.Drawables.MdiLightbulb,
        "mdi:lamp" => Rez.Drawables.MdiLightbulb,
        "mdi:ceiling-light" => Rez.Drawables.MdiLightbulb,
        "mdi:light-recessed" => Rez.Drawables.MdiLightbulb,
        "mdi:track-light" => Rez.Drawables.MdiLightbulb,
        "mdi:power-plug" => Rez.Drawables.MdiPowerPlug,
        "mdi:power-plug-outline" => Rez.Drawables.MdiPowerPlug,
        "mdi:power-socket" => Rez.Drawables.MdiPowerPlug,
        "mdi:power-socket-eu" => Rez.Drawables.MdiPowerPlug,
        "mdi:power" => Rez.Drawables.MdiPowerPlug,
        "mdi:toggle-switch" => Rez.Drawables.MdiPowerPlug,
        "mdi:toggle-switch-outline" => Rez.Drawables.MdiPowerPlug,
        "mdi:television" => Rez.Drawables.MdiTelevision,
        "mdi:television-classic" => Rez.Drawables.MdiTelevision,
        "mdi:monitor" => Rez.Drawables.MdiTelevision,
        "mdi:projector" => Rez.Drawables.MdiTelevision,
        "mdi:speaker" => Rez.Drawables.MdiSpeaker,
        "mdi:speaker-wireless" => Rez.Drawables.MdiSpeaker,
        "mdi:cast" => Rez.Drawables.MdiSpeaker,
        "mdi:cast-audio" => Rez.Drawables.MdiSpeaker,
        "mdi:cast-connected" => Rez.Drawables.MdiSpeaker,
        "mdi:google-home" => Rez.Drawables.MdiSpeaker,
        "mdi:soundbar" => Rez.Drawables.MdiSpeaker,
        "mdi:coffee" => Rez.Drawables.MdiCoffee,
        "mdi:coffee-outline" => Rez.Drawables.MdiCoffee,
        "mdi:coffee-maker" => Rez.Drawables.MdiCoffee,
        "mdi:fridge" => Rez.Drawables.MdiFridge,
        "mdi:fridge-outline" => Rez.Drawables.MdiFridge,
        "mdi:washing-machine" => Rez.Drawables.MdiWasher,
        "mdi:tumble-dryer" => Rez.Drawables.MdiWasher,
        "mdi:dishwasher" => Rez.Drawables.MdiWasher,
        "mdi:thermostat" => Rez.Drawables.MdiThermostat,
        "mdi:thermostat-box" => Rez.Drawables.MdiThermostat,
        "mdi:home-thermometer" => Rez.Drawables.MdiThermostat,
        "mdi:home" => Rez.Drawables.MdiHome,
        "mdi:home-outline" => Rez.Drawables.MdiHome,
        "mdi:home-assistant" => Rez.Drawables.MdiHome,
        "mdi:home-automation" => Rez.Drawables.MdiHome,
        "mdi:garage" => Rez.Drawables.MdiGarage,
        "mdi:garage-variant" => Rez.Drawables.MdiGarage,
        "mdi:garage-open" => Rez.Drawables.MdiGarage,
        "mdi:garage-open-variant" => Rez.Drawables.MdiGarage,
        "mdi:garage-alert" => Rez.Drawables.MdiGarage,
        "mdi:door" => Rez.Drawables.MdiDoor,
        "mdi:door-open" => Rez.Drawables.MdiDoor,
        "mdi:door-closed" => Rez.Drawables.MdiDoor,
        "mdi:door-closed-lock" => Rez.Drawables.MdiDoor,
        "mdi:window-closed" => Rez.Drawables.MdiWindow,
        "mdi:window-closed-variant" => Rez.Drawables.MdiWindow,
        "mdi:window-open" => Rez.Drawables.MdiWindow,
        "mdi:window-open-variant" => Rez.Drawables.MdiWindow,
        "mdi:blinds" => Rez.Drawables.MdiBlinds,
        "mdi:blinds-open" => Rez.Drawables.MdiBlinds,
        "mdi:blinds-horizontal" => Rez.Drawables.MdiBlinds,
        "mdi:roller-shade" => Rez.Drawables.MdiBlinds,
        "mdi:roller-shade-closed" => Rez.Drawables.MdiBlinds,
        "mdi:curtains" => Rez.Drawables.MdiBlinds,
        "mdi:curtains-closed" => Rez.Drawables.MdiBlinds,
        "mdi:window-shutter" => Rez.Drawables.MdiBlinds,
        "mdi:weather-night" => Rez.Drawables.MdiWeatherNight,
        "mdi:weather-night-partly-cloudy" => Rez.Drawables.MdiWeatherNight,
        "mdi:moon-waning-crescent" => Rez.Drawables.MdiWeatherNight,
        "mdi:weather-sunny" => Rez.Drawables.MdiWeatherSunny,
        "mdi:white-balance-sunny" => Rez.Drawables.MdiWeatherSunny,
        "mdi:brightness-7" => Rez.Drawables.MdiWeatherSunny,
        "mdi:weather-partly-cloudy" => Rez.Drawables.MdiWeatherSunny,
        "mdi:bell" => Rez.Drawables.MdiBell,
        "mdi:bell-outline" => Rez.Drawables.MdiBell,
        "mdi:bell-ring" => Rez.Drawables.MdiBell,
        "mdi:bell-ring-outline" => Rez.Drawables.MdiBell,
        "mdi:shield-home" => Rez.Drawables.MdiShield,
        "mdi:shield-home-outline" => Rez.Drawables.MdiShield,
        "mdi:shield-lock" => Rez.Drawables.MdiShield,
        "mdi:shield-check" => Rez.Drawables.MdiShield,
        "mdi:security" => Rez.Drawables.MdiShield,
        "mdi:shield" => Rez.Drawables.MdiShield,
        "mdi:key" => Rez.Drawables.MdiKey,
        "mdi:key-variant" => Rez.Drawables.MdiKey,
        "mdi:key-chain" => Rez.Drawables.MdiKey,
        "mdi:play" => Rez.Drawables.MdiPlay,
        "mdi:play-circle" => Rez.Drawables.MdiPlay,
        "mdi:play-circle-outline" => Rez.Drawables.MdiPlay,
        "mdi:motion-play" => Rez.Drawables.MdiPlay,
        "mdi:pause" => Rez.Drawables.MdiPause,
        "mdi:pause-circle" => Rez.Drawables.MdiPause,
        "mdi:pause-circle-outline" => Rez.Drawables.MdiPause,
        "mdi:stop" => Rez.Drawables.MdiStop,
        "mdi:stop-circle" => Rez.Drawables.MdiStop,
        "mdi:stop-circle-outline" => Rez.Drawables.MdiStop,
        "mdi:volume-high" => Rez.Drawables.MdiVolume,
        "mdi:volume-medium" => Rez.Drawables.MdiVolume,
        "mdi:volume-low" => Rez.Drawables.MdiVolume,
        "mdi:volume-source" => Rez.Drawables.MdiVolume,
        "mdi:fire" => Rez.Drawables.MdiFire,
        "mdi:fireplace" => Rez.Drawables.MdiFire,
        "mdi:campfire" => Rez.Drawables.MdiFire,
        "mdi:fire-circle" => Rez.Drawables.MdiFire,
        "mdi:snowflake" => Rez.Drawables.MdiSnowflake,
        "mdi:snowflake-variant" => Rez.Drawables.MdiSnowflake,
        "mdi:air-conditioner" => Rez.Drawables.MdiSnowflake,
        "mdi:air-filter" => Rez.Drawables.MdiSnowflake,
        "mdi:leaf" => Rez.Drawables.MdiLeaf,
        "mdi:sprout" => Rez.Drawables.MdiLeaf,
        "mdi:sprout-outline" => Rez.Drawables.MdiLeaf,
        "mdi:flower" => Rez.Drawables.MdiLeaf,
        "mdi:tree" => Rez.Drawables.MdiLeaf,
        "mdi:grass" => Rez.Drawables.MdiLeaf,
        "mdi:battery" => Rez.Drawables.MdiBattery,
        "mdi:battery-charging" => Rez.Drawables.MdiBattery,
        "mdi:battery-high" => Rez.Drawables.MdiBattery,
        "mdi:battery-medium" => Rez.Drawables.MdiBattery,
        "mdi:silverware-fork-knife" => Rez.Drawables.MdiFood,
        "mdi:silverware" => Rez.Drawables.MdiFood,
        "mdi:silverware-variant" => Rez.Drawables.MdiFood,
        "mdi:food" => Rez.Drawables.MdiFood,
        "mdi:food-fork-drink" => Rez.Drawables.MdiFood,
        "mdi:sofa" => Rez.Drawables.MdiSofa,
        "mdi:sofa-outline" => Rez.Drawables.MdiSofa,
        "mdi:sofa-single" => Rez.Drawables.MdiSofa,
        "mdi:desk-lamp" => Rez.Drawables.MdiDeskLamp,
        "mdi:desk-lamp-on" => Rez.Drawables.MdiDeskLamp,
        "mdi:floor-lamp" => Rez.Drawables.MdiDeskLamp,
        "mdi:kettle" => Rez.Drawables.MdiKettle,
        "mdi:kettle-steam" => Rez.Drawables.MdiKettle,
        "mdi:kettle-outline" => Rez.Drawables.MdiKettle,
        "mdi:water" => Rez.Drawables.MdiWater,
        "mdi:water-outline" => Rez.Drawables.MdiWater,
        "mdi:water-pump" => Rez.Drawables.MdiWater,
        "mdi:sprinkler" => Rez.Drawables.MdiWater,
        "mdi:sprinkler-variant" => Rez.Drawables.MdiWater,
        "mdi:pipe" => Rez.Drawables.MdiWater,
      };
    }
    return _mMdiMap;
  }

  function drawPageBar(dc) {
    var numEntities = _mController.getCount();
    var currentIndex = _mController.getIndex();

    var vh = dc.getHeight();
    var vw = dc.getWidth();

    var cvh = vh / 2;
    var cvw = vw / 2;

    if (Utils.isRectangularScreen()) {
      // Rectangular screen page bar on the left side
      var barWidth = 10;
      var barHeight = vh * 0.7;
      var barX = 15;
      var barY = (vh - barHeight) / 2;

      // Draw background bar
      dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
      dc.fillRoundedRectangle(barX, barY, barWidth, barHeight, 5);

      // Calculate the active segment height and position
      var segmentHeight = barHeight / numEntities;
      var activeSegmentY = barY + (segmentHeight * currentIndex);

      // Draw active segment
      dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
      dc.fillRoundedRectangle(barX, activeSegmentY, barWidth, segmentHeight, 5);
    } else {
      // Round screen page bar
      var radius = cvh - 10;
      var attr = Graphics.ARC_COUNTER_CLOCKWISE;
      var topDegreeStart = 130;
      var bottomDegreeEnd = 230;

      // Calculate the exact size of each segment to ensure we use the full arc
      var barSize = (bottomDegreeEnd - topDegreeStart) / numEntities;

      // Calculate the start position for the current indicator
      var barStart = topDegreeStart + (barSize * currentIndex);

      // Draw the background arc
      dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
      dc.setPenWidth(10);
      dc.drawArc(cvw, cvh, radius, attr, topDegreeStart, bottomDegreeEnd);

      // Draw the current position indicator
      dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
      dc.setPenWidth(6);
      dc.drawArc(cvw, cvh, radius, attr, barStart, barStart + barSize);
    }
  }

  function onTimerDone() {
    _mTimerActive = false;
    _mShowBar = false;
    Ui.requestUpdate();
  }

  function shouldShowBar() {
    var index = _mController.getIndex();

    if (_mTimerActive && _mShowBar == true) {
      return;
    }

    if (_mLastIndex != index) {
      if (_mTimerActive) {
        _mTimer.stop();
      }
      _mShowBar = true;
      _mTimer.start(method(:onTimerDone), 1000, false);
    }

    _mLastIndex = index;
  }

  function onUpdate(dc) {
    View.onUpdate(dc);

    _mController.refreshEntities();

    var entity = _mController.getCurrentEntity();

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.clear();

    if (entity == null) {
      drawNoEntityText(dc);
      return;
    }

    shouldShowBar();

    drawEntityText(dc, entity);
    drawIcon(dc, entity);

    if (_mShowBar) {
      drawPageBar(dc);
    }

    return;

  }
}