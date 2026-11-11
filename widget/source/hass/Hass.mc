using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.System;
using Toybox.Lang;

using Utils;

module Hass {
  // The entity list is stored as records of up to STORE_CHUNK entities
  // each, under STORAGE_KEY + "0", "1", ... - the list ends at the first
  // missing record. A record is a flat Array: the number of slots per entity
  // first (Entity.STORED_FIELDS of the build that wrote it), then that many
  // slots for every entity (see Entity.writeToStorage()), null where unused.
  //
  // Why records: Application.Storage serialises a value inside the app's
  // heap, and an Out Of Memory error cannot be caught. Written as one Array
  // (up to 2.3.0), a list of 20 to 26 entities needed about 6 kB of free
  // heap on an Instinct 2X, and every refresh - that is every launch - ended
  // in a crash. One record needs a small, fixed amount whatever the size of
  // the list (see STORE_MIN_FREE). It also keeps a long list clear of
  // Storage's limit of 32 kB per value.
  //
  // Why the slot count is in the record: the two build tiers store a
  // different number of slots. Reading it from the record lets either tier
  // load what the other wrote, should a device ever move between them.
  const STORAGE_KEY = "Hass/entities/v4/";

  // What earlier releases wrote, read once by _migrateStoredEntities(): one
  // flat Array for the whole list, and before that one Dictionary per entity
  // under the legacy key.
  //   v2: 6 slots per entity - every device in 2.1.0, :lowmem again from
  //       2.2.1 to 2.3.0
  //   v3: 10 slots per entity on :fullmem, 2.2.0 to 2.3.0 - and 6 slots on
  //       :lowmem in 2.2.0 alone, which used this key on both tiers. 2.2.1
  //       went back to v2 there and left the v3 list where it was.
  const STORAGE_KEY_V3 = "Hass/entities/v3";

  const STORAGE_KEY_V2 = "Hass/entities/v2";

  (:fullmem)
  const STORAGE_KEY_LEGACY = "Hass/entities";

  // Entities per record, and the free heap storeEntities() asks for before
  // it writes. Measured in the simulator (Instinct 2X; the heap filled until
  // a given amount was free, then one record built and written): a record
  // needs free heap in proportion to its entities and their strings, with
  // next to no fixed part -
  //    6 slots per entity: 0.3 kB for 1 entity, 1.3 kB for 4, 1.8 kB for 6,
  //      3.0 kB for 12, 5.7 kB for 24; 2.6 kB for 6 whose ids have 53 and
  //      whose names have 39 characters
  //   10 slots per entity: 3.3 kB for 12, 6.4 kB for 24; 6.3 kB for 8
  //      selects with 20 options each
  // Reading a record back takes about nine tenths of what writing it does.
  //
  // The floors leave room for a record of long names (:lowmem) or of
  // nothing but large selects (:fullmem). On :lowmem the floor stays below
  // MIN_FREE_MEMORY, so a list that could be refreshed can be stored. On
  // :fullmem only the three 128 KB devices ever get near theirs.
  (:lowmem)
  const STORE_CHUNK = 4;

  (:fullmem)
  const STORE_CHUNK = 8;

  (:lowmem)
  const STORE_MIN_FREE = 3000;

  (:fullmem)
  const STORE_MIN_FREE = 10000;

  var client = null;
  var _entities = new [0];
  var _entitiesToRefresh = new [0];
  var _transitionalEntities =  new [0];
  var _continueRefreshOnError = false;
  var _refreshActive = false;
  var _pendingImportIds = null;

  // A refresh chain that stopped at the free-heap floor inside a response
  // callback and goes on from the deferred job (see _continueRefresh()).
  var _refreshPaused = false;

  // Records in storage, as of the last load or store.
  var _storedChunks = 0;

  // Set while the list in memory comes from the key of an earlier release
  // and is not stored as records yet (see _migrateStoredEntities()).
  var _oldKeys = false;

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
    var group = Utils.getProperty("group", "Garmin");

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

  // Writes the entity list, one record at a time (see STORAGE_KEY). Returns
  // true when every record was written.
  function storeEntities() {
    Utils.logMem("storeEntities:enter", null);

    // Skipping the write costs only the offline copy of this session's
    // changes - far better than an Out Of Memory crash. The records already
    // stored stay valid.
    if (Utils.freeMemory() < STORE_MIN_FREE) {
      Utils.debugLog("storeEntities: skipped, low memory", null, null);
      return false;
    }

    var size = 1 + STORE_CHUNK * Entity.STORED_FIELDS;
    var count = _entities.size();
    var i = 0;
    var chunks = 0;

    // Runs once for an empty list too: an empty record 0 says "stored, and
    // empty", where no record at all sends the next launch looking for the
    // lists of earlier releases (see loadStoredEntities()).
    do {
      var chunk = new [size];
      var slot = 1;

      chunk[0] = Entity.STORED_FIELDS;

      while (i < count && slot < size) {
        // External (settings-defined) entities are never stored.
        if (!_entities[i].isExternal()) {
          slot = _entities[i].writeToStorage(chunk, slot);
        }
        i++;
      }

      if (slot == 1 && chunks > 0) {
        // Only external entities were left: no empty record at the end.
        break;
      }

      // Application.Storage throws when the store has no room left. The
      // records written so far stay, with the old ones behind them - all of
      // them complete, and the next store puts it right.
      try {
        App.Storage.setValue(STORAGE_KEY + chunks, chunk);
      } catch (e) {
        Utils.debugLog("storeEntities: setValue failed", null, null);

        if (_oldKeys) {
          // The list of an earlier release is still under its old key, and
          // complete there. Records that hold only its first part must not
          // stand in for it: without record 0, the next launch reads the
          // old key again.
          App.Storage.deleteValue(STORAGE_KEY + 0);
        }
        return false;
      }

      // Released before the next one is built.
      chunk = null;
      chunks++;

      // Counted at once: should a later write throw, the next store still
      // knows of every record there is.
      if (chunks > _storedChunks) {
        _storedChunks = chunks;
      }
    } while (i < count);

    // A shorter list: drop the records behind it, last first, so that what
    // is stored is a run from record 0 at every moment.
    while (_storedChunks > chunks) {
      _storedChunks--;
      App.Storage.deleteValue(STORAGE_KEY + _storedChunks);
    }

    _storedChunks = chunks;

    if (_oldKeys) {
      // The list exists as records now - only now may its old key go. That
      // is this store whichever it is: the one of the migration at launch
      // or, if that one was skipped or failed, a later one.
      _oldKeys = false;
      _dropOldKeys();
    }

    Utils.logMem("storeEntities:done n", chunks);
    return true;
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
        _keepIcon(_entities[i], preservedIcons);
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
        _restoreIcon(newEntity, preservedIcons);

        _entities.add(newEntity);
      }
    }
  }

  // The two halves of loadScenesFromSettings()'s icon snapshot. Entities
  // have no icon on the 64 KB tier (see Entity._mIcon).
  (:fullmem)
  function _keepIcon(entity, icons) {
    var icon = entity.getIcon();

    if (icon != null) {
      icons[entity.getId()] = icon;
    }
  }

  (:lowmem)
  function _keepIcon(entity, icons) {
  }

  (:fullmem)
  function _restoreIcon(entity, icons) {
    var id = entity.getId();

    if (icons.hasKey(id)) {
      entity.setIcon(icons[id]);
    }
  }

  (:lowmem)
  function _restoreIcon(entity, icons) {
  }

  // One function for both tiers.
  function loadStoredEntities() {
    _entities = new [0];
    _storedChunks = 0;

    var chunk = App.Storage.getValue(STORAGE_KEY + 0);

    if (chunk == null) {
      // Nothing in this layout yet: an update from an earlier release, or a
      // first launch. Leaves record 0 behind either way, so this runs once.
      _migrateStoredEntities();
    }

    // Ends at the first missing record - or one that is no Array at all.
    // Every record is counted, also when _addStored() takes nothing from it
    // any more: the next store must know how many there are to drop.
    while (chunk instanceof Lang.Array) {
      _addStored(chunk, 0);
      _storedChunks++;
      chunk = null;
      chunk = App.Storage.getValue(STORAGE_KEY + _storedChunks);
    }

    loadScenesFromSettings();

    Utils.debugLog("Loaded entities: ", _entities, " total");
  }

  // Adds the entities of one stored Array. A record names its slots per
  // entity in slot 0; the flat Arrays of earlier releases start with an
  // entity id instead and have `stride` slots per entity.
  //
  // Stops at the free-heap floor, as the import does: a list that no longer
  // fits - after an update that left less heap - comes up short instead of
  // ending every launch in a crash. The next store then writes what did fit.
  function _addStored(stored, stride) {
    var i = 0;

    if (stored.size() > 0 && stored[0] instanceof Lang.Number) {
      stride = stored[0];
      i = 1;
    }

    if (stride < Entity.STORED_FIELDS_MIN) {
      // Damaged. (And 0 would never end the loop below.)
      return;
    }

    while (i + stride <= stored.size() && Utils.freeMemory() >= MIN_FREE_MEMORY) {
      var entity = Entity.createFromStorage(stored, i, stride);

      // An id that is there already: a store cut short after the group
      // changed leaves new records in front of old ones, and an entity that
      // moved between them is in both.
      if (entity != null && getEntity(entity.getId()) == null) {
        _entities.add(entity);
      }
      i += stride;
    }
  }

  // Reads the list an earlier release stored (see STORAGE_KEY_V3) and writes
  // it as records right away - at launch the heap is at its emptiest. The
  // old keys go only once a store went through (see _oldKeys): if this one
  // is skipped or fails, a later one of this session does it, and if none
  // does, the next launch finds no record 0 and comes here again. (2.2.0
  // changed its key without reading the old one, and the update showed "No
  // entities configured".)
  (:fullmem)
  function _migrateStoredEntities() {
    var stride = Entity.STORED_FIELDS;
    var stored = App.Storage.getValue(STORAGE_KEY_V3);

    if (stored == null) {
      stride = Entity.STORED_FIELDS_MIN;
      stored = App.Storage.getValue(STORAGE_KEY_V2);
    }

    if (stored instanceof Lang.Array) {
      _addStored(stored, stride);
    } else {
      _loadLegacyStoredEntities();
    }

    // Gone before the records are built.
    stored = null;

    _oldKeys = true;
    storeEntities();

    Utils.debugLog("Migrated entities: ", _entities, " total");
  }

  (:fullmem)
  function _dropOldKeys() {
    App.Storage.deleteValue(STORAGE_KEY_V3);
    App.Storage.deleteValue(STORAGE_KEY_V2);
    App.Storage.deleteValue(STORAGE_KEY_LEGACY);
  }

  // On the 64 KB tier both keys hold six slots per entity. v2 comes first:
  // where both exist, v3 is the list 2.2.0 left behind (see STORAGE_KEY_V3).
  // The Dictionary format before 2.1.0 is not read here: its reader costs
  // more code than this tier can spare for a release that ran out of memory
  // on it. Such an install starts with an empty list and imports its group
  // again.
  (:lowmem)
  function _migrateStoredEntities() {
    var stored = App.Storage.getValue(STORAGE_KEY_V2);

    if (stored == null) {
      stored = App.Storage.getValue(STORAGE_KEY_V3);
    }

    if (stored instanceof Lang.Array) {
      _addStored(stored, Entity.STORED_FIELDS);
    }

    stored = null;

    _oldKeys = true;
    storeEntities();
  }

  (:lowmem)
  function _dropOldKeys() {
    App.Storage.deleteValue(STORAGE_KEY_V2);
    App.Storage.deleteValue(STORAGE_KEY_V3);
  }

  // Reads the pre-2.0.4 format (one Dictionary per entity). Its key is
  // deleted by _dropOldKeys() once the records are written - not here, as
  // it used to be: without a refresh to store the list again, that lost it.
  (:fullmem)
  function _loadLegacyStoredEntities() {
    var stored = App.Storage.getValue(STORAGE_KEY_LEGACY);

    if (!(stored instanceof Lang.Array)) {
      return;
    }

    for (var i = 0; i < stored.size(); i++) {
      var entity = Entity.createFromDict(stored[i]);
      if (entity != null) {
        _entities.add(entity);
      }
    }
  }

  function _onReceiveEntity(err, data) {
    Utils.logMem("onReceiveEntity queue", _entitiesToRefresh);
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

      // A chain that paused for the deferred job ends here as well: that job
      // must not go on with it once the error is on screen.
      _refreshPaused = false;
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
      // Every transitional entity in a chain lands here; the keyed job is
      // simply moved. The dedicated timer this used to have was start()ed
      // again for each of them while still running, which may
      // (undocumented) raise "Too Many Timers Error" (#101).
      Scheduler.schedule(:transitional, Utils.method(Hass, :_refreshTransitionalEntities), 2000);
    }

    _continueRefresh(false);
  }

  // The next step of a refresh chain. `released` says whether the response
  // before it is gone: false inside a response callback, true from the
  // deferred job.
  function _continueRefresh(released) {
    if (_entitiesToRefresh.size() > 0 && Utils.freeMemory() < MIN_FREE_MEMORY) {
      if (!released) {
        // A response callback runs inside OAuthClient.onWebResponse(), whose
        // frame still holds the parsed body - about 2 kB that are free again
        // the moment this returns, and before the next response is parsed.
        // Giving up here stopped a refresh 6 to 9 entities short of what the
        // floor is meant to allow - and on a list loaded from storage, where
        // the heap is as full at the first response as at the last, it
        // stopped the whole refresh after one entity. So ask again from the
        // deferred job; the cost is one timer round trip per step, and only
        // this close to the floor.
        _refreshPaused = true;
        _scheduleDeferred();
        return;
      }

      // Not enough heap left to parse another response. Abandon the rest of
      // the chain; those entities keep their last known state instead of the
      // whole app dying mid-refresh.
      Utils.debugLog("refresh: stopped early, low memory, ", _entitiesToRefresh, " left");
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
        _continueRefresh(released);
      }
    } else {
      _refreshActive = false;

      // Finish on a fresh stack rather than inline. This branch runs inside
      // OAuthClient.onWebResponse(), whose frame still holds the last parsed
      // response body - a couple of KB. Storing the entities while that
      // response is still live is a peak a 64 KB device cannot afford at the
      // end of a group import.
      _scheduleDeferred();
    }
  }

  // Defers work that must not run on an HTTP response's stack, where the
  // parsed body is still live. By the time the :deferred job runs (see
  // Scheduler), onWebResponse() has returned and the response is
  // collectable.
  function _scheduleDeferred() {
    Scheduler.schedule(:deferred, Utils.method(Hass, :_runDeferred), Scheduler.MIN_DELAY);
  }

  // The one :deferred job covers all three kinds of deferred work: building
  // an imported group, going on with a refresh chain that paused at the
  // free-heap floor, and finishing a refresh. A pending import wins: it ends
  // by starting a refresh, which schedules the job again to finish - or,
  // without the phone, schedules it right away (see
  // _buildImportedEntities()).
  function _runDeferred() {
    if (_pendingImportIds != null) {
      _buildImportedEntities();
      return;
    }

    if (_refreshPaused) {
      _refreshPaused = false;

      if (!_canRefresh()) {
        // The connection went since the chain paused: every further
        // request would fail. End the chain here.
        _entitiesToRefresh = new [0];
      }

      _continueRefresh(true);
      return;
    }

    _finishRefresh();
  }

  // Tail of a completed refresh chain. Runs as the deferred job (see
  // _scheduleDeferred()), so the HTTP response that triggered it has already
  // been released.
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
    if (_refreshActive || !_canRefresh()) {
      return;
    }
    _refreshActive = true;

    // A chain of the list before this one that is still paused must not go
    // on from the deferred job next to this one (see _buildImportedEntities(),
    // which starts over on a new list).
    _refreshPaused = false;

    _entitiesToRefresh = new [0];
    _continueRefreshOnError = continueOnError == true;

    for (var i = 0; i < _entities.size(); i++) {
      _entitiesToRefresh.add(_entities[i]);
    }

    _refreshPendingEntities(null, null);
  }

  // Without a connection - the phone, or Wi-Fi that is up outside a sync
  // as on Edge units (WifiLte.hasDirectConnection()) - every request of the
  // chain fails, and the first "Phone not connected" error closes the app.
  // A "Refresh on show" in onShow() would do that right while
  // ConnectionWait waits for a connection, or when the system sync screen
  // of a Wi-Fi/LTE action closes (startSync2() is documented to restart the
  // app in sync mode, but in practice the app can stay alive under that
  // screen). So refreshAllEntities() does nothing then - silently: callers
  // must not count on the refresh finishing, or on it removing a loader
  // (see _buildImportedEntities()).
  //
  // The trade-off: only the wait at launch (ConnectionWait) refreshes once
  // a connection is there. After a disconnect later on, nothing refreshes
  // by itself when the phone comes back - the stored states stay until the
  // next refresh is asked for (Refresh on show, the menu, the next launch).
  // (:fullmem only - the 64 KB devices keep the old behavior.)
  (:fullmem)
  function _canRefresh() {
    return WifiLte.hasDirectConnection();
  }

  (:lowmem)
  function _canRefresh() {
    return true;
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

    // Hold on to the id list only, then let the deferred job build the
    // entities. Building them here would do it inside onWebResponse(), where
    // the whole parsed group response is still live - 2.4 KB for a 12-member
    // group, measured on Instinct 2X, against 1.6 KB of free heap. Keeping
    // just the id array keeps the ids (which the entities reference anyway)
    // and drops the rest of the response.
    _pendingImportIds = data[:body]["attributes"]["entity_id"];
    Utils.logMem("import:parsed n", _pendingImportIds);

    _scheduleDeferred();
  }

  // Rebuilds _entities from the imported group. Runs as the deferred job
  // (see _scheduleDeferred()), so the group response has already been
  // released.
  function _buildImportedEntities() {
    var ids = _pendingImportIds;
    _pendingImportIds = null;

    if (ids == null) {
      return;
    }

    Utils.logMem("import:build:enter n", ids);

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

    Utils.logMem("import:build:done n", _entities);

    loadScenesFromSettings();

    // The entity list was just replaced, so any refresh chain still walking
    // the old list is stale. Clear the guard so this refresh always starts.
    _refreshActive = false;

    if (_canRefresh()) {
      refreshAllEntities(false);
    } else {
      // The phone dropped since the group response came in (the ~50 ms of
      // the deferral). refreshAllEntities() would do nothing at all (see
      // _canRefresh()), so _finishRefresh() would never run: the
      // "Refreshing" loader would stay up and the new list would not be
      // stored. With _pendingImportIds already cleared above, the deferred
      // job goes straight to _finishRefresh().
      _scheduleDeferred();
    }

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
    if (Utils.getProperty("closeAfterAction", false)) {
      // Small delay before exiting to ensure UI updates are seen by user.
      // This used to start a brand-new Timer for every action - one of the
      // timers behind "Too Many Timers Error" (issue #101). Each exit reason
      // has a key of its own, so none replaces or cancels another.
      Scheduler.schedule(:exitAfterAction, Utils.method(Hass, :exitApplication), 2000);
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
    var params = { "option" => option };

    // No connection: offer to send it over Wi-Fi/LTE (see WifiLte.mc). The
    // question shows just the option, see WifiLte.offerService().
    if (WifiLte.shouldUse()) {
      WifiLte.offerService(entity, "select_option", params, "Selecting\n" + option, option);
      return;
    }

    App.getApp().viewController.showLoader("Selecting");

    client.callService(
      entity.getServiceDomain(),
      "select_option",
      entity.getId(),
      params,
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
    var params = { "value" => value };

    // No connection: offer to send it over Wi-Fi/LTE (see WifiLte.mc). The
    // question shows just the value, see WifiLte.offerService().
    if (WifiLte.shouldUse()) {
      var text = Utils.formatNumberForStep(value, entity.getStep());

      WifiLte.offerService(entity, "set_value", params, "Setting " + entity.getRawName() + "\nto " + text, text);
      return;
    }

    App.getApp().viewController.showLoader("Setting");

    client.callService(
      entity.getServiceDomain(),
      "set_value",
      entity.getId(),
      params,
      Utils.method(Hass, :onSetInputNumberValueCompleted)
    );
  }

  // input_datetime/date/time/datetime editing (DateTimeEditView) is
  // :fullmem-only - same reasoning as select above. See DateTimeValue for
  // the formats and services.
  (:fullmem)
  function onSetDateTimeValueCompleted(error, data) {
    if (error != null) {
      App.getApp().viewController.removeLoaderImmediate();
      App.getApp().viewController.showError(error);
      return;
    }

    if (data == null || data[:context] == null || data[:context][:entityId] == null) {
      Utils.debugLog("Invalid set date/time value response", null, null);
      App.getApp().viewController.removeLoader();
      return;
    }

    var entity = getEntity(data[:context][:entityId]);
    var params = data[:context][:extraParams];

    if (entity != null && params != null) {
      // What Home Assistant now reports - for datetime.* the UTC form of
      // what was sent.
      var state = DateTimeValue.reportedState(entity, params);

      if (state != null) {
        entity.setState(state);
        storeEntities();
        Ui.requestUpdate();
      }
    }

    App.getApp().viewController.removeLoader();
  }

  // Sets a date/time entity to `fields` ([year, month, day, hour, minute],
  // the watch's local time - see DateTimeValue). `mode` is what the editor
  // showed; what is sent is what the entity holds now.
  (:fullmem)
  function setDateTimeValue(entity, fields, mode) {
    // A refresh while the editor was open can change what an
    // input_datetime holds (its state shows whether it has a date, a time
    // or both) - typically from "unknown", which opens with date and time,
    // to what it really has. If that is part of what was shown, just that
    // part is sent; sending a part the entity does not have would fail.
    // Should it need a part the editor did not show, what was entered does
    // not fit it, and nothing is sent - as LockConfirm.execute() refuses a
    // lock whose state changed.
    var current = DateTimeValue.modeOf(entity);

    if ((current & mode) != current) {
      App.getApp().viewController.showError("Entity changed,\nplease retry");
      return;
    }

    mode = current;

    var service = DateTimeValue.serviceName(entity);
    var params = DateTimeValue.serviceParams(entity, fields, mode);

    // No connection: offer to send it over Wi-Fi/LTE (see WifiLte.mc). The
    // question shows just the value, see WifiLte.offerService().
    if (WifiLte.shouldUse()) {
      var text = DateTimeValue.format(mode, fields);

      WifiLte.offerService(entity, service, params, "Setting " + entity.getRawName() + "\nto " + text, text);
      return;
    }

    App.getApp().viewController.showLoader("Setting");

    client.callService(
      entity.getServiceDomain(),
      service,
      entity.getId(),
      params,
      Utils.method(Hass, :onSetDateTimeValueCompleted)
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
    if (entity.getType() == Entity.TYPE_SELECT || entity.getType() == Entity.TYPE_INPUT_NUMBER || entity.getType() == TYPE_DATETIME) {
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
      } else {
        // Locking, unlocking, jammed, open or unknown: no service fits.
        // Without an action Client.setEntityState() falls back to
        // lock/turn_on, which Home Assistant refuses (400) - via the phone,
        // or only after a whole Wi-Fi/LTE sync.
        App.getApp().viewController.showError("Lock is busy,\ntry again");
        return;
      }
    } else if (entity.getType() == Entity.TYPE_VALVE) {
      if (currentState == Entity.STATE_OPEN) {
        action = Client.ENTITY_ACTION_CLOSE;
        loadingText = "Closing";
      } else if (currentState == Entity.STATE_CLOSED) {
        action = Client.ENTITY_ACTION_OPEN;
        loadingText = "Opening";
      } else {
        // Opening, closing or unknown: valve/turn_on, see the lock above.
        App.getApp().viewController.showError("Valve is busy,\ntry again");
        return;
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

    if (entityType == null) {
      // TYPE_UNKNOWN: there is no service to call, via the phone or over
      // Wi-Fi/LTE.
      return;
    }

    // No connection: offer to send it over Wi-Fi/LTE instead (:fullmem, see
    // WifiLte.mc).
    if (_offerWifiLte(entity, entityType, action, loadingText)) {
      return;
    }

    App.getApp().viewController.showLoader(loadingText);

    client.setEntityState(entityId, entityType, action, Utils.method(Hass, :onToggleEntityStateCompleted));
  }

  // Returns true when the action was handed to a Wi-Fi/LTE prompt instead.
  (:fullmem)
  function _offerWifiLte(entity, entityType, action, loadingText) {
    if (!WifiLte.shouldUse()) {
      return false;
    }

    if (entity.getType() == Entity.TYPE_SCENE) {
      // Scenes fall through toggleEntityState() with the generic "Loading".
      loadingText = "Activating";
    }

    // "exit": "Close App after successful action" applies, as it does to a
    // toggle sent via the phone (onToggleEntityStateCompleted()) - and, as
    // there, not to a select option or number value (WifiLte.offerService()).
    var command = {
      "id" => entity.getId(),
      "domain" => entityType,
      "exit" => true
    };

    // null for scenes - see Client.setEntityState(). Left out rather than
    // stored as null.
    if (action != null) {
      command["action"] = action;
    }

    WifiLte.offer(command, loadingText + "\n" + entity.getRawName(), null);
    return true;
  }

  (:lowmem)
  function _offerWifiLte(entity, entityType, action, loadingText) {
    return false;
  }
}