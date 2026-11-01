using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.Math;
using Hass;
using Utils;

// Excluded on 64 KB widget devices (:lowmem, see monkey.jungle) - see the
// comment on Entity.detectExtendedType() and
// EntityListDelegate.handleExtendedEntityTypes() for why.
(:fullmem)
class InputNumberEditDelegate extends Ui.BehaviorDelegate {
  hidden var _mEntity;
  hidden var _mView;
  hidden var _mStep;
  hidden var _mMin;
  hidden var _mMax;
  // Set once confirm()/onBack() pops this view. A second tap/key/select
  // event can still be queued and dispatched to this delegate before the
  // pop actually takes effect (e.g. a fast double-tap) - without this guard
  // that second event would call Ui.popView() again, popping an extra view
  // underneath (the entity list) and landing back further than intended,
  // as far as exiting the app entirely if there was nothing left to pop to.
  hidden var _mDismissed;

  function initialize(entity, view) {
    BehaviorDelegate.initialize();
    _mEntity = entity;
    _mView = view;
    _mStep = entity.getStep() != null ? entity.getStep() : 1;
    _mMin = entity.getMin();
    _mMax = entity.getMax();
    _mDismissed = false;
  }

  function clamp(value) {
    if (_mMin != null && value < _mMin) {
      return _mMin;
    }
    if (_mMax != null && value > _mMax) {
      return _mMax;
    }
    return value;
  }

  // Snaps a value to the entity's declared decimal precision (derived from
  // its step) so repeated float addition/subtraction doesn't drift into
  // values like 45.00000029802322.
  function roundToStep(value) {
    var factor = Math.pow(10, _mView.getDecimals()).toFloat();
    return Math.round(value * factor) / factor;
  }

  function increment() {
    _mView.setStagedValue(roundToStep(clamp(_mView.getStagedValue() + _mStep)));
    Ui.requestUpdate();
    return true;
  }

  function decrement() {
    _mView.setStagedValue(roundToStep(clamp(_mView.getStagedValue() - _mStep)));
    Ui.requestUpdate();
    return true;
  }

  // onPreviousPage()/onNextPage() are the up/down-button behaviors; named for
  // list paging, but here they step the value instead. The physical "up"
  // button (top of the device) fires onPreviousPage() - map that to
  // increment so up/top means "increase", matching user expectation.
  function onNextPage() {
    App.getApp().resetInactivityTimer();
    return decrement();
  }

  function onPreviousPage() {
    App.getApp().resetInactivityTimer();
    return increment();
  }

  hidden function confirm() {
    if (_mDismissed) {
      return true;
    }
    _mDismissed = true;
    // Pop first: setInputNumberValue() pushes a view of its own (the loader,
    // or the Wi-Fi/LTE prompt), which a later popView() would take off
    // again instead of this one.
    Ui.popView(Ui.SLIDE_IMMEDIATE);
    Hass.setInputNumberValue(_mEntity, _mView.getStagedValue());
    return true;
  }

  // Deferring to false lets BehaviorDelegate fall back to onKey() (physical
  // Enter button) or onTap() (touch) below, which is what actually confirms.
  // Returning true here would suppress both of those calls, so every tap -
  // regardless of where it landed - would confirm instead of just the ones
  // in the middle band.
  function onSelect() {
    return false;
  }

  function onKey(keyEvent) {
    if (keyEvent.getKey() == Ui.KEY_ENTER) {
      App.getApp().resetInactivityTimer();
      return confirm();
    }
    return false;
  }

  function onBack() {
    if (_mDismissed) {
      return true;
    }
    _mDismissed = true;
    App.getApp().resetInactivityTimer();
    Ui.popView(Ui.SLIDE_IMMEDIATE);
    return true;
  }

  // Touch screen: explicit tap handler, so no tap is left unhandled. Without
  // this, an unhandled tap (e.g. near the screen edge) falls through to the
  // system's default behavior, which on some devices exits the app instead
  // of just backing out of this view.
  //
  // Screen is split into three horizontal bands: top "+" band increments,
  // bottom "-" band decrements, middle band (the value itself) confirms.
  // Zone height comes from the view's own last-drawn height, not device
  // settings, so the hit-test always matches what's actually on screen
  // (dc.getHeight() and screenHeight are not always the same value).
  function onTap(clickEvent) {
    App.getApp().resetInactivityTimer();
    var vh = _mView.getHeight();
    var y = clickEvent.getCoordinates()[1];
    var zoneHeight = vh * InputNumberEditView.ZONE_FRACTION;

    if (y < zoneHeight) {
      return increment();
    }
    if (y > vh - zoneHeight) {
      return decrement();
    }
    return confirm();
  }

  // Touch screen: explicit swipe/drag handler. Dragging from bottom to top
  // increments, top to bottom decrements. Toybox's SWIPE_UP/SWIPE_DOWN name
  // the gesture the opposite way round from that (verified empirically, not
  // from a documented convention), hence the reversed mapping below.
  function onSwipe(swipeEvent) {
    App.getApp().resetInactivityTimer();
    var dir = swipeEvent.getDirection();

    if (dir == Ui.SWIPE_UP) {
      return decrement();
    }
    if (dir == Ui.SWIPE_DOWN) {
      return increment();
    }
    return false;
  }
}

(:fullmem)
class InputNumberEditView extends Ui.View {
  // Fraction of screen height each of the top "+" and bottom "-" bands
  // occupies. Shared with InputNumberEditDelegate.onTap() so the drawn
  // highlight and the tappable region always agree.
  static const ZONE_FRACTION = 0.22;

  hidden var _mEntity;
  hidden var _mStagedValue;
  hidden var _mDecimals;
  hidden var _mHeight; // last dc.getHeight() from onUpdate; see getHeight()

  function initialize(entity) {
    View.initialize();
    _mEntity = entity;
    _mDecimals = Utils.decimalPlacesForStep(entity.getStep());
    _mHeight = 0;

    var currentValue = entity.getSensorValue() != null ? entity.getSensorValue().toFloat() : null;
    _mStagedValue = currentValue != null ? currentValue : 0;
  }

  function getDecimals() {
    return _mDecimals;
  }

  function getStagedValue() {
    return _mStagedValue;
  }

  function setStagedValue(value) {
    _mStagedValue = value;
  }

  // The delegate's onTap() hit-tests against this rather than device
  // settings, so the tappable zones always match what onUpdate() drew.
  function getHeight() {
    return _mHeight;
  }

  function onLayout(dc) {
    setLayout([]);
  }

  // Draws a highlighted band with a centered "+"/"-" glyph. The glyph's
  // background is left transparent (rather than matching bgColor) because
  // Dc.drawText anti-aliases glyph edges against whatever background color
  // it's given, and a glyph can render a couple pixels taller than the
  // fitted rectangle - with an explicit bgColor that mismatch shows up as a
  // sliver of the zone color bleeding past its rectangle.
  hidden function drawZone(dc, y, height, vw, glyph) {
    var bgColor = 0x1A2A3A;
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
    var zoneHeight = vh * ZONE_FRACTION;
    _mHeight = vh;

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.clear();

    drawZone(dc, 0, zoneHeight, vw, "+");
    drawZone(dc, vh - zoneHeight, zoneHeight, vw, "-");

    // Name: one line, small font, ellipsis-truncated rather than wrapped, in
    // the gap between the "+" band and the value.
    var nameFont = Graphics.FONT_XTINY;
    var nameFontH = dc.getFontHeight(nameFont);
    var namePadding = 6;
    var nameText = Graphics.fitTextToArea(_mEntity.getRawName(), nameFont, vw * 0.9, nameFontH, true);
    var nameY = zoneHeight + namePadding;

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.drawText(cvw, nameY, nameFont, nameText, Graphics.TEXT_JUSTIFY_CENTER);

    // Value: centered in whatever space is left below the name.
    var valueTop = nameY + nameFontH + namePadding;
    var valueBottom = vh - zoneHeight;
    var valueCenterY = valueTop + (valueBottom - valueTop) / 2;
    var valueText = _mStagedValue.format("%." + _mDecimals + "f");

    dc.drawText(cvw, valueCenterY, Graphics.FONT_NUMBER_MEDIUM, valueText, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
  }
}
