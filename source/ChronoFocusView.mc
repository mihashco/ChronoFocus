// ============================================================
// V2DenseView.mc
// Watchface: DATA DENSE (v2)
//
// Layout:
//   OUTER ring  (r≈95%) — day timeline, segmented pomodoro arcs, 320° span
//   MID ring    (r≈73%) — current-segment progress (pomodoro / break)
//   INNER ring  (r≈67%) — daily step-count ring (gold)
//
//   TOP BAR     — battery · date · pomodoro state label
//   CENTER      — task label / large HH:MM:SS / pomodoro countdown + set
//   LEFT        — heart-rate complication
//   RIGHT       — streak complication
//   BOTTOM BAR  — steps · goal% · next-event time
//
// Arc orientation: 320° clockwise, starting at 160° (≈10 o'clock).
//   angleForMinute(m) = ARC_START − (m / DAY_MIN) × ARC_SPAN
//   This matches the SVG prototype (DAY_START = −160°, Y-flipped).
//
// Depends on:
//   ChronoUIBarrel.ChronoUI.UiMath   (pointOnCircle, clamp01)
//   ChronoUIBarrel.ChronoUI.UiText   (drawCenteredAt)
// ============================================================

import Toybox.Application;
import Toybox.Timer;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Math;
import Toybox.System;
import Toybox.ActivityMonitor;
import Toybox.Activity;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Background;
import Toybox.Notifications;

// Convenient aliases to ChronoUI barrel classes
using ChronoUIBarrel.ChronoUI as ChronoUI;

class DataProvider {
    public function getBodyBattery() {
        var value = "--";

        if (Toybox has :SensorHistory && SensorHistory has :getBodyBatteryHistory) {
            var iter = SensorHistory.getBodyBatteryHistory({:period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST});
            var sample = iter.next();

            if (sample != null && sample.data != null) {
                value = sample.data.toNumber();
            }
        }

        return value;
    }
}

class ChronoFocusView extends WatchUi.WatchFace {

    // ── Palette ───────────────────────────────────────────────────────────────
    private const COLOR_BG        as Number = 0x000000;
    private const COLOR_FG        as Number = 0xF2EEE5;
    private const COLOR_MUTED     as Number = 0x888888;
    private const COLOR_DIM       as Number = 0x666666;
    private const COLOR_VDIM      as Number = 0x444444;
    private const COLOR_DIMLINE   as Number = 0x222222;
    private const COLOR_FOCUS_ACT as Number = 0x7DD181; // green – active focus
    private const COLOR_BREAK_ACT as Number = 0x7DB6D1; // blue  – active break
    private const COLOR_IDLE_ACT  as Number = 0x888888;
    private const COLOR_FOCUS_PST as Number = 0x3A5A3E; // past focus segments

    private const COLOR_STEPS_FG  as Number = 0xC8A64A; // gold – steps ring
    private const COLOR_HR_RED    as Number = 0xC84A4A;
    private const COLOR_RING_BG   as Number = 0x1A1A1A;
    private const COLOR_STEPS_BG  as Number = 0x181818;

    // ── Ring radius factors (fraction of watch half-width) ────────────────────
    private const RF_OUTER as Float = 0.942f; // day-timeline ring
    private const RF_MID   as Float = 0.727f; // pomodoro-progress ring
    private const RF_INNER as Float = 0.669f; // steps ring

    // ── Arc geometry (Garmin: 0=right, 90=top, clockwise = decreasing angle) ──
    // Pomodoro / steps rings — full 320° arc (unchanged)
    private const ARC_START as Float = 160.0f;
    private const ARC_SPAN  as Float = 320.0f;

    // Day-timeline two-half rings:
    //   AM ring (top):    160° → 20°   (10 o'clock → 1 o'clock, 140° sweep)
    //   PM ring (bottom): -20° → -160° ( 5 o'clock → 8 o'clock, 140° sweep)
    //   ≈40° gap on each side (3 and 9 o'clock) reserved for complications.
    private const DAY_HALF_SPAN as Float = 140.0f;
    private const DAY_PM_START  as Float = -20.0f;

    // ── Pomodoro timing constants (seconds) ──────────────────────────────────
    private const POM_FOCUS_S      as Number = 30;  // 25 min
    private const POM_BREAK_S      as Number = 10;   //  5 min
    private const POM_LONG_BREAK_S as Number = 30;  // 25 min — every 4 sessions

    // ── Pomodoro state ────────────────────────────────────────────────────────
    // :idle    – waiting for first tap of the day
    // :focus   – 25-min countdown running
    // :break   –  5-min break countdown running (auto after focus ends)
    // :waiting – break done, waiting for upper tap to start next focus
    private var _pomState      as Symbol        = :idle;
    private var _segElapsed    as Float         = 0.0f;
    private var _segTotal      as Float         = 0.0f;
    private var _segStartEpoch as Number        = 0;    // epoch (s) when segment started
    private var _pomCompleted  as Number        = 0;
    private var _pomGoal       as Number        = 16;
    private var _timer         as Timer.Timer?  = null; // started from first onUpdate()
    private var _focusTask    as String;
    private var _nextEvTime   as String;

    private var _dataProvider as DataProvider;

    // ─────────────────────────────────────────────────────────────────────────
    // LIFECYCLE
    // ─────────────────────────────────────────────────────────────────────────
    private function _scheduleWakeEvent(secondsFromNow as Number) as Void {
        if (Background has :registerForTemporalEvent) {
            try {
                Background.deleteTemporalEvent();
            } catch (ex instanceof Lang.Exception) {}
            try {
                var targetTime = Time.now().add(new Time.Duration(secondsFromNow));
                Background.registerForTemporalEvent(targetTime);
            } catch (ex instanceof Lang.Exception) {}
        }
    }

    private function _cancelWakeEvent() as Void {
        if (Background has :deleteTemporalEvent) {
            try {
                Background.deleteTemporalEvent();
            } catch (ex instanceof Lang.Exception) {
            }
        }
    }

    public function initialize() {
        WatchFace.initialize();
        _pomGoal    = 16;
        _focusTask  = "Q3 roadmap";
        _nextEvTime = "13:30";

        _dataProvider = new DataProvider();
        _loadState();
    }

    public function onLayout(dc as Dc) as Void {
        // Fully programmatic — no layout resource needed.
    }

    public function onUpdate(dc as Dc) as Void {
        // Start 1-second timer once from onUpdate() — the only UI context that
        // allows Timer.start() for watchfaces without a permission crash.
        if (_timer == null) {
            var t = new Timer.Timer();
            t.start(method(:tickSecond), 1000, true);
            _timer = t;
        }

        // Recompute elapsed from wall clock so it is accurate even after
        // sleep/wake cycles where the timer was paused by the OS.
        if ((_pomState == :focus || _pomState == :break) && _segStartEpoch > 0) {
            _segElapsed = (Time.now().value().toNumber() - _segStartEpoch).toFloat();
            if (_segElapsed >= _segTotal) {
                if (_pomState == :focus) {
                    _pomCompleted++;
                    _startBreak();
                } else {
                    _toWaiting();
                }
            }
        }

        _checkDayReset();

        var sw  = dc.getWidth();
        var sh  = dc.getHeight();
        var cx  = (sw / 2).toNumber();
        var cy  = (sh / 2).toNumber();
        var R   = ((sw < sh ? sw : sh) / 2).toNumber(); // watch radius

        // ── Live system data ─────────────────────────────────────────────────
        var ct          = System.getClockTime();
        var sysStats    = System.getSystemStats();
        var battPct     = (sysStats.battery + 0.5f).toNumber(); // 0–100

        var dayTotal   = 0;
        var dayElapsed = 0;

        // Activity
        var actInfo   = ActivityMonitor.getInfo();
        var steps     = (actInfo != null && actInfo.steps    != null) ? actInfo.steps    : 0;
        var stepsGoal = (actInfo != null && actInfo.stepGoal != null) ? actInfo.stepGoal : 8000;

        var stepProg  = (stepsGoal > 0)
            ? ChronoUI.UiMath.clamp01(steps.toFloat() / stepsGoal.toFloat())
            : 0.0f;

        var hr = 0;
        var aInfo = Activity.getActivityInfo();
        if (aInfo != null && aInfo.currentHeartRate != null) {
            hr = aInfo.currentHeartRate;
        }

        var dailyGoalPct = (stepsGoal > 0)
            ? ((steps.toFloat() / stepsGoal.toFloat()) * 100.0f + 0.5f).toNumber()
            : 0;
        if (dailyGoalPct > 100) { dailyGoalPct = 100; }

        var accentColor = _accentColor();

        // ── Draw layers (back to front) ──────────────────────────────────────
        _clearBackground(dc, sw, sh);
        _drawDayRing       (dc, cx, cy, R, dayElapsed, dayTotal, accentColor);
        _drawPomodoroRing  (dc, cx, cy, R, accentColor);
        _drawStepsRing     (dc, cx, cy, R, stepProg);
        // _drawCurrentMarker (dc, cx, cy, R, dayElapsed, dayTotal, COLOR_BREAK_ACT);
        _drawTopBar        (dc, cx, cy, R, battPct, accentColor);
        _drawCenterContent (dc, cx, cy, R, ct.hour, ct.min, ct.sec, accentColor);
        _drawComplications (dc, cx, cy, R, hr);
        _drawBottomBar     (dc, cx, cy, R, steps, stepsGoal, dailyGoalPct, accentColor);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC API (call from WatchFaceDelegate)
    // ─────────────────────────────────────────────────────────────────────────

    // Upper half tap (or centre button): start focus from idle/waiting
    public function onUpperTap() as Void {
        if ((_pomState == :idle || _pomState == :waiting) && _pomCompleted < _pomGoal) {
            _startFocus();
        }
        WatchUi.requestUpdate();
    }

    // Lower half tap: skip current focus (no credit) → break, or skip break → waiting
    public function onLowerTap() as Void {
        if (_pomState == :focus) {
            _startBreak();
        } else if (_pomState == :break) {
            _toWaiting();
        }
        WatchUi.requestUpdate();
    }

    // Timer callback — just triggers a redraw; onUpdate() does all the real work.
    public function tickSecond() as Void {
        WatchUi.requestUpdate();
    }

    /** Update user-configurable data (call after loading from AppStorage). */
    public function setMeta(task as String, streak as Number, nextEvTime as String) as Void {
        _focusTask  = task;
        _nextEvTime = nextEvTime;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: DRAWING
    // ─────────────────────────────────────────────────────────────────────────

    private function _clearBackground(dc as Dc, sw as Number, sh as Number) as Void {
        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();
    }

    // ── DAY RING: 8 fixed focus slots (4 per half), independent of clock time ───
    //   Top ring (AM):    slots 0-3, arc 160°→20°
    //   Bottom ring (PM): slots 4-7, arc -20°→-160°
    //   Progress driven by _pomCompleted, not work-start/end time.
    //   Default: gray. Completed: dim green. Current: accent.
    private function _drawDayRing(
        dc          as Dc,
        cx          as Number,
        cy          as Number,
        R           as Number,
        dayElapsed  as Number,
        dayTotal    as Number,
        accentColor as Number
    ) as Void {
        var rOuter   = (R.toFloat() * RF_OUTER).toNumber();
        // Layout per half-ring: [4 slots] bigGap [4 slots], 6 small gaps total.
        // smallGap = gap within a group, bigGap = gap between groups (25-min break).
        var smallGap = 4.0f;
        var bigGap   = 12.0f;
        var slotSpan = (DAY_HALF_SPAN - 6.0f * smallGap - bigGap) / 8.0f; // ~13° each

        // ── Background tracks ─────────────────────────────────────────────────
        dc.setColor(COLOR_RING_BG, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(10);
        dc.drawArc(cx, cy, rOuter, Graphics.ARC_CLOCKWISE,
            ARC_START.toNumber(),    (ARC_START    - DAY_HALF_SPAN).toNumber());
        dc.drawArc(cx, cy, rOuter, Graphics.ARC_CLOCKWISE,
            DAY_PM_START.toNumber(), (DAY_PM_START - DAY_HALF_SPAN).toNumber());

        // ── 16 focus slots: 4 groups of 4 (top:[0-3][4-7], bottom:[8-11][12-15]) ──
        for (var i = 0; i < 16; i++) {
            var isBottom = (i >= 8);
            var slotIdx  = isBottom ? (i - 8) : i;  // 0-7 within each half

            var startDeg = isBottom ? DAY_PM_START : ARC_START;
            var a1;
            if (slotIdx < 4) {
                a1 = startDeg - slotIdx.toFloat() * (slotSpan + smallGap);
            } else {
                // skip over bigGap after the first group of 4
                a1 = startDeg - (4.0f * slotSpan + 3.0f * smallGap + bigGap
                     + (slotIdx - 4).toFloat() * (slotSpan + smallGap));
            }
            var a2 = a1 - slotSpan;

            var isDone    = (i < _pomCompleted);
            var isCurrent = (i == _pomCompleted) && (_pomState == :focus || _pomState == :break);

            var col;
            if (isCurrent) {
                col = accentColor;
            } else if (isDone) {
                col = COLOR_FOCUS_PST;
            } else {
                col = COLOR_DIM;
            }

            dc.setPenWidth(10);
            dc.setColor(col, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, rOuter, Graphics.ARC_CLOCKWISE,
                a1.toNumber(), a2.toNumber());

            // Rounded caps
            var p1 = ChronoUI.UiMath.pointOnCircle(a1, cx, cy, rOuter);
            dc.fillCircle(p1[0], p1[1], 5);
            var p2 = ChronoUI.UiMath.pointOnCircle(a2, cx, cy, rOuter);
            dc.fillCircle(p2[0], p2[1], 5);
        }
    }

    // ── MID RING: pomodoro-segment progress ───────────────────────────────────
    private function _drawPomodoroRing(
        dc          as Dc,
        cx          as Number,
        cy          as Number,
        R           as Number,
        accentColor as Number
    ) as Void {
        var rMid = (R.toFloat() * RF_MID).toNumber();

        // Background track
        dc.setColor(COLOR_RING_BG, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(4);
        dc.drawArc(cx, cy, rMid, Graphics.ARC_CLOCKWISE,
            ARC_START.toNumber(), (ARC_START - ARC_SPAN).toNumber());

        if (_pomState == :idle) { return; }

        var prog;
        var ringColor;
        if (_pomState == :waiting) {
            prog      = 1.0f;
            ringColor = COLOR_FOCUS_PST;
        } else {
            prog      = (_segTotal > 0.0f) ? ChronoUI.UiMath.clamp01(_segElapsed / _segTotal) : 0.0f;
            ringColor = accentColor;
        }
        var pAngle = ARC_START - prog * ARC_SPAN;

        dc.setColor(ringColor, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, rMid, Graphics.ARC_CLOCKWISE,
            ARC_START.toNumber(), pAngle.toNumber());

        // Rounded caps
        var sp = ChronoUI.UiMath.pointOnCircle(ARC_START, cx, cy, rMid);
        var ep = ChronoUI.UiMath.pointOnCircle(pAngle,    cx, cy, rMid);
        dc.fillCircle(sp[0], sp[1], 2);
        if (prog > 0.01f) { dc.fillCircle(ep[0], ep[1], 2); }
    }

    // ── INNER RING: steps ─────────────────────────────────────────────────────
    private function _drawStepsRing(
        dc       as Dc,
        cx       as Number,
        cy       as Number,
        R        as Number,
        stepProg as Float
    ) as Void {
        var rInner = (R.toFloat() * RF_INNER).toNumber();

        dc.setColor(COLOR_STEPS_BG, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(3);
        dc.drawArc(cx, cy, rInner, Graphics.ARC_CLOCKWISE,
            ARC_START.toNumber(), (ARC_START - ARC_SPAN).toNumber());

        if (stepProg <= 0.001f) { return; }

        var pAngle = ARC_START - stepProg * ARC_SPAN;
        dc.setColor(COLOR_STEPS_FG, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, rInner, Graphics.ARC_CLOCKWISE,
            ARC_START.toNumber(), pAngle.toNumber());

        var ep = ChronoUI.UiMath.pointOnCircle(pAngle, cx, cy, rInner);
        dc.fillCircle(ep[0], ep[1], 2);
    }

    // ── TOP BAR: arc text between pomodoro ring and day ring ─────────────────
    //   battery at ~150°  ·  date at 90° (top)  ·  state at ~30°
    //   radius sits at the midpoint between RF_MID and RF_OUTER.
    private function _drawTopBar(
        dc          as Dc,
        cx          as Number,
        cy          as Number,
        R           as Number,
        battPct     as Number,
        accentColor as Number
    ) as Void {
        var arcR = ((RF_MID + RF_OUTER) / 2.0f * R.toFloat()).toNumber();

        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var dows = ["SUN","MON","TUE","WED","THU","FRI","SAT"] as Array<String>;
        var dow  = info.day_of_week;
        if (dow < 1) { dow = 1; }
        if (dow > 7) { dow = 7; }
        var mo  = info.month;
        var dy  = info.day;
        var moS = (mo < 10 ? "0" : "") + mo.toString();
        var dyS = (dy < 10 ? "0" : "") + dy.toString();

        var batStr   = battPct.toString() + "%";
        var dateStr  = dows[dow - 1] + " " + dyS + "." + moS;
        var stateStr = (_pomState == :focus) ? "FOCUS" :
                       (_pomState == :break) ? "BREAK" : "IDLE";
        var outStr = batStr + " " + dateStr + " " + stateStr;

        var size = 24;
        var font = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => size
        });

        dc.setColor(COLOR_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawRadialText(
            cx,
            cy,
            font,
            outStr,
            Graphics.TEXT_JUSTIFY_CENTER,
            90,
            R-50,
            Graphics.RADIAL_TEXT_DIRECTION_CLOCKWISE
        );
    }

    // ── CENTER: task / HH:MM:SS / pomodoro block ──────────────────────────────
    private function _drawCenterContent(
        dc          as Dc,
        cx          as Number,
        cy          as Number,
        R           as Number,
        hour        as Number,
        minute      as Number,
        second      as Number,
        accentColor as Number
    ) as Void {
        // ── Large time HH:MM ────────────────────────────────────────────────
        var hh = (hour   < 10 ? "0" : "") + hour.toString();
        var mm = (minute < 10 ? "0" : "") + minute.toString();
        var ss = (second < 10 ? "0" : "") + second.toString();

        var size = 100;
        var tFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => size
        });

        var sSize = 50;
        var sFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => sSize
        });

        var tH     = dc.getFontHeight(tFont);
        // var timeOff = (R.toFloat() * 0.06f).toNumber();
        var tBaseCY = cy;// - timeOff;

        // Compute total width for centering: HH + ":" + MM
        var wHH    = dc.getTextWidthInPixels(hh,   tFont);
        var wColon = dc.getTextWidthInPixels(":",   tFont);
        var wMM    = dc.getTextWidthInPixels(mm,    tFont);
        var wSec   = dc.getTextWidthInPixels(":" + ss, sFont);

        var totalW = wHH + wColon + wMM + 4 + wSec;
        var tx     = cx - totalW / 2;
        var ty     = tBaseCY - tH / 2;

        // HH
        dc.setColor(COLOR_FG, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, ty, tFont, hh, Graphics.TEXT_JUSTIFY_LEFT);
        tx += wHH;

        // colon (dim)
        dc.setColor(0x444444, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, ty, tFont, ":", Graphics.TEXT_JUSTIFY_LEFT);
        tx += wColon;

        // MM
        dc.setColor(COLOR_FG, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, ty, tFont, mm, Graphics.TEXT_JUSTIFY_LEFT);
        tx += wMM + 4;

        // :SS (small, muted)
        var sH    = dc.getFontHeight(sFont);
        dc.setColor(0x555555, Graphics.COLOR_TRANSPARENT);
        dc.drawText(tx, tBaseCY - sH / 2, sFont, ":" + ss,
            Graphics.TEXT_JUSTIFY_LEFT);

        // ── Pomodoro separator lines + block ────────────────────────────────
        var sepOff1 = (R.toFloat() * 0.42f).toNumber();
        var sepOff2 = (R.toFloat() * 0.22f).toNumber();
        var sepY1   = cy - sepOff1;
        var sepY2   = cy - sepOff2;
        var blockW  = (R.toFloat() * 1.0f).toNumber();  // full inner width

        dc.setColor(COLOR_DIMLINE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        // dc.drawLine(cx - blockW / 2, sepY1, cx + blockW / 2, sepY1);
        dc.drawLine(cx - blockW / 2, sepY2, cx + blockW / 2, sepY2);

        var blockCY = (sepY1 + sepY2) / 2;

        // Left half: POM label + countdown
        var pomLabel = "POM " + ((_pomState == :waiting) ? _pomCompleted : (_pomCompleted + 1)).toString();
        var pSize = 28;
        var pFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => pSize
        });

        var pValSize = 50;
        var pValFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => pValSize
        });
        var leftCX   = cx;

        var remStr;
        if (_pomState == :idle) {
            remStr = "--:--";
        } else if (_pomState == :waiting) {
            remStr = "DONE";
        } else {
            var remSec = _segTotal - _segElapsed;
            if (remSec < 0.0f) { remSec = 0.0f; }
            var remM = (remSec / 60.0f).toNumber();
            var remS = (remSec - remM.toFloat() * 60.0f).toNumber();
            remStr = (remM < 10 ? "0" : "") + remM.toString() + ":"
                   + (remS < 10 ? "0" : "") + remS.toString();
        }

        ChronoUI.UiText.drawCenteredAt(dc, leftCX, sepY1 - 20,  pomLabel, pFont, 0x555555);
        ChronoUI.UiText.drawCenteredAt(dc, leftCX, blockCY - 5, remStr,  pValFont, accentColor);
    }

    // ── LEFT/RIGHT COMPLICATIONS ──────────────────────────────────────────────
    private function _drawComplications(
        dc as Dc,
        cx as Number,
        cy as Number,
        R  as Number,
        hr as Number
    ) as Void {
        var offset = (R.toFloat() * 0.88f).toNumber();

        var lSize = 28;
        var lFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => lSize
        });

        var vSize = 28;
        var vFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => vSize
        });


        // ── Left: Heart Rate ─────────────────────────────────────────────────
        var lx     = cx - offset;
        var hrStr  = (hr > 0) ? hr.toString() : "--";

        ChronoUI.UiText.drawCenteredAt(dc, lx, cy - 34, "HR",    lFont, 0x555555);
        ChronoUI.UiText.drawCenteredAt(dc, lx, cy,  hrStr,   vFont, COLOR_FG);
        ChronoUI.UiText.drawCenteredAt(dc, lx, cy + 34, "BPM",   lFont, COLOR_HR_RED);

        // ── Right: Body Bat ────────────────────────────────────────────────────
        var rx = cx + offset;

        ChronoUI.UiText.drawCenteredAt(dc, rx, cy - 34, "BD",       lFont, 0x555555);
        ChronoUI.UiText.drawCenteredAt(dc, rx, cy,  _dataProvider.getBodyBattery().toString(), vFont, COLOR_FG);
        ChronoUI.UiText.drawCenteredAt(dc, rx, cy + 34, "BAT",         lFont, COLOR_STEPS_FG);
    }

    // ── BOTTOM BAR: steps · goal% · → next event ─────────────────────────────
    private function _drawBottomBar(
        dc           as Dc,
        cx           as Number,
        cy           as Number,
        R            as Number,
        steps        as Number,
        stepsGoal    as Number,
        dailyGoalPct as Number,
        accentColor  as Number
    ) as Void {
        var botY = cy + (R.toFloat() * 0.75f).toNumber();
        var font = Graphics.FONT_XTINY;
        var th   = dc.getFontHeight(font);
        var ty   = botY - th / 2;

        // Format steps
        var stepsStr;
        if (steps >= 10000) {
            stepsStr = (steps / 1000).toString() + "K";
        } else if (steps >= 1000) {
            var k = steps / 1000;
            var d = (steps % 1000) / 100;
            stepsStr = k.toString() + "." + d.toString() + "K";
        } else {
            stepsStr = steps.toString();
        }
        var goalKStr   = (stepsGoal / 1000).toString() + "K";
        var stepsLabel = stepsStr + "/" + goalKStr;
        var goalLabel  = "GOAL " + dailyGoalPct.toString() + "%";
        var evLabel    = "\u2192 " + _nextEvTime;  // → arrow
        var dot        = " · ";

        // Two-pass draw: muted text, then accent overrides
        var leftStr = "  " + stepsLabel + dot + "GOAL ";    // steps arrow space
        var leftW   = dc.getTextWidthInPixels(leftStr, font);
        var pctStr  = dailyGoalPct.toString() + "%";
        var pctW    = dc.getTextWidthInPixels(pctStr, font);
        var midStr  = dot;
        var midW    = dc.getTextWidthInPixels(midStr, font);
        var evW     = dc.getTextWidthInPixels(evLabel, font);
        var arrowW  = dc.getTextWidthInPixels("▲ ", font);

        var fullW = arrowW + dc.getTextWidthInPixels(stepsLabel, font) +
                    dc.getTextWidthInPixels(dot, font) +
                    dc.getTextWidthInPixels("GOAL ", font) +
                    pctW + midW + evW;
        var startX = cx - fullW / 2;

        // Steps triangle
        dc.setColor(COLOR_STEPS_FG, Graphics.COLOR_TRANSPARENT);
        dc.drawText(startX, ty, font, "▲", Graphics.TEXT_JUSTIFY_LEFT);
        startX += dc.getTextWidthInPixels("▲", font) + 3;

        // Steps count
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(startX, ty, font, stepsLabel, Graphics.TEXT_JUSTIFY_LEFT);
        startX += dc.getTextWidthInPixels(stepsLabel, font);

        // Separator
        dc.setColor(0x333333, Graphics.COLOR_TRANSPARENT);
        dc.drawText(startX, ty, font, dot, Graphics.TEXT_JUSTIFY_LEFT);
        startX += dc.getTextWidthInPixels(dot, font);

        // "GOAL" muted, pct accented
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(startX, ty, font, "GOAL ", Graphics.TEXT_JUSTIFY_LEFT);
        startX += dc.getTextWidthInPixels("GOAL ", font);

        dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(startX, ty, font, pctStr, Graphics.TEXT_JUSTIFY_LEFT);
        startX += pctW;

        // Separator
        dc.setColor(0x333333, Graphics.COLOR_TRANSPARENT);
        dc.drawText(startX, ty, font, dot, Graphics.TEXT_JUSTIFY_LEFT);
        startX += dc.getTextWidthInPixels(dot, font);

        // Next event
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(startX, ty, font, evLabel, Graphics.TEXT_JUSTIFY_LEFT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    private function _accentColor() as Number {
        if (_pomState == :focus)   { return COLOR_FOCUS_ACT; }
        if (_pomState == :break)   { return COLOR_BREAK_ACT; }
        if (_pomState == :waiting) { return COLOR_FOCUS_PST; }
        return COLOR_IDLE_ACT;
    }

    // ── State transitions ────────────────────────────────────────────────────

    private function _startFocus() as Void {
        _pomState      = :focus;
        _segStartEpoch = Time.now().value();
        _segElapsed    = 0.0f;
        _segTotal      = POM_FOCUS_S.toFloat();
        _saveState();
        _scheduleWakeEvent(POM_FOCUS_S);
    }

    private function _startBreak() as Void {
        var isLong     = (_pomCompleted > 0 && _pomCompleted % 4 == 0);
        var breakSecs  = isLong ? POM_LONG_BREAK_S : POM_BREAK_S;
        _pomState      = :break;
        _segStartEpoch = Time.now().value();
        _segElapsed    = 0.0f;
        _segTotal      = breakSecs.toFloat();
        _saveState();
        _scheduleWakeEvent(breakSecs);
        _notify("ChronoFocus", isLong ? "Długa przerwa — 25 min!" : "Czas na przerwę!");
    }

    private function _toWaiting() as Void {
        _pomState   = :waiting;
        _segElapsed = POM_FOCUS_S.toFloat();
        _segTotal   = POM_FOCUS_S.toFloat();
        _saveState();
        _cancelWakeEvent();
        _notify("ChronoFocus", "Przerwa zakończona!");
    }

    private function _notify(title as String, subtitle as String) as Void {
        if (Notifications has :showNotification) {
            Notifications.showNotification(title, subtitle, {:actions => [], :dismissPrevious => true});
        }
    }


    // ── Persistence ──────────────────────────────────────────────────────────

    private function _saveState() as Void {
        var stateInt = 0;
        if (_pomState == :focus)   { stateInt = 1; }
        if (_pomState == :break)   { stateInt = 2; }
        if (_pomState == :waiting) { stateInt = 3; }
        Application.Storage.setValue("pom_state",       stateInt);
        Application.Storage.setValue("pom_completed",   _pomCompleted);
        Application.Storage.setValue("pom_start_epoch", _segStartEpoch);
        Application.Storage.setValue("pom_total",       _segTotal.toNumber());
        Application.Storage.setValue("pom_day",         _todayDayNumber());
    }

    private function _loadState() as Void {
        var today     = _todayDayNumber();
        var storedDay = Application.Storage.getValue("pom_day") as Number?;
        if (storedDay == null || storedDay != today) {
            _resetDay(today);
            return;
        }
        var c = Application.Storage.getValue("pom_completed") as Number?;
        _pomCompleted = (c != null) ? c : 0;
        var s = Application.Storage.getValue("pom_state") as Number?;
        var ep = Application.Storage.getValue("pom_start_epoch") as Number?;
        var stateInt = (s != null) ? s : 0;
        _segStartEpoch = (ep != null) ? ep : 0;
        if (stateInt == 1) {
            _pomState   = :focus;
            _segTotal   = POM_FOCUS_S.toFloat();
            _segElapsed = (Time.now().value() - _segStartEpoch).toFloat();
            if (_segElapsed >= _segTotal) { _pomCompleted++; _toWaiting(); }
        } else if (stateInt == 2) {
            var t = Application.Storage.getValue("pom_total") as Number?;
            _pomState   = :break;
            _segTotal   = (t != null && t > 0) ? t.toFloat() : POM_BREAK_S.toFloat();
            _segElapsed = (Time.now().value() - _segStartEpoch).toFloat();
            if (_segElapsed >= _segTotal) { _toWaiting(); }
        } else if (stateInt == 3) {
            _toWaiting();
        } else {
            _pomState   = :idle;
            _segElapsed = 0.0f;
            _segTotal   = POM_FOCUS_S.toFloat();
        }
    }

    private function _resetDay(today as Number) as Void {
        _pomState      = :idle;
        _pomCompleted  = 0;
        _segElapsed    = 0.0f;
        _segTotal      = POM_FOCUS_S.toFloat();
        _segStartEpoch = 0;
        Application.Storage.setValue("pom_day",         today);
        Application.Storage.setValue("pom_completed",   0);
        Application.Storage.setValue("pom_state",       0);
        Application.Storage.setValue("pom_start_epoch", 0);
        Application.Storage.setValue("pom_total",       0);
    }

    private function _checkDayReset() as Void {
        var today     = _todayDayNumber();
        var storedDay = Application.Storage.getValue("pom_day") as Number?;
        if (storedDay == null || storedDay != today) {
            _resetDay(today);
            WatchUi.requestUpdate();
        }
    }

    private function _todayDayNumber() as Number {
        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        return info.year * 10000 + info.month * 100 + info.day;
    }

}
