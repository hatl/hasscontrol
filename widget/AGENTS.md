# Project Context
HassControl is a Connect IQ widget for Garmin devices that interfaces with Home Assistant, a popular open-source home automation platform. The app enables users to control their home automation entities (lights, switches, sensors, etc.) directly from their Garmin watch, making it easier to control their smart home without using a phone or voice assistant.

The widget supports various Home Assistant entity types and handles both OAuth and long-lived token authentication methods. It's designed to be battery-efficient and compatible with a range of Garmin devices.

# Code Structure - Core Modules
- `App.mc`: Main application entry point, handles initialization and view management
- `ViewController.mc`: Manages transitions between different views (EntityView, SceneView, etc.)
- `hass/Client.mc`: Handles API communication with Home Assistant
- `hass/Hass.mc`: Core module with entity management functionality
- `hass/Entity.mc`: Entity class representing Home Assistant entities
- `hass/Constants.mc`: Constants for entity types, states, and errors
- `hass/OAuthClient.mc`: Handles OAuth authentication flow
- `hass/OauthCredentials.mc`: Manages storage and retrieval of authentication tokens
- `Scheduler.mc`: The app's only `Timer.Timer`; every delayed callback is a keyed job on it (see Performance Considerations)
- `ConnectionWait.mc` (fullmem): At launch without a direct connection (`WifiLte.hasDirectConnection()`: the phone, or on the `:directwifi` units - the Edge family, see `monkey.jungle` - a connected Wi-Fi), shows "Waiting for connection" and runs the startup requests once there is one; gives up after 3 minutes. No loader when Wi-Fi/LTE execution is usable or the initial view is `BaseView` (the widget-loop page on devices without glances, where a loader would block scrolling the loop) - the wait then runs quietly and still refreshes on connect. While a Wi-Fi/LTE sync is pending (`WifiLte.isSyncPending()`) it only reschedules itself. While the wait is pending, "Phone not connected" does not close the app (`HassControlApp.isWaitingForPhone()`, checked in `Error.initialize()`)
- `hass/WifiLte.mc` (fullmem): Wi-Fi/LTE execution - stores an action, starts a system sync (deferred off the Confirmation callback, `:wifiLteStart`), and `HassSyncDelegate` sends it from inside the sync. The stored command must never be sent by a later sync without a prompt: it is cleared when the sync is cancelled (`onStopSync()`), after `COMMAND_MAX_AGE` (60 s; also by the `:wifiLteExpire` watchdog) and at the next normal launch (`dropStaleCommand()`, from `HassControlApp.startStartupWork()`). `hasDirectConnection()` (the phone, or a connected Wi-Fi radio - but only on the units built with the `:directwifi` annotation in `monkey.jungle`, the Edge family; on watches Wi-Fi reads as connected during and just after a sync, so there only the phone counts, and `shouldUse()` is always false on `:directwifi` units) is what `Client.hasConnection()`, `Hass._canRefresh()` and `ConnectionWait` check; with one, Wi-Fi/LTE execution is not offered (`shouldUse()`)
- `Lock/LockConfirm.mc`, `Lock/PinEntryView.mc` (fullmem): The optional yes/no question or wallet-style PIN before a lock is toggled
- `hass/DateTimeValue.mc` (fullmem): The date/time entities' values - parses their states, formats the display text and the service parameters, and converts `datetime.*` between UTC and the watch's local time with its own integer arithmetic (`System.getClockTime().timeZoneOffset`, not `Time.Gregorian.moment()`)
- `Entities/DateTimeEditView.mc` (fullmem): The date/time editor (`DateTimeEditView` + `DateTimeEditDelegate`), laid out like `InputNumberEditView`: up/down step the active field (hold to repeat, `:fieldRepeat`), select moves to the next field and sends on the last, back moves to the previous field and cancels on the first

# Code Style Guidelines

## General
- Use Monkey C conventions and patterns
- Maintain consistent 2-space indentation
- Place opening braces on the same line as statements
- Use camelCase for variables and methods
- Prefix private/hidden variables with underscore (_variableName)
- Use class prefix for enums and constants (e.g., `HASS_STATE_ON`, `ERROR_NOT_AUTHORIZED`)
- Read settings with `Utils.getProperty(key, default)`, passing the default from `resources/properties.xml` - never `Properties.getValue()` directly: it throws `InvalidKeyException` for a key the stored settings do not have (after an app update that adds a setting, or with an older build's settings file in the simulator). `Properties.setValue()` is fine

## Classes and Modules
- Place class methods in Monkey C modules with clear responsibilities
- Use the `:glance` annotation for code that can run in Garmin's glance mode
- Initialize all instance variables in the constructor
- Follow established naming patterns for consistency

## Comments
- Add comments for complex logic or non-obvious behavior
- Use function header comments to explain purpose, parameters, and return values
- Include `// TODO:` comments for incomplete implementations
- Document any workarounds for Connect IQ platform limitations

# Entity Implementation

## Entity Types
HassControl supports the following entity types:
- `TYPE_LIGHT`: Lights (on/off only)
- `TYPE_SWITCH`: Switches (on/off only)
- `TYPE_COVER`: Cover entities (open/close)
- `TYPE_LOCK`: Lock entities (lock/unlock). Fullmem devices can put a yes/no question or a PIN in front of the toggle (`lockConfirmation` setting, `LockConfirm.request()` from `EntityListDelegate.handleExtendedEntityTypes()`).
- `TYPE_FAN`: Fan entities (on/off only)
- `TYPE_SCENE`: Scene activation
- `TYPE_SCRIPT`: Script activation
- `TYPE_AUTOMATION`: Automation toggle
- `TYPE_VALVE`: Valve entities (open/close)
- `TYPE_BINARY_SENSOR`: Read-only binary sensors
- `TYPE_INPUT_BOOLEAN`: Toggle boolean entities
- `TYPE_BUTTON`: Button entities that can be pressed
- `TYPE_INPUT_BUTTON`: Input button entities
- `TYPE_SENSOR`: Sensors with values (temperature, humidity, etc.)
- `TYPE_SELECT`: `select`/`input_select` entities (pick one of a list of options). Fullmem devices use a Menu2 picker. 64 KB widget devices (`:lowmem`, see `monkey.jungle`) show these read-only, the same as a plain sensor - no menu, no editing.
- `TYPE_INPUT_NUMBER`: `input_number`/`number` entities (numeric value with min/max/step). Fullmem devices use a dedicated edit view (`InputNumberEditView.mc`: select confirms, back cancels). 64 KB widget devices show these read-only too, same as `TYPE_SELECT`.
- `TYPE_DATETIME`: `input_datetime`/`date`/`time`/`datetime` entities (detected by id prefix, `input_datetime.` first). Fullmem devices use `DateTimeEditView.mc` and show `datetime.*` in local time; 64 KB widget devices show the state read-only, trimmed (`Entity.getDisplayValue()`), `datetime.*` in UTC. Whether an entity has a date, a time or both is derived, never stored (`DateTimeValue.modeOf()`): from the domain, and for `input_datetime` from its state string.

## Entity States
Entities can be in various states:
- Basic states: `STATE_ON`, `STATE_OFF`, `STATE_UNKNOWN`
- Lock states: `STATE_LOCKED`, `STATE_UNLOCKED`, `STATE_LOCKING`, `STATE_UNLOCKING`
- Cover states: `STATE_OPEN`, `STATE_CLOSED`, `STATE_OPENING`, `STATE_CLOSING`
- Sensor state: `STATE_SENSOR` (with associated value) — also used for `TYPE_SELECT`'s current option, `TYPE_INPUT_NUMBER`'s current numeric value and `TYPE_DATETIME`'s state string (shown through `Entity.getDisplayValue()`). On fullmem the value itself is stored in the state slot, so it survives a launch without the phone (`Entity.writeToStorage()`/`restoreValue()`); the 64 KB tier stores "unknown" there, as before

## Adding New Entity Types
When adding a new entity type:
1. Add type constants in `hass/Constants.mc`
2. Update entity identification in `Entity.initialize()`
3. Add appropriate drawable resources in `resources/drawables/`
4. Implement state handling in `toggleEntityState()` method in `hass/Hass.mc`
5. Add icon handling in `EntityListView.getDrawableForEntity()`

# Error Handling
- Use the established error object patterns (`Error`, `RequestError`, `OAuthError`)
- Always check for null values before accessing object properties
- Use try/catch blocks for operations that may fail
- Implement proper error display to the user with contextual information
- Handle network errors and authentication failures gracefully

# Performance Considerations
- Minimize API calls to preserve battery life (Garmin watches have limited battery)
- Cache entities and other data whenever possible using `App.Storage`
- Use timers judiciously to avoid excessive battery drain
- Never create a `Timer.Timer`: schedule a keyed job with `Scheduler.schedule(:key, method, ms)` and drop it with `Scheduler.cancel(:key)`. Connect IQ allows only a few running timers (3 by default) and throws "Too Many Timers Error" past that (issue #101); rescheduling a key moves its deadline instead of adding a timer
- Give every purpose its own key, as a key's last schedule replaces the job before it: the app exits are `:exitPhoneLost` (`Error.mc`), `:exitAfterAction` (`Hass.mc`) and `:exitAfterSync` (`WifiLte.mc`), so none replaces or cancels another
- A Wi-Fi/LTE sync (`startSync2()`) is documented to restart the app in sync mode, where `getInitialView()` never ran: code reachable from `HassSyncDelegate` must not assume views, `viewController` or a loaded entity list (see `WifiLte.prepare()`; `WifiLte.noteHeadless()` records `_headless` at every entry from the system, and `quiesce()` cancels the inactivity and exit jobs: then `onSyncFinished()` neither updates the UI nor schedules an exit or the inactivity timer - that process ends on its own). In practice the app can also stay alive under the sync screen: while `WifiLte.isSyncPending()`, no timed work may push views or start requests (`WifiLte.start()` cancels `:inactivity`, `:exitPhoneLost` and `:exitAfterAction`)
- Set appropriate refresh intervals for transitional states
- Clean up resources (especially timers) when views are hidden or app is closed
- Prefer batch operations over multiple individual API calls

# UI Guidelines
- Support both touch and button-based navigation for different Garmin models
- Ensure text is readable on small watch screens (limit text length)
- Use appropriate icons from the `resources/drawables` folder
- Follow Garmin's UI patterns for consistency with the platform
- Support Garmin's glance mode for quick information display
- Implement proper loading indicators for network operations
- Show a loader only through `ViewController.showLoader()` (or `showLoaderWithDelegate()` with a delegate whose `onBack` calls `dismissLoader()`, as `ConnectionWait` does): a loader the system pops on back by itself leaves `_loaderActive` set, and the next removal then pops another view
- A loader's delegate must never pop the loader on back: the system pops the `Ui.ProgressBar` by itself (verified in the simulator, even when `onBack()` returned true), so a pop of our own takes the view beneath as well. `LoaderDelegate` and `ConnectionWaitDelegate` only call `ViewController.loaderDismissedByBack()` and return false

# Authentication
- Support both OAuth and long-lived token authentication methods
- OAuth flow: Handle authorization, token retrieval, refresh, and expiration
- Long-lived token: Store securely and use for API requests
- Validate connectivity and settings before attempting API calls
- Store credentials securely using Garmin's storage API
- Handle token revocation and auth errors properly
- Support additional HTTP headers for advanced authentication scenarios

# Sync and Data Management
- Use efficient entity synchronization with Home Assistant
- On fullmem, `Hass.refreshAllEntities()` silently does nothing without a direct connection (`_canRefresh()`, `WifiLte.hasDirectConnection()`): callers must not rely on the refresh finishing or on it removing a loader (see `Hass._buildImportedEntities()`). Only `ConnectionWait` refreshes once the connection is back, and only at launch
- Support group-based entity import from Home Assistant
- Handle transitional states with appropriate refresh timers
- Store entities for offline access
- Implement proper battery reporting to Home Assistant
- Cache entity states to minimize network traffic
