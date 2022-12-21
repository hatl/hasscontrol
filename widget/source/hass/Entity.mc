
module Hass {
  class Entity {
    static function createFromDict(dict) {
      return new Entity({
        :id => dict["id"],
        :name => dict["name"],
        :state => dict["state"],
        :ext => dict["ext"],
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
      if (HASS_STATE_OPEN.equals(stateInText)) {
        return STATE_OPEN;
      }
      if (HASS_STATE_CLOSED.equals(stateInText)) {
        return STATE_CLOSED;
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
      if (state == STATE_CLOSED) {
        return HASS_STATE_CLOSED;
      }
      if (state == STATE_LOCKED) {
        return HASS_STATE_LOCKED;
      }
      if (state == STATE_UNLOCKED) {
        return HASS_STATE_UNLOCKED;
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

    function initialize(entity) {
      _mId = entity[:id];
      _mName = entity[:name];
      _mState = Entity.stringToState(entity[:state]);
      _mExt = entity[:ext] == true;

      if (_mId.find("scene.") != null) {
        _mType = TYPE_SCENE;
      } else if (_mId.find("light.") != null) {
        _mType = TYPE_LIGHT;
      } else if (_mId.find("switch.") != null) {
        _mType = TYPE_SWITCH;
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
      } else {
        _mType = TYPE_UNKNOWN;
      }
    }

    function getId() {
      return _mId;
    }

    function getName() {
      return _mName;
    }

    function setName(newName) {
      _mName = newName;
    }

    function getType() {
      return _mType;
    }

    function setState(newState) {
      if (newState instanceof String) {
        _mState = Entity.stringToState(newState);
        return;
      }

      if (
        newState != null
        && newState != STATE_ON
        && newState != STATE_OFF
        && newState != STATE_LOCKED
        && newState != STATE_UNLOCKED
        && newState != STATE_CLOSED
        && newState != STATE_OPEN
        && newState != STATE_UNKNOWN
      ) {
        throw new Toybox.Lang.InvalidValueException("state must be a valid Entity state");
      }

      _mState = newState;
    }

    function getState() {
      return _mState;
    }

    function isExternal() {
      return _mExt;
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
      };
    }

    function toString() {
      return toDict().toString();
    }
  }
}
