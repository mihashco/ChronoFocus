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

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Math;
import Toybox.System;
import Toybox.ActivityMonitor;
import Toybox.Activity;
import Toybox.Time;
import Toybox.Time.Gregorian;

// Convenient aliases to ChronoUI barrel classes
using ChronoUIBarrel.ChronoUI as ChronoUI;

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
    private const COLOR_FOCUS_FUT as Number = 0x383838; // future focus segments
    private const COLOR_BREAK_TRK as Number = 0x1A1A1A; // break track (bg shade)
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

    // ── Work-day / pomodoro constants ─────────────────────────────────────────
    private const WORK_START_H as Number = 8;  // 08:00
    private const WORK_END_H   as Number = 16; // 18:00
    private const POM_FOCUS    as Number = 25; // minutes
    private const POM_BREAK    as Number = 5;  // minutes
    private const POM_LONG_BRK as Number = 15; // long break every 4 poms

    // ── Pomodoro state (managed by this view; set from delegate) ──────────────
    private var _pomState     as Symbol;  // :focus | :break | :idle
    private var _segElapsed   as Float;   // minutes elapsed in current segment
    private var _segTotal     as Float;   // total minutes for current segment
    private var _pomCompleted as Number;
    private var _pomGoal      as Number;  // target pomodoros for the day
    private var _focusTask    as String;
    private var _streak       as Number;
    private var _nextEvTime   as String;

    // ── Pre-built day segments (focus/break sequence for the work day) ────────
    private var _segments as Array;

    // ─────────────────────────────────────────────────────────────────────────
    // LIFECYCLE
    // ─────────────────────────────────────────────────────────────────────────

    public function initialize() {
        WatchFace.initialize();

        // Default / demo pomodoro state — replace with AppStorage persistence
        _pomState     = :focus;
        _segElapsed   = 12.0f;   // 12 min into current focus
        _segTotal     = POM_FOCUS.toFloat();
        _pomCompleted = 3;
        _pomGoal      = 12;
        _focusTask    = "Q3 roadmap";
        _streak       = 14;
        _nextEvTime   = "13:30";

        _segments = _buildSegments();
    }

    public function onLayout(dc as Dc) as Void {
        // Fully programmatic — no layout resource needed.
    }

    public function onUpdate(dc as Dc) as Void {
        System.println("Test onUpdate Function");
        var sw  = dc.getWidth();
        var sh  = dc.getHeight();
        var cx  = (sw / 2).toNumber();
        var cy  = (sh / 2).toNumber();
        var R   = ((sw < sh ? sw : sh) / 2).toNumber(); // watch radius

        // ── Live system data ─────────────────────────────────────────────────
        var ct          = System.getClockTime();
        var sysStats    = System.getSystemStats();
        var battPct     = (sysStats.battery + 0.5f).toNumber(); // 0–100

        var dayTotal    = (WORK_END_H - WORK_START_H) * 60;     // 600 min
        var dayElapsed  = (ct.hour - WORK_START_H) * 60 + ct.min;
        if (dayElapsed < 0)        { dayElapsed = 0; }
        if (dayElapsed > dayTotal) { dayElapsed = dayTotal; }

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
        // _drawBottomBar     (dc, cx, cy, R, steps, stepsGoal, dailyGoalPct, accentColor);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC API (call from WatchFaceDelegate)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Cycle pomodoro state: idle → focus → break → focus → ...
     * Bind to a hardware button in your delegate's onKey().
     */
    public function onPomodoroAction() as Void {
        if (_pomState == :idle) {
            _pomState   = :focus;
            _segElapsed = 0.0f;
            _segTotal   = POM_FOCUS.toFloat();
        } else if (_pomState == :focus) {
            _pomState   = :break;
            _segElapsed = 0.0f;
            _segTotal   = POM_BREAK.toFloat();
        } else {
            _pomState   = :focus;
            _segElapsed = 0.0f;
            _segTotal   = POM_FOCUS.toFloat();
        }
        WatchUi.requestUpdate();
    }

    /**
     * Advance the active segment by deltaMin minutes.
     * Call from a 1-minute timer in your AppBase (or onPartialUpdate).
     */
    public function tickMinute(deltaMin as Float) as Void {
        if (_pomState == :idle) { return; }
        _segElapsed += deltaMin;
        if (_segElapsed >= _segTotal) {
            if (_pomState == :focus) {
                _pomCompleted++;
                _pomState   = :break;
                _segElapsed = 0.0f;
                _segTotal   = ((_pomCompleted % 4 == 0) ? POM_LONG_BRK : POM_BREAK).toFloat();
            } else {
                _pomState   = :focus;
                _segElapsed = 0.0f;
                _segTotal   = POM_FOCUS.toFloat();
            }
        }
        WatchUi.requestUpdate();
    }

    /** Update user-configurable data (call after loading from AppStorage). */
    public function setMeta(task as String, streak as Number, nextEvTime as String) as Void {
        _focusTask  = task;
        _streak     = streak;
        _nextEvTime = nextEvTime;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: DRAWING
    // ─────────────────────────────────────────────────────────────────────────

    private function _clearBackground(dc as Dc, sw as Number, sh as Number) as Void {
        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();
    }

    // ── DAY RING: two symmetric arcs, same radius ─────────────────────────────
    //   AM ring (top):    ARC_START → ARC_START-DAY_HALF_SPAN  (160°→20°)
    //   PM ring (bottom): DAY_PM_START → DAY_PM_START-DAY_HALF_SPAN (-20°→-160°)
    //   ~40° gap on each side (3 and 9 o'clock) for complications.
    private function _drawDayRing(
        dc          as Dc,
        cx          as Number,
        cy          as Number,
        R           as Number,
        dayElapsed  as Number,
        dayTotal    as Number,
        accentColor as Number
    ) as Void {
        var rOuter  = (R.toFloat() * RF_OUTER).toNumber();
        var halfMin = dayTotal.toFloat() / 2.0f;
        var amEnd   = ARC_START    - DAY_HALF_SPAN;  //  20°
        var pmEnd   = DAY_PM_START - DAY_HALF_SPAN;  // -160°

        // ── Background tracks ─────────────────────────────────────────────────
        dc.setColor(COLOR_RING_BG, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(10);
        dc.drawArc(cx, cy, rOuter, Graphics.ARC_CLOCKWISE,
            ARC_START.toNumber(),    amEnd.toNumber());
        dc.drawArc(cx, cy, rOuter, Graphics.ARC_CLOCKWISE,
            DAY_PM_START.toNumber(), pmEnd.toNumber());

        // ── Pomodoro segments ─────────────────────────────────────────────────
        for (var i = 0; i < _segments.size(); i++) {
            var seg  = _segments[i] as Dictionary;
            var kind = seg[:kind]   as Symbol;
            var sF   = (seg[:start] as Number).toFloat();
            var eF   = (seg[:end]   as Number).toFloat();

            var isPast    = (seg[:end]   as Number) <= dayElapsed;
            var isCurrent = dayElapsed   >= (seg[:start] as Number) &&
                            dayElapsed   <  (seg[:end]   as Number);

            var col;
            var pw;
            if (kind == :focus) {
                pw  = 10;
                col = isPast    ? COLOR_FOCUS_PST :
                      isCurrent ? accentColor      :
                                  COLOR_FOCUS_FUT;
            } else {
                pw  = 4;
                col = isPast ? COLOR_DIMLINE : COLOR_BREAK_TRK;
            }
            dc.setPenWidth(pw);
            dc.setColor(col, Graphics.COLOR_TRANSPARENT);

            // AM portion — top arc
            if (sF < halfMin) {
                var s  = sF;
                var e  = (eF < halfMin) ? eF : halfMin;
                var a1 = ARC_START - (s / halfMin) * DAY_HALF_SPAN;
                var a2 = ARC_START - (e / halfMin) * DAY_HALF_SPAN;
                dc.drawArc(cx, cy, rOuter, Graphics.ARC_CLOCKWISE,
                    a1.toNumber(), (a2 + 0.4f).toNumber());
            }

            // PM portion — bottom arc
            if (eF > halfMin) {
                var s  = (sF > halfMin) ? sF : halfMin;
                var e  = eF;
                var a1 = DAY_PM_START - ((s - halfMin) / halfMin) * DAY_HALF_SPAN;
                var a2 = DAY_PM_START - ((e - halfMin) / halfMin) * DAY_HALF_SPAN;
                dc.drawArc(cx, cy, rOuter, Graphics.ARC_CLOCKWISE,
                    a1.toNumber(), (a2 + 0.4f).toNumber());
            }
        }
    }

    // ── CURRENT POSITION MARKER ──────────────────────────────────────────────
    private function _drawCurrentMarker(
        dc          as Dc,
        cx          as Number,
        cy          as Number,
        R           as Number,
        dayElapsed  as Number,
        dayTotal    as Number,
        accentColor as Number
    ) as Void {
        var rOuter  = (R.toFloat() * RF_OUTER).toNumber();
        var halfMin = dayTotal.toFloat() / 2.0f;
        var isAM    = dayElapsed.toFloat() <= halfMin;

        var startDeg = isAM ? ARC_START    : DAY_PM_START;
        var prog     = isAM
            ? dayElapsed.toFloat() / halfMin
            : (dayElapsed.toFloat() - halfMin) / halfMin;

        ChronoUI.RadialMarker.draw(dc, prog, {
            :cx             => cx,            :cy           => cy,
            :radius         => rOuter,
            :startDeg       => startDeg,      :sweepDeg     => DAY_HALF_SPAN,
            :color          => accentColor,   :size         => 6,
            :style          => :dot,
            :trail          => true,          :trailDeg     => 12.0f,
            :trailThickness => 2,             :trailColor   => accentColor
        });
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

        if (_pomState == :idle || _segTotal <= 0.0f) { return; }

        var prog   = ChronoUI.UiMath.clamp01(_segElapsed / _segTotal);
        var pAngle = ARC_START - prog * ARC_SPAN;

        dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
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
        var sepOff1 = (R.toFloat() * 0.22f).toNumber();
        var sepOff2 = (R.toFloat() * 0.36f).toNumber();
        var sepY1   = cy + sepOff1;
        var sepY2   = cy + sepOff2;
        var blockW  = (R.toFloat() * 1.0f).toNumber();  // full inner width

        dc.setColor(COLOR_DIMLINE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        dc.drawLine(cx - blockW / 2, sepY1, cx + blockW / 2, sepY1);
        dc.drawLine(cx - blockW / 2, sepY2, cx + blockW / 2, sepY2);

        // Vertical centre divider
        dc.drawLine(cx, sepY1 + 2, cx, sepY2 - 2);
        var blockCY = (sepY1 + sepY2) / 2;

        // Left half: POM label + countdown
        var pomLabel = "POM " + (_pomCompleted + 1).toString();
        var pSize = 20;
        var pFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => pSize
        });

        var pValSize = 20;
        var pValFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => pValSize
        });
        var leftCX   = cx - blockW / 4;

        var remTotal = _segTotal - _segElapsed;
        var remM     = remTotal.toNumber();
        var remS     = ((remTotal - remM.toFloat()) * 60.0f + 0.5f).toNumber();
        if (remM < 0) { remM = 0; }
        if (remS < 0) { remS = 0; }
        var remStr   = (_pomState == :idle)
            ? "--:--"
            : (remM < 10 ? "0" : "") + remM.toString() + ":" +
              (remS < 10 ? "0" : "") + remS.toString();

        ChronoUI.UiText.drawCenteredAt(dc, leftCX, sepY1 + 7,  pomLabel, pFont, 0x555555);
        ChronoUI.UiText.drawCenteredAt(dc, leftCX, blockCY + 5, remStr,  pValFont, accentColor);

        // Right half: SET X / total
        var rightCX   = cx + blockW / 4;
        var cmpStr    = _pomCompleted.toString();
        var totalStr  = "/" + _pomGoal.toString();
        var cmpSize = 20;
        var cmpFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => cmpSize
        });

        ChronoUI.UiText.drawCenteredAt(dc, rightCX, sepY1 + 7, "SET", pFont, 0x555555);

        var cmpW  = dc.getTextWidthInPixels(cmpStr,   cmpFont);
        var totW  = dc.getTextWidthInPixels(totalStr,  pFont);
        var rowW  = cmpW + totW;
        var rowX  = rightCX - rowW / 2;
        var rowCY = blockCY + 5;
        var cmpH  = dc.getFontHeight(cmpFont);
        var totH  = dc.getFontHeight(pFont);

        dc.setColor(COLOR_FG, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rowX, rowCY - cmpH / 2, cmpFont, cmpStr,
            Graphics.TEXT_JUSTIFY_LEFT);

        dc.setColor(0x555555, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rowX + cmpW, rowCY - totH / 2, pFont, totalStr,
            Graphics.TEXT_JUSTIFY_LEFT);
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

        var lSize = 20;
        var lFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => lSize
        });

        var vSize = 20;
        var vFont = Graphics.getVectorFont({
            :face => ["RobotoCondensed", "RobotoRegular", "Swiss721Regular"],
            :size => vSize
        });


        // ── Left: Heart Rate ─────────────────────────────────────────────────
        var lx     = cx - offset;
        var hrStr  = (hr > 0) ? hr.toString() : "--";

        ChronoUI.UiText.drawCenteredAt(dc, lx, cy - 14, "HR",    lFont, 0x555555);
        ChronoUI.UiText.drawCenteredAt(dc, lx, cy + 2,  hrStr,   vFont, COLOR_FG);
        ChronoUI.UiText.drawCenteredAt(dc, lx, cy + 16, "BPM",   lFont, COLOR_HR_RED);

        // ── Right: Streak ────────────────────────────────────────────────────
        var rx = cx + offset;

        ChronoUI.UiText.drawCenteredAt(dc, rx, cy - 14, "SER",       lFont, 0x555555);
        ChronoUI.UiText.drawCenteredAt(dc, rx, cy + 2,  _streak.toString(), vFont, COLOR_FG);
        ChronoUI.UiText.drawCenteredAt(dc, rx, cy + 16, "DAYS",         lFont, COLOR_STEPS_FG);
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
        if (_pomState == :focus) { return COLOR_FOCUS_ACT; }
        if (_pomState == :break) { return COLOR_BREAK_ACT; }
        return COLOR_IDLE_ACT;
    }

    /**
     * Build the sequence of focus/break segments for the full work day.
     * Returns Array<Dictionary> each with :kind, :start, :end (minutes from 08:00).
     */
    private function _buildSegments() as Array {
        var segs    = [] as Array<Dictionary>;
        var dayMins = (WORK_END_H - WORK_START_H) * 60;
        var elapsed = 0;
        var pomIdx  = 0;

        while (elapsed < dayMins) {
            // Focus block
            var fEnd = elapsed + POM_FOCUS;
            if (fEnd > dayMins) { fEnd = dayMins; }
            segs.add({ :kind => :focus, :start => elapsed, :end => fEnd, :idx => pomIdx });
            elapsed = fEnd;
            if (elapsed >= dayMins) { break; }

            // Break block (long every 4th pomodoro)
            var isLong = ((pomIdx + 1) % 4 == 0);
            var bLen   = isLong ? POM_LONG_BRK : POM_BREAK;
            var bEnd   = elapsed + bLen;
            if (bEnd > dayMins) { bEnd = dayMins; }
            var bKind  = isLong ? :longbreak : :break;
            segs.add({ :kind => bKind, :start => elapsed, :end => bEnd, :idx => pomIdx });
            elapsed = bEnd;
            pomIdx++;
        }

        return segs;
    }
}
