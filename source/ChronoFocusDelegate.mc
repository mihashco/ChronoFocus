import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.System;

class ChronoFocusDelegate extends WatchUi.WatchFaceDelegate {

    private var _view as ChronoFocusView;

    public function initialize(view as ChronoFocusView) {
        WatchFaceDelegate.initialize();
        _view = view;
    }

    // Trigger a redraw when screen wakes — the view's timer handles the rest
    public function onExitSleep() as Void {
        WatchUi.requestUpdate();
    }

    public function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        if (keyEvent.getKey() == WatchUi.KEY_ENTER) {
            _view.onUpperTap();
            return true;
        }
        return false;
    }

    public function onPress(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords   = clickEvent.getCoordinates();
        var settings = System.getDeviceSettings();
        if (coords[1] < settings.screenHeight / 2) {
            _view.onUpperTap();
        } else {
            _view.onLowerTap();
        }
        return true;
    }
}
