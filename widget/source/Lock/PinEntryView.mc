using Toybox.Application as App;
using Toybox.Attention;
using Toybox.Graphics;
using Toybox.System;
using Toybox.WatchUi as Ui;
using Utils;

// PIN entry modelled on the Garmin Pay wallet's passcode screen: four
// masked slots fill up as digits go in, and the PIN is checked as soon as
// the fourth one is in - there is no OK step.
//
//  * Touch screens get the wallet's keypad: tap the digits. The buttons
//    work too - up/down move a focus ring over the keys, select presses the
//    focused one - for watches whose touch screen is switched off.
//  * Button watches get the wallet's digit wheel: up/down roll it, select
//    takes the digit. The wheel goes back to 0 after each digit, so it
//    never shows one that was entered.
//
// Back deletes the last digit, and leaves the screen when there is none.
// Wrong entries and the lock-out are handled by LockConfirm.
//
// :fullmem only, see monkey.jungle.
(:fullmem)
class PinEntryView extends Ui.View {
  // What keyAt() and getSelectedKey() return besides a digit 0-9.
  static const KEY_DELETE = -2;

  // The keypad is 3 columns by 4 rows, cell = row * 3 + column: cells 0-8
  // hold 1-9, and the bottom row is [blank] [0] [delete].
  static const CELL_BLANK = 9;
  static const CELL_COUNT = 12;

  hidden var _mTitle;   // e.g. "Unlock Front Door"
  hidden var _mKeypad;  // true: keypad, false: digit wheel
  hidden var _mCount;   // digits entered so far
  hidden var _mWheel;   // digit on the wheel
  hidden var _mFocus;   // keypad cell with the focus ring, -1 for none
  hidden var _mMessage; // shown instead of "Enter PIN" after a wrong entry
  hidden var _mDetail;  // shown instead of the title after a wrong entry

  // Keypad geometry of the last onUpdate(), for keyAt().
  hidden var _mGridLeft;
  hidden var _mGridTop;
  hidden var _mCellWidth;
  hidden var _mCellHeight;

  function initialize(title) {
    View.initialize();
    _mTitle = title;
    _mKeypad = System.getDeviceSettings().isTouchScreen;
    _mCount = 0;
    _mWheel = 0;
    _mFocus = -1;
    _mMessage = null;
    _mDetail = null;
    _mGridLeft = null;
    _mGridTop = null;
    _mCellWidth = null;
    _mCellHeight = null;
  }

  function onLayout(dc) {
    setLayout([]);
  }

  function setCount(count) {
    _mCount = count;
  }

  function setMessage(message, detail) {
    _mMessage = message;
    _mDetail = detail;
  }

  function resetWheel() {
    _mWheel = 0;
  }

  // Up/down: roll the wheel, or move the keypad's focus ring (which up
  // moves back towards 1, like reading order).
  function step(up) {
    if (!_mKeypad) {
      _mWheel = (_mWheel + (up ? 1 : 9)) % 10;
      return;
    }

    // -1 is added as CELL_COUNT - 1, keeping % on positive numbers.
    var delta = up ? CELL_COUNT - 1 : 1;

    _mFocus = _mFocus < 0 ? 0 : (_mFocus + delta) % CELL_COUNT;

    if (_mFocus == CELL_BLANK) {
      _mFocus = (_mFocus + delta) % CELL_COUNT;
    }
  }

  // The key the select button presses: the wheel's digit, or the focused
  // keypad key - null while no key has the focus yet.
  function getSelectedKey() {
    if (!_mKeypad) {
      return _mWheel;
    }

    if (_mFocus < 0) {
      return null;
    }

    return cellKey(_mFocus);
  }

  // The keypad key at a screen position, or null. The whole cell counts,
  // not just the circle drawn in it.
  function keyAt(x, y) {
    if (!_mKeypad || _mCellWidth == null || x < _mGridLeft || y < _mGridTop) {
      return null;
    }

    var column = ((x - _mGridLeft) / _mCellWidth).toNumber();
    var row = ((y - _mGridTop) / _mCellHeight).toNumber();

    if (column > 2 || row > 3) {
      return null;
    }

    return cellKey(row * 3 + column);
  }

  hidden function cellKey(cell) {
    if (cell < CELL_BLANK) {
      return cell + 1;
    }
    if (cell == 10) {
      return 0;
    }
    if (cell == 11) {
      return KEY_DELETE;
    }
    return null;
  }

  function onUpdate(dc) {
    View.onUpdate(dc);

    var width = dc.getWidth();
    var height = dc.getHeight();

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.clear();

    if (dc has :setAntiAlias) {
      dc.setAntiAlias(true);
    }

    // There is no reliable way to tell a color display from a monochrome
    // one, so the "Colored icons" setting decides here too (see README).
    var colored = Utils.getProperty("coloredIcons", false) == true;

    drawHeader(dc, width, height, colored);

    if (_mKeypad) {
      drawKeypad(dc, width, height, colored);
    } else {
      drawWheel(dc, width, height, colored);
    }
  }

  // "Enter PIN", what it is for, and the four slots - filled once entered,
  // the next one ringed.
  hidden function drawHeader(dc, width, height, colored) {
    var center = width / 2;
    var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

    var prompt = _mMessage != null ? _mMessage : "Enter PIN";
    dc.setColor(
      _mMessage != null && colored ? 0xFF5555 : Graphics.COLOR_WHITE,
      Graphics.COLOR_TRANSPARENT
    );
    dc.drawText(center, height * 0.12, Graphics.FONT_SMALL, prompt, justify);

    // A round screen is narrow this close to its top edge.
    var textWidth = width * (Utils.isRectangularScreen() ? 0.9 : 0.62);
    var detail = _mDetail != null ? _mDetail : _mTitle;
    var fitted = Graphics.fitTextToArea(
      detail,
      Graphics.FONT_XTINY,
      textWidth,
      dc.getFontHeight(Graphics.FONT_XTINY),
      true
    );

    dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
    dc.drawText(center, height * 0.205, Graphics.FONT_XTINY, fitted != null ? fitted : detail, justify);

    var slotY = height * 0.29;
    var radius = height * 0.022;
    if (radius < 4) {
      radius = 4;
    }
    var spacing = radius * 4;

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

    for (var i = 0; i < LockConfirm.PIN_LENGTH; i++) {
      var x = center + (i - (LockConfirm.PIN_LENGTH - 1) / 2.0) * spacing;

      if (i < _mCount) {
        dc.fillCircle(x, slotY, radius);
      } else {
        dc.setPenWidth(i == _mCount ? 3 : 1);
        dc.drawCircle(x, slotY, radius);
      }
    }

    dc.setPenWidth(1);
  }

  // The selected digit large in a band, its neighbours small above and
  // below: up rolls towards the one above.
  hidden function drawWheel(dc, width, height, colored) {
    var center = width / 2;
    var y = height * 0.67;
    var bigFont = Graphics.FONT_NUMBER_MEDIUM;
    var smallFont = Graphics.FONT_SMALL;
    var bigHeight = dc.getFontHeight(bigFont);
    var gap = (bigHeight + dc.getFontHeight(smallFont)) / 2;
    var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

    var bandWidth = dc.getTextWidthInPixels("8", bigFont) * 2;
    var bandHeight = bigHeight * 0.9;

    if (colored) {
      dc.setColor(0x1A2A3A, 0x1A2A3A);
      dc.fillRoundedRectangle(center - bandWidth / 2, y - bandHeight / 2, bandWidth, bandHeight, 8);
    } else {
      dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
      dc.drawRoundedRectangle(center - bandWidth / 2, y - bandHeight / 2, bandWidth, bandHeight, 8);
    }

    dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
    dc.drawText(center, y - gap, smallFont, ((_mWheel + 1) % 10).toString(), justify);
    dc.drawText(center, y + gap, smallFont, ((_mWheel + 9) % 10).toString(), justify);

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
    dc.drawText(center, y, bigFont, _mWheel.toString(), justify);
  }

  hidden function drawKeypad(dc, width, height, colored) {
    var top = height * 0.36;
    var bottom = height * (Utils.isRectangularScreen() ? 0.98 : 0.96);
    var cellHeight = (bottom - top) / 4;
    var cellWidth = width * 0.24;

    if (cellWidth > cellHeight * 1.6) {
      cellWidth = cellHeight * 1.6;
    }

    _mGridLeft = width / 2 - cellWidth * 1.5;
    _mGridTop = top;
    _mCellWidth = cellWidth;
    _mCellHeight = cellHeight;

    // Sized so the outer keys of the bottom row stay inside a round screen.
    var radius = (cellWidth < cellHeight ? cellWidth : cellHeight) * 0.42;

    var font = Graphics.FONT_MEDIUM;
    if (dc.getFontHeight(font) > radius * 1.5) {
      font = Graphics.FONT_SMALL;
    }
    if (dc.getFontHeight(font) > radius * 1.7) {
      font = Graphics.FONT_TINY;
    }

    var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
    var face = colored ? 0x222222 : Graphics.COLOR_BLACK;

    for (var cell = 0; cell < CELL_COUNT; cell++) {
      var key = cellKey(cell);

      if (key == null) {
        continue;
      }

      var x = _mGridLeft + (cell % 3 + 0.5) * cellWidth;
      var y = top + (cell / 3 + 0.5) * cellHeight;
      var focused = cell == _mFocus;

      // The focused key is drawn inverted: white face, black ink.
      dc.setColor(focused ? Graphics.COLOR_WHITE : face, Graphics.COLOR_TRANSPARENT);
      dc.fillCircle(x, y, radius);

      if (!focused) {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(x, y, radius);
        dc.setPenWidth(1);
      }

      var ink = focused ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;

      if (key == KEY_DELETE) {
        drawDeleteGlyph(dc, x, y, radius * 0.55, ink, focused ? Graphics.COLOR_WHITE : face);
      } else {
        dc.setColor(ink, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, key.toString(), justify);
      }
    }
  }

  // A backspace key: a tag pointing left with an "x" cut into it.
  hidden function drawDeleteGlyph(dc, x, y, size, ink, background) {
    var left = (x - size).toNumber();
    var notch = (x - size * 0.4).toNumber();
    var right = (x + size).toNumber();
    var upper = (y - size * 0.6).toNumber();
    var lower = (y + size * 0.6).toNumber();

    dc.setColor(ink, ink);
    dc.fillPolygon([
      [left, y.toNumber()],
      [notch, upper],
      [right, upper],
      [right, lower],
      [notch, lower]
    ]);

    var crossLeft = x - size * 0.1;
    var crossRight = x + size * 0.5;
    var crossUp = y - size * 0.3;
    var crossDown = y + size * 0.3;

    dc.setColor(background, background);
    dc.setPenWidth(2);
    dc.drawLine(crossLeft, crossUp, crossRight, crossDown);
    dc.drawLine(crossLeft, crossDown, crossRight, crossUp);
    dc.setPenWidth(1);
  }
}

(:fullmem)
class PinEntryDelegate extends Ui.BehaviorDelegate {
  hidden var _mView;
  hidden var _mEntity;
  hidden var _mState;   // the lock state the PIN confirms, see LockConfirm.execute()
  hidden var _mPin;
  hidden var _mEntered; // the digits so far
  // Set once the screen is left: input still queued (a fast double tap)
  // must not act on it again - a second popView() would take the entity
  // view with it (see InputNumberEditDelegate._mDismissed).
  hidden var _mDone;

  function initialize(view, entity, pin) {
    BehaviorDelegate.initialize();
    _mView = view;
    _mEntity = entity;
    _mState = entity.getState();
    _mPin = pin;
    _mEntered = "";
    _mDone = false;
  }

  // Returning false makes BehaviorDelegate fall back to onKey() (the select
  // button) or onTap() (touch) - see EntityListDelegate.onSelect().
  function onSelect() {
    return false;
  }

  function onKey(keyEvent) {
    if (keyEvent.getKey() != Ui.KEY_ENTER) {
      return false;
    }

    App.getApp().resetInactivityTimer();

    var key = _mView.getSelectedKey();

    if (key == null) {
      // Keypad, no key focused yet: the first press brings up the ring.
      _mView.step(false);
      Ui.requestUpdate();
    } else {
      press(key);
    }

    return true;
  }

  // Every tap is taken, also between the keys: an unhandled one can fall
  // through to the system, which on some devices leaves the app (see
  // InputNumberEditDelegate.onTap()).
  function onTap(clickEvent) {
    App.getApp().resetInactivityTimer();

    var xy = clickEvent.getCoordinates();
    var key = _mView.keyAt(xy[0], xy[1]);

    if (key != null) {
      press(key);
    }

    return true;
  }

  // The up button.
  function onPreviousPage() {
    return step(true);
  }

  // The down button.
  function onNextPage() {
    return step(false);
  }

  function onBack() {
    App.getApp().resetInactivityTimer();

    if (_mDone) {
      return true;
    }

    if (_mEntered.length() > 0) {
      deleteDigit();
      return true;
    }

    _mDone = true;
    Ui.popView(Ui.SLIDE_IMMEDIATE);
    return true;
  }

  hidden function step(up) {
    App.getApp().resetInactivityTimer();

    if (!_mDone) {
      _mView.step(up);
      Ui.requestUpdate();
    }

    return true;
  }

  hidden function press(key) {
    if (_mDone) {
      return;
    }

    if (key == PinEntryView.KEY_DELETE) {
      deleteDigit();
      return;
    }

    _mEntered += key.toString();
    _mView.setCount(_mEntered.length());
    _mView.setMessage(null, null);
    _mView.resetWheel();

    if (_mEntered.length() == LockConfirm.PIN_LENGTH) {
      verify();
    }

    Ui.requestUpdate();
  }

  hidden function deleteDigit() {
    if (_mEntered.length() == 0) {
      return;
    }

    _mEntered = _mEntered.substring(0, _mEntered.length() - 1);
    _mView.setCount(_mEntered.length());
    Ui.requestUpdate();
  }

  hidden function verify() {
    if (_mEntered.equals(_mPin)) {
      _mDone = true;
      LockConfirm.resetFailures();
      Ui.popView(Ui.SLIDE_IMMEDIATE);
      LockConfirm.execute(_mEntity, _mState);
      return;
    }

    _mEntered = "";
    _mView.setCount(0);
    vibrate();

    var left = LockConfirm.recordFailure(_mPin);

    if (left == 0) {
      _mDone = true;
      Ui.popView(Ui.SLIDE_IMMEDIATE);
      App.getApp().viewController.showError(LockConfirm.MESSAGE_LOCKED);
      return;
    }

    _mView.setMessage("Wrong PIN", left == 1 ? "1 attempt left" : left.toString() + " attempts left");
  }

  hidden function vibrate() {
    if (Attention has :vibrate && System.getDeviceSettings().vibrateOn) {
      Attention.vibrate([
        new Attention.VibeProfile(100, 150),
        new Attention.VibeProfile(0, 100),
        new Attention.VibeProfile(100, 150)
      ]);
    }
  }
}
