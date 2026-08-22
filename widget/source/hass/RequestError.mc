using Toybox.WatchUi as Ui;
using Toybox.System;
using Toybox.Communications as Comm;

(:glance)
module Hass {
    class RequestError extends Error {
        var code;
        var message;

        var responseCode;

        function initialize(resCode) {
            Error.initialize(resCode);

            responseCode = resCode;

            if (resCode == 401) {
                code = ERROR_NOT_AUTHORIZED;
                message = Rez.Strings.Error_Request_NotAuthorized;
                return;
            }

            if (resCode == 404) {
                code = ERROR_NOT_FOUND;
                message = Rez.Strings.Error_Request_NotFound;
                return;
            }

            // The system could not parse the response into the app's heap.
            // On a 64 KB widget device that means the Home Assistant group has
            // more members than the watch can hold - a real limit the user can
            // act on, not the "Unknown error, code=-403" it showed before.
            if (resCode == Comm.NETWORK_RESPONSE_OUT_OF_MEMORY) {
                code = ERROR_OUT_OF_MEMORY;
                message = Rez.Strings.Error_Request_OutOfMemory;
                return;
            }

            if (resCode == ERROR_INVALID_URL) {
                code = ERROR_INVALID_URL;
                message = Rez.Strings.Error_Request_InvalidUrl;
                return;
            }
        }

        function toString() {
            var str = Ui.loadResource(message);
            var string = "RequestError: " + str + ", code=" + responseCode;

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
}