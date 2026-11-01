using Toybox.Communications as Comm;
using Toybox.Application as App;
using Toybox.StringUtil;
using Toybox.Time;
using Utils;

(:glance)
module Hass {
    class OAuthClient {
        hidden var _authUrl;
        hidden var _tokenUrl;
        hidden var _clientId;
        hidden var _redirectUrl;
        hidden var _credentials;

        hidden var _tokenCallbacks;

        hidden var _isLoggingIn;
        hidden var _isFetchingAccessToken;
        hidden var _additionalHeaderKey;
        hidden var _additionalHeaderValue;
        // Context of the request in flight inside a Wi-Fi/LTE sync - see
        // doAuthenticatedWebRequest() and onSyncWebResponse().
        (:fullmem) hidden var _syncContext;

        function initialize(options) {
            Comm.registerForOAuthMessages(method(:onReceiveCode));

            _authUrl = options[:authUrl];
            _tokenUrl = options[:tokenUrl];
            _clientId = options[:clientId];
            _redirectUrl = options[:redirectUrl];
            _credentials = new OauthCredentials();
            _tokenCallbacks = new [0];
            _isLoggingIn = false;
            _isFetchingAccessToken = false;
            _additionalHeaderKey = Utils.getProperty("additional_header_key", "");
            _additionalHeaderValue = Utils.getProperty("additional_header_value", "");
            setSyncContext(null);
        }

        function onSettingsChanged() {
            _credentials.loadLongLivedToken();
        }

        function setAuthUrl(newUrl) {
            if (!_authUrl.equals(newUrl)) {
                logout();
            }

            _authUrl = newUrl;
        }

        function setTokenUrl(newUrl) {
            if (!_tokenUrl.equals(newUrl)) {
                logout();
            }

            _tokenUrl = newUrl;
        }

        function addTokenCallback(callback, context) {
            _tokenCallbacks.add({
                "callback" => callback,
                "context" => context
            });
        }

        function removeTokenCallback(callbackObject) {
            _tokenCallbacks.remove(callbackObject);
        }

        // Fires every queued callback exactly once and drops the queue.
        //
        // Removing entry i inside a `for (i++)` loop skipped the next entry and
        // left it in _tokenCallbacks forever - together with its context (url,
        // parameters, options), which is the request that was never sent. Every
        // token refresh that had more than one request queued leaked one entry
        // and fired a stale request on the following refresh.
        //
        // Detaching the list first is also what makes re-entrancy safe: a
        // callback that issues a new request appends to the fresh queue.
        function fireTokenCallbacks(error) {
            var callbacks = _tokenCallbacks;
            _tokenCallbacks = new [0];

            for (var i = 0; i < callbacks.size(); i++) {
                callbacks[i]["callback"].invoke(error, callbacks[i]["context"]);
            }
        }

        // Communications.cancelAllRequests() can drop a request without ever
        // calling back. If that was a token refresh, _isFetchingAccessToken
        // would stay set and block every later request; the requests queued
        // behind it are dropped too. (:fullmem: only a cancelled Wi-Fi/LTE
        // sync cancels requests - see HassSyncDelegate.onStopSync().)
        (:fullmem)
        function onRequestsCancelled() {
            _isFetchingAccessToken = false;
            _tokenCallbacks = new [0];
            setSyncContext(null);
        }

        function _setIsLoggingIn(isLoggingIn) {
            Utils.debugLog("is logging in: ", isLoggingIn, null);
            _isLoggingIn = isLoggingIn;
            App.getApp().viewController.showLoginView(_isLoggingIn);
        }

        function isLoggedIn() {
            return _credentials.isLoggedIn();
        }

        function onReceiveTokens(code, data) {
            _setIsLoggingIn(false);

            _isFetchingAccessToken = false;

            if (code == 200) {
                _credentials.setExpires(data["expires_in"]);
                _credentials.setAccessToken(data["access_token"]);

                if (data["refresh_token"]) {
                    Utils.debugLog("Saving refresh token", null, null);
                    _credentials.setRefreshToken(data["refresh_token"]);
                }

                Utils.debugLog("Received tokens from home assistant", null, null);

                fireTokenCallbacks(null);
            } else {
                var error = new OAuthError(code);

                if (error.code == ERROR_TOKEN_REVOKED) {
                    logout();
                }

                Utils.debugLog("Failed to complete token request, status ", code, null);
                Utils.debugLog(data, null, null);

                fireTokenCallbacks(error);
            }
        }

        function refreshToken(force) {
            if (_isLoggingIn) {
                return;
            }

            if (isLoggedIn() == false) {
                Utils.debugLog("Not logged in, let's log in!", null, null);
                login(null);
                return;
            }

            if (_isFetchingAccessToken == true) {
                return;
            }

            if (_credentials.hasExpired() == true || force == true) {
                Utils.debugLog("AccessToken has expired, lets refresh!", null, null);
                var refreshToken = _credentials.getRefreshToken();

                _isFetchingAccessToken = true;
                Comm.makeWebRequest(
                    _tokenUrl,
                    {
                        "grant_type" => "refresh_token",
                        "client_id" => _clientId,
                        "refresh_token" => refreshToken
                    },
                    {
                        :method => Comm.HTTP_REQUEST_METHOD_POST
                    },
                    method(:onReceiveTokens)
                );
            } else {
                Utils.debugLog("AccessToken still valid :)", null, null);
                fireTokenCallbacks(null);
            }
        }

        function getTokensFromCode(code) {
            if (_isFetchingAccessToken != true) {
                _isFetchingAccessToken = true;

                Utils.debugLog("Fetching token from code", null, null);
                Utils.debugLog(_tokenUrl, null, null);

                Comm.makeWebRequest(
                    _tokenUrl,
                    {
                        "grant_type" => "authorization_code",
                        "client_id" => _clientId,
                        "code" => code
                    },
                    {
                        :method => Comm.HTTP_REQUEST_METHOD_POST
                    },
                    method(:onReceiveTokens)
                );
            }
        }

        function onReceiveCode(value) {
            if (value.data["code"] != null) {
                Utils.debugLog("Received auth code from home assistant", null, null);
                getTokensFromCode(value.data["code"]);
            } else {
                var error = new OAuthError(value.responseCode);

                _setIsLoggingIn(false);

                fireTokenCallbacks(error);

                Utils.debugLog("Failed to receive auth code!", null, null);
                Utils.debugLog(error, null, null);
            }
        }

        function login(callback) {
            if (callback != null) {
                addTokenCallback(callback, {});
            }

            if (isLoggedIn() == true) {
                Utils.debugLog("Trying to login when we are already logged in", null, null);
                refreshToken(false);
                return;
            }

            _setIsLoggingIn(true);

            if (!System.getDeviceSettings().phoneConnected) {
                var error = new OAuthError(OAuthError.ERROR_PHONE_NOT_CONNECTED);

                fireTokenCallbacks(error);

                return;
            }

            Utils.debugLog("About to fire an oauth request!", null, null);
            Comm.makeOAuthRequest(
            _authUrl,
                {
                    "client_id" => _clientId,
                    "response_type"=>"code",
                    "scope"=>"public",
                    "redirect_uri"=> _redirectUrl
                },
                _redirectUrl,
                Comm.OAUTH_RESULT_TYPE_URL,
                {"code"=>"code"}
            );
        }

        function logout() {
            // TODO: try to clear session in home assistant?
            _credentials.clear();
        }

        function onWebResponse(responseCode, body, context) {
            var error = null;

            if (responseCode < 200 || responseCode >= 300) {
                error = new RequestError(responseCode);

                if (error.code == ERROR_NOT_AUTHORIZED) {
                    _credentials.setAccessToken(null);
                    _credentials.setExpires(null);
                }
                if (
                    error.code == ERROR_NOT_FOUND
                    && context[:context] != null
                    && context[:context][:resource] != null
                ) {
                    error.setContext(context[:context][:resource]);
                }
            }

            // Was System.println(context): stringifying the nested context
            // dictionary allocated a multi-hundred-byte String on every single
            // response - in release builds too - at the moment heap is tightest.
            Utils.logMem("onWebResponse code", responseCode);

            context[:responseCallback].invoke(error, {
                :responseCode => responseCode,
                :body => body,
                :context => context[:context]
            });
        }

        function doAuthenticatedWebRequest(error, context) {
            if (error != null) {
                context[:responseCallback].invoke(error, {
                    :context => context[:context]
                });
                return;
            }

            var accessToken = _credentials.getAccessToken();

            var options = {
                :method => Comm.HTTP_REQUEST_METHOD_GET,
                :headers => {
                    "Content-Type" => Comm.REQUEST_CONTENT_TYPE_JSON,
                    "Authorization" => "Bearer " + accessToken
                },
                :context => {
                    :responseCallback => context[:responseCallback],
                    :context => context[:options][:context]
                }
            };

            if (_additionalHeaderKey.length() > 0) {
                options[:headers][_additionalHeaderKey] = _additionalHeaderValue;
            }

            var passedOptions = context[:options];

            if (passedOptions[:method] != null) {
                options[:method] = passedOptions[:method];
            }

            if (options[:method] == Comm.HTTP_REQUEST_METHOD_GET) {
                Utils.debugLogRequest("GET", context[:url], context[:parameters]);
            } else if (options[:method] == Comm.HTTP_REQUEST_METHOD_POST) {
                Utils.debugLogRequest("POST", context[:url], context[:parameters]);
            } else {
                Utils.debugLogRequest("REQUEST", context[:url], context[:parameters]);
            }

            // Inside a Wi-Fi/LTE sync the system calls the response callback with two arguments
            // even though :context is set, and a three-parameter callback then dies with "Not
            // Enough Arguments Error" - taking the whole sync with it. So in a sync the context is
            // not handed to the system at all: it is kept here and a two-parameter callback picks
            // it up. Only one request is ever in flight there (the single stored action), so one
            // field is enough. Everywhere else :context is used as before.
            if (useSyncCallback()) {
                setSyncContext(options[:context]);
                options.remove(:context);

                Comm.makeWebRequest(
                    context[:url],
                    context[:parameters],
                    options,
                    method(:onSyncWebResponse)
                );
                return;
            }

            Comm.makeWebRequest(
                context[:url],
                context[:parameters],
                options,
                method(:onWebResponse)
            );
        }

        // The two-parameter form of onWebResponse() used inside a Wi-Fi/LTE sync.
        (:fullmem)
        function onSyncWebResponse(responseCode, body) {
            var context = _syncContext;

            setSyncContext(null);

            if (context == null) {
                // A response with nothing waiting for it: the sync was cancelled, or this is a
                // second callback for the same request.
                Utils.logMem("onSyncWebResponse without context", responseCode);
                return;
            }

            onWebResponse(responseCode, body, context);
        }

        (:lowmem)
        function onSyncWebResponse(responseCode, body) {
        }

        (:fullmem)
        hidden function useSyncCallback() {
            return WifiLte.isSyncActive();
        }

        (:lowmem)
        hidden function useSyncCallback() {
            return false;
        }

        (:fullmem)
        hidden function setSyncContext(context) {
            _syncContext = context;
        }

        (:lowmem)
        hidden function setSyncContext(context) {
        }

        function makeAuthenticatedWebRequest(url, parameters, options, responseCallback) {
            addTokenCallback(method(:doAuthenticatedWebRequest), {
                :url => url,
                :parameters => parameters,
                :options => options,
                :responseCallback => responseCallback,
            });

            refreshToken(false);
        }
    }
}