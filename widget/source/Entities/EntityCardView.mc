using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Hass;
using Utils;

// Classic single-entity view (pre-redesign layout):
// one full-screen card per entity with a centered icon and the
// entity name below it.  Reuses EntityListController and
// EntityListDelegate from EntityListView.mc for navigation and
// input handling.
class EntityCardView extends Ui.View {
  hidden var _mController;
  hidden var _mLastIndex;
  hidden var _mShowBar;

  function initialize(controller) {
    View.initialize();
    _mController = controller;
    _mLastIndex = null;
    _mShowBar = false;
  }

  function onLayout(dc) {
    setLayout([]);
  }

  function onShow() {
    if (Utils.getProperty("refresh", false)) {
      Hass.refreshAllEntities(true);
    }
  }

  function onHide() {
    // Drop the pending bar hide so it cannot fire on a view that is gone.
    // The bar goes with it: left on, it would stay up for good, as nothing
    // reschedules its hide until the index changes again.
    Scheduler.cancel(:pageBar);
    _mShowBar = false;
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
    if (entity.getState() == Hass.STATE_SENSOR && useFixedTwoLineSensorLayout()) {
      drawSensorEntityText(dc, entity);
      return;
    }

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

  // Only affects the lowmem tier (see useFixedTwoLineSensorLayout()) - the
  // general loop above lets a long name and the "\n"-joined sensor value
  // wrap freely as one block of text, so a long enough name can consume
  // both available lines by itself and push the value off screen
  // entirely. Fitting the name and value to one truncated line each,
  // independently, guarantees the value is always shown.
  hidden function drawSensorEntityText(dc, entity) {
    var vh = dc.getHeight();
    var vw = dc.getWidth();
    var fontWidth = vw * 0.80;
    var gap = 4;

    var font = Graphics.FONT_TINY;
    var fontH = dc.getFontHeight(font);

    var name = Graphics.fitTextToArea(entity.getRawName(), font, fontWidth, fontH, true);
    var value = Graphics.fitTextToArea(entity.getDisplayValue(), font, fontWidth, fontH, true);

    // Each line is explicitly vertically centered on its own Y (rather
    // than relying on dc.drawText()'s default anchor for an un-justified
    // Y, which the general loop above gets away with for a single line)
    // so the two lines land symmetrically above/below the same center
    // point the general loop uses, regardless of that default's exact
    // behavior.
    var halfPitch = (fontH + gap) / 2;
    var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

    // Nudged down slightly from the general loop's center point - the
    // icon above (see drawIcon()) otherwise overlaps the top line.
    var verticalNudge = vh * 0.04;

    if (Utils.isRectangularScreen()) {
      var centerY = (vh / 2) + verticalNudge;
      dc.drawText(vw / 2, centerY - halfPitch, font, name, justify);
      dc.drawText(vw / 2, centerY + halfPitch, font, value, justify);
    } else {
      // Matches the round-screen center point the general loop above uses.
      var centerY = ((vw / 2) * 1.1) + verticalNudge;
      dc.drawText(vh / 2, centerY - halfPitch, font, name, justify);
      dc.drawText(vh / 2, centerY + halfPitch, font, value, justify);
    }
  }

  (:fullmem)
  hidden function useFixedTwoLineSensorLayout() {
    return false;
  }

  (:lowmem)
  hidden function useFixedTwoLineSensorLayout() {
    return true;
  }

  // TYPE_SELECT (select and input_select share this type)/TYPE_INPUT_NUMBER
  // (input_number and number)/TYPE_DATETIME (input_datetime, date, time and
  // datetime) entities exist on every tier (see
  // Entity.detectExtendedType()), but their distinctive icon is
  // fullmem-only. The (:lowmem) stub returns null so that build never
  // loads the mdi bitmaps below (it still carries them: resources are not
  // filtered by annotations) - drawIcon()'s null-drawable fallback then
  // draws Rez.Drawables.Unknown, the same generic icon a TYPE_SENSOR with
  // SENSOR_OTHER gets. Any other type gets null here as well, and with it
  // the same fallback.
  (:fullmem)
  hidden function fullmemOnlyIcon(entity) {
    var type = entity.getType();

    if (type == Hass.TYPE_SELECT) {
      return WatchUi.loadResource(Rez.Drawables.MdiFormatListBulleted);
    }
    if (type == Hass.TYPE_INPUT_NUMBER) {
      return WatchUi.loadResource(Rez.Drawables.MdiNumeric);
    }
    if (type == Hass.TYPE_DATETIME) {
      return WatchUi.loadResource(EntityCardView.dateTimeIcon(entity));
    }
    return null;
  }

  (:lowmem)
  hidden function fullmemOnlyIcon(entity) {
    return null;
  }

  // A date/time entity's icon, by what it holds: mdi:calendar for a date,
  // mdi:clock-outline for a time, mdi:calendar-clock for both. Shared with
  // EntityListView.
  (:fullmem)
  static function dateTimeIcon(entity) {
    var mode = DateTimeValue.modeOf(entity);

    if (mode == DateTimeValue.MODE_DATE) {
      return Rez.Drawables.MdiCalendar;
    }
    if (mode == DateTimeValue.MODE_TIME) {
      return Rez.Drawables.MdiClockOutline;
    }
    return Rez.Drawables.MdiCalendarClock;
  }

  function drawIcon(dc, entity) {
    var vh = dc.getHeight();
    var vw = dc.getWidth();

    var cvw = vw / 2;

    // Adjust icon position for rectangular screens
    var iconVertPosition = Utils.isRectangularScreen() ? 0.25 : 0.3;

    // A Home Assistant `icon` attribute (mdi:*) that we have a matching bitmap
    // for takes precedence; otherwise fall back to the type/state icon below.
    var drawable = Utils.getMdiIconDrawable(entity);

    var type = entity.getType();
    var state = entity.getState();
    var sensorClass = entity.getSensorClass();

    if (drawable == null) {
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
    } else {
      drawable = fullmemOnlyIcon(entity);
    }
    }

    if (drawable == null) {
        drawable = WatchUi.loadResource(Rez.Drawables.Unknown);
    }

    var iconX = cvw - (drawable.getHeight() / 2);
    var iconY = (vh * iconVertPosition) - (drawable.getHeight() / 2);
    Utils.drawIcon(dc, iconX, iconY, drawable, Utils.getIconTintColor(entity));
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
    _mShowBar = false;
    Ui.requestUpdate();
  }

  // Shows the page bar on every index change and hides it a second after
  // the last one. _mTimerActive used to guard this, but nothing ever set it,
  // so every scroll start()ed the bar timer again while it was still
  // running - which may (undocumented) raise "Too Many Timers Error" by
  // itself, and the bar timer was one of the app's timers behind issue
  // #101 anyway. Rescheduling the keyed job just moves the hide.
  function shouldShowBar() {
    var index = _mController.getIndex();

    if (_mLastIndex != index) {
      _mShowBar = true;
      Scheduler.schedule(:pageBar, method(:onTimerDone), 1000);
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

    Utils.logMem("card:beforeDraw", null);
    drawEntityText(dc, entity);
    drawIcon(dc, entity);
    Utils.logMem("card:afterDraw", null);

    if (_mShowBar) {
      drawPageBar(dc);
    }

    return;
  }
}
