using Toybox.Application as App;
using Toybox.Lang;
using Toybox.WatchUi as Ui;
using Hass;

// Optional confirmation before a lock entity is locked or unlocked, set by
// the "lockConfirmation" app setting: none, a yes/no question, or a PIN.
//
// The PIN works like the Garmin Pay wallet passcode: four digits, entered
// on PinEntryView, and three wrong entries in a row lock it. It stays locked
// - across restarts, so restarting the app does not buy more guesses -
// until a different PIN is set in the app settings, just as the wallet's
// passcode has to be reset in Garmin Connect. Only the app settings can do
// that: the ConnectIQ app on the phone the watch is paired with, or Garmin
// Express on a computer the watch is connected to.
//
// The setting lives in the app settings only, deliberately: a watch-side
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

  // The wrong entries in a row, as [count, pin]. The count only applies
  // while `pin` is the configured PIN: failures made against an old PIN do
  // not carry over to a new one, and setting a different PIN ends a
  // lockout. One value, so a record is never half written (two keys could
  // leave a count behind without its PIN, locked for good). The PIN itself
  // may sit here: it is in plain text in the app's Properties anyway, in
  // the same sandbox.
  const STORAGE_KEY_FAILURES = "Lock/pinFailures";

  const MESSAGE_LOCKED = "PIN locked\nSet a different\nPIN in the app";

  // Called before `entity` (a lock) is toggled. Returns true when it took
  // over - a question, the PIN entry, the login or an error is on screen,
  // and the toggle happens from there, if at all - or false to toggle
  // right away.
  function request(entity) {
    var state = entity.getState();

    // Only locked/unlocked can be toggled; other states are refused by the
    // toggle, so there is nothing to confirm.
    if (state != Hass.STATE_LOCKED && state != Hass.STATE_UNLOCKED) {
      return false;
    }

    var mode = Utils.getProperty("lockConfirmation", MODE_OFF);

    if (mode != MODE_YES_NO && mode != MODE_PIN) {
      return false;
    }

    var viaWifiLte = WifiLte.shouldUse();

    // Direct connection: the phone, or on Edge units Wi-Fi outside a sync
    // (see WifiLte.hasDirectConnection()).
    if (!WifiLte.hasDirectConnection() && !viaWifiLte) {
      // Nothing could carry the command: no point in asking for a PIN
      // first. Reported here rather than left to the toggle, so that no
      // later change to the toggle's own checks can turn this into an
      // unconfirmed send. Error() also schedules the usual app exit.
      App.getApp().viewController.showError(new Error(Error.ERROR_PHONE_NOT_CONNECTED));
      return true;
    }

    if (!App.getApp().isLoggedIn()) {
      // Logged out (OAuth without a refresh token): the toggle cannot be
      // sent yet, so no PIN is spent on it. Not `return false` though: the
      // toggle would queue its request behind the login it starts
      // (OAuthClient.makeAuthenticatedWebRequest()) and send it as soon as
      // someone completes that login on the phone - unconfirmed. Only the
      // login is started; selected again, the lock asks as usual.
      App.getApp().login();
      return true;
    }

    var verb = state == Hass.STATE_LOCKED ? "Unlock" : "Lock";

    if (mode == MODE_YES_NO) {
      // Asked even when the action will go out over Wi-Fi/LTE, whose own
      // question then follows: leaving the lock's confirmation to the
      // toggle's Wi-Fi/LTE check would let a change there silently turn
      // the question off.
      var question = new Ui.Confirmation(verb + "\n" + entity.getRawName() + "?");
      Ui.pushView(question, new LockConfirmDelegate(entity, question), Ui.SLIDE_IMMEDIATE);
      return true;
    }

    var pin = getPin();

    // onSettingsChanged() only runs while the widget is open: catches up on
    // a PIN changed while it was not.
    dropStaleFailures(pin);

    if (pin == null) {
      // Fail closed: a PIN that is required but unusable must not mean
      // "no PIN".
      App.getApp().viewController.showError("Lock PIN not set\nor not 4 digits\n(app settings)");
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

  // The wrong entries in a row made against `pin`: 0 unless the stored
  // record belongs to that very PIN.
  function failuresFor(pin) {
    var s = App.Storage.getValue(STORAGE_KEY_FAILURES);
    return (s instanceof Lang.Array && s.size() == 2 && pin.equals(s[1])) ? s[0] : 0;
  }

  // Survives restarts, and ends when a different PIN is set.
  function isLockedOut(pin) {
    return failuresFor(pin) >= MAX_ATTEMPTS;
  }

  // Counts a wrong entry against `pin` and returns how many attempts are
  // left; 0 means the PIN is locked now.
  function recordFailure(pin) {
    var n = failuresFor(pin) + 1;
    App.Storage.setValue(STORAGE_KEY_FAILURES, [n, pin]);
    return n >= MAX_ATTEMPTS ? 0 : MAX_ATTEMPTS - n;
  }

  function resetFailures() {
    App.Storage.deleteValue(STORAGE_KEY_FAILURES);
  }

  // Drops the record when it was made against a PIN other than `pin`, the
  // configured one (null: none) - a different PIN has been set since. Left
  // in place it would come back, lockout and all, should that old PIN ever
  // be set again.
  function dropStaleFailures(pin) {
    if (App.Storage.getValue(STORAGE_KEY_FAILURES) != null && (pin == null || failuresFor(pin) == 0)) {
      resetFailures();
    }
  }

  // From HassControlApp.onSettingsChanged(): a different PIN ends a
  // lockout right away.
  function onSettingsChanged() {
    dropStaleFailures(getPin());
  }
}

// The yes/no question.
(:fullmem)
class LockConfirmDelegate extends Ui.ConfirmationDelegate {
  // How often run() waits another Scheduler.MIN_DELAY for the question to
  // go, about half a second in all.
  static const MAX_WAITS = 10;

  hidden var _mEntity;
  hidden var _mState;
  hidden var _mQuestion; // the Ui.Confirmation this answers, see run()
  hidden var _mWaits;

  function initialize(entity, question) {
    ConfirmationDelegate.initialize();
    _mEntity = entity;
    _mState = entity.getState();
    _mQuestion = question;
    _mWaits = 0;
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

  // When exactly the system pops the Confirmation after onResponse() is
  // not documented. Where getCurrentView() tells (3.4.0+), the toggle waits
  // for the question to be gone. After MAX_WAITS it goes ahead anyway, as
  // it does without getCurrentView(): waiting longer would not help, and
  // the confirmed action still happens.
  function run() {
    if (Ui has :getCurrentView && _mWaits < MAX_WAITS && Ui.getCurrentView()[0] == _mQuestion) {
      _mWaits++;
      Scheduler.schedule(:lockAction, method(:run), Scheduler.MIN_DELAY);
      return;
    }

    LockConfirm.execute(_mEntity, _mState);
  }
}
