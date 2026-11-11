using Toybox.WatchUi as Ui;
using Toybox.System;
using Toybox.Graphics;
using Hass;
using Utils;

(:glance)
class AppGlance extends Ui.GlanceView {
  function initialize() {
    GlanceView.initialize();
  }

  function onUpdate(dc) {
    // No GlanceView.onUpdate(dc) and a transparent text background: the
    // firmware paints the glance stripe itself, and clearing or filling the
    // dc would draw a black box over it that doesn't match the other glances.
    var x = Utils.isRectangularScreen() ? 10 : 5;

    // The Edge units (and a few handhelds) paint that stripe white in their
    // Day display mode, where white text cannot be seen (issue #108). The
    // devices that have such a mode are the ones whose settings tell which
    // one is on, so no list of devices is needed: everything else keeps its
    // dark stripe and white text.
    var settings = System.getDeviceSettings();
    var day = (settings has :isNightModeEnabled) && !settings.isNightModeEnabled;

    dc.setColor(day ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
    dc.drawText(
      x,
      dc.getHeight() / 2,
      Graphics.FONT_MEDIUM,
      "HassControl",
      Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
    );
  }
}
