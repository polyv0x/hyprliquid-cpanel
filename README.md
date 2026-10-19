# Hyprliquid for Noctalia

A Noctalia v5 companion for the native
[Hyprliquid renderer](https://github.com/polyv0x/hyprliquid): choose a preset,
adjust the material live, follow the shell theme, and save custom profiles.

Plugin ID: `polyv0x/hyprliquid`.

<img width="200" src="https://github.com/user-attachments/assets/030d230b-e7f1-4cd8-a71e-2ec3e149c259"/>

## Installation

Requires Noctalia with plugin API **24** or newer (tested with **v5.2.0**),
`hyprctl`, and the [Hyprliquid plugin](https://github.com/polyv0x/hyprliquid)
installed and loaded in Hyprland. Hyprliquid must match the running Hyprland
build. Start Noctalia, then:

```sh
git clone https://github.com/polyv0x/hyprliquid-cpanel.git
cd hyprliquid-cpanel
noctalia msg plugins source add hyprliquid path "$PWD"
noctalia msg plugins enable polyv0x/hyprliquid
noctalia msg panel-toggle polyv0x/hyprliquid:panel
```

Keep the cloned directory in place while it is registered as a plugin source.
Add `polyv0x/hyprliquid:widget` through the bar's Add-widget picker, or add
`polyv0x/hyprliquid:shortcut` in Control Center shortcut settings. Both open the
same panel.

Alternatively, copy the `hyprliquid/` directory to
`${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins/hyprliquid/` and enable it.

## Adjusting the glass

Choose a **Base preset**, select a **Theme**, and expand a control group to
adjust the material. Changes apply live and save automatically. The **Glass
effect** switch turns the effect on or off.

The five built-in presets offer different levels of blur and refraction:

| Preset | Appearance |
| --- | --- |
| `frosted` | Soft, even blur |
| `soft-glass` | Gentle refraction, soft blur, and rim highlights |
| `clear-glass` | Sharp backdrop with strong refraction and color fringes |
| `frosted-glass` | Strong refraction with blur across the whole pane |
| `clear-edge` | Frosted center with a clear, refractive border |

Configured custom presets also appear in the picker. Selecting a base preset
resets the sliders to that preset's values. Each slider's reset button restores
its preset value individually.

**Theme** selects dark or light face shading and rim highlights. **Follow
Noctalia** matches the shell's dark/light mode. Customized slider values take
precedence; reset a slider to let it follow the preset and theme again.

**Refraction → Neighbor contribution** adjusts how strongly neighbouring
windows appear in the glass, including floating panes that touch or overlap.
`1` preserves the full neighbour scene; `0` removes the additional neighbour
image while preserving windows underneath the glass. Lower values soften
neighbour content without fading the main frosted area. The default is `1`.

**Reflection falloff** softens reflected and wallpaper detail into the frost
while preserving brightness. `0` keeps the preset's usual blur transition;
higher values soften detail faster, up to the default of `1`. **Blur sigma**
sets the final softness. With zero blur, falloff has no effect. These neighbour
controls affect windows; layer surfaces keep their configured appearance.

All 33 material controls are grouped in the panel. Window radius, borders,
rounding, per-application rules, and layer surfaces remain configured in
Hyprland. Windows with an explicit preset rule keep that preset.

## Saved settings and profiles

**Restore last settings** is enabled by default in the plugin settings. It
restores the last applied material after a restart or Hyprland configuration
reload. Turning it off leaves the current appearance unchanged.

Use **Save** to keep a named profile of the current preset, theme, enable state,
and slider values. Spaces in names become underscores. Saving an existing name
asks for confirmation before replacing it. **Rename** and **Delete** operate on
the selected saved profile; deleting a profile leaves the current appearance
unchanged.

Editing after selecting a profile saves the current settings automatically.
The named profile keeps its saved values until it is explicitly overwritten.

**Reset to configuration** returns to the Hyprland configuration and clears
the automatically saved settings. Named profiles remain available. Closing the
panel, disabling the Noctalia plugin, or exiting Noctalia leaves the current
material active; reset first to return to the configured appearance.

Profiles survive plugin updates and Noctalia restarts. On a standard
installation, they are stored in
`~/.local/state/noctalia/plugins/data/polyv0x/hyprliquid/profiles.json`.

## Troubleshooting

If Hyprliquid is unavailable, check that the Hyprliquid plugin is installed,
up to date, and loaded in Hyprland, then choose **Reconnect**. Rebuild Hyprliquid
after updating Hyprland.

If settings change outside the panel, the panel shows those changes and cancels
pending edits. Adjust a control to start editing from the new settings.

If profiles cannot be saved, the panel shows an error and preserves the existing
file. Check the file's permissions and available disk space. A damaged or
unsupported profile file is also preserved so it can be backed up or recovered.

## License

Copyright (c) 2026, polyv0x.

This project is licensed under the GNU General Public License, version 3 or
(at your option) any later version (`GPL-3.0-or-later`). See [LICENSE](LICENSE)
for the full terms.
