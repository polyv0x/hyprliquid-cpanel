# Hyprliquid for Noctalia

A Noctalia v5 companion for the native Hyprliquid renderer: choose a preset,
adjust the material live, follow the shell theme, and save custom profiles.
Plugin id: `polyv0x/hyprliquid`. This repository contains the controls; the
renderer and its control API stay in the separate Hyprliquid repository.

Requires Noctalia plugin API **24** or newer (tested with **v5.2.0**), `hyprctl`,
and a loaded Hyprliquid build exposing **control API 1**. Hyprliquid must match
the running Hyprland build and dependency ABI. An older renderer is shown as
unavailable; its legacy `config()`/`preset()` interface is insufficient for live
controls. Build the renderer with the new `json-c` dependency installed.

## Local installation

Use this repository as a local source; this also works with Noctalia offline
mode. No remote repository or public catalog is required.

```sh
noctalia plugins lint ./hyprliquid
noctalia msg plugins source add hyprliquid-dev path /home/polyvox/hyprliquid-cpanel
noctalia msg plugins enable polyv0x/hyprliquid
noctalia msg panel-toggle polyv0x/hyprliquid:panel
```

Add `polyv0x/hyprliquid:widget` through the bar's Add-widget picker, or add
`polyv0x/hyprliquid:shortcut` in Control Center shortcut settings. Both open the
same panel. The service starts when the plugin is enabled. Plugin settings
include **Restore last settings** (enabled by default).

Alternatively, copy the `hyprliquid/` directory to
`${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins/hyprliquid/` and enable it.
Luau changes hot-reload; manifest changes need a Noctalia config reload. Keep
hosting private if adding a git source. Do not store profiles in the source or
installation directory.

## Editing and ownership

The panel discovers presets, scalar defaults, and bounds from the renderer.
All 34 material parameters are grouped; expand a group to see its controls.
Inverse-height controls use a logarithmic scale and display their actual values.
Measured face mix stays a continuous 0–1 control. Coverage affects shader edge
coverage. Window radius, borders, rounding power, per-application rules, and
layer materials remain configured in Hyprland.

**Refraction → Neighbor contribution** adjusts how strongly neighbouring
windows appear in the glass, including floating panes that touch or overlap.
`1` preserves the full neighbour scene; `0` removes the additional neighbour
image while preserving windows underneath the glass.
Lower values soften neighbour content without fading the main frosted area.
It affects text and opaque windows too. The control acts on the neighbour image
sampled outside the receiving pane; windows directly underneath still follow
normal transparency and stacking, including at refracted edges. Partial overlap
is handled per pixel, so adjacent portions still respond to the sliders.
Layer surfaces retain native behavior.
Existing profiles default to `1`. The control appears when the renderer exposes
this parameter.

**Neighbor falloff** adds a smooth exponential fade from the receiving pane's
rounded edge toward its center. `0` keeps uniform contribution; higher values
fade it faster. Try `0.5`, which halves the contribution every 16 logical pixels
at the default effect scale. The main frost stays present. This is an artistic
edge fade, not a simulation of physical caustics. It affects neighbour images
in both refraction and edge bleed, and defaults to `0` in existing profiles.
Underlying windows stay visible instead of fading toward the wallpaper.

**Theme** selects the renderer preset's dark or light face shading and rim
highlights. All five current built-in presets provide both variants; clear glass
and its frosted derivatives use a subtler face blend. **Follow Noctalia** tracks
the shell's dark/light mode. Explicit slider overrides take precedence, so reset
a customized field to inherit its theme value again. Older renderer builds
without preset variants can accept the selection without changing the material.

The displayed status distinguishes pending edits from confirmed changes.
Slider events are coalesced every 75 ms with one IPC operation in flight, and
drag-end flushes the latest complete intent. Each write carries the backend
epoch/revision. Render-driven slider/select callbacks are ignored, including
native clamping of invalid pending values. Failed requests roll back the draft
and show an error; external
changes cancel pending edits instead of silently overwriting them.

Each parameter's reset removes its explicit override. **Reset to configuration**
removes the entire panel layer and clears the saved-profile selection. Choosing
a base preset starts with that preset's inherited scalar values. **Save**
saves the current confirmed base, theme mode, enable state, and sparse overrides.
Spaces in names become underscores when saving or renaming, before checking for
an existing name.
Saving an existing name asks whether to overwrite that profile; Cancel keeps it
unchanged. Names remain unique. **Rename** and **Delete** operate on the chosen
saved profile; deleting never deletes a renderer config preset or changes the
current material.
Editing after selecting a saved profile updates the automatically saved current
settings and leaves that named profile unchanged. Save creates or updates a
named snapshot; it is not required to keep ordinary edits across restarts.

Current settings and named profiles are versioned JSON in
`noctalia.pluginDataDir()/profiles.json`, written
to a sibling temporary file then renamed. A corrupt or unsupported file is
preserved and reported, and cannot be overwritten by the panel. Profiles
survive plugin updates and Noctalia restarts. Existing version 1 profiles migrate
automatically without losing their names or selection.

Every accepted edit automatically saves the enable state, base preset, theme
choice, and explicit parameter overrides. Pending or rejected edits are never
saved. With restoration enabled, the last accepted settings are restored after
renderer load or config reload, following an initial state read. A saved
epoch/revision checkpoint lets a Noctalia restart adopt matching active settings
without writing to the renderer again. Initial activation also captures an
already-active material, so installing this version preserves current edits.

**Reset to configuration** clears the automatically saved settings so they do
not return on restart. A terminal edit or reset in the same renderer generation
releases panel ownership. Changing restore settings affects future restoration,
not the currently applied material. Follow Noctalia changes only while the panel
still owns that choice; explicit dark/light stay explicit. Named profiles remain
available even when automatic settings are cleared.

Keep the renderer's loading declaration in Hyprland's Lua config. Material
changes stay in Noctalia's data directory; the panel does not rewrite Lua or
reload Hyprland for slider changes. On a standard installation the file is
`~/.local/state/noctalia/plugins/data/polyv0x/hyprliquid/profiles.json`.

Closing the panel, disabling the plugin, or exiting Noctalia leaves the last
accepted material in the renderer. Reset first to return to your configured
baseline. An abrupt frontend exit cannot break rendering. Recovery checks run
every 15 seconds while closed, or every 2 seconds while open; reopening or
Reconnect requests an immediate check. No background network calls are used.

## Development and verification

```sh
noctalia plugins lint hyprliquid
lua tests/service.lua
python3 scripts/test-noctalia.py /home/polyvox/hyprliquid
```

The deterministic Lua harness uses the production service and panel callbacks
to exercise coalescing, delayed replies, conflicts, IPC failure, profile-file
failure, restore ownership, themes, and field resets. The scripts intentionally
use the Lua-compatible subset of Luau, so the harness needs only `lua`.

The integration script requires a parent Wayland session, Hyprland, Noctalia,
`dbus-daemon`, `grim`, and a built compatible renderer. It starts a
disposable compositor and Noctalia with isolated config, runtime, data, state,
and D-Bus session. A test-only adapter in the temporary plugin copy allows state
inspection and drives the service. It checks real Luau/JSON IPC, the panel,
profile persistence, restart/reload, theme following, and reconnect behavior.
Logs and screenshots stay under ignored `build/`.

Run the renderer's `make -j4 all test` and `python3 scripts/test-nested.py` too.
Review and build backend changes in that repository. Never overwrite a shared
library in place while a compositor has it mapped.

The implementation follows the official Noctalia
[example panel](https://github.com/noctalia-dev/official-plugins/tree/main/example),
[timer service](https://github.com/noctalia-dev/official-plugins/blob/main/timer/service.luau),
and [v5 runtime documentation](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/).
It uses `.luau` entries and `plugin.toml`; the legacy QML plugin system does not apply.
