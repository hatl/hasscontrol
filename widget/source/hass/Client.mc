using Toybox.Communications as Comm;
using Toybox.Application as App;
using Toybox.StringUtil;
using Hass;
using Utils;

(:glance)
module Hass {
    const AUTH_ENDPOINT = "/auth/authorize";
    const TOKEN_ENDPOINT = "/auth/token";

    class Client extends Hass.OAuthClient {
        static enum {
            ENTITY_ACTION_TURN_ON,
            ENTITY_ACTION_TURN_OFF,
            ENTITY_ACTION_LOCK,
            ENTITY_ACTION_UNLOCK,
            ENTITY_ACTION_CLOSE,
            ENTITY_ACTION_OPEN,
            ENTITY_ACTION_COVER_TOGGLE,
            ENTITY_ACTION_PRESS
        }

        hidden var _baseUrl;
        hidden var _baseUrlIsValid;

        function initialize() {
            refreshBaseUrl();

            OAuthClient.initialize({
                :authUrl => _baseUrl + AUTH_ENDPOINT,
                :tokenUrl => _baseUrl + TOKEN_ENDPOINT,
                :clientId => "https://hasscontrol",
                :redirectUrl => "https://hasscontrol/hass/auth_callback"
            });
        }

        function refreshBaseUrl() {
            var newUrl = Utils.getProperty("host", "https://homeassistant.local");
            var chars = newUrl.toCharArray();

            // strip potential trailing slash
            if (chars.size() > 0 && chars[chars.size() - 1] == '/') {
                chars = chars.slice(0, chars.size() - 1);
            }

            // Set even when the host is invalid (empty, say): initialize()
            // and onSettingsChanged() build the auth URLs from it, and
            // validateSettings() stops every request before it is used.
            _baseUrl = StringUtil.charArrayToString(chars);

            // verify that host is starting with "https://" - or is plain
            // http to the phone itself (:fullmem, see isLoopbackHttpUrl())
            _baseUrlIsValid = _baseUrl.find("https://") == 0 || isLoopbackHttpUrl(_baseUrl);
        }

        // Plain http is accepted for the loopback host only:
        // "http://localhost", "http://127.0.0.1" or "http://[::1]", each
        // optionally followed by a port and a path. Requests travel through
        // the phone, so loopback is meant to reach a server on the phone
        // itself - e.g. a local proxy app forwarding to Home Assistant on
        // the LAN. That works in the Connect IQ simulator; whether the
        // Garmin Connect app relays plain http to the phone's own loopback
        // has not been verified (iOS/Android cleartext policies may block
        // it).
        //
        // The host has to end right there - only the end of the URL, ":"
        // (a port) or "/" (a path) may follow: "http://localhost.example.com"
        // is a different host on the internet and stays rejected. "?" and
        // "#" are refused too, as the API paths are appended to the URL. And
        // so is any "@", wherever it is: "http://localhost:8123@evil.example.com"
        // is user "localhost" with password "8123" at evil.example.com.
        //
        // Matched case-insensitively, as phone keyboards capitalise the
        // first letter ("Http://localhost"); the URL is still used as typed.
        (:fullmem)
        hidden function isLoopbackHttpUrl(url) {
            if (url.find("@") != null) {
                return false;
            }

            var lower = url.toLower();
            var hosts = ["http://localhost", "http://127.0.0.1", "http://[::1]"];

            for (var i = 0; i < hosts.size(); i++) {
                var length = hosts[i].length();

                if (lower.find(hosts[i]) == 0) {
                    if (lower.length() == length) {
                        return true;
                    }

                    var next = lower.substring(length, length + 1);
                    return next.equals(":") || next.equals("/");
                }
            }

            return false;
        }

        (:lowmem)
        hidden function isLoopbackHttpUrl(url) {
            return false;
        }

        // Wi-Fi/LTE execution needs https: over Wi-Fi the watch connects to
        // Home Assistant itself, so a loopback host would be the watch.
        (:fullmem)
        function isHttpsUrl() {
            return _baseUrlIsValid && _baseUrl.find("https://") == 0;
        }

        function onSettingsChanged() {
            refreshBaseUrl();

            OAuthClient.onSettingsChanged();

            setAuthUrl(_baseUrl + AUTH_ENDPOINT);
            setTokenUrl(_baseUrl + TOKEN_ENDPOINT);
        }

        // Whether a request can go out at all. They are relayed by the phone -
        // except from inside a Wi-Fi/LTE sync, and over Wi-Fi that is up
        // outside one (Edge units), where the watch sends them itself
        // (:fullmem, see WifiLte.hasDirectConnection()).
        (:fullmem)
        hidden function hasConnection() {
            return WifiLte.isSyncActive() || WifiLte.hasDirectConnection();
        }

        (:lowmem)
        hidden function hasConnection() {
            return System.getDeviceSettings().phoneConnected;
        }

        function validateSettings(errorCallback) {
            var error = null;

            if (!hasConnection()) {
                error = new Error(OAuthError.ERROR_PHONE_NOT_CONNECTED);
            }

            if (!_baseUrlIsValid) {
                error = new RequestError(ERROR_INVALID_URL);
            }

            if (error != null && errorCallback != null) {
                errorCallback.invoke(error, null);
            }

            return error;
        }


        function getEntity(entityId, context, callback) {
            if (validateSettings(callback) != null) {
                return;
            }

            if (context == null) {
                context = {};
            }

            if (context[:resource] == null) {
                context[:resource] = entityId;
            }

            makeAuthenticatedWebRequest(
                _baseUrl + "/api/states/" + entityId,
                {},
                {
                    :context => context
                },
                callback
            );
        }

        function setEntityState(entityId, entityType, action, callback) {
            if (validateSettings(callback) != null) {
                return;
            }

            var serviceAction = "turn_on";
            var newState = null;

            if (action == Client.ENTITY_ACTION_TURN_ON) {
                serviceAction = "turn_on";
                newState = "on";
            } else if (action == Client.ENTITY_ACTION_TURN_OFF) {
                serviceAction = "turn_off";
                newState = "off";
            } else if (action == Client.ENTITY_ACTION_CLOSE) {
                // OPEN/CLOSE are only used for valves - covers toggle (below).
                // Home Assistant's valve services are open_valve and
                // close_valve; there is no "valve/open" or "valve/close".
                serviceAction = "close_valve";
                newState = "closed";
            } else if (action == Client.ENTITY_ACTION_COVER_TOGGLE) {
                serviceAction = "toggle";
            } else if (action == Client.ENTITY_ACTION_OPEN) {
                serviceAction = "open_valve";
                newState = "open";
            } else if (action == Client.ENTITY_ACTION_LOCK) {
                serviceAction = "lock";
                newState = "locked";
            } else if (action == Client.ENTITY_ACTION_UNLOCK) {
                serviceAction = "unlock";
                newState = "unlocked";
            } else if (action == Client.ENTITY_ACTION_PRESS) {
                serviceAction = "press";
                newState = "timestamp"; // button doesn't have a real state - the state is the time stamp of it's last triggering
            }

            makeAuthenticatedWebRequest(
                _baseUrl + "/api/services/" + entityType + "/" + serviceAction,
                {
                    "entity_id" => entityId
                },
                {
                    :method => Comm.HTTP_REQUEST_METHOD_POST,
                    :context => {
                        :entityId => entityId,
                        :state => newState,
                    }
                },
                callback
            );
        }

        // Only used by select/input_select/input_number/number editing,
        // :fullmem-only (see Entity.mc and Hass.selectOption()/
        // setInputNumberValue()) - 64 KB widget devices show these entities
        // read-only.
        (:fullmem)
        function callService(domain, service, entityId, extraParams, callback) {
            if (validateSettings(callback) != null) {
                return;
            }

            var body = { "entity_id" => entityId };
            var keys = extraParams.keys();

            for (var i = 0; i < keys.size(); i++) {
                body[keys[i]] = extraParams[keys[i]];
            }

            makeAuthenticatedWebRequest(
                _baseUrl + "/api/services/" + domain + "/" + service,
                body,
                {
                    :method => Comm.HTTP_REQUEST_METHOD_POST,
                    :context => {
                        :entityId => entityId,
                        :extraParams => extraParams
                    }
                },
                callback
            );
        }

        function reportBatteryValue(entity_id, callback) {
            var state = System.getSystemStats().battery.toNumber();
            makeAuthenticatedWebRequest(
                _baseUrl + "/api/states/sensor." + entity_id,
                {
                    "state" => state,
                    "attributes" => {
                        "unit_of_measurement" => "%",
                        "device_class" => "battery",
                        "state_class" => "measurement"
                    }
                },
                {
                    :method => Comm.HTTP_REQUEST_METHOD_POST,
                    :context => {
                        :entityId => entity_id,
                        :state => state,
                    }
                },
                callback
            );
        }
    }
}
