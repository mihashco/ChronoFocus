// ============================================================
// WatchFaceDelegate for the ChronoFocus watchface.
//
// Responsibilities:
//   • Forward onExitSleep / onEnterSleep to the view
//   • Handle hardware-button press to cycle pomodoro state
//   • Fire a per-minute timer to advance the active segment
// ============================================================

import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.System;
import Toybox.Timer;

class ChronoFocusDelegate extends WatchUi.WatchFaceDelegate {

    private var _view  as ChronoFocusView;
    private var _timer as Timer.Timer;

    public function initialize(view as ChronoFocusView) {
        WatchFaceDelegate.initialize();
        _view  = view;
        _timer = new Timer.Timer();
    }

    public function onActivate() as Void {
        // Tick every 60 seconds to advance the pomodoro segment
        _timer.start(method(:_onTick), 60000, true);
    }

    public function onDeactivate() as Void {
        _timer.stop();
    }

    /**
     * Hardware button press cycles pomodoro state.
     * On round devices the SELECT key (centre button) is a good fit.
     */
    public function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        if (keyEvent.getKey() == WatchUi.KEY_ENTER) {
            _view.onPomodoroAction();
            return true;
        }
        return false;
    }

    // Called once per minute by the internal timer
    public function _onTick() as Void {
        _view.tickMinute(1.0f);
    }
}
