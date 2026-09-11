using Toybox.WatchUi as Ui;
using Toybox.System as System;
using Hass;
using Utils;

(:glance)
class AppGlance extends Ui.GlanceView {
  var _mClient;

  function initialize() {
    GlanceView.initialize();
  }

  function getLayout() {
    setLayout([]);
  }

  function onUpdate(dc) {
    GlanceView.onUpdate(dc);

    var height = dc.getHeight();

    var font = Graphics.FONT_MEDIUM;
    var text = "HassControl";

    var textDimensions = dc.getTextDimensions(text, font);
    var textHeight = textDimensions[1];

    
    var bg = System.getDeviceSettings().isNightModeEnabled ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
    var fg = bg == Graphics.COLOR_BLACK ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;

    dc.setColor(bg, bg);
    dc.clear();

    dc.setColor(fg,bg);

    // Adjust text position based on screen shape
    if (Utils.isRectangularScreen()) {
      dc.drawText(10, (height / 2) - (textHeight / 2), font, text, Graphics.TEXT_JUSTIFY_LEFT);
    } else {
      dc.drawText(5, (height / 2) - (textHeight / 2), font, text, Graphics.TEXT_JUSTIFY_LEFT);
    }
  }
}