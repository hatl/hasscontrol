
module Hass {
  class Entity {
    static function createFromDict(dict) {
      return new Entity({
        :id => dict["id"],
        :name => dict["name"],
        :state => dict["state"],
        :ext => dict["ext"],
        :sensorClass => dict["sensorClass"]
      });
    }

    static function stringToState(stateInText) {
      if (stateInText == null) {
        return null;
      }
      if (HASS_STATE_ON.equals(stateInText)) {
        return STATE_ON;
      }
      if (HASS_STATE_OFF.equals(stateInText)) {
        return STATE_OFF;
      }
      if (HASS_STATE_LOCKED.equals(stateInText)) {
        return STATE_LOCKED;
      }
      if (HASS_STATE_UNLOCKED.equals(stateInText)) {
        return STATE_UNLOCKED;
      }
      if (HASS_STATE_LOCKING.equals(stateInText)) {
        return STATE_LOCKING;
      }
      if (HASS_STATE_UNLOCKING.equals(stateInText)) {
        return STATE_UNLOCKING;
      }
      if (HASS_STATE_OPEN.equals(stateInText)) {
        return STATE_OPEN;
      }
      if (HASS_STATE_OPENING.equals(stateInText)) {
        return STATE_OPENING;
      }
      if (HASS_STATE_CLOSED.equals(stateInText)) {
        return STATE_CLOSED;
      }
      if (HASS_STATE_CLOSING.equals(stateInText)) {
        return STATE_CLOSING;
      }

      return STATE_UNKNOWN;
    }

    static function stateToString(state) {
      if (state == STATE_ON) {
        return HASS_STATE_ON;
      }
      if (state == STATE_OFF) {
        return HASS_STATE_OFF;
      }
      if (state == STATE_OPEN) {
        return HASS_STATE_OPEN;
      }
      if (state == STATE_OPENING) {
        return HASS_STATE_OPENING;
      }
      if (state == STATE_CLOSED) {
        return HASS_STATE_CLOSED;
      }
      if (state == STATE_CLOSING) {
        return HASS_STATE_CLOSING;
      }
      if (state == STATE_LOCKED) {
        return HASS_STATE_LOCKED;
      }
      if (state == STATE_UNLOCKED) {
        return HASS_STATE_UNLOCKED;
      }
      if (state == STATE_LOCKING) {
        return HASS_STATE_LOCKING;
      }
      if (state == STATE_UNLOCKING) {
        return HASS_STATE_UNLOCKING;
      }

      if (state == null) {
        return null;
      }

      return HASS_STATE_UNKNOWN;
    }

    hidden var _mId; // Home assistant id
    hidden var _mType; // Type of entity
    hidden var _mName; // Name
    hidden var _mState; // Current State
    hidden var _mExt; // Is this entity loaded from settings?
    hidden var _mSensorValue; // Custom state info text
    hidden var _mSensorClass; // Device class for sensor

    function initialize(entity) {
      _mId = entity[:id];
      _mName = entity[:name];
      _mState = Entity.stringToState(entity[:state]);
      _mExt = entity[:ext] == true;
      _mSensorClass = entity[:sensorClass];

      if (_mId.find("scene.") != null) {
        _mType = TYPE_SCENE;
      } else if (_mId.find("light.") != null) {
        _mType = TYPE_LIGHT;
      } else if (_mId.find("switch.") != null) {
        _mType = TYPE_SWITCH;
      } else if (_mId.find("valve.") != null) {
        _mType = TYPE_VALVE;
      } else if (_mId.find("automation.") != null) {
        _mType = TYPE_AUTOMATION;
      } else if (_mId.find("script.") != null) {
        _mType = TYPE_SCRIPT;
      } else if (_mId.find("lock.") != null) {
        _mType = TYPE_LOCK;
      } else if (_mId.find("cover.") != null) {
        _mType = TYPE_COVER;
      } else if (_mId.find("fan.") != null) {
        _mType = TYPE_FAN;
      } else if (_mId.find("binary_sensor.") != null) {
        _mType = TYPE_BINARY_SENSOR;
      } else if (_mId.find("input_boolean.") != null) {
        _mType = TYPE_INPUT_BOOLEAN;
      } else if (_mId.find("input_button.") != null) {
        _mType = TYPE_INPUT_BUTTON;
      } else if (_mId.find("button.") != null) {
        _mType = TYPE_BUTTON;
      } else if (_mId.find("sensor.") != null) {
        _mType = TYPE_SENSOR;
      } else {
        _mType = TYPE_UNKNOWN;
      }
    }

    function getId() {
      return _mId;
    }

    function getName() {
      if (_mState == STATE_SENSOR) {
        return _mName + "\n" + _mSensorValue;
      }
      else {
        return _mName;
      }
    }

    function setName(newName) {
      _mName = newName;
    }

    function getType() {
      return _mType;
    }

    function setState(newState) {
      if (newState instanceof String) {
        if (_mType == TYPE_SENSOR ) {
          _mState = STATE_SENSOR;
          _mSensorValue = newState;
        } else {
          _mState = Entity.stringToState(newState);
        }
        return;
      }

      if (
        newState != null
        && newState != STATE_ON
        && newState != STATE_OFF
        && newState != STATE_LOCKED
        && newState != STATE_UNLOCKED
        && newState != STATE_LOCKING
        && newState != STATE_UNLOCKING
        && newState != STATE_CLOSED
        && newState != STATE_CLOSING
        && newState != STATE_OPEN
        && newState != STATE_OPENING
        && newState != STATE_SENSOR
        && newState != STATE_UNKNOWN
      ) {
        throw new Toybox.Lang.InvalidValueException("Invalid entity state value");
      }

      _mState = newState;
    }

    function getState() {
      return _mState;
    }


    function getSensorClass() {
      return _mSensorClass;
    }

    function setSensorClass(newSensorClass) {
      _mSensorClass = newSensorClass;
    }

    function isExternal() {
      return _mExt;
    }

    function isTransitional() {
      return _mState == STATE_CLOSING || _mState == STATE_OPENING || _mState == STATE_LOCKING || _mState == STATE_UNLOCKING;
    }

    function setExternal(isExternal) {
      _mExt = isExternal;
    }

    function toDict() {
      return {
        "id" => _mId,
        "name" => _mName,
        "state" => Entity.stateToString(_mState),
        "ext" => _mExt,
        "sensorClass" => _mSensorClass,
      };
    }

    function toString() {
      return toDict().toString();
    }
  }
}
