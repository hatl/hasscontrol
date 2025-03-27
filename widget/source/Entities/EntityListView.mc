using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.Timer;
using Hass;

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

    if (_mIndex >= _mEntities.size()) {
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
      throw new Toybox.Lang.InvalidValueException();
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
    App.getApp().menu.showRootMenu();

    return true;
  }

  function onSelect() {
    var entity = _mController.getCurrentEntity();

    if (entity != null) {
      _mController.toggleEntity(entity);
    } else {
      App.getApp().menu.showRootMenu();
      App.getApp().viewController.showError("No entity to toggle,\nplease refresh group\nfrom settings");
    }

    return true;
  }

  function onNextPage() {
    var index = _mController.getIndex();
    var count = _mController.getCount();

    index += 1;

    if (index > count - 1) {
      index = 0;
    }

    _mController.setIndex(index);
    Ui.requestUpdate();

    return true;
  }

  function onPreviousPage() {
    var index = _mController.getIndex();
    var count = _mController.getCount();

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

  function initialize(controller) {
    View.initialize();
    _mController = controller;
    _mLastIndex = null;
    _mTimer = new Timer.Timer();
    _mTimerActive = false;
    _mShowBar = false;
  }

  function onLayout(dc) {
    setLayout([]);
  }

  function onShow() {
    if (App.Properties.getValue("refresh")) {
      Hass.refreshAllEntities(true);
    }
  }

  function drawNoEntityText(dc) {
    var vh = dc.getHeight();
    var vw = dc.getWidth();

    var cvh = vh / 2;
    var cvw = vw / 2;

    var SmileySad = Ui.loadResource(Rez.Drawables.SmileySad);

    dc.drawBitmap(
      cvw - (SmileySad.getHeight() / 2),
      (vh * 0.3) - (SmileySad.getHeight() / 2),
      SmileySad
    );

    var font = Graphics.FONT_MEDIUM;
    var text = Ui.loadResource(Rez.Strings.NoEntities);
    text = Graphics.fitTextToArea(text, font, vw * 0.9, vh * 0.9, true);

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.drawText(cvh, cvw, font, text, Graphics.TEXT_JUSTIFY_CENTER);
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

    dc.drawText(cvh, cvw * 1.1, font, text, Graphics.TEXT_JUSTIFY_CENTER);
  }

  function drawIcon(dc, entity) {
    var vh = dc.getHeight();
    var vw = dc.getWidth();

    var cvw = vw / 2;

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
      if (sensorClass == Hass.SENSOR_TEMPERATUE) {
        drawable = WatchUi.loadResource(Rez.Drawables.Temperature);
      } else if (sensorClass == Hass.SENSOR_HUMIDITY) {
        drawable = WatchUi.loadResource(Rez.Drawables.Humidity);
      } else if (sensorClass == Hass.SENSOR_CO2) {
        drawable = WatchUi.loadResource(Rez.Drawables.CO2);
      } else if (sensorClass == Hass.SENSOR_PM) {
        drawable = WatchUi.loadResource(Rez.Drawables.AirPM);
      } else if (sensorClass == Hass.SENSOR_OTHER) {
        drawable = WatchUi.loadResource(Rez.Drawables.Unknown);
      }
    }

    if (drawable == null) {
        drawable = WatchUi.loadResource(Rez.Drawables.Unknown);
    }

    dc.drawBitmap(
      cvw - (drawable.getHeight() / 2),
      (vh * 0.3) - (drawable.getHeight() / 2),
      drawable
    );
  }

  function drawPageBar(dc) {
    var numEntities = _mController.getCount();
    var currentIndex = _mController.getIndex();

    var vh = dc.getHeight();
    var vw = dc.getWidth();

    var cvh = vh / 2;
    var cvw = vw / 2;

    var radius = cvh - 10;

    var attr = Graphics.ARC_COUNTER_CLOCKWISE;

    var padding = 1;
    var topDegreeStart = 130;
    var bottomDegreeEnd = 230;

    var barSize = ((bottomDegreeEnd - padding) - (topDegreeStart + padding)) / numEntities;

    var barStart = (topDegreeStart + padding) + (barSize * currentIndex);

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.setPenWidth(10);
    dc.drawArc(cvw, cvh, radius, attr, topDegreeStart, bottomDegreeEnd);

    dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
    dc.setPenWidth(6);
    dc.drawArc(cvw, cvh, radius, attr, barStart, barStart + barSize);
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