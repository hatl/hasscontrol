using Toybox.Application as App;
using Toybox.System;
using Toybox.WatchUi as Ui;
using Hass;

// Optional confirmation before a lock entity is locked or unlocked, set by
// the "lockConfirmation" app setting: none, a yes/no question, or a PIN.
//
// The PIN works like the Garmin Pay wallet passcode: four digits, entered
// on PinEntryView, and three wrong entries in a row lock it. It stays locked
// - across restarts, so restarting the app does not buy more guesses -
// until a different PIN is set in the app settings, just as the wallet's
// passcode has to be reset in Garmin Connect. Only the phone the watch is
// paired with can do that.
//
// The setting lives in the phone app only, deliberately: a watch-side
// switch would let anyone holding the watch turn the PIN off.
//
// :fullmem only, see monkey.jungle.
(:fullmem)
module LockConfirm {
  // Values of the "lockConfirmation" list setting.
  enum {
    MODE_OFF,
    MODE_YES_NO,
    MODE_PIN
  }

  const PIN_LENGTH = 4;
  const MAX_ATTEMPTS = 3;

  // Consecutive wrong entries, and the hash of the PIN they were made
  // against once MAX_ATTEMPTS is reached (locked).
  const STORAGE_KEY_FAILURES = "Lock/pinFailures";
  const STORAGE_KEY_LOCKED = "Lock/pinLocked";

  const MESSAGE_LOCKED = "PIN locked\nSet a new PIN in\nthe app settings";

  // Called before `entity` (a lock) is toggled. Returns true when it took
  // over - a question, the PIN entry or an error is on screen, and the
  // toggle happens from there - or false to toggle right away.
  function request(entity) {
    var state = entity.getState();

    // Hass.toggleEntityState() only acts on these two.
    if (state != Hass.STATE_LOCKED && state != Hass.STATE_UNLOCKED) {
      return false;
    }

    var mode = Utils.getProperty("lockConfirmation", MODE_OFF);

    if (mode != MODE_YES_NO && mode != MODE_PIN) {
      return false;
    }

    var viaWifiLte = WifiLte.shouldUse();

    if (!System.getDeviceSettings().phoneConnected && !viaWifiLte) {
      // Nothing could carry the command: no point in asking for a PIN
      // first. The toggle reports "Phone not connected".
      return false;
    }

    var verb = state == Hass.STATE_LOCKED ? "Unlock" : "Lock";

    if (mode == MODE_YES_NO) {
      if (viaWifiLte) {
        // The Wi-Fi/LTE prompt the toggle shows asks the same question.
        return false;
      }

      Ui.pushView(
        new Ui.Confirmation(verb + "\n" + entity.getRawName() + "?"),
        new LockConfirmDelegate(entity),
        Ui.SLIDE_IMMEDIATE
      );
      return true;
    }

    var pin = getPin();

    if (pin == null) {
      // Fail closed: a PIN that is required but unusable must not mean
      // "no PIN".
      App.getApp().viewController.showError("Lock PIN not set\nEnter 4 digits in\nthe app settings");
      return true;
    }

    if (isLockedOut(pin)) {
      App.getApp().viewController.showError(MESSAGE_LOCKED);
      return true;
    }

    var view = new PinEntryView(verb + " " + entity.getRawName());
    Ui.pushView(view, new PinEntryDelegate(view, entity, pin), Ui.SLIDE_IMMEDIATE);
    return true;
  }

  // Toggles `entity` once confirmed. The action is worked out from the
  // state again (Hass.toggleEntityState()): if a refresh changed the state
  // while the question was up, toggling now would do the opposite of what
  // was confirmed - lock instead of unlock, or the other way round.
  function execute(entity, confirmedState) {
    if (entity.getState() != confirmedState) {
      App.getApp().viewController.showError("Lock state\nchanged,\nplease retry");
      return;
    }

    Hass.toggleEntityState(entity);
  }

  // The configured PIN, or null unless it is exactly PIN_LENGTH digits.
  function getPin() {
    var pin = Utils.getProperty("lockPin", "");

    if (pin == null) {
      return null;
    }

    pin = pin.toString();

    if (pin.length() != PIN_LENGTH) {
      return null;
    }

    var chars = pin.toCharArray();

    for (var i = 0; i < chars.size(); i++) {
      var c = chars[i].toNumber();

      if (c < 48 || c > 57) { // '0'..'9'
        return null;
      }
    }

    return pin;
  }

  function isLockedOut(pin) {
    var failures = App.Storage.getValue(STORAGE_KEY_FAILURES);

    if (failures == null || failures < MAX_ATTEMPTS) {
      return false;
    }

    var lockedPin = App.Storage.getValue(STORAGE_KEY_LOCKED);

    if (lockedPin != null && lockedPin != pin.hashCode()) {
      // A new PIN was set in the app settings since: unlocked.
      resetFailures();
      return false;
    }

    return true;
  }

  // Counts a wrong entry and returns how many attempts are left; 0 means the
  // PIN is locked now.
  function recordFailure(pin) {
    var failures = App.Storage.getValue(STORAGE_KEY_FAILURES);
    failures = failures == null ? 1 : failures + 1;

    App.Storage.setValue(STORAGE_KEY_FAILURES, failures);

    if (failures >= MAX_ATTEMPTS) {
      // The hash, not the PIN itself: enough to notice a new one.
      App.Storage.setValue(STORAGE_KEY_LOCKED, pin.hashCode());
      return 0;
    }

    return MAX_ATTEMPTS - failures;
  }

  function resetFailures() {
    App.Storage.deleteValue(STORAGE_KEY_FAILURES);
    App.Storage.deleteValue(STORAGE_KEY_LOCKED);
  }
}

// The yes/no question.
(:fullmem)
class LockConfirmDelegate extends Ui.ConfirmationDelegate {
  hidden var _mEntity;
  hidden var _mState;

  function initialize(entity) {
    ConfirmationDelegate.initialize();
    _mEntity = entity;
    _mState = entity.getState();
  }

  function onResponse(response) {
    App.getApp().resetInactivityTimer();

    if (response == Ui.CONFIRM_YES) {
      // The system pops the Confirmation only after this returns. Toggling
      // right here would push the loader first - and the pop meant for the
      // Confirmation would then take the loader off instead.
      Scheduler.schedule(:lockAction, method(:run), Scheduler.MIN_DELAY);
    }

    return true;
  }

  function run() {
    LockConfirm.execute(_mEntity, _mState);
  }
}
