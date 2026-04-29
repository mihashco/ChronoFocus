import Toybox.Background;
import Toybox.System;

(:background)
class ChronoFocusServiceDelegate extends System.ServiceDelegate {

    public function initialize() {
        ServiceDelegate.initialize();
    }

    public function onTemporalEvent() as Void {
        Background.requestApplicationWake("Czas minął!");
        Background.exit(null);
    }
}