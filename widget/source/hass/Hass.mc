using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.System;
using Toybox.Timer;
using Toybox.Lang;

using Utils;

module Hass {
  // v3: :fullmem's STORED_FIELDS grew from the old fixed 6-field stride to
  // 10, to persist select's options and input_number/number's min/max/step
  // (see Entity.mc). Bumped so a :fullmem device never misreads an old
  // v2 (6-field) array with the new 10-field stride - offset math would
  // silently pull the next entity's id/name into this one's tail fields.
  // :lowmem's stride never changed (still 6), so it stays on v2 below -
  // bumping it too would force every lowmem install to migrate for a
  // format change that never applied to it.
  (:fullmem)
  const STORAGE_KEY = "Hass/entities/v3";

  // The pre-2.2.0 flat-array key, read by loadStoredEntities()'s one-time
  // migration below. :fullmem-only: on :lowmem, STORAGE_KEY is already
  // this same key (see above), so there's nothing to migrate from.
  (:fullmem)
  const STORAGE_KEY_V2 = "Hass/entities/v2";

  (:lowmem)
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
      Utils.debugLog("storeEntities: skipped, low memory", null, null);
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

  // :fullmem needs the v2 -> v3 migration below; :lowmem's STORAGE_KEY is
  // already v2, so there's nothing to migrate and it keeps the plain read.
  (:fullmem)
  function loadStoredEntities() {
    _entities = new [0];

    var stored = App.Storage.getValue(STORAGE_KEY);

    if (stored != null) {
      for (var i = 0; i + Entity.STORED_FIELDS <= stored.size(); i += Entity.STORED_FIELDS) {
        var entity = Entity.createFromStorage(stored, i);
        // Filter out null entities (from corrupted or invalid data)
        if (entity != null) {
          _entities.add(entity);
        }
      }

      // A leftover v2 key means the device was already on 2.2.0+ and
      // recovered (or the migration below ran but the store-skip left v2
      // behind). Current storage is authoritative; drop the stale copy.
      if (App.Storage.getValue(STORAGE_KEY_V2) != null) {
        App.Storage.deleteValue(STORAGE_KEY_V2);
      }
    } else if (App.Storage.getValue(STORAGE_KEY_V2) != null) {
      // One-time migration of the 2.1.0-era format (see _migrateV2Entities).
      _migrateV2Entities();
    } else {
      _loadLegacyStoredEntities();
    }

    loadScenesFromSettings();

    Utils.debugLog("Loaded entities: ", _entities.size(), " total");
  }

  (:lowmem)
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

    Utils.debugLog("Loaded entities: ", _entities.size(), " total");
  }

  // Reads the 2.1.0-era flat array (Entity.STORED_FIELDS_V2 slots per
  // entity) and rewrites it under the current key. 2.2.0 bumped the key
  // without a migration, which made the 2.1.0 -> 2.2.0 update show
  // "No entities configured" with a startup refresh that walks an empty
  // list - the data was orphaned, not gone, so this recovers it.
  (:fullmem)
  function _migrateV2Entities() {
    var stored = App.Storage.getValue(STORAGE_KEY_V2);

    if (stored == null) {
      return;
    }

    for (var i = 0; i + Entity.STORED_FIELDS_V2 <= stored.size(); i += Entity.STORED_FIELDS_V2) {
      var entity = Entity.createFromV2Storage(stored, i);
      if (entity != null) {
        _entities.add(entity);
      }
    }

    Utils.debugLog("Migrated v2 entities: ", _entities.size(), " total");

    storeEntities();

    // Drop the old key only once the new one is confirmed written. On a
    // 64 KB device storeEntities() skips when free heap is below
    // MIN_FREE_MEMORY - the normal state at startup there - and the
    // in-memory list is what the rest of the app uses, so deleting v2 now
    // would turn a recoverable skip into real data loss. Leaving it makes
    // the next launch retry here instead: self-healing. A successful write
    // leaves both keys present only until this delete, which is cheap.
    if (App.Storage.getValue(STORAGE_KEY) != null) {
      App.Storage.deleteValue(STORAGE_KEY_V2);
    }
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
      Utils.debugLog("Invalid entity data received", null, null);
      if (data != null && data[:context] != null && data[:context][:callback] != null) {
        data[:context][:callback].invoke(new Error(Error.ERROR_UNKNOWN), null);
      }
      return;
    }

    var entity = getEntity(data[:body]["entity_id"]);

    // If entity doesn't exist, skip processing but still invoke callback to continue chain
    if (entity == null) {
      Utils.debugLog("Entity not found: ", data[:body]["entity_id"], null);
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

      if (data[:body]["attributes"]["unit_of_measurement"] != null && entity.getType() != Entity.TYPE_INPUT_NUMBER) {
        // input_number/number keep a plain numeric value so it can be parsed for editing
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

      _applyExtendedAttributes(entity, data[:body]["attributes"]);
    } else {
      state = data[:body]["state"];
      sensorClass = SENSOR_OTHER;
    }

    if (name != null) {
      entity.setName(name);
    }

    if (state != null) {
      entity.setState(_formatEntityState(entity, state));
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

  // input_number/number's raw HA state string (e.g. "85.0") doesn't
  // necessarily match the precision implied by its step - reformat it the
  // same way the optimistic update in onSetInputNumberValueCompleted()
  // already does, or a refresh right after confirming a value flips the
  // display from the just-confirmed "85" back to HA's own "85.0".
  // :fullmem-only since it needs entity.getStep()/Utils.formatNumberForStep,
  // both editing-only; 64 KB widget devices just display HA's raw state.
  (:fullmem)
  function _formatEntityState(entity, state) {
    if (entity.getType() == Entity.TYPE_INPUT_NUMBER) {
      return Utils.formatNumberForStep(state, entity.getStep());
    }
    return state;
  }

  (:lowmem)
  function _formatEntityState(entity, state) {
    return state;
  }

  // select/input_select's options and input_number/number's min/max/step -
  // editing-only data (see Entity._mOptions and friends), so this is
  // :fullmem-only; on 64 KB widget devices (:lowmem, see monkey.jungle)
  // these entities are read-only and never read these attributes.
  (:fullmem)
  function _applyExtendedAttributes(entity, attributes) {
    if (attributes["options"] != null) {
      entity.setOptions(attributes["options"]);
    }
    if (attributes["min"] != null) {
      entity.setMin(attributes["min"]);
    }
    if (attributes["max"] != null) {
      entity.setMax(attributes["max"]);
    }
    if (attributes["step"] != null) {
      entity.setStep(attributes["step"]);
    }
  }

  (:lowmem)
  function _applyExtendedAttributes(entity, attributes) {
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
      Utils.debugLog("refresh: stopped early, low memory, ", _entitiesToRefresh.size(), " left");
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
      Utils.debugLog("Invalid entities data received", null, null);
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
      Utils.debugLog("import: dropped ", dropped, " entities, low memory");
      App.getApp().viewController.showError(
        "Low memory:\nonly " + _entities.size() + " of " + (_entities.size() + dropped) + "\nentities loaded"
      );
    }
  }

  // showLoaderUi must be false when called from App.getInitialView()'s
  // cold-start self-heal (see below) - the runtime hasn't pushed the
  // initial view onto the Ui stack yet at that point, and showLoader()'s
  // Ui.pushView() destabilizes the simulator (and, going by the crash
  // shape, likely real hardware too) once enough Ui.requestUpdate() calls
  // land during the refresh that follows. The initial view already shows
  // "No entities" and updates once data arrives, so no loader is needed
  // there anyway.
  function importEntities(showLoaderUi) {
    Utils.logMem("importEntities:enter", null);
    var group = getGroup();

    if (group == null) {
      App.getApp().viewController.showError("Group\nnot\nconfigured");
      return;
    }

    if (showLoaderUi) {
      App.getApp().viewController.showLoader("Refreshing");
    }

    client.getEntity(group, null, Utils.method(Hass, :_onReceiveEntities));
  }

  function _onBatteryUpdate(err, data) {
      if (err != null) {
        Utils.debugLogError("Battery update error: ", err);
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
      Utils.debugLog("Invalid toggle entity response", null, null);
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

  // select/input_select editing (Menu2 option picker) is :fullmem-only -
  // 64 KB widget devices (:lowmem, see monkey.jungle) show these entities
  // read-only, so these four functions are only reachable through it.
  (:fullmem)
  function onSelectOptionCompleted(error, data) {
    if (error != null) {
      App.getApp().viewController.removeLoaderImmediate();
      App.getApp().viewController.showError(error);
      return;
    }

    if (data == null || data[:context] == null || data[:context][:entityId] == null) {
      Utils.debugLog("Invalid select option response", null, null);
      App.getApp().viewController.removeLoader();
      return;
    }

    var entity = getEntity(data[:context][:entityId]);
    if (entity != null && data[:context][:extraParams] != null && data[:context][:extraParams]["option"] != null) {
      entity.setState(data[:context][:extraParams]["option"]);
      storeEntities();
      Ui.requestUpdate();
    }

    App.getApp().viewController.removeLoader();
  }

  (:fullmem)
  function selectOption(entity, option) {
    App.getApp().viewController.showLoader("Selecting");

    client.callService(
      entity.getServiceDomain(),
      "select_option",
      entity.getId(),
      { "option" => option },
      Utils.method(Hass, :onSelectOptionCompleted)
    );
  }

  // input_number/number editing (InputNumberEditView) is :fullmem-only -
  // same reasoning as select above.
  (:fullmem)
  function onSetInputNumberValueCompleted(error, data) {
    if (error != null) {
      App.getApp().viewController.removeLoaderImmediate();
      App.getApp().viewController.showError(error);
      return;
    }

    if (data == null || data[:context] == null || data[:context][:entityId] == null) {
      Utils.debugLog("Invalid set input number value response", null, null);
      App.getApp().viewController.removeLoader();
      return;
    }

    var entity = getEntity(data[:context][:entityId]);
    if (entity != null && data[:context][:extraParams] != null && data[:context][:extraParams]["value"] != null) {
      var value = data[:context][:extraParams]["value"];
      entity.setState(Utils.formatNumberForStep(value, entity.getStep()));
      storeEntities();
      Ui.requestUpdate();
    }

    App.getApp().viewController.removeLoader();
  }

  (:fullmem)
  function setInputNumberValue(entity, value) {
    App.getApp().viewController.showLoader("Setting");

    client.callService(
      entity.getServiceDomain(),
      "set_value",
      entity.getId(),
      { "value" => value },
      Utils.method(Hass, :onSetInputNumberValueCompleted)
    );
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
    if (entity.getType() == Entity.TYPE_SELECT || entity.getType() == Entity.TYPE_INPUT_NUMBER) {
      // handled via a dedicated menu / edit view, not a simple toggle
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