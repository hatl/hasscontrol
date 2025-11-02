
(:glance)
module Hass {
    const HASS_STATE_ON = "on";
    const HASS_STATE_OFF = "off";
    const HASS_STATE_LOCKED = "locked";
    const HASS_STATE_UNLOCKED = "unlocked";
    const HASS_STATE_LOCKING = "locking";
    const HASS_STATE_UNLOCKING = "unlocking";
    const HASS_STATE_OPENING = "opening";
    const HASS_STATE_OPEN = "open";
    const HASS_STATE_CLOSING = "closing";
    const HASS_STATE_CLOSED = "closed";
    const HASS_STATE_UNKNOWN = "unknown";

    enum {
        TYPE_SCENE,
        TYPE_LIGHT,
        TYPE_SWITCH,
        TYPE_VALVE,
        TYPE_SCRIPT,
        TYPE_LOCK,
        TYPE_COVER,
        TYPE_FAN,
        TYPE_BINARY_SENSOR,
        TYPE_INPUT_BOOLEAN,
        TYPE_AUTOMATION,
        TYPE_BUTTON,
        TYPE_INPUT_BUTTON,
        TYPE_SENSOR,
        TYPE_UNKNOWN
    }

    enum {
        STATE_ON,
        STATE_OFF,
        STATE_LOCKED,
        STATE_UNLOCKED,
        STATE_LOCKING,
        STATE_UNLOCKING,
        STATE_CLOSED,
        STATE_CLOSING,
        STATE_OPEN,
        STATE_OPENING,
        STATE_SENSOR,
        STATE_UNKNOWN
    }

    enum {
        ERROR_TOKEN_REVOKED,
        ERROR_SERVER_NOT_REACHABLE,
        ERROR_NOT_FOUND,
        ERROR_NOT_AUTHORIZED,
        ERROR_INVALID_URL
    }

    enum {
        SENSOR_TEMPERATURE,
        SENSOR_HUMIDITY,
        SENSOR_CO2,
        SENSOR_PM,
        SENSOR_ENERGY,
        SENSOR_GAS,
        SENSOR_WATER,
        SENSOR_OTHER
    }
}