using Toybox.Application as App;
using Toybox.StringUtil;
using Toybox.Lang;
using Toybox.System;

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

  (:glance)
  function isRectangularScreen() {
    var deviceSettings = System.getDeviceSettings();
    if (deviceSettings has :screenShape) {
      return deviceSettings.screenShape == System.SCREEN_SHAPE_RECTANGLE;
    }
    return false;
  }
}