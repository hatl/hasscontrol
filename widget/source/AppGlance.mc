using Toybox.WatchUi as Ui;
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

    // Adjust text position based on screen shape
    if (Utils.isRectangularScreen()) {
      dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
      dc.drawText(10, (height / 2) - (textHeight / 2), font, text, Graphics.TEXT_JUSTIFY_LEFT);
    } else {
      dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
      dc.drawText(5, (height / 2) - (textHeight / 2), font, text, Graphics.TEXT_JUSTIFY_LEFT);
    }
  }
}