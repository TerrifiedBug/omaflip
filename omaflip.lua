-- Windows-style ALT+TAB for Hyprland: cycle every window on every workspace,
-- most recently used first. Hold ALT, tap TAB to move down the list, release
-- ALT to jump to the highlighted window. ALT+SHIFT+TAB moves back up,
-- ALT+ESCAPE cancels.
--
-- Nothing to add to the Hyprland config: OmaFlip.qml evaluates this file with
-- `hyprctl eval` when the shell loads it and again after every config reload,
-- which drops runtime binds. So evaluating it twice has to be harmless.
--
-- This half owns all the state and all the keys. The panel draws whatever the
-- last `omaflip:` custom event told it to.
--
-- Two details that make it behave like Windows rather than like `cyclenext`:
--   * The list is snapshotted when the switch starts and then frozen, so the
--     order cannot shuffle underneath you while you are tabbing through it.
--   * Selection is virtual. Focus moves once, on commit. Focusing on every tap
--     would drag you across workspaces on the way past.

local omaflip = { windows = {}, index = 1, active = false, snap = 0 }
local SUBMAP = "omaflip"

-- Minimal JSON string escaping. Window titles are arbitrary text and routinely
-- contain quotes and backslashes; control characters are escaped too, which
-- keeps the event on one line.
local function json_string(value)
  local escaped = tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("[%c]", function(control) return string.format("\\u%04x", control:byte()) end)
  return '"' .. escaped .. '"'
end

-- Hyprland custom events reach the shell over the event socket it already
-- reads. Driving the panel over `omarchy-shell` IPC instead cost a process
-- spawn and ~110 ms per TAB, and two quick taps could land out of order.
local function send(json)
  hl.dispatch(hl.dsp.event("omaflip:" .. json))
end

-- The rows travel once per switch; a TAB only sends the cursor.
local function show()
  local rows = {}
  for _, window in ipairs(omaflip.windows) do
    rows[#rows + 1] = string.format(
      '{"title":%s,"appClass":%s,"workspace":%s}',
      json_string(window.title),
      json_string(window.class),
      json_string(window.workspace and window.workspace.name or "")
    )
  end
  send(string.format('{"snap":%d,"index":%d,"windows":[%s]}',
    omaflip.snap, omaflip.index - 1, table.concat(rows, ",")))
end

local function select()
  send(string.format('{"snap":%d,"index":%d}', omaflip.snap, omaflip.index - 1))
end

local function teardown()
  if not omaflip.active then return end
  omaflip.active = false
  omaflip.windows = {}
  hl.dispatch(hl.dsp.submap("reset"))
  send('{"hide":true}')
end

local function commit()
  if not omaflip.active then
    return -- nothing in flight; the Alt release fires on every switch-less tap
  end

  -- Read the address before tearing down. Teardown drops the snapshot, and the
  -- window handles do not survive it: reading `.address` afterwards throws
  -- inside the key callback, which silently loses the switch.
  local target = omaflip.windows[omaflip.index]
  local address = target and target.address

  teardown()

  -- Focusing from inside the key callback updates Hyprland's idea of the
  -- active window but does not settle until the next input event, so the
  -- switch looks like it did nothing until you tap a key again. A 1 ms timer
  -- (the shortest Hyprland allows) runs the same dispatcher from the event
  -- loop instead.
  if address then
    hl.timer(function()
      hl.dispatch(hl.dsp.focus({ window = "address:" .. address }))
    end, { timeout = 1, type = "oneshot" })
  end
end

local function snapshot()
  local windows = {}
  for _, window in ipairs(hl.get_windows()) do
    local workspace = window.workspace
    if window.mapped and workspace and not workspace.special then
      windows[#windows + 1] = window
    end
  end

  table.sort(windows, function(a, b) return a.focus_history_id < b.focus_history_id end)
  return windows
end

local function step(delta)
  -- Already switching: just move the cursor, wrapping at both ends.
  if omaflip.active then
    omaflip.index = (omaflip.index - 1 + delta) % #omaflip.windows + 1
    select()
    return
  end

  omaflip.windows = snapshot()
  if #omaflip.windows < 2 then
    return
  end

  -- Entry 1 is the window you are already on, so one tap has to land on entry 2
  -- and one back-tap has to wrap to the oldest.
  omaflip.index = delta % #omaflip.windows + 1
  omaflip.active = true
  omaflip.snap = omaflip.snap + 1
  hl.dispatch(hl.dsp.submap(SUBMAP))
  show()
end

-- Self-heal hook for the panel. If the ALT release is ever missed, the panel
-- gives up on its own after a few seconds and calls this, so the two halves
-- cannot disagree about whether a switch is still in progress.
_G.__omaflip_cancel = teardown

-- Omarchy binds ALT+TAB four times by default (cyclenext and bring_to_top, in
-- both directions), so both chords are cleared before rebinding. Unbinding a
-- chord clears it from every submap too, which drops this file's own binds
-- from an earlier evaluation.
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.bind("ALT + TAB", function() step(1) end, { description = "Switch window" })
hl.bind("ALT + SHIFT + TAB", function() step(-1) end, { description = "Switch window (reverse)" })

-- While a switch is up the keyboard belongs to it: the catchall drops every
-- key this map does not bind, so ALT+ESCAPE and friends never reach the window
-- underneath. Done in the compositor rather than by giving the panel keyboard
-- focus, because Hyprland will not move window focus away from an exclusive
-- layer and the app underneath would get a leave/enter on every switch.
hl.define_submap(SUBMAP, function()
  hl.unbind("ALT + ESCAPE")
  hl.unbind("catchall")
  hl.bind("ALT + TAB", function() step(1) end)
  hl.bind("ALT + SHIFT + TAB", function() step(-1) end)
  hl.bind("ALT + ESCAPE", teardown)
  hl.bind("catchall", hl.dsp.no_op())
end)

-- The list should be on screen the moment it is asked for, not fade in over
-- the compositor's layer animation. Created once per Lua state.
if not _G.__omaflip_rule then
  _G.__omaflip_rule = hl.layer_rule({ match = { namespace = "omaflip" }, no_anim = true })
end

-- Committing on ALT release cannot be a keybind. A release bind on a modifier
-- only fires when that modifier is tapped on its own; pressing TAB in between
-- cancels it, which is exactly what every switch does. So the raw key stream is
-- read instead, where the release always shows up.
--
-- 64 is Alt_L and 108 is Alt_R. This runs for every keystroke on the system, so
-- it stays down to two integer compares and a boolean unless a switch is up.
-- The previous evaluation's subscription is removed first, or every reload
-- would stack another listener.
local ALT_KEYCODES = { [64] = true, [108] = true }

if _G.__omaflip_keys then _G.__omaflip_keys:remove() end
_G.__omaflip_keys = hl.on("input.keyboard.key", function(keycode, _, state)
  if state == 0 and omaflip.active and ALT_KEYCODES[keycode] then
    commit()
  end
end)
