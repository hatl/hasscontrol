# Contributing

Thanks for helping improve HassControl! This document covers what you need to
know to build, test, and submit changes.

## Project layout

- The widget source lives in `widget/` (this is also the VS Code workspace root).
- `widget/source/hass/` - Home Assistant communication (client, OAuth, entities).
- `widget/source/Entities/` - the entity views (card and list style).
- `widget/source/Menu/` - settings menus.
- `widget/monkey.jungle` - build configuration, including the memory-tier split described below. Only `widget/source/` is compiled (`base.sourcePath`).
- `widget/tools/simtest/` - the automated simulator tests (see its `README.md`).
- `widget/AGENTS.md` - coding conventions (naming, comments, entity-type checklist). Please read it before making code changes.

## Building

Use the Connect IQ SDK (`monkeyc`). In VS Code the build task
`monkeyc: fenix7x` builds the default target; from the command line:

```sh
java -jar <SDK>/bin/monkeybrains.jar -o bin/widget.prg -f monkey.jungle \
  -y <developer_key> -d fenix7x -w -l 0
```

## Memory tiers: always test both

Garmin devices fall into two memory classes for this widget:

- **high-mem (fullmem)** - most modern watches (e.g. fenix7x, edge1040).
  Full feature set: MDI icons, list view, select/input_number editing.
- **low-mem** - devices with a 64 KB widget heap (e.g. instinct2x, fenix5, fr245, vivoactive3;
  see `monkey.jungle` for the full list). These build with `excludeAnnotations = fullmem`, which strips icons, the list view, and all editing UI at compile time.

**Every change must be built and smoke-tested on at least one device of each class.** A feature that compiles on fenix7x can still break the low-mem build (excluded symbols) or push it over the memory budget (launch failure or runtime Out Of Memory errors). Check the code+data size with `--build-stats 0`; the budget for low-mem widgets is 65536 bytes. `widget/tools/memcheck.sh` prints it for all low-mem devices.

Three high-mem devices are small as well: Instinct E (40 mm and 45 mm) and Instinct 3 Solar 45 mm have 128 KB, and get the full feature set. On these and on the low-mem devices every byte of code is a byte less for entities; an entity takes about 250 bytes on a low-mem device and about 360 on a high-mem one. When a change adds code, or touches how entities are loaded, refreshed or stored, run the capacity test on one low-mem device and on `instincte45mm` and compare with the build before it:

```sh
cd widget/tools/simtest
uv run capacity.py instinct2x 18 24 28 --mixed
uv run capacity.py instincte45mm 60 100
```

### Low-mem testing requires release mode

Low-mem devices can only be tested with a **release build** (`-r` flag / release configuration). A debug build carries extra code that pushes the binary past the 64 KB heap budget, so the app runs out of memory and won't even start in debug mode on these devices. Do not debug-test low-mem; use release builds and verify behavior there.

## Testing the storage upgrade path

The widget caches entities in `App.Storage` under a versioned key, and the persisted format has changed between releases. A bad migration makes the app show "No entities configured" after an update - this has happened before, so **test the upgrade path whenever you touch anything that is persisted**.

Simulator procedure:

1. Build the **old** release (e.g. `git checkout v2.1.0`), run it in the simulator, and let it import and store entities.
2. Stop the app, but keep the simulator running so its storage persists.
3. Build the **new** version, start it in the *same* simulator session, and confirm the previously stored entities are loaded (names and states intact), then that a refresh succeeds.
4. Repeat on a low-mem device (release build) - the stored form differs per memory tier, so a migration that works on fenix7x can still be wrong on instinct2x.

The simulator tests do this for the step from master to the current tree (`f7_storage_upgrade`, `i2_storage_upgrade`), and `uv run capacity.py <device> 24 --mixed --first-ref <tag>` does it for any release and list size. Add the release you are migrating from when you change what is stored.

## Submitting

- Keep changes focused; match the existing code style (2-space indent, camelCase, `Utils.debugLog` instead of `System.println`).
- State in the pull request which devices you tested, and whether you exercised the storage upgrade path.
