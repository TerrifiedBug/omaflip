# OmaFlip

Windows-style `ALT`+`TAB` for [Omarchy](https://omarchy.org/). It cycles every
window on every workspace, most recently used first.

Hold `ALT`, tap `TAB` to move down the list, and let go of `ALT` to jump to the
highlighted window.

Forked from Pablo Merino's
[omarchy-altswitch](https://github.com/Pablo-Merino/omarchy-altswitch).

## Keys

| Keys | Action |
| --- | --- |
| `ALT`+`TAB` | Open the switcher on the previous window |
| `TAB` again, `ALT` still held | Move one further down the list |
| `ALT`+`SHIFT`+`TAB` | Move back up the list |
| Release `ALT` | Switch to the highlighted window |
| `ALT`+`ESCAPE` | Cancel without switching |

The list is snapshotted when the switch starts, so it can't reshuffle while
you tab through it. Focus moves once, when you let go, so tabbing past a window
on another workspace doesn't drag you there.

While the list is up, every other key is dropped. `ALT`+`ESCAPE` cancels the
switch and never reaches the terminal underneath.

Special and scratchpad workspaces are left out. Every monitor is included.

## Requirements

- Omarchy 4 (Quattro shell plugins)
- Hyprland 0.56 or newer with the Lua config

Nothing else to install.

## Install

```bash
omarchy plugin add https://github.com/TerrifiedBug/omaflip.git --enable
```

That's it. The plugin binds `ALT`+`TAB` itself every time the shell starts and
after every `hyprctl reload`. You don't edit `bindings.lua`.

If you used omarchy-altswitch before, remove its `dofile` line from
`~/.config/hypr/bindings.lua` and uninstall it, or the two will fight over the
same keys after each reload.

## Settings

App icons show by default. Turn them off with:

```bash
omarchy-shell omaflip set showIcons false
```

The change applies straight away and lands in the plugin's entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.terrifiedbug.omaflip", "showIcons": false }
```

## Remove

```bash
omarchy plugin remove io.github.terrifiedbug.omaflip
hyprctl reload
```

The reload brings back Omarchy's default `ALT`+`TAB` binds. Nothing was written
to your Hyprland config, so there's nothing else to clean up.

## How it works

There are two files.

`omaflip.lua` runs inside Hyprland and owns the keys and the state. It snapshots
`hl.get_windows()` sorted by `focus_history_id`, holds the keyboard in a
Hyprland submap while a switch is up, and spots the `ALT` release in the raw
`input.keyboard.key` stream. A release bind on a modifier only fires when the
modifier is tapped alone, so a bind can't do it.

`OmaFlip.qml` runs inside `omarchy-shell`. It loads the Lua file with
`hyprctl eval` when the shell starts and after each config reload, then draws
whatever the Lua side sends it. Each step travels as a Hyprland custom event
on the event socket the shell already listens to, so a `TAB` press doesn't
start a process.

A few details if you want to change it:

- The submap's catchall is what keeps stray keys away from the focused app. The
  panel itself never takes keyboard focus, because Hyprland won't move window
  focus away from a layer that holds the keyboard.
- Focusing a window from inside the key callback doesn't settle until the next
  input event, so the focus dispatch runs from a 1 ms Hyprland timer instead.
- If the `ALT` release is ever missed, the panel gives up after ten seconds and
  resets the Lua side, which also releases the keyboard.

## Known limitations

- No window thumbnails.
- No type-to-filter or mouse selection.

## Theme compatibility

Theme colors use a namespaced `qs.Commons.Color` import to avoid Qt 6.12's
`Color` name collision. This keeps the existing palette roles and fallbacks
without changing the plugin's Omarchy requirements.

## License

[MIT](LICENSE)
