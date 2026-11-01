using Toybox.Application as App;
using Toybox.Graphics;
using Toybox.System;
using Toybox.WatchUi as Ui;
using Hass;
using Utils;

// The editor for date/time entities (TYPE_DATETIME: input_datetime, date,
// time, datetime), laid out like InputNumberEditView: a "+" band at the top,
// a "-" band at the bottom, the entity's name below the "+" band, and the
// value between them in one or two rows - the date ("2026-11-01") and the
// time ("14:30", or "2:30 PM" with an AM/PM field of its own on a watch set
// to the 12-hour clock), whichever the entity has. One field at a time is
// active, drawn inverted.
//
//  * up/down (and the bands, and swipes as in the number editor) step the
//    active field by one: month, day, hour, minute and AM/PM wrap around,
//    the year stays within DateTimeValue.YEAR_MIN..YEAR_MAX. Holding up or
//    down repeats the step.
//  * select moves on to the next field, and on the last one sends the
//    value. Back goes to the previous field, and on the first one leaves
//    without sending anything.
//  * a tap on a field makes it the active one; a tap on the active field
//    acts as select, so that touch-only watches can move on and send.
//
// :fullmem only, see monkey.jungle - like InputNumberEditView, it is opened
// from EntityListDelegate.handleExtendedEntityTypes() only.
(:fullmem)
class DateTimeEditView extends Ui.View {
  // A field: the first five are indexes into the value (DateTimeValue.YEAR
  // ... MINUTE). AM/PM is the half of the day of the hour, a field of its
  // own on a 12-hour watch.
  static const FIELD_AMPM = 5;

  hidden var _mEntity;
  hidden var _mValues;    // [year, month, day, hour (0-23), minute], see DateTimeValue
  hidden var _mFields;    // the fields the entity has, in the order they are edited
  hidden var _mActive;    // index into _mFields
  hidden var _mRows;      // per row: its items, a field (Number) or a separator (String)
  hidden var _m24Hour;
  hidden var _mHeight;    // last dc.getHeight() from onUpdate(); see getHeight()

  // The layout, worked out by the first onUpdate(): the font, its height,
  // the padding around a field and every field's width (index: field).
  hidden var _mFont;
  hidden var _mFontHeight;
  hidden var _mPad;
  hidden var _mSlotWidths;

  // Per field, [left, top, right, bottom] as last drawn - see fieldAt().
  hidden var _mBoxes;

  function initialize(entity) {
    View.initialize();

    _mEntity = entity;
    _mValues = DateTimeValue.initialFields(entity);
    _m24Hour = System.getDeviceSettings().is24Hour;
    _mActive = 0;
    _mHeight = 0;
    _mFont = null;
    _mFontHeight = 0;
    _mPad = 0;
    _mSlotWidths = null;
    _mBoxes = new [FIELD_AMPM + 1];

    var mode = DateTimeValue.modeOf(entity);

    _mFields = [];
    _mRows = [];

    if ((mode & DateTimeValue.MODE_DATE) != 0) {
      _mFields.addAll([DateTimeValue.YEAR, DateTimeValue.MONTH, DateTimeValue.DAY]);
      _mRows.add([DateTimeValue.YEAR, "-", DateTimeValue.MONTH, "-", DateTimeValue.DAY]);
    }

    if ((mode & DateTimeValue.MODE_TIME) != 0) {
      var row = [DateTimeValue.HOUR, ":", DateTimeValue.MINUTE];

      _mFields.addAll([DateTimeValue.HOUR, DateTimeValue.MINUTE]);

      if (!_m24Hour) {
        row.addAll([" ", FIELD_AMPM]);
        _mFields.add(FIELD_AMPM);
      }

      _mRows.add(row);
    }
  }

  function onLayout(dc) {
    setLayout([]);
  }

  // A key repeat must not outlive the view - see DateTimeEditDelegate.
  function onHide() {
    Scheduler.cancel(:fieldRepeat);
  }

  // The value to send: [year, month, day, hour (0-23), minute], local time.
  function getValues() {
    return _mValues;
  }

  function getActive() {
    return _mActive;
  }

  function setActive(index) {
    _mActive = index;
  }

  function isFirstField() {
    return _mActive == 0;
  }

  function isLastField() {
    return _mActive == _mFields.size() - 1;
  }

  // The delegate's onTap() hit-tests the bands against this rather than
  // device settings, so the tappable zones always match what onUpdate()
  // drew (see InputNumberEditView.getHeight()).
  function getHeight() {
    return _mHeight;
  }

  // Steps the active field by `delta` (+1 or -1).
  function step(delta) {
    var field = _mFields[_mActive];

    if (field == DateTimeValue.YEAR) {
      var year = _mValues[DateTimeValue.YEAR] + delta;

      if (year >= DateTimeValue.YEAR_MIN && year <= DateTimeValue.YEAR_MAX) {
        _mValues[DateTimeValue.YEAR] = year;
      }
      clampDay();
    } else if (field == DateTimeValue.MONTH) {
      _mValues[DateTimeValue.MONTH] = wrap(_mValues[DateTimeValue.MONTH] + delta, 1, 12);
      clampDay();
    } else if (field == DateTimeValue.DAY) {
      var days = DateTimeValue.daysInMonth(_mValues[DateTimeValue.YEAR], _mValues[DateTimeValue.MONTH]);
      _mValues[DateTimeValue.DAY] = wrap(_mValues[DateTimeValue.DAY] + delta, 1, days);
    } else if (field == DateTimeValue.HOUR) {
      var hour = _mValues[DateTimeValue.HOUR];

      if (_m24Hour) {
        _mValues[DateTimeValue.HOUR] = wrap(hour + delta, 0, 23);
      } else {
        // 1-12 within the same half of the day, which only the AM/PM field
        // changes: 11 -> 12 -> 1. 12 is held as 0 (12 AM is 00:xx).
        var half = hour >= 12 ? 12 : 0;
        _mValues[DateTimeValue.HOUR] = wrap(hour - half + delta, 0, 11) + half;
      }
    } else if (field == DateTimeValue.MINUTE) {
      _mValues[DateTimeValue.MINUTE] = wrap(_mValues[DateTimeValue.MINUTE] + delta, 0, 59);
    } else {
      _mValues[DateTimeValue.HOUR] = (_mValues[DateTimeValue.HOUR] + 12) % 24;
    }
  }

  // Moves the active field by `delta` (+1 or -1); the delegate stops at the
  // first and the last one.
  function moveActive(delta) {
    var index = _mActive + delta;

    if (index >= 0 && index < _mFields.size()) {
      _mActive = index;
    }
  }

  // 31 January -> February shows the 28th or 29th right away.
  hidden function clampDay() {
    var days = DateTimeValue.daysInMonth(_mValues[DateTimeValue.YEAR], _mValues[DateTimeValue.MONTH]);

    if (_mValues[DateTimeValue.DAY] > days) {
      _mValues[DateTimeValue.DAY] = days;
    }
  }

  // One step past either end wraps to the other one.
  hidden function wrap(value, low, high) {
    if (value > high) {
      return low;
    }
    if (value < low) {
      return high;
    }
    return value;
  }

  // The index into the fields of the one drawn at (x, y), or -1. A few
  // pixels around a field count too, as fingers are wide and the fields
  // small; where that reaches two of them, the nearer one wins.
  function fieldAt(x, y) {
    var margin = _mFontHeight / 4;
    var best = -1;
    var bestDistance = null;

    for (var i = 0; i < _mFields.size(); i++) {
      var box = _mBoxes[_mFields[i]];

      if (box == null) {
        continue;
      }

      if (x < box[0] - margin || x > box[2] + margin || y < box[1] - margin || y > box[3] + margin) {
        continue;
      }

      var dx = x - (box[0] + box[2]) / 2;
      var dy = y - (box[1] + box[3]) / 2;
      var distance = dx * dx + dy * dy;

      if (bestDistance == null || distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }

    return best;
  }

  // The number editor's bands (InputNumberEditView.drawZone()): the same
  // size and colour, so that touch works the same in both. The glyph's
  // background is left transparent, see there.
  hidden function drawZone(dc, y, height, vw, glyph) {
    var bgColor = InputNumberEditView.ZONE_COLOR;
    dc.setColor(bgColor, bgColor);
    dc.fillRectangle(0, y, vw, height);

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
    dc.drawText(vw / 2, y + height / 2, Graphics.FONT_NUMBER_MILD, glyph, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
  }

  function onUpdate(dc) {
    View.onUpdate(dc);

    var vh = dc.getHeight();
    var vw = dc.getWidth();
    var cvw = vw / 2;
    var zoneHeight = vh * InputNumberEditView.ZONE_FRACTION;
    _mHeight = vh;

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.clear();

    drawZone(dc, 0, zoneHeight, vw, "+");
    drawZone(dc, vh - zoneHeight, zoneHeight, vw, "-");

    // Name: as in the number editor - one line, small font,
    // ellipsis-truncated rather than wrapped, below the "+" band.
    var nameFont = Graphics.FONT_XTINY;
    var nameFontH = dc.getFontHeight(nameFont);
    var namePadding = 6;
    var nameText = Graphics.fitTextToArea(_mEntity.getRawName(), nameFont, vw * 0.9, nameFontH, true);
    var nameY = zoneHeight + namePadding;

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.drawText(cvw, nameY, nameFont, nameText, Graphics.TEXT_JUSTIFY_CENTER);

    // The rows: centered in whatever space is left below the name.
    var valueTop = nameY + nameFontH + namePadding;
    var valueBottom = vh - zoneHeight;

    if (_mFont == null) {
      layOut(dc, vw * 0.9, valueBottom - valueTop);
    }

    var rowCount = _mRows.size();
    var blockHeight = rowCount * _mFontHeight + (rowCount - 1) * _mPad;
    var rowY = valueTop + (valueBottom - valueTop - blockHeight) / 2 + _mFontHeight / 2;

    for (var i = 0; i < rowCount; i++) {
      drawRow(dc, _mRows[i], cvw, rowY);
      rowY += _mFontHeight + _mPad;
    }
  }

  // Picks the largest font at which the widest row fits `maxWidth` and all
  // rows fit `maxHeight`: FONT_NUMBER_MEDIUM, FONT_MEDIUM or FONT_SMALL -
  // the number font only without an AM/PM field, as it has no letters.
  // Measured with "0" for every digit, so that the layout does not shift as
  // the value changes.
  hidden function layOut(dc, maxWidth, maxHeight) {
    var fonts = _mFields.size() > 0 && _mFields[_mFields.size() - 1] == FIELD_AMPM
      ? [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL]
      : [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL];

    for (var i = 0; i < fonts.size(); i++) {
      measure(dc, fonts[i]);

      if (i == fonts.size() - 1) {
        break;
      }

      var rowCount = _mRows.size();
      var fitsHeight = rowCount * _mFontHeight + (rowCount - 1) * _mPad <= maxHeight;
      var fitsWidth = true;

      for (var r = 0; r < rowCount; r++) {
        if (rowWidth(dc, _mRows[r]) > maxWidth) {
          fitsWidth = false;
        }
      }

      if (fitsWidth && fitsHeight) {
        break;
      }
    }
  }

  // The layout for `font`: its height, the padding around a field, and
  // every field's width.
  hidden function measure(dc, font) {
    _mFont = font;
    _mFontHeight = dc.getFontHeight(font);
    _mPad = _mFontHeight / 10;

    if (_mPad < 2) {
      _mPad = 2;
    }

    var twoDigits = dc.getTextWidthInPixels("00", font);
    var am = dc.getTextWidthInPixels("AM", font);
    var pm = dc.getTextWidthInPixels("PM", font);

    _mSlotWidths = [
      dc.getTextWidthInPixels("0000", font), // year
      twoDigits,                             // month
      twoDigits,                             // day
      twoDigits,                             // hour
      twoDigits,                             // minute
      am > pm ? am : pm                      // AM/PM
    ];

    for (var i = 0; i < _mSlotWidths.size(); i++) {
      _mSlotWidths[i] += 2 * _mPad;
    }
  }

  hidden function rowWidth(dc, row) {
    var width = 0;

    for (var i = 0; i < row.size(); i++) {
      width += row[i] instanceof String ? dc.getTextWidthInPixels(row[i], _mFont) : _mSlotWidths[row[i]];
    }

    return width;
  }

  // Draws one row centered on (centerX, centerY), the active field as a
  // white rounded rectangle with black text - unmistakable on MIP and
  // AMOLED screens alike - and notes where each field went.
  hidden function drawRow(dc, row, centerX, centerY) {
    var x = centerX - rowWidth(dc, row) / 2;
    var top = centerY - _mFontHeight / 2;
    var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
    var activeField = _mFields[_mActive];

    for (var i = 0; i < row.size(); i++) {
      var item = row[i];

      if (item instanceof String) {
        var separatorWidth = dc.getTextWidthInPixels(item, _mFont);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + separatorWidth / 2, centerY, _mFont, item, justify);
        x += separatorWidth;
        continue;
      }

      var width = _mSlotWidths[item];

      if (item == activeField) {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillRoundedRectangle(x, top, width, _mFontHeight, _mPad * 2);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
      } else {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
      }

      dc.drawText(x + width / 2, centerY, _mFont, fieldText(item), justify);
      _mBoxes[item] = [x, top, x + width, top + _mFontHeight];
      x += width;
    }
  }

  hidden function fieldText(field) {
    if (field == FIELD_AMPM) {
      return _mValues[DateTimeValue.HOUR] < 12 ? "AM" : "PM";
    }

    var value = _mValues[field];

    if (field == DateTimeValue.YEAR) {
      return value.format("%04d");
    }
    if (field == DateTimeValue.HOUR && !_m24Hour) {
      return DateTimeValue.hour12(value).toString();
    }
    return value.format("%02d");
  }
}

(:fullmem)
class DateTimeEditDelegate extends Ui.BehaviorDelegate {
  // Holding up or down repeats the step: first after REPEAT_DELAY ms, then
  // every REPEAT_INTERVAL ms until the button is released - but no more
  // than REPEAT_MAX times, should the release never arrive.
  static const REPEAT_DELAY = 400;
  static const REPEAT_INTERVAL = 150;
  static const REPEAT_MAX = 60;

  hidden var _mEntity;
  hidden var _mView;
  // Set once confirm() or onBack() pops this view: input still queued (a
  // fast double tap) must not act on it again - see
  // InputNumberEditDelegate._mDismissed.
  hidden var _mDismissed;
  hidden var _mRepeatDelta;  // +1/-1 while up/down is held, 0 otherwise
  hidden var _mRepeatCount;

  function initialize(entity, view) {
    BehaviorDelegate.initialize();
    _mEntity = entity;
    _mView = view;
    _mDismissed = false;
    _mRepeatDelta = 0;
    _mRepeatCount = 0;
  }

  hidden function step(delta) {
    if (!_mDismissed) {
      _mView.step(delta);
      Ui.requestUpdate();
    }
    return true;
  }

  // The up button (and a swipe down, see onSwipe()) steps the active field
  // up, the down button down - as in InputNumberEditDelegate.
  function onPreviousPage() {
    App.getApp().resetInactivityTimer();
    return step(1);
  }

  function onNextPage() {
    App.getApp().resetInactivityTimer();
    return step(-1);
  }

  // Select: the next field, or on the last one, send.
  hidden function next() {
    if (_mDismissed) {
      return true;
    }

    if (_mView.isLastField()) {
      return confirm();
    }

    _mView.moveActive(1);
    Ui.requestUpdate();
    return true;
  }

  hidden function confirm() {
    if (_mDismissed) {
      return true;
    }
    _mDismissed = true;
    stopRepeat();
    // Pop first: setDateTimeValue() pushes a view of its own (the loader,
    // or the Wi-Fi/LTE prompt), which a later popView() would take off
    // again instead of this one.
    Ui.popView(Ui.SLIDE_IMMEDIATE);
    Hass.setDateTimeValue(_mEntity, _mView.getValues());
    return true;
  }

  // Returning false lets BehaviorDelegate fall back to onKey() (the select
  // button) or onTap() (touch) below - see InputNumberEditDelegate.onSelect().
  function onSelect() {
    return false;
  }

  function onKey(keyEvent) {
    if (keyEvent.getKey() == Ui.KEY_ENTER) {
      stopRepeat();
      App.getApp().resetInactivityTimer();
      return next();
    }
    return false;
  }

  // Back: the previous field, or on the first one, leave without sending.
  function onBack() {
    stopRepeat();

    if (_mDismissed) {
      return true;
    }

    App.getApp().resetInactivityTimer();

    if (!_mView.isFirstField()) {
      _mView.moveActive(-1);
      Ui.requestUpdate();
      return true;
    }

    _mDismissed = true;
    Ui.popView(Ui.SLIDE_IMMEDIATE);
    return true;
  }

  // Touch: the bands step the active field as in InputNumberEditDelegate;
  // in between, a tap on a field makes it the active one, and a tap on the
  // active one acts as select. Every tap is taken, also one that hits no
  // field: an unhandled one can fall through to the system, which on some
  // devices leaves the app (see InputNumberEditDelegate.onTap()).
  function onTap(clickEvent) {
    App.getApp().resetInactivityTimer();
    stopRepeat();

    var xy = clickEvent.getCoordinates();
    var vh = _mView.getHeight();
    var zoneHeight = vh * InputNumberEditView.ZONE_FRACTION;

    if (xy[1] < zoneHeight) {
      return step(1);
    }
    if (xy[1] > vh - zoneHeight) {
      return step(-1);
    }

    var index = _mView.fieldAt(xy[0], xy[1]);

    if (index < 0 || _mDismissed) {
      return true;
    }

    if (index == _mView.getActive()) {
      return next();
    }

    _mView.setActive(index);
    Ui.requestUpdate();
    return true;
  }

  // Dragging from bottom to top steps up, top to bottom down - mapped
  // exactly as in InputNumberEditDelegate.onSwipe(), which explains why
  // SWIPE_UP means down.
  function onSwipe(swipeEvent) {
    App.getApp().resetInactivityTimer();
    stopRepeat();

    var dir = swipeEvent.getDirection();

    if (dir == Ui.SWIPE_UP) {
      return step(-1);
    }
    if (dir == Ui.SWIPE_DOWN) {
      return step(1);
    }
    return false;
  }

  // Up/down pressed: the press steps once by itself (onPreviousPage() or
  // onNextPage()); this only starts the repeat for as long as the button is
  // held. Connect IQ delivers onKeyPressed()/onKeyReleased() to every
  // InputDelegate, BehaviorDelegate included (API 1.1.2). Not consumed, so
  // that the behaviour still follows.
  function onKeyPressed(keyEvent) {
    var key = keyEvent.getKey();

    if (key == Ui.KEY_UP || key == Ui.KEY_DOWN) {
      _mRepeatDelta = key == Ui.KEY_UP ? 1 : -1;
      _mRepeatCount = 0;
      Scheduler.schedule(:fieldRepeat, method(:onRepeat), REPEAT_DELAY);
    }

    return false;
  }

  // Any release ends the repeat: where holding up opens the menu, the
  // release may well be reported for another key.
  function onKeyReleased(keyEvent) {
    stopRepeat();
    return false;
  }

  // Holding up opens the menu on some watches - that, too, ends the repeat.
  // Not consumed, as in the number editor.
  function onMenu() {
    stopRepeat();
    return false;
  }

  // The :fieldRepeat job.
  function onRepeat() {
    if (_mDismissed || _mRepeatDelta == 0 || _mRepeatCount >= REPEAT_MAX) {
      _mRepeatDelta = 0;
      return;
    }

    _mRepeatCount++;
    App.getApp().resetInactivityTimer();
    step(_mRepeatDelta);
    Scheduler.schedule(:fieldRepeat, method(:onRepeat), REPEAT_INTERVAL);
  }

  hidden function stopRepeat() {
    _mRepeatDelta = 0;
    Scheduler.cancel(:fieldRepeat);
  }
}
