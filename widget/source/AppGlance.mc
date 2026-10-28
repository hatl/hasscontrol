using Toybox.WatchUi as Ui;
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

    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
    dc.drawText(
      x,
      dc.getHeight() / 2,
      Graphics.FONT_MEDIUM,
      "HassControl",
      Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
    );
  }
}
