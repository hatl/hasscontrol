using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;

// Every delayed callback in the app goes through this module, which runs
// them all off one single Timer.Timer.
//
// Connect IQ only lets an app run a few timers at once (3 by default, the
// exact number depends on the device) and throws "Too Many Timers Error"
// past that - on some firmware also when start() is called on a timer that
// is still running. The app used to own up to seven: the inactivity,
// loader, transitional-refresh and finalize timers, the page bar timer of
// the entity view, plus a new one for every "Close App after successful
// action" and for every "Phone not connected" Error. Toggling a cover in the
// list view with "Close App after successful action" enabled had five of
// them running at once (issue #101).
//
// Jobs are keyed by a Symbol. Scheduling a key that is still pending
// replaces that job (its deadline moves), so repeated calls - a refresh
// chain finishing twice, one "Phone not connected" error per entity - can
// never pile up. The timer is never start()ed without a stop() first.
//
// Do not create Timer.Timer objects anywhere else in the app.
module Scheduler {
  // Connect IQ's shortest timer period (50 ms by default, device dependent).
  const MIN_DELAY = 50;

  // A job due within this many ms is run with the current wake-up instead
  // of costing another MIN_DELAY round trip.
  const SLACK = 10;

  var _timer = null;
  var _onTimerMethod = null;
  var _jobs = {};       // key => [callback, due], due in System.getTimer() ms
  var _armedDue = null; // when the running timer fires; null while idle

  // Runs `callback` (a Lang.Method taking no arguments) once, `delayMs` from
  // now, replacing the job pending under `key` if there is one.
  function schedule(key, callback, delayMs) {
    if (delayMs < MIN_DELAY) {
      delayMs = MIN_DELAY;
    }

    var due = System.getTimer() + delayMs;
    _jobs[key] = [callback, due];
    _arm(due);
  }

  // Drops the job pending under `key`, if any. The timer itself is left
  // alone: a wake-up with nothing due costs next to nothing and re-arms for
  // whatever is still pending.
  function cancel(key) {
    _jobs.remove(key);
  }

  // Makes sure the timer fires no later than `due`.
  function _arm(due) {
    // System.getTimer() wraps around, so moments are compared through their
    // difference rather than directly.
    if (_armedDue != null && _armedDue - due <= 0) {
      return;
    }

    if (_timer == null) {
      _timer = new Timer.Timer();
      _onTimerMethod = new Lang.Method(Scheduler, :_onTimer);
    } else {
      // Always stop before start: starting a timer that is still running is
      // exactly what can raise "Too Many Timers Error" on its own.
      _timer.stop();
    }

    var now = System.getTimer();
    var wait = due - now;
    if (wait < MIN_DELAY) {
      wait = MIN_DELAY;
    }

    _armedDue = now + wait;
    _timer.start(_onTimerMethod, wait, false);
  }

  function _onTimer() {
    _armedDue = null;

    var now = System.getTimer();
    var keys = _jobs.keys();

    for (var i = 0; i < keys.size(); i++) {
      // Looked up again for every key: a callback run earlier in this loop
      // may have cancelled or rescheduled any of the others.
      var job = _jobs[keys[i]];

      if (job != null && job[1] - now <= SLACK) {
        _jobs.remove(keys[i]);
        job[0].invoke();
      }
    }

    // Jobs scheduled by the callbacks above have armed the timer already;
    // this covers the ones that were pending but not due yet.
    keys = _jobs.keys();
    var next = null;

    for (var i = 0; i < keys.size(); i++) {
      var due = _jobs[keys[i]][1];

      if (next == null || due - next < 0) {
        next = due;
      }
    }

    if (next != null) {
      _arm(next);
    }
  }
}
