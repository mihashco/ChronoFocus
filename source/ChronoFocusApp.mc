import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.System;
import Toybox.Background;

(:background)
class ChronoFocusApp extends Application.AppBase {
    private var _view as ChronoFocusView?;

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
    }

    public function onStop(state as Dictionary?) as Void {
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        var view     = new ChronoFocusView();
        var delegate = new ChronoFocusDelegate(view);
        _view = view;
        return [view, delegate];
    }

    (:background)
    public function getServiceDelegate() as [System.ServiceDelegate] {
        return [new ChronoFocusServiceDelegate()];
    }

    public function onBackgroundData(data as Application.PersistableType) as Void {
        WatchUi.requestUpdate();
    }
}

function getApp() as ChronoFocusApp {
    return Application.getApp() as ChronoFocusApp;
}