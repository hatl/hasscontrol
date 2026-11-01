using Toybox.WatchUi as Ui;
using Toybox.System;


class Error {
    static var ERROR_UNKNOWN = 0;
    static var ERROR_PHONE_NOT_CONNECTED = 1;

    var code;
    var message;
    var context;
    var responseCode = null;  // Added to prevent crash when checking responseCode on base Error

    function exitApplication() {
        System.exit();
    }

    function initialize(errorCode) {
        if (errorCode == Error.ERROR_PHONE_NOT_CONNECTED) {
            code = Error.ERROR_PHONE_NOT_CONNECTED;
            message = Rez.Strings.Error_PhoneNotConnected;
            // One keyed job however many of these are built - every request
            // that fails this way builds one, and each used to start a Timer
            // of its own: "Too Many Timers Error" once three ran (issue #101).
            Scheduler.schedule(:exit, method(:exitApplication), 2500);
            return;
        }

        code = Error.ERROR_UNKNOWN;
        message = Rez.Strings.Error_Unknown;
        context = null;
    }

    function setContext(ctx) {
        context = ctx;
    }

    function toString() {
        var str = Ui.loadResource(message);
        var string = "Error: " + str;

        if (context != null) {
            string += " ctx=" + context;
        }
        return string;
    }

    function toShortString() {
        var str = Ui.loadResource(message);
        return str;
    }
}