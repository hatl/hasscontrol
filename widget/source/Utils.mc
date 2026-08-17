using Toybox.Application as App;
using Toybox.StringUtil;
using Toybox.Lang;
using Toybox.System;
using Toybox.WatchUi;

module Utils {
  function getScenesFromSettings() {
    var scenes = new [0];

    var sceneString = App.Properties.getValue("scenes");

    if (sceneString != null && sceneString != "") {
      var chars = sceneString.toCharArray();
      var currentId = "";
      var currentName = "";

      for (var i = 0; i < chars.size(); i++) {
        var char = chars[i];

        if (char.equals(',')) {
          if (currentId.equals("")) {
            currentId = currentName;
          }

          // Prefix with scene if not done from settings
          if (currentId.find("scene.") == null) {
            currentId = "scene." + currentId;
          }

          scenes.add([currentId, currentName]);
          currentId = "";
          currentName = "";
        } else if (char.equals('=')) {
          currentId = currentName;
          currentName = "";
        } else {
          currentName += char;
        }
      }

      if (!currentName.equals("")) {
        if (currentId.equals("")) {
          currentId = currentName;
        }

        // Prefix with scene if not done from settings
        if (currentId.find("scene.") == null) {
          currentId = "scene." + currentId;
        }

        scenes.add([currentId, currentName]);
      }
    }

    // remove whitespace
    for (var sceneIndex = 0; sceneIndex < scenes.size(); sceneIndex++) {
      var sceneIdChars = scenes[sceneIndex][0].toCharArray();
      var sceneNameChars = scenes[sceneIndex][1].toCharArray();
      var sceneId = "";

      for (var i = 0; i < sceneIdChars.size(); i++) {
        if (sceneIdChars[i].equals(' ')) {
          continue;
        }
        sceneId += sceneIdChars[i];
      }

      for (var i = 0; i < sceneNameChars.size(); i++) {
        if (!sceneNameChars[i].equals(' ')) {
          break;
        }
        sceneNameChars = sceneNameChars.slice(i + 1, null);
      }
      for (var i = sceneNameChars.size() - 1; i >= 0; i--) {
        if (!sceneNameChars[i].equals(' ')) {
          break;
        }
        sceneNameChars = sceneNameChars.slice(null, i);
      }

      scenes[sceneIndex][0] = sceneId;
      scenes[sceneIndex][1] = StringUtil.charArrayToString(sceneNameChars);
    }

    return scenes;
  }

  function method(Scope, symbol) {
    return new Lang.Method(Scope, symbol);
  }

  // Lazily-built "mdi:*" (Home Assistant icon attribute) -> drawable lookup.
  // Module-level so it is shared by both the list and the classic entity views.
  // Built once on first use. Unmapped icons fall through to type/state selection.
  // Extend by adding a bitmap in drawables.xml and mapping the mdi name(s) here.
  var _mdiMap = null;

  function getMdiMap() {
    if (_mdiMap == null) {
      _mdiMap = {
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
    return _mdiMap;
  }

  // Maps a Home Assistant `device_class` to a bundled drawable. Used as a
  // fallback icon when an entity has no custom `icon` attribute — Home
  // Assistant derives these icons from the device class in its own UI but does
  // not send them in the `icon` attribute. Only device classes with a matching
  // bundled glyph are listed; extend alongside getMdiMap().
  var _deviceClassMap = null;

  function getDeviceClassMap() {
    if (_deviceClassMap == null) {
      _deviceClassMap = {
        // sensor / binary_sensor device classes
        "battery"          => Rez.Drawables.MdiBattery,
        "battery_charging" => Rez.Drawables.MdiBattery,
        "temperature"      => Rez.Drawables.Temperature,
        "humidity"         => Rez.Drawables.Humidity,
        "carbon_dioxide"   => Rez.Drawables.CO2,
        "pm25"             => Rez.Drawables.AirPM,
        "pm10"             => Rez.Drawables.AirPM,
        "energy"           => Rez.Drawables.EnergyMeter,
        "power"            => Rez.Drawables.MdiPowerPlug,
        "water"            => Rez.Drawables.WaterMeter,
        "gas"              => Rez.Drawables.GasMeter,
        "illuminance"      => Rez.Drawables.MdiWeatherSunny,
        "motion"           => Rez.Drawables.MdiPlay,
        "door"             => Rez.Drawables.MdiDoor,
        "window"           => Rez.Drawables.MdiWindow,
        "garage_door"      => Rez.Drawables.MdiGarage,
        "lock"             => Rez.Drawables.MdiKey,
        "smoke"            => Rez.Drawables.MdiFire,
        "heat"             => Rez.Drawables.MdiFire,
        "moisture"         => Rez.Drawables.MdiWater,
        "plug"             => Rez.Drawables.MdiPowerPlug,
        "outlet"           => Rez.Drawables.MdiPowerPlug,
        "light"            => Rez.Drawables.MdiLightbulb,
        "tv"               => Rez.Drawables.MdiTelevision,
        "speaker"          => Rez.Drawables.MdiSpeaker,
        "vacuum"           => Rez.Drawables.MdiVacuum,
      };
    }
    return _deviceClassMap;
  }

  // Resolves an entity's icon to a drawable. Priority:
  //   1. the explicit Home Assistant `icon` attribute (mdi:*), then
  //   2. the entity's `device_class` (the icon HA's own UI would show), then
  //   3. null — callers fall back to the type/state icon.
  function getMdiIconDrawable(entity) {
    var icon = entity.getIcon();

    if (icon != null) {
      var mdiId = getMdiMap().get(icon);
      if (mdiId != null) {
        return WatchUi.loadResource(mdiId);
      }
    }

    // No custom icon (or it isn't bundled): fall back to the device class.
    var deviceClass = entity.getDeviceClass();
    if (deviceClass != null) {
      var dcId = getDeviceClassMap().get(deviceClass);
      if (dcId != null) {
        return WatchUi.loadResource(dcId);
      }
    }

    return null;
  }

  // Returns the tint color for an entity's state icon, or null when the state
  // has no state-specific tint (sensors, scene/script/button triggers and
  // transitional states keep their current rendering).
  //
  // Two palettes are used depending on the "coloredIcons" setting:
  //  - colored (true):  Home Assistant style colors.
  //  - mono    (false): white brightness only, for monochrome/limited displays.
  //
  // State mapping:
  //   on/open      -> on-highlight  (#FFC010 / 100% white)
  //   off/closed   -> off-dim       (#46729D / 50% white)
  //   unlocked     -> alert red     (#F44539 / 50% white)
  //   locked       -> secure green  (#4DAD51 / 100% white)
  //
  // The color is applied at draw time via Dc.drawBitmap2(:tintColor), so the
  // cached drawables do not need to change.
  function getIconTintColor(entity) {
    var state = entity.getState();

    // "coloredIcons" has a default in properties.xml, so it is never null.
    var colored = App.Properties.getValue("coloredIcons");

    if (state == Hass.STATE_LOCKED) {
      return colored ? 0x4DAD51 : 0xFFFFFF; // secure: green / full white
    }
    if (state == Hass.STATE_UNLOCKED) {
      return colored ? 0xF44539 : 0x808080; // alert: red / 50% white
    }
    if (state == Hass.STATE_ON || state == Hass.STATE_OPEN) {
      return colored ? 0xFFC010 : 0xFFFFFF; // on-highlight
    }
    if (state == Hass.STATE_OFF || state == Hass.STATE_CLOSED) {
      return colored ? 0x46729D : 0x808080; // off-dim
    }

    return null;
  }

  (:glance)
  function isRectangularScreen() {
    var deviceSettings = System.getDeviceSettings();
    if (deviceSettings has :screenShape) {
      return deviceSettings.screenShape == System.SCREEN_SHAPE_RECTANGLE;
    }
    return false;
  }
}