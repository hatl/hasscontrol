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

  function getEntityAt(index) {
    if (index < 0 || index >= _mEntities.size()) {
      return null;
    }
    return _mEntities[index];
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

  // Touch screen: explicit tap handler.
  // BehaviorDelegate translates onTap → onSelect on most watches, but some
  // models fire onTap (InputDelegate) directly without the translation.
  // Overriding here guarantees toggling works on all touch watches.
  function onTap(clickEvent) {
    return onSelect();
  }

  // Touch screen: explicit swipe handler.
  // BehaviorDelegate's onNextPage/onPreviousPage are not always triggered by
  // swipe gestures on touch-only watches — the raw onSwipe event is fired
  // instead.  We map UP→next entity and DOWN→previous entity here.
  // LEFT/RIGHT return false so the system handles widget navigation normally.
  function onSwipe(swipeEvent) {
    App.getApp().resetInactivityTimer();
    var dir = swipeEvent.getDirection();
    if (dir == Ui.SWIPE_UP) {
      return onNextPage();
    }
    if (dir == Ui.SWIPE_DOWN) {
      return onPreviousPage();
    }
    return false;
  }
}

class EntityListView extends Ui.View {
  hidden var _mController;
  hidden var _mLastIndex;
  hidden var _mTimer;
  hidden var _mTimerActive;
  hidden var _mShowBar;
  hidden var _mIconCache; // entityId => { :drawable, :type, :state, :sensorClass }

  function initialize(controller) {
    View.initialize();
    _mController = controller;
    _mLastIndex = null;
    _mTimer = new Timer.Timer();
    _mTimerActive = false;
    _mShowBar = false;
    _mIconCache = {};
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

  hidden function getIconDrawable(entity) {
    var type = entity.getType();
    var state = entity.getState();
    var sensorClass = entity.getSensorClass();

    if (type == Hass.TYPE_LIGHT) {
      if (state == Hass.STATE_ON) { return WatchUi.loadResource(Rez.Drawables.LightOn); }
      if (state == Hass.STATE_OFF) { return WatchUi.loadResource(Rez.Drawables.LightOff); }
    } else if (type == Hass.TYPE_SWITCH) {
      if (state == Hass.STATE_ON) { return WatchUi.loadResource(Rez.Drawables.SwitchOn); }
      if (state == Hass.STATE_OFF) { return WatchUi.loadResource(Rez.Drawables.SwitchOff); }
    } else if (type == Hass.TYPE_VALVE) {
      if (state == Hass.STATE_OPEN) { return WatchUi.loadResource(Rez.Drawables.ValveOpen); }
      if (state == Hass.STATE_CLOSED) { return WatchUi.loadResource(Rez.Drawables.ValveClosed); }
    } else if (type == Hass.TYPE_INPUT_BOOLEAN) {
      if (state == Hass.STATE_ON) { return WatchUi.loadResource(Rez.Drawables.CheckboxOn); }
      if (state == Hass.STATE_OFF) { return WatchUi.loadResource(Rez.Drawables.CheckboxOff); }
    } else if (type == Hass.TYPE_AUTOMATION) {
      if (state == Hass.STATE_ON) { return WatchUi.loadResource(Rez.Drawables.AutomationOn); }
      if (state == Hass.STATE_OFF) { return WatchUi.loadResource(Rez.Drawables.AutomationOff); }
    } else if (type == Hass.TYPE_LOCK) {
      if (state == Hass.STATE_LOCKED) { return WatchUi.loadResource(Rez.Drawables.LockLocked); }
      if (state == Hass.STATE_UNLOCKED) { return WatchUi.loadResource(Rez.Drawables.LockUnlocked); }
      if (state == Hass.STATE_LOCKING || state == Hass.STATE_UNLOCKING) { return WatchUi.loadResource(Rez.Drawables.LockChanging); }
    } else if (type == Hass.TYPE_COVER) {
      if (state == Hass.STATE_OPEN) { return WatchUi.loadResource(Rez.Drawables.CoverOpen); }
      if (state == Hass.STATE_OPENING) { return WatchUi.loadResource(Rez.Drawables.CoverOpening); }
      if (state == Hass.STATE_CLOSED) { return WatchUi.loadResource(Rez.Drawables.CoverClosed); }
      if (state == Hass.STATE_CLOSING) { return WatchUi.loadResource(Rez.Drawables.CoverClosing); }
    } else if (type == Hass.TYPE_FAN) {
      if (state == Hass.STATE_ON) { return WatchUi.loadResource(Rez.Drawables.FanOn); }
      if (state == Hass.STATE_OFF) { return WatchUi.loadResource(Rez.Drawables.FanOff); }
    } else if (type == Hass.TYPE_BINARY_SENSOR) {
      if (state == Hass.STATE_ON) { return WatchUi.loadResource(Rez.Drawables.BinaryOn); }
      if (state == Hass.STATE_OFF) { return WatchUi.loadResource(Rez.Drawables.BinaryOff); }
    } else if (type == Hass.TYPE_BUTTON || type == Hass.TYPE_INPUT_BUTTON) {
      return WatchUi.loadResource(Rez.Drawables.Button);
    } else if (type == Hass.TYPE_SCRIPT) {
      return WatchUi.loadResource(Rez.Drawables.ScriptOff);
    } else if (type == Hass.TYPE_SCENE) {
      return WatchUi.loadResource(Rez.Drawables.Scene);
    } else if (type == Hass.TYPE_SENSOR) {
      if (sensorClass == Hass.SENSOR_TEMPERATURE) { return WatchUi.loadResource(Rez.Drawables.Temperature); }
      if (sensorClass == Hass.SENSOR_HUMIDITY) { return WatchUi.loadResource(Rez.Drawables.Humidity); }
      if (sensorClass == Hass.SENSOR_CO2) { return WatchUi.loadResource(Rez.Drawables.CO2); }
      if (sensorClass == Hass.SENSOR_PM) { return WatchUi.loadResource(Rez.Drawables.AirPM); }
      if (sensorClass == Hass.SENSOR_ENERGY) { return WatchUi.loadResource(Rez.Drawables.EnergyMeter); }
      if (sensorClass == Hass.SENSOR_WATER) { return WatchUi.loadResource(Rez.Drawables.WaterMeter); }
      if (sensorClass == Hass.SENSOR_GAS) { return WatchUi.loadResource(Rez.Drawables.GasMeter); }
      return WatchUi.loadResource(Rez.Drawables.Unknown);
    }

    return WatchUi.loadResource(Rez.Drawables.Unknown);
  }

  // Returns true for one-shot trigger types that have no meaningful on/off state.
  hidden function isTriggerType(entity) {
    var type = entity.getType();
    return type == Hass.TYPE_SCENE
        || type == Hass.TYPE_SCRIPT
        || type == Hass.TYPE_BUTTON
        || type == Hass.TYPE_INPUT_BUTTON;
  }

  // Returns the left-accent-bar color that communicates the entity state at a glance.
  // Matches Garmin's native color language: green = active, orange = transitional,
  // blue = sensor read-only, purple = trigger, gray = inactive.
  hidden function getAccentColor(entity) {
    var state = entity.getState();

    if (isTriggerType(entity)) {
      return 0x8844FF; // purple — one-shot trigger
    }
    if (state == Hass.STATE_SENSOR) {
      return 0x00AAFF; // blue — read-only sensor value
    }
    if (state == Hass.STATE_ON
        || state == Hass.STATE_OPEN
        || state == Hass.STATE_UNLOCKED) {
      return 0x00CC00; // green — active / open
    }
    if (state == Hass.STATE_LOCKING
        || state == Hass.STATE_UNLOCKING
        || state == Hass.STATE_OPENING
        || state == Hass.STATE_CLOSING) {
      return 0xFF8800; // orange — transitional
    }
    return 0x444444; // dark gray — inactive / off / closed / locked
  }

  // Returns the human-readable state label shown below the entity name.
  // Returns null/empty for trigger types (scenes, scripts, buttons).
  hidden function getStateText(entity) {
    if (isTriggerType(entity)) {
      return "";
    }
    var state = entity.getState();
    if (state == Hass.STATE_ON) { return "On"; }
    if (state == Hass.STATE_OFF) { return "Off"; }
    if (state == Hass.STATE_LOCKED) { return "Locked"; }
    if (state == Hass.STATE_UNLOCKED) { return "Unlocked"; }
    if (state == Hass.STATE_LOCKING) { return "Locking..."; }
    if (state == Hass.STATE_UNLOCKING) { return "Unlocking..."; }
    if (state == Hass.STATE_OPEN) { return "Open"; }
    if (state == Hass.STATE_CLOSED) { return "Closed"; }
    if (state == Hass.STATE_OPENING) { return "Opening..."; }
    if (state == Hass.STATE_CLOSING) { return "Closing..."; }
    if (state == Hass.STATE_SENSOR) {
      // Sensor value is appended after "\n" inside getName()
      var nameStr = entity.getName();
      var nlIdx = nameStr.find("\n");
      if (nlIdx != null) {
        return nameStr.substring(nlIdx + 1, nameStr.length());
      }
    }
    return "";
  }

  // Returns the color used to render the state label text.
  hidden function getStateTextColor(entity, isSelected, bgColor) {
    var state = entity.getState();
    if (state == Hass.STATE_ON
        || state == Hass.STATE_OPEN
        || state == Hass.STATE_UNLOCKED) {
      return 0x00CC00; // green — active
    }
    if (state == Hass.STATE_LOCKING
        || state == Hass.STATE_UNLOCKING
        || state == Hass.STATE_OPENING
        || state == Hass.STATE_CLOSING) {
      return 0xFF8800; // orange — transitional
    }
    if (state == Hass.STATE_SENSOR) {
      return 0x88CCFF; // light blue — sensor value
    }
    // Off / closed / locked
    return isSelected ? 0xAAAAAA : 0x666666;
  }

  // Counts the number of display lines in a (possibly wrapped) text string.
  hidden function countTextLines(text) {
    if (text == null) { return 0; }
    var lines = 1;
    var chars = text.toCharArray();
    for (var i = 0; i < chars.size(); i++) {
      if (chars[i].equals('\n')) { lines++; }
    }
    return lines;
  }

  // Loads (or validates) icons for the three currently visible rows and stores
  // them in _mIconCache keyed by entity ID.  Entries for entities that have
  // scrolled out of view are evicted so memory stays bounded to 3 bitmaps.
  hidden function updateIconCache() {
    var currentIndex = _mController.getIndex();
    var count        = _mController.getCount();
    var visibleIds   = {};

    for (var i = 0; i < 3; i++) {
      var entityIndex = currentIndex - 1 + i;
      if (entityIndex < 0 || entityIndex >= count) { continue; }
      var entity = _mController.getEntityAt(entityIndex);
      if (entity == null) { continue; }

      var id          = entity.getId();
      var type        = entity.getType();
      var state       = entity.getState();
      var sensorClass = entity.getSensorClass();
      visibleIds[id]  = true;

      var cached = _mIconCache[id];
      if (cached == null
          || cached[:type]        != type
          || cached[:state]       != state
          || cached[:sensorClass] != sensorClass) {
        _mIconCache[id] = {
          :drawable    => getIconDrawable(entity),
          :type        => type,
          :state       => state,
          :sensorClass => sensorClass
        };
      }
    }

    // Evict stale entries — keeps peak memory to exactly 3 bitmaps
    var keys = _mIconCache.keys();
    for (var k = 0; k < keys.size(); k++) {
      if (!visibleIds.hasKey(keys[k])) {
        _mIconCache.remove(keys[k]);
      }
    }
  }

  // Returns the cached drawable for entity, falling back to a fresh load if the
  // cache was somehow missed (should not happen in normal onUpdate flow).
  hidden function getCachedIconDrawable(entity) {
    var cached = _mIconCache[entity.getId()];
    if (cached != null) {
      return cached[:drawable];
    }
    return getIconDrawable(entity);
  }

  // Draws one list row following the Garmin native lightweight pattern.
  //
  // Layout (left → right):
  //   [leftMargin — clears page-bar] [4 px bar*] [8 px gap] [icon] [6 px gap] [text]
  //   * bar only drawn on the selected row
  //
  // Spacing: each row has an internal vPad that leaves dead-black space near
  // the row boundary.  Two adjacent rows therefore share 2×vPad of gap without
  // any explicit gap calculation in onUpdate:
  //
  //   row 0:  content  [ 0+vPad … rowH-vPad ]   ← vPad px of black above/below
  //   row 1:  content  [ rowH+vPad … 2rowH-vPad ]
  //   visual gap between them = 2 × vPad px
  //
  // leftMargin clears the page-bar indicator drawn on the left edge:
  //   • Round screen:       arc inner edge ≈ 15 px  → leftMargin 20 (5 px gap)
  //   • Rectangular screen: barX(15)+barWidth(10)=25 → leftMargin 30 (5 px gap)
  //
  // Text readability: tries FONT_TINY first (up to 2 wrapped lines), then falls
  // back to FONT_XTINY — hard-truncates only as a last resort.
  //
  // Scenes / scripts / buttons show no state text (one-shot triggers).
  hidden function drawListRow(dc, entity, rowY, rowHeight, isSelected, vw) {
    // ── Layout constants ─────────────────────────────────────────────────────
    var leftMargin = Utils.isRectangularScreen() ? 40 : 30; //Done some more margin for better looking
    var vPad    = 12;  // vertical inset → 2×vPad gap between adjacent rows
    var barW    = 4;   // bar width (at its narrowest, bottom)
    var barSkew = 15;  // top edge shifts right by this many px, creating the "/" angle
    var iconX   = leftMargin + barW + barSkew + 4; // 4 px clearance after bar's widest point
    var textX   = iconX + 60 + 6;
    var textMaxW = vw - textX - 5;
    var stateFont = Graphics.FONT_XTINY;
    var lineGap   = 2;

    // Content area inset by vPad top and bottom
    var cY = rowY + vPad;
    var cH = rowHeight - 2 * vPad;

    // ── Background (selected row only) ───────────────────────────────────────
    var bgColor = isSelected ? 0x0E0E2A : Graphics.COLOR_BLACK;
    if (isSelected) {
      dc.setColor(bgColor, bgColor);
      dc.fillRectangle(leftMargin, cY, vw - leftMargin, cH);
    }

    // ── Accent bar — angled parallelogram (/ shape), selected row only ──────
    if (isSelected) {
      var accentColor = getAccentColor(entity);
      dc.setColor(accentColor, accentColor);
      dc.fillPolygon([
        [leftMargin + barSkew,        cY + 3     ],
        [leftMargin + barW + barSkew, cY + 3     ],
        [leftMargin + barW,           cY + cH - 3],
        [leftMargin,                  cY + cH - 3]
      ]);
    }

    // ── Icon (vertically centered) ────────────────────────────────────────────
    var drawable = getCachedIconDrawable(entity);
    if (drawable != null) {
      var iconH = drawable.getHeight();
      // On small screens the 60 px icon may be taller than the padded content
      // area; fall back to centering within the full row height in that case.
      var iconY = iconH <= cH
        ? cY + (cH - iconH) / 2
        : rowY + (rowHeight - iconH) / 2;
      dc.drawBitmap(iconX, iconY, drawable);
    }

    // ── Build text block ─────────────────────────────────────────────────────
    // Strip the "\n<sensor value>" suffix that getName() appends for sensors.
    var rawName = entity.getName();
    var nlIdx = rawName.find("\n");
    if (nlIdx != null) {
      rawName = rawName.substring(0, nlIdx);
    }

    var stateStr   = getStateText(entity);
    var hasState   = stateStr != null && !stateStr.equals("");
    var stateFontH = dc.getFontHeight(stateFont);

    // Try FONT_TINY first (preferred size, up to 2 lines).
    // If the text doesn't fit without truncation, shrink to FONT_XTINY.
    // Only hard-truncate as a last resort, so long names wrap gracefully.
    var titleFonts  = [Graphics.FONT_TINY, Graphics.FONT_XTINY];
    var titleFont   = titleFonts[0];
    var titleFontH  = dc.getFontHeight(titleFont);
    var fittedTitle = null;

    for (var fi = 0; fi < titleFonts.size(); fi++) {
      titleFont  = titleFonts[fi];
      titleFontH = dc.getFontHeight(titleFont);
      var maxTitleH = hasState ? (titleFontH * 2 + 2) : (cH - 8);
      // truncate=false → returns null when text doesn't fit; try smaller font next
      var candidate = Graphics.fitTextToArea(rawName, titleFont, textMaxW, maxTitleH, false);
      if (candidate != null) {
        fittedTitle = candidate;
        break;
      }
    }

    if (fittedTitle == null) {
      // Last resort: FONT_XTINY with hard truncation
      titleFont  = Graphics.FONT_XTINY;
      titleFontH = dc.getFontHeight(titleFont);
      var maxTitleH = hasState ? (titleFontH * 2 + 2) : (cH - 8);
      fittedTitle = Graphics.fitTextToArea(rawName, titleFont, textMaxW, maxTitleH, true);
      if (fittedTitle == null) { fittedTitle = rawName; }
    }

    var titleLines  = countTextLines(fittedTitle);
    var titleBlockH = titleLines * titleFontH;

    // Total text block height
    var totalH = titleBlockH + (hasState ? lineGap + stateFontH : 0);

    // Vertically center the whole text block inside the content area.
    var blockY = cY + (cH - totalH) / 2;

    // ── Draw title ─────────────────────────────────────────────────────────────
    // Selected: bright white.  Adjacent: dimmed so the selected row pops.
    var titleColor = isSelected ? Graphics.COLOR_WHITE : 0xAAAAAA;
    dc.setColor(titleColor, bgColor);
    dc.drawText(textX, blockY, titleFont, fittedTitle, Graphics.TEXT_JUSTIFY_LEFT);

    // ── Draw state text (not shown for trigger-type entities) ──────────────────
    if (hasState) {
      var stateColor = getStateTextColor(entity, isSelected, bgColor);
      dc.setColor(stateColor, bgColor);
      dc.drawText(textX, blockY + titleBlockH + lineGap, stateFont, stateStr, Graphics.TEXT_JUSTIFY_LEFT);
    }
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

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.clear();

    var count = _mController.getCount();

    if (count == 0) {
      drawNoEntityText(dc);
      return;
    }

    shouldShowBar();
    updateIconCache();

    var vh = dc.getHeight();
    var vw = dc.getWidth();
    var currentIndex = _mController.getIndex();
    var visibleRows = 3;
    var rowHeight = vh / visibleRows;

    for (var i = 0; i < visibleRows; i++) {
      var entityIndex = currentIndex - 1 + i;
      if (entityIndex < 0 || entityIndex >= count) {
        continue;
      }
      var entity = _mController.getEntityAt(entityIndex);
      if (entity == null) { continue; }
      drawListRow(dc, entity, i * rowHeight, rowHeight, entityIndex == currentIndex, vw);
    }

    if (_mShowBar) {
      drawPageBar(dc);
    }
  }
}