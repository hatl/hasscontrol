using Toybox.Application as App;
using Toybox.Graphics;
using Toybox.System;
using Toybox.WatchUi as Ui;
using Utils;

// The yes/no question before a lock is locked or unlocked: what is about to
// happen, and two keys - cancel on the left, confirm on the right.
//
// It stands in for the system's Ui.Confirmation, whose select button
// confirms: a lock selected with a double press of that button was toggled
// by the second press. Here nothing confirms by accident:
//
//  * With buttons, one key has the focus, and it starts on cancel. Up/down
//    move it, select presses the focused key - so select alone only ever
//    cancels. Back cancels as well.
//  * On a touch screen the keys are tapped. A touch watch with up/down
//    buttons has the focus too; without them (Venu, vivoactive, Edge
//    1040/1050) there is none and select does nothing.
//  * A confirming press or tap in the first moment (GUARD_MS) is ignored:
//    that is the rest of a double tap, not an answer.
//
// :fullmem only, see monkey.jungle.
(:fullmem)
class LockConfirmView extends Ui.View {
  hidden var _mVerb;      // "Unlock" or "Lock"
  hidden var _mName;      // the lock's name
  hidden var _mTouch;
  hidden var _mRing;      // one key has the focus, up/down move it
  hidden var _mConfirm;   // the focus is on confirm rather than on cancel
  hidden var _mColored;   // the "Colored icons" setting
  hidden var _mSubscreen; // Instinct sub-window, or null

  // Key geometry of the last onUpdate(), for keyAt().
  hidden var _mMiddle;
  hidden var _mKeyY;
  hidden var _mKeyOffset; // of either key's centre from the middle
  hidden var _mRadius;

  function initialize(verb, name) {
    View.initialize();

    var settings = System.getDeviceSettings();
    var buttons = settings.inputButtons;

    _mVerb = verb;
    _mName = name;
    _mTouch = settings.isTouchScreen;
    // The focus needs something that moves it: without up/down buttons a
    // touch screen goes without (see PinEntryView's focus ring).
    _mRing = !_mTouch
      || ((buttons & System.BUTTON_INPUT_UP) != 0 && (buttons & System.BUTTON_INPUT_DOWN) != 0);
    _mConfirm = false;
    _mColored = Utils.getProperty("coloredIcons", false) == true;
    _mSubscreen = LockConfirm.subscreen();
    _mMiddle = null;
    _mKeyY = null;
    _mKeyOffset = null;
    _mRadius = null;
  }

  function onLayout(dc) {
    setLayout([]);
  }

  function isTouch() {
    return _mTouch;
  }

  // Up/down: with two keys, either moves the focus to the other one.
  function moveFocus() {
    if (_mRing) {
      _mConfirm = !_mConfirm;
    }
  }

  // The key the select button presses: true for confirm, false for cancel,
  // null without a focus.
  function getFocusedKey() {
    return _mRing ? _mConfirm : null;
  }

  // The key at a screen position: true for confirm, false for cancel, null
  // for neither. A key reaches a little beyond its circle, not further: a
  // tap somewhere on the screen is no answer.
  function keyAt(x, y) {
    if (_mRadius == null) {
      return null;
    }

    var reach = _mRadius * 1.3;
    var dy = y - _mKeyY;
    var dx = x - _mMiddle;
    var confirm = dx > 0;

    dx = (confirm ? dx : -dx) - _mKeyOffset;

    if (dy < -reach || dy > reach || dx < -reach || dx > reach) {
      return null;
    }

    return confirm;
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

    var titleHeight = dc.getFontHeight(Graphics.FONT_MEDIUM);
    var nameHeight = dc.getFontHeight(Graphics.FONT_SMALL);
    var radius = (width < height ? width : height) * 0.13;
    var gap = radius * 0.8;
    // The two lines and the keys are one block, in the middle of the screen.
    var top = (height - titleHeight - nameHeight - gap - radius * 2) / 2;

    var center = width / 2;
    var room = width * (Utils.isRectangularScreen() ? 0.9 : 0.8);

    if (_mSubscreen != null && top < _mSubscreen.y + _mSubscreen.height) {
      // Both lines left of the sub-window, so that neither runs under it
      // and the two stay one above the other.
      center = _mSubscreen.x / 2;
      room = _mSubscreen.x - 8;
    }

    // The name says which lock: it gets a smaller font when it is too long
    // for the usual one, a second line when it is too long for the smallest,
    // and is cut off only when that is not enough either. A name that long
    // goes without its question mark, which could end up alone on a line.
    var name = _mName + "?";
    var nameFont = Graphics.FONT_SMALL;

    while (nameFont > Graphics.FONT_XTINY && dc.getTextWidthInPixels(name, nameFont) > room) {
      nameFont--;
    }

    if (dc.getTextWidthInPixels(name, nameFont) > room) {
      // An area of exactly two lines' height takes one line only: two and a
      // half it is, which a third line does not fit into.
      var twoLines = dc.getFontHeight(nameFont) * 2;
      var fitted = Graphics.fitTextToArea(_mName, nameFont, room, twoLines * 1.25, true);

      if (fitted != null) {
        name = fitted;
      }
      if (name.find("\n") != null && twoLines > nameHeight) {
        top -= (twoLines - nameHeight) / 2;
        nameHeight = twoLines;
      }
    }

    var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
    dc.drawText(center, top + titleHeight / 2, Graphics.FONT_MEDIUM, _mVerb, justify);
    dc.drawText(center, top + titleHeight + nameHeight / 2, nameFont, name, justify);

    _mMiddle = width / 2;
    _mKeyY = top + titleHeight + nameHeight + gap + radius;
    _mKeyOffset = width * 0.22;
    _mRadius = radius;

    drawKey(dc, _mMiddle - _mKeyOffset, false);
    drawKey(dc, _mMiddle + _mKeyOffset, true);
  }

  // A round key with a cross (cancel) or a check mark (confirm). The one
  // with the focus is filled and has a ring around it. The other one is not
  // dimmed: on a touch screen it is as good for a tap.
  hidden function drawKey(dc, x, confirm) {
    var y = _mKeyY;
    var radius = _mRadius;
    var focused = _mRing && confirm == _mConfirm;
    var ink = Graphics.COLOR_WHITE;

    if (focused) {
      dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
      dc.fillCircle(x, y, radius * 0.86);
      dc.setPenWidth(2);
      dc.drawCircle(x, y, radius);
      ink = Graphics.COLOR_BLACK;
    } else {
      if (_mColored) {
        dc.setColor(0x222222, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, radius);
        ink = confirm ? 0x55FF55 : 0xFF5555;
      }

      dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
      dc.setPenWidth(2);
      dc.drawCircle(x, y, radius);
    }

    var pen = radius * 0.14;
    if (pen < 3) {
      pen = 3;
    }

    dc.setColor(ink, Graphics.COLOR_TRANSPARENT);

    if (!confirm) {
      LockConfirm.drawCross(dc, x, y, radius * 0.3, pen);
      return;
    }

    var bend = x - radius * 0.12;
    var low = y + radius * 0.3;

    dc.setPenWidth(pen);
    dc.drawLine(x - radius * 0.4, y + radius * 0.02, bend, low);
    dc.drawLine(bend, low, x + radius * 0.42, y - radius * 0.3);
    dc.setPenWidth(1);
  }
}

(:fullmem)
class LockConfirmDelegate extends Ui.BehaviorDelegate {
  // How long after the question came up a confirming input is ignored.
  static const GUARD_MS = 500;

  hidden var _mView;
  hidden var _mEntity;
  hidden var _mState; // the lock state the answer confirms, see LockConfirm.execute()
  hidden var _mShown; // System.getTimer() when the question came up
  // Set once the screen is left: input still queued must not act on it
  // again - a second popView() would take the entity view with it.
  hidden var _mDone;

  function initialize(view, entity) {
    BehaviorDelegate.initialize();
    _mView = view;
    _mEntity = entity;
    _mState = entity.getState();
    _mShown = System.getTimer();
    _mDone = false;
  }

  // Returning false makes BehaviorDelegate fall back to onKey() (the select
  // button) or onTap() (touch) - see EntityListDelegate.onSelect().
  function onSelect() {
    return false;
  }

  function onKey(keyEvent) {
    var pressed = keyEvent.getKey();

    if (pressed == Ui.KEY_UP || pressed == Ui.KEY_DOWN) {
      // The up/down buttons of a touch watch, passed on by onPreviousPage()
      // and onNextPage().
      return moveFocus();
    }

    if (pressed != Ui.KEY_ENTER) {
      return false;
    }

    App.getApp().resetInactivityTimer();
    answer(_mView.getFocusedKey());
    return true;
  }

  // Every tap is taken, also next to the keys: an unhandled one can fall
  // through to the system, which on some devices leaves the app (see
  // InputNumberEditDelegate.onTap()).
  function onTap(clickEvent) {
    App.getApp().resetInactivityTimer();

    var xy = clickEvent.getCoordinates();

    answer(_mView.keyAt(xy[0], xy[1]));
    return true;
  }

  // Swipes do nothing: up, down and left are swallowed. Right is not: where
  // it means back, it is the system's to turn into onBack().
  function onSwipe(swipeEvent) {
    return swipeEvent.getDirection() != Ui.SWIPE_RIGHT;
  }

  // The up button. Touch screens map swipes to the page behaviours too, so
  // there both are passed on: the button to onKey(), which moves the focus,
  // a swipe to onSwipe(), which ignores it.
  function onPreviousPage() {
    return _mView.isTouch() ? false : moveFocus();
  }

  // The down button, see onPreviousPage().
  function onNextPage() {
    return _mView.isTouch() ? false : moveFocus();
  }

  function onBack() {
    App.getApp().resetInactivityTimer();
    answer(false);
    return true;
  }

  hidden function moveFocus() {
    App.getApp().resetInactivityTimer();

    if (!_mDone) {
      _mView.moveFocus();
      Ui.requestUpdate();
    }

    return true;
  }

  // `confirm`: true locks or unlocks, false leaves the lock alone, null (a
  // tap next to the keys, select without a focus) does nothing.
  hidden function answer(confirm) {
    if (_mDone || confirm == null) {
      return;
    }

    if (confirm && System.getTimer() - _mShown < GUARD_MS) {
      return;
    }

    _mDone = true;
    Ui.popView(Ui.SLIDE_IMMEDIATE);

    if (confirm) {
      LockConfirm.execute(_mEntity, _mState);
    }
  }
}
