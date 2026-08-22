using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.System;
using Toybox.Timer;
using Toybox.Lang;

using Utils;

module Hass {
  const STORAGE_KEY = "Hass/entities/v2";
  const STORAGE_KEY_LEGACY = "Hass/entities";

  var client = null;
  var _entities = new [0];
  var _entitiesToRefresh = new [0];
  var _transitionalEntities =  new [0];
  var _continueRefreshOnError = false;
  var _refreshActive = false;
  var _refreshTimer = new Timer.Timer();
  var _finalizeTimer = new Timer.Timer();
  var _pendingImportIds = null;

  // Free-heap floor, in bytes. Below this we stop allocating rather than let
  // the VM throw Out Of Memory. Measured on Instinct 2X (64 KB widget budget):
  // parsing one entity's HTTP response costs ~2.0 KB and a 12-member group
  // response ~2.4 KB, so a request issued with less than this free cannot
  // complete. Bigger devices never come near it.
  const MIN_FREE_MEMORY = 3500;

  function initClient() {
    client = new Client();
  }

  function getGroup() {
    var group = App.Properties.getValue("group");

    if (group == null || group.length() == 0) {
      return null;
    }

    if (group.find(".") == null) {
      group = "group." + group;
    }

    return group;
  }

  function getEntities() {
    return _entities;
  }

  function getEntitiesByTypes(types) {
    var entities = new [0];

    for (var eI = 0; eI < _entities.size(); eI++) {
      var match = false;

      for (var tI = 0; tI < types.size(); tI++) {
        if (_entities[eI].getType() == types[tI]) {
          match = true;
          break;
        }
      }

      if (match) {
        entities.add(_entities[eI]);
      }
    }

    return entities;
  }

  function getEntity(id) {
    var entity = null;

    for (var i = 0; i < _entities.size(); i++) {
      if (_entities[i].getId().equals(id)) {
        entity = _entities[i];
        break;
      }
    }

    return entity;
  }

  function storeEntities() {
    Utils.logMem("storeEntities:enter", null);

    // Serialising every entity briefly doubles the entity data. Skipping the
    // write costs only the offline cache for this session - far better than an
    // Out Of Memory crash at the end of an otherwise successful refresh.
    if (Utils.freeMemory() < MIN_FREE_MEMORY) {
      System.println("storeEntities: skipped, low memory");
      return;
    }

    // Size the array up front: growing it with add() would reallocate and copy
    // repeatedly, which is its own peak on a device with a few KB to spare.
    var count = 0;

    for (var i = 0; i < _entities.size(); i++) {
      if (!_entities[i].isExternal()) {
        count++;
      }
    }

    var stored = new [count * Entity.STORED_FIELDS];
    var slot = 0;

    for (var i = 0; i < _entities.size(); i++) {
      if (_entities[i].isExternal()) {
        continue;
      }
      slot = _entities[i].writeToStorage(stored, slot);
    }

    Utils.logMem("storeEntities:built n", count);
    App.Storage.setValue(STORAGE_KEY, stored);
    Utils.logMem("storeEntities:done", null);
  }

  function loadScenesFromSettings() {
    var scenes = Utils.getScenesFromSettings();

    // Snapshot the icon of each external entity before removal so a refreshed
    // icon (set during refreshAllEntities) survives the rebuild below.
    // Without this, the recreated entity always has icon=null and the mdi
    // override never applies to scenes loaded from the "scenes" setting.
    var preservedIcons = {};

    // first remove all external scenes to make sure we are not persisting any old scenes
    var entitiesToRemove = new [0];
    for (var i = 0; i < _entities.size(); i++) {
      if (_entities[i].isExternal()) {
        var oldIcon = _entities[i].getIcon();
        if (oldIcon != null) {
          preservedIcons[_entities[i].getId()] = oldIcon;
        }
        entitiesToRemove.add(_entities[i]);
      }
    }
    for (var i = 0; i < entitiesToRemove.size(); i++) {
      _entities.remove(entitiesToRemove[i]);
    }
    entitiesToRemove = null;

    for (var i = 0; i < scenes.size(); i++) {
      var entity = getEntity(scenes[i][0]);

      if (entity != null) {
        // We only set the name if it's different than the id
        if (!scenes[i][0].equals(scenes[i][1])) {
          entity.setName(scenes[i][1]);
        }
      } else {
        var newEntity = new Entity({
          :id => scenes[i][0],
          :name => scenes[i][1],
          :state => "scening",
          :ext => true
        });

        // Restore the icon that was fetched before the rebuild (if any).
        if (preservedIcons.hasKey(scenes[i][0])) {
          newEntity.setIcon(preservedIcons[scenes[i][0]]);
        }

        _entities.add(newEntity);
      }
    }
  }

  function loadStoredEntities() {
    _entities = new [0];

    var stored = App.Storage.getValue(STORAGE_KEY);

    if (stored == null) {
      _loadLegacyStoredEntities();
    } else {
      for (var i = 0; i + Entity.STORED_FIELDS <= stored.size(); i += Entity.STORED_FIELDS) {
        var entity = Entity.createFromStorage(stored, i);
        // Filter out null entities (from corrupted or invalid data)
        if (entity != null) {
          _entities.add(entity);
        }
      }
    }

    loadScenesFromSettings();

    System.println("Loaded entities: " + _entities.size() + " total");
  }

  // One-time read of the pre-2.0.4 format (one Dictionary per entity). The
  // next storeEntities() writes the compact form, so the old key is dropped
  // here rather than kept in sync.
  function _loadLegacyStoredEntities() {
    var stored = App.Storage.getValue(STORAGE_KEY_LEGACY);

    if (stored == null) {
      return;
    }

    for (var i = 0; i < stored.size(); i++) {
      var entity = Entity.createFromDict(stored[i]);
      if (entity != null) {
        _entities.add(entity);
      }
    }

    App.Storage.deleteValue(STORAGE_KEY_LEGACY);
  }

  function _onReceiveEntity(err, data) {
    Utils.logMem("onReceiveEntity queue", _entitiesToRefresh.size());
    if (err != null) {
      if (data != null && data[:context] != null && data[:context][:callback] != null) {
        data[:context][:callback].invoke(err, null);
      } else {
        App.getApp().viewController.showError(err);
      }
      return;
    }

    // Validate data structure before proceeding
    if (data == null || data[:body] == null || data[:body]["entity_id"] == null) {
      System.println("Invalid entity data received");
      if (data != null && data[:context] != null && data[:context][:callback] != null) {
        data[:context][:callback].invoke(new Error(Error.ERROR_UNKNOWN), null);
      }
      return;
    }

    var entity = getEntity(data[:body]["entity_id"]);

    // If entity doesn't exist, skip processing but still invoke callback to continue chain
    if (entity == null) {
      System.println("Entity not found: " + data[:body]["entity_id"]);
      // Always try to invoke callback to prevent breaking the refresh chain
      if (data[:context] != null && data[:context][:callback] != null) {
        data[:context][:callback].invoke(null, null);
      } else {
        // Fallback: continue refreshing remaining entities if we're in a batch refresh
        _refreshPendingEntities(null, null);
      }
      return;
    }

    var name = null;
    var state = null;
    var sensorClass = null;
    var sensorClassStr = null;
    var icon = null;
    var deviceClass = null;

    if (data[:body]["attributes"] != null) {
      name = data[:body]["attributes"]["friendly_name"];

      // Home Assistant only sends `icon` when the entity has a custom icon set.
      icon = data[:body]["attributes"]["icon"];

      // Raw device_class string (e.g. "battery") — used as an icon fallback
      // when no custom `icon` is set.
      deviceClass = data[:body]["attributes"]["device_class"];

      if (data[:body]["attributes"]["unit_of_measurement"] != null) {
        state = data[:body]["state"] + data[:body]["attributes"]["unit_of_measurement"];
      } else {
        state = data[:body]["state"];
      }

      if (data[:body]["attributes"]["device_class"] != null) {
        sensorClassStr = data[:body]["attributes"]["device_class"];
        if (sensorClassStr.find("temperature") != null) {
          sensorClass = SENSOR_TEMPERATURE;
        } else if (sensorClassStr.find("humidity") != null) {
          sensorClass = SENSOR_HUMIDITY;
        } else if (sensorClassStr.find("carbon_dioxide") != null) {
          sensorClass = SENSOR_CO2;
        } else if (sensorClassStr.find("pm25") != null) {
          sensorClass = SENSOR_PM;
        } else if (sensorClassStr.find("pm10") != null) {
          sensorClass = SENSOR_PM;
        } else if (sensorClassStr.find("energy") != null) {
          sensorClass = SENSOR_ENERGY;
        } else if (sensorClassStr.find("water") != null) {
          sensorClass = SENSOR_WATER;
        } else if (sensorClassStr.find("gas") != null) {
          sensorClass = SENSOR_GAS;
        }
      } else {
        sensorClass = SENSOR_OTHER;
      }
    } else {
      state = data[:body]["state"];
      sensorClass = SENSOR_OTHER;
    }

    if (name != null) {
      entity.setName(name);
    }

    if (state != null) {
      entity.setState(state);
    } else {
      entity.setState(Entity.STATE_UNKNOWN);
    }

    if (sensorClass != null) {
      entity.setSensorClass(sensorClass);
    }

    _applyIconAttributes(entity, icon, deviceClass);

    if (data[:context] != null && data[:context][:callback] != null) {
      data[:context][:callback].invoke(null, entity);
    }
  }

  // Reflects the current icon / device_class attributes (null clears a
  // previously stored value).
  (:fullmem)
  function _applyIconAttributes(entity, icon, deviceClass) {
    entity.setIcon(icon);
    entity.setDeviceClass(deviceClass);
  }

  // Lean build: Utils.getMdiIconDrawable() always returns null there, so
  // nothing reads these. Not storing them keeps every entity's icon string
  // (e.g. "mdi:television-classic") out of the heap for the app's lifetime,
  // and out of the dictionary storeEntities() serialises.
  (:lowmem)
  function _applyIconAttributes(entity, icon, deviceClass) {
  }

  function refreshEntity(entity, callback) {
    client.getEntity(
      entity.getId(),
      {
        :entity => entity,
        :callback => callback
      },
      Utils.method(Hass, :_onReceiveEntity)
    );
  }

  function _refreshPendingEntities(error, noop) {
    if (error != null && !_continueRefreshOnError) {
      _refreshActive = false;
      App.getApp().viewController.removeLoader();
      App.getApp().viewController.showError(error);

      // We need to finalize with reading the scenes from settings again,
      // so that the name config takes precedence
      loadScenesFromSettings();

      storeEntities();

      Ui.requestUpdate();
      return;
    }

    if(noop != null && noop.isTransitional()){
      _transitionalEntities.add(noop);
      _refreshTimer.start(Utils.method(Hass, :_refreshTransitionalEntities), 2000, false);
    }

    if (_entitiesToRefresh.size() > 0 && Utils.freeMemory() < MIN_FREE_MEMORY) {
      // Not enough heap left to parse another response. Abandon the rest of
      // the chain; those entities keep their last known state instead of the
      // whole app dying mid-refresh.
      System.println("refresh: stopped early, low memory, " + _entitiesToRefresh.size() + " left");
      _entitiesToRefresh = new [0];
    }

    if (_entitiesToRefresh.size() > 0) {
      var entity = _entitiesToRefresh[0];

      _entitiesToRefresh.remove(entity);

      // Add null check for entity before refreshing
      if (entity != null) {
        refreshEntity(entity, Utils.method(Hass, :_refreshPendingEntities));
      } else {
        // Skip null entity and continue with next
        _refreshPendingEntities(null, null);
      }
    } else {
      _refreshActive = false;

      // Finish on a fresh stack rather than inline. This branch runs inside
      // OAuthClient.onWebResponse(), whose frame still holds the last parsed
      // response body - a couple of KB. Serialising every entity for storage
      // while that response is still live is the peak that runs a 64 KB device
      // out of memory at the end of a group import.
      _scheduleDeferred();
    }
  }

  // Defers work that must not run on an HTTP response's stack, where the
  // parsed body is still live. By the time the timer fires, onWebResponse()
  // has returned and the response is collectable.
  function _scheduleDeferred() {
    _finalizeTimer.start(Utils.method(Hass, :_runDeferred), 50, false);
  }

  // One timer serves both deferred jobs. A pending import wins: it ends by
  // starting a refresh, which schedules the finalize again afterwards.
  function _runDeferred() {
    if (_pendingImportIds != null) {
      _buildImportedEntities();
      return;
    }

    _finishRefresh();
  }

  // Tail of a completed refresh chain. Runs from a timer so the HTTP response
  // that triggered it has already been released.
  function _finishRefresh() {
    Utils.logMem("finishRefresh:enter", null);

    // We need to finalize with reading the scenes from settings again,
    // so that the name config takes precedence
    loadScenesFromSettings();

    storeEntities();

    Ui.requestUpdate();

    App.getApp().viewController.removeLoader();

    Utils.logMem("finishRefresh:done", null);
  }

  function refreshAllEntities(continueOnError) {
    // App.getInitialView() and the entity view's onShow() both ask for a
    // refresh at startup, which used to start two chains walking the same
    // entity list: two requests in flight, two response buffers, two queues.
    // On a 64 KB device that duplicate is a large slice of the free heap.
    if (_refreshActive) {
      return;
    }
    _refreshActive = true;

    _entitiesToRefresh = new [0];
    _continueRefreshOnError = continueOnError == true;

    for (var i = 0; i < _entities.size(); i++) {
      _entitiesToRefresh.add(_entities[i]);
    }

    _refreshPendingEntities(null, null);
  }

  function _refreshTransitionalEntities(){
    _entitiesToRefresh.addAll(_transitionalEntities);
    _transitionalEntities = new [0];
    _refreshPendingEntities(null, null);
  }

  function _onReceiveEntities(err, data) {
    if (err != null) {
      App.getApp().viewController.removeLoader();
      App.getApp().viewController.showError(err);
      return;
    }

    // Validate data structure
    if (data == null || data[:body] == null || data[:body]["attributes"] == null || data[:body]["attributes"]["entity_id"] == null) {
      System.println("Invalid entities data received");
      App.getApp().viewController.removeLoader();
      App.getApp().viewController.showError("Invalid\ngroup\nresponse");
      return;
    }

    // Hold on to the id list only, then let the timer build the entities.
    // Building them here would do it inside onWebResponse(), where the whole
    // parsed group response is still live - 2.4 KB for a 12-member group,
    // measured on Instinct 2X, against 1.6 KB of free heap. Keeping just the
    // id array keeps the ids (which the entities reference anyway) and drops
    // the rest of the response.
    _pendingImportIds = data[:body]["attributes"]["entity_id"];
    Utils.logMem("import:parsed n", _pendingImportIds.size());

    _scheduleDeferred();
  }

  // Rebuilds _entities from the imported group. Runs from the deferred timer,
  // so the group response has already been released.
  function _buildImportedEntities() {
    var ids = _pendingImportIds;
    _pendingImportIds = null;

    if (ids == null) {
      return;
    }

    Utils.logMem("import:build:enter n", ids.size());

    // Build against the *old* list so entities still in the group are reused.
    // Clearing _entities first (as this did) made getEntity() search an empty
    // list, so every re-import allocated a fresh Entity for every member.
    var imported = new [0];
    var dropped = 0;

    for (var i = 0; i < ids.size(); i++) {
      if (Utils.freeMemory() < MIN_FREE_MEMORY) {
        dropped = ids.size() - i;
        break;
      }

      var entity = getEntity(ids[i]);

      if (entity == null) {
        entity = new Entity({
          :id => ids[i],
          :name => ids[i],
          :state => null,
          :sensorClass => null
        });
      } else {
        entity.setExternal(false);
      }

      imported.add(entity);
    }

    _entities = imported;
    ids = null;

    Utils.logMem("import:build:done n", _entities.size());

    loadScenesFromSettings();

    // The entity list was just replaced, so any refresh chain still walking
    // the old list is stale. Clear the guard so this refresh always starts.
    _refreshActive = false;
    refreshAllEntities(false);

    if (dropped > 0) {
      // Tell the user rather than silently showing a short list.
      System.println("import: dropped " + dropped + " entities, low memory");
      App.getApp().viewController.showError(
        "Low memory:\nonly " + _entities.size() + " of " + (_entities.size() + dropped) + "\nentities loaded"
      );
    }
  }

  function importEntities() {
    Utils.logMem("importEntities:enter", null);
    var group = getGroup();

    if (group == null) {
      App.getApp().viewController.showError("Group\nnot\nconfigured");
      return;
    }

    App.getApp().viewController.showLoader("Refreshing");

    client.getEntity(group, null, Utils.method(Hass, :_onReceiveEntities));
  }

  function _onBatteryUpdate(err, data) {
      if (err != null) {
        System.println("Battery update error: " + err.toShortString());
      }
  }

  function reportBatteryValue(entity_id) {
    client.reportBatteryValue(entity_id, Utils.method(Hass, :_onBatteryUpdate));
  }

  function onToggleEntityStateCompleted(error, data) {
    if (error != null) {
      App.getApp().viewController.removeLoaderImmediate();
      App.getApp().viewController.showError(error);
      return;
    }

    // Validate data structure
    if (data == null || data[:context] == null || data[:context][:entityId] == null) {
      System.println("Invalid toggle entity response");
      App.getApp().viewController.removeLoader();
      return;
    }

    var entity = getEntity(data[:context][:entityId]);
    if (entity != null) {
      if (data[:context][:state] != null) {
        var newState = data[:context][:state];

        if (entity.getType() == Entity.TYPE_SCRIPT || entity.getType() == Entity.TYPE_BUTTON) {
          newState = Entity.STATE_OFF;
        }

        entity.setState(newState);

        storeEntities();
        Ui.requestUpdate();
      } else {
        refreshEntity(entity, Utils.method(Hass, :_refreshPendingEntities));
      }
    }

    App.getApp().viewController.removeLoader();

    // Check if we should exit after action
    if (App.Properties.getValue("closeAfterAction")) {
      // Small delay before exiting to ensure UI updates are seen by user
      var exitTimer = new Timer.Timer();
      exitTimer.start(Utils.method(Hass, :exitApplication), 2000, false);
    }
  }

  function exitApplication() {
    System.exit();
  }

  function toggleEntityState(entity) {
    var entityId = entity.getId();
    var currentState = entity.getState();
    var entityType = null;
    var action = null;
    var loadingText = "Loading";

    if (entity.getType() == Entity.TYPE_BINARY_SENSOR) {
        // binary_sensor cannot be set, only read
        return;
    }
    if (entity.getType() == Entity.TYPE_SENSOR) {
      // binary_sensor cannot be set, only read
      return;
    }

    if (entity.getType() == Entity.TYPE_SCRIPT) {
      action = Client.ENTITY_ACTION_TURN_ON;
      loadingText = "Running";
    } else if (entity.getType() == Entity.TYPE_LOCK) {
      if (currentState == Entity.STATE_UNLOCKED) {
        action = Client.ENTITY_ACTION_LOCK;
        loadingText = "Locking";
      } else if (currentState == Entity.STATE_LOCKED) {
        action = Client.ENTITY_ACTION_UNLOCK;
        loadingText = "Unlocking";
      }
    } else if (entity.getType() == Entity.TYPE_VALVE) {
      if (currentState == Entity.STATE_OPEN) {
        action = Client.ENTITY_ACTION_CLOSE;
        loadingText = "Closing";
      } else if (currentState == Entity.STATE_CLOSED) {
        action = Client.ENTITY_ACTION_OPEN;
        loadingText = "Opening";
      }
    } else if (entity.getType() == Entity.TYPE_COVER) {
      action = Client.ENTITY_ACTION_COVER_TOGGLE;
      loadingText = "Toggling";
    } else if (entity.getType() == Entity.TYPE_BUTTON || entity.getType() == Entity.TYPE_INPUT_BUTTON) {
      action = Client.ENTITY_ACTION_PRESS;
      loadingText = "Pressing";
    } else {
      if (currentState == Entity.STATE_ON) {
        action = Client.ENTITY_ACTION_TURN_OFF;
        loadingText = "Turning off";
      } else if (currentState == Entity.STATE_OFF) {
        action = Client.ENTITY_ACTION_TURN_ON;
        loadingText = "Turning on";
      }
    }

    if (entity.getType() == Entity.TYPE_SCENE) {
      entityType = "scene";
      action = null;
    } else if (entity.getType() == Entity.TYPE_LIGHT) {
      entityType = "light";
    } else if (entity.getType() == Entity.TYPE_SWITCH) {
      entityType = "switch";
    } else if (entity.getType() == Entity.TYPE_VALVE) {
      entityType = "valve";
    } else if (entity.getType() == Entity.TYPE_AUTOMATION) {
      entityType = "automation";
    } else if (entity.getType() == Entity.TYPE_SCRIPT) {
      entityType = "script";
    } else if (entity.getType() == Entity.TYPE_LOCK) {
      entityType = "lock";
    } else if (entity.getType() == Entity.TYPE_COVER) {
      entityType = "cover";
    } else if (entity.getType() == Entity.TYPE_FAN) {
      entityType = "fan";
    } else if (entity.getType() == Entity.TYPE_INPUT_BOOLEAN) {
      entityType = "input_boolean";
    } else if (entity.getType() == Entity.TYPE_BUTTON) {
      entityType = "button";
    } else if (entity.getType() == Entity.TYPE_INPUT_BUTTON) {
      entityType = "input_button";
    }

    App.getApp().viewController.showLoader(loadingText);

    client.setEntityState(entityId, entityType, action, Utils.method(Hass, :onToggleEntityStateCompleted));
  }
}

class HassController {



  // function _refreshPendingEntities() {
  //   var entity = null;

  //   for (var i = 0; i < _entities.size(); i++) {
  //     if (_entities[i].getState() == null) {
  //       entity = _entities[i];
  //       break;
  //     }
  //   }

  //   if (entity != null) {
  //     client.getEntity(entity.getId(), method(:onReceiveRefreshedEntity));
  //   } else {
  //     System.println(_entities);
  //     storeEntities();
  //     App.getApp().viewController.removeLoader();
  //   }
  // }

  // function onReceiveEntities(err, data) {
  //   if (err == null) {
  //     var entities = data[:body]["attributes"]["entity_id"];

  //     _entities = new [0];

  //     for (var i = 0; i < entities.size(); i++) {
  //       _entities.add(new Entity({
  //         :id => entities[i],
  //         :name => "",
  //         :state => null
  //       }));
  //     }

  //     _refreshPendingEntities();
  //   } else {
  //     App.getApp().viewController.showError(err);
  //   }
  // }

  // function refreshAllEntityStates() {
  //     for (var i = 0; i < _entities.size(); i++) {
  //       _entities[i].setState(null);
  //     }

  //     _refreshPendingEntities();
  // }
}