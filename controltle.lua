--- Controltle: a turtle that smelts wood into charcoal.
--- The smeltery collects wood and other stuff from the turtles (and reclamation chest),
--- then smelts the wood into charcoal.
--- 
--- To begin, it crafts some logs into planks, then uses those as fuel.

local expect = require "cc.expect".expect

local new_parallelism_handler = require "parallelism_handler"
local dir = require "filesystem":programPath()
local minilogger = require "minilogger"
local _log = minilogger.new("Controltle")
local catppuccin = require "catppuccin"
local palette = catppuccin.set_palette("mocha")
local smn = require "single_modem_network"
local thread = require "thread"
local locks = require "locks"
local mega_inventory = require "mega_inventory"
minilogger.set_log_level(... and minilogger.LOG_LEVELS[(...):upper()] or minilogger.LOG_LEVELS.INFO)
term.setBackgroundColor(palette.crust)
term.setTextColor(palette.text)
term.clear()

--#region Setup
local storages = mega_inventory.new()
do
  local modem_found
  for _, side in ipairs(redstone.getSides()) do
    if peripheral.hasType(side, "peripheral_hub") then
      if modem_found then
        error("Too many wired modems connected. Only connect one.")
      end
      smn.set_modem(side)
      modem_found = true
    end
  end
  if not modem_found then
    error("No wired modem connected. Connect one.")
  end

  local log_to_nothing_window = window.create(term.current(), 0, 0, 100, 1, false)
  minilogger.set_log_window(log_to_nothing_window)
end
--#endregion Setup

--#region Constants

--- The communication channel for Treetle.
---@type integer
local TREETLE_CHANNEL = 35000
smn.open(TREETLE_CHANNEL)

local SELF_NETWORK_ID = smn.getNameLocal()
if not SELF_NETWORK_ID then
  error("Turn on the modem, idot.")
end

--- The item IDs of saplings that the turtle will plant.
---@type id_lookup
local SAPLING_IDS = {
  ["minecraft:oak_sapling"] = true,
  ["minecraft:spruce_sapling"] = true,
  ["minecraft:birch_sapling"] = true,
  ["minecraft:jungle_sapling"] = true,
  ["minecraft:acacia_sapling"] = true,
  ["minecraft:dark_oak_sapling"] = true,
  ["minecraft:cherry_sapling"] = true,
  ["sc-goodies:sakura_sapling"] = true,
  ["sc-goodies:maple_sapling"] = true,
  ["sc-goodies:blue_sapling"] = true
}

--- The item IDs of logs that the turtle will cut down.
---@type id_lookup
local LOG_IDS = {
  ["minecraft:oak_log"] = true,
  ["minecraft:spruce_log"] = true,
  ["minecraft:birch_log"] = true,
  ["minecraft:jungle_log"] = true,
  ["minecraft:acacia_log"] = true,
  ["minecraft:dark_oak_log"] = true,
  ["minecraft:mangrove_log"] = true,
  ["minecraft:cherry_log"] = true,
  ["sc-goodies:sakura_log"] = true,
  ["sc-goodies:maple_log"] = true,
  ["sc-goodies:blue_log"] = true
}

--- The item IDs of planks that the turtle may craft.
---@type id_lookup
local PLANK_IDS = {
  ["minecraft:oak_planks"] = true,
  ["minecraft:spruce_planks"] = true,
  ["minecraft:birch_planks"] = true,
  ["minecraft:jungle_planks"] = true,
  ["minecraft:acacia_planks"] = true,
  ["minecraft:dark_oak_planks"] = true,
  ["minecraft:mangrove_planks"] = true,
  ["minecraft:cherry_planks"] = true,
  ["sc-goodies:sakura_planks"] = true,
  ["sc-goodies:maple_planks"] = true,
  ["sc-goodies:blue_planks"] = true
}

--- The item IDs of "good" fuels that will be sent to turtles for refueling.
--- 
--- **Notice:**
---   Coal blocks and buckets of lava are *intentionally left out*.
---   These blocks can smelt more than 64 items, so would need extra handling
---   to move the extra blocks in when they are able to fit in the slot.
---   I plan to eventually support these, but for now the system entirely
---   ignores them.
--- 
---@type id_lookup
local FUEL_IDS = {
  ["minecraft:charcoal"] = true,
  ["minecraft:coal"] = true,
  ["minecraft:dried_kelp_block"] = true,
  ["minecraft:blaze_rod"] = true
}

---@alias fuel_lookup table<string, integer> Maps fuel to their burn time.

--- The item IDs of fuels that will be used in smelting, mapped to their burn time (in ticks).
---@type fuel_lookup
local SMELT_FUEL_IDS = {
  ["minecraft:coal"] = 1600,
  ["minecraft:charcoal"] = 1600,
  ["minecraft:dried_kelp_block"] = 4000,
  ["minecraft:blaze_rod"] = 2400,
}
for name in pairs(PLANK_IDS) do
  SMELT_FUEL_IDS[name] = 300
  FUEL_IDS[name] = true
end

--- The amount of time it takes to smelt a single item, in ticks.
local SMELT_TIME = 200

---@alias fuel_ratio_lookup table<string, {[1]:integer, [2]:integer}>

--- Item IDs of fuels -> {fuel cost, items smelted}
---@type fuel_ratio_lookup
local SMELT_FUEL_RATIOS = {
  ["minecraft:coal"] = {1, 8},
  ["minecraft:charcoal"] = {1, 8},
  ["minecraft:dried_kelp_block"] = {1, 20},
  ["minecraft:blaze_rod"] = {1, 12},
}
for name in pairs(PLANK_IDS) do
  SMELT_FUEL_RATIOS[name] = {2, 3}
end

--- The size of the screen.
local T_W, T_H = term.getSize()

--- The main window drawn to.
local MAIN_WINDOW = window.create(term.current(), 1, 1, T_W, T_H)

--- The config file.
local CONFIG_FILE = dir:file("controltle.cfg")

--#endregion Constants

--#region Configuration

---@class controltle_config
---@field intermediate_chest string? The name of the inventory that is designated as the intermediate chest. This chest is used to pull items from turtles.
---@field reclamation_chest string? The name of the inventory that is designated as the 'reclamation' chest, if one is present.
---@field storages string[] The names of inventories used as general-purpose storage.
---@field furnaces string[] The names of inventories which are furnaces.
local config = {
  intermediate_chest = nil,
  reclamation_chest = nil,
  storages = {},
  furnaces = {}
}



--- Loads the configuration from the config file.
local function load_config()
  config = CONFIG_FILE:unserialize(config) --[[@as controltle_config]]

  storages = mega_inventory.new()
  for _, storage in ipairs(config.storages) do
    local inv = smn.wrap(storage) --[[@as Inventory?]]
    if inv then
      storages:add_inventory(inv)
    else
      _log.warn("Storage", storage, "is not present.")
    end
  end
end



--- Saves the configuration to the config file.
local function save_config()
  CONFIG_FILE:serialize(config, {compact=true})
end


--#endregion Configuration

--#region logs

local ui_log = minilogger.new("ui")
local t_log = minilogger.new("treetle_handler")
local r_log = minilogger.new("reclamation")
local s_log = minilogger.new("smelting")
local c_log = minilogger.new("crafting")

--#endregion logs

--#region locks

--- Lock for the main storages.
local storage_lock = locks.new()

--- Lock for the intermediate chest.
local intermediate_lock = locks.new()

--#endregion locks

--#region Helper Functions


local help_displaying = false


--- Pull multiple events.
---@param ... string The events to pull.
---@return string event The event pulled.
---@return any ... The arguments of the event.
local function pull_events(...)
  local ev = {}

  local function is_event(event, ...)
    for i = 1, select("#", ...) do
      if event[1] == select(i, ...) then
        return true
      end
    end
    return false
  end

  repeat
    ev = table.pack(os.pullEvent())
  until is_event(ev, ...)

  return table.unpack(ev)
end



--- Renders the main background, with nothing on it.
---@param win Window The window to render to.
local function render_background(win)
  local function draw_box(x, y, w, h, color)
    win.setBackgroundColor(color)
    local txt =  (' '):rep(w)

    for _y = 0, h - 1 do
      win.setCursorPos(x, y + _y)
      win.write(txt)
    end
  end

  -- First: 12x6, top left.
  draw_box(1, 1, 12, 6, palette.base)

  -- Second: 25x6, top right.
  draw_box(15, 1, 25, 6, palette.base)

  -- Third: 12x6, bottom left.
  draw_box(1, 8, 12, 6, palette.base)

  -- Fourth: 25x6, bottom right.
  draw_box(15, 8, 25, 6, palette.base)

  -- Storages sub-box: 16, 3, 23x3
  draw_box(16, 3, 23, 3, palette.surface_0)

  -- Scroll arrows (both 'disabled')
  win.setCursorPos(38, 3)
  win.setTextColor(palette.subtext_1)
  win.write("\x18")
  win.setCursorPos(38, 5)
  win.write("\x19")


  -- Turtle sub-box: 16, 10, 23x3
  draw_box(16, 10, 23, 3, palette.surface_0)

  -- Scroll arrows (both 'disabled')
  win.setCursorPos(38, 10)
  win.write("\x18")
  win.setCursorPos(38, 12)
  win.write("\x19")

  -- Furnaces sub-box: 2, 10, 10x3
  draw_box(2, 10, 10, 3, palette.surface_0)

  -- Scroll arrows (both 'disabled')
  win.setCursorPos(11, 10)
  win.write("\x18")
  win.setCursorPos(11, 12)
  win.write("\x19")

  -- Storages Label: 16, 1
  win.setCursorPos(16, 1)
  win.setBackgroundColor(palette.base)
  win.setTextColor(palette.blue)
  win.write("Storages")
  win.setCursorPos(16, 2)
  win.write(("\x83"):rep(8))

  -- Intermediate Chest Label: 16, 8
  win.setCursorPos(16, 8)
  win.write("Intermediate Chest")
  win.setCursorPos(16, 9)
  win.write(("\x83"):rep(18))

  -- Furnaces Label: 2, 8
  win.setCursorPos(2, 8)
  win.write("Furnaces")
  win.setCursorPos(2, 9)
  win.write(("\x83"):rep(8))

  -- Main counts labels
  win.setCursorPos(1, 3)
  win.setTextColor(palette.text)
  win.write("CCoal :    -") -- Charcoal
  win.setCursorPos(1, 4)
  win.write("Logs  :    -")
  win.setCursorPos(1, 5)
  win.write("Planks:    -")
  win.setCursorPos(1, 6)
  win.write("Sapls :    -") -- Saplings

  -- The state, centered within x={1,12}
  -- Initial state is just "INIT" in red.
  win.setCursorPos(5, 1)
  win.setTextColor(palette.red)
  win.write("INIT")

  -- Draw the smaller lines in-between each box.
  win.setBackgroundColor(palette.mantle)
  win.setTextColor(palette.crust)
  win.setCursorPos(1, 7)
  win.write(("\x8c"):rep(T_W))
  for y = 1, T_H do
    win.setCursorPos(14, y)
    win.write("\x95")
  end
  win.setCursorPos(14, 7)
  win.write("\x9d")

  win.setBackgroundColor(palette.crust)
  win.setTextColor(palette.mantle)
  for y = 1, T_H do
    win.setCursorPos(13, y)
    win.write("\x95")
  end
  win.setCursorPos(13, 7)
  win.write("\x91")

  -- Lock messages
  win.setCursorPos(6, 13)
  win.setTextColor(palette.green)
  win.setBackgroundColor(palette.overlay_0)
  win.write(" LOCK ")

  win.setCursorPos(33, 13)
  win.write(" LOCK ")

  win.setCursorPos(33, 6)
  win.write(" LOCK ")
end



--- Tween a value from A to B, using square easing.
---@param a number The starting value.
---@param b number The ending value.
---@param t number The time, from 0 to 1.
---@return number value The value at time t.
local function tween(a, b, t)
  return a + (b - a) * t^2
end



--- Fade in the main UI.
local function fade_in()
  local old_palette = {}
  local crust_r, crust_g, crust_b = term.getPaletteColor(palette.crust)
  for i = 0, 15 do
    old_palette[i] = {term.getPaletteColor(2^i)}
    term.setPaletteColor(2^i, crust_r, crust_g, crust_b)
  end

  render_background(MAIN_WINDOW)
  MAIN_WINDOW.setVisible(true)

  -- Le epic fade-in
  local start_time = os.clock()
  local anim_duration = 1
  while os.clock() - start_time < anim_duration do
    local t = (os.clock() - start_time) / anim_duration
    for i = 0, 15 do
      term.setPaletteColor(2^i, tween(crust_r, old_palette[i][1], t), tween(crust_g, old_palette[i][2], t), tween(crust_b, old_palette[i][3], t))
    end
    sleep()
  end
end



--- Sends `n` items of the given type to the given turtle, from the given inventory.
---@param inv_name string The name of the inventory to send items from.
---@param turtle_name string The name of the turtle to send items to.
---@param item_types id_lookup The type of item to send.
---@param n integer The number of items to send.
---@return integer sent The number of items actually sent.
local function send_items(inv_name, turtle_name, item_types, n)
  expect(1, inv_name, "string")
  expect(2, turtle_name, "string")
  expect(3, item_types, "table")
  expect(4, n, "number")

  local sent = 0

  -- Get info about what is in the inventory.
  local items = smn.call(inv_name, "list")

  -- Send the items to the turtle.
  for slot, item in pairs(items) do
    if item_types[item.name] then
      sent = sent + smn.call(inv_name, "pushItems", turtle_name, slot, n - sent)

      if sent >= n then
        break
      end
    end
  end

  local names = {}
  for name in pairs(item_types) do
    table.insert(names, name)
  end
  t_log.debug("Sent", sent, "of", n, "items (", table.concat(names, ", "), ") to", turtle_name, "from", inv_name)

  return sent
end



--- Sends `n` items of the given types to the given inventory, from storage.
--- 
--- Requires lock.
---@param inv_name string The name of the inventory to send items to.
---@param item_types id_lookup The type of item to send.
---@param n integer The number of items to send.
---@return integer sent The number of items actually sent.
local function send_items_from_storage(inv_name, item_types, n)
  expect(1, inv_name, "string")
  expect(2, item_types, "table")
  expect(3, n, "number")

  storage_lock:await_lock()

  storages:list()
  local sent = storages:batch_push_items(inv_name, item_types, n)

  storage_lock:unlock()

  return sent
end



--- Sends `n` items of the given type to the given inventory, from storage.
--- 
--- Requires lock.
---@param inventory_name string The name of the inventory to send items to.
---@param item_type string The type of item to send.
---@param n integer The number of items to send.
---@param result_slot integer? The slot to put the result in.
---@return integer sent The number of items actually sent.
local function send_item_from_storage(inventory_name, item_type, n, result_slot)
  expect(1, inventory_name, "string")
  expect(2, item_type, "string")
  expect(3, n, "number")
  expect(4, result_slot, "number", "nil")

  storage_lock:await_lock()

  local sent = storages:push_items(inventory_name, item_type, n, result_slot)

  storage_lock:unlock()

  return sent
end



--- Count how many of each item of a given item type there is in the storages.
---@param item_types id_lookup The type of item to count.
---@return table<string, integer> counts The counts of each item type.
local function count_items(item_types)
  expect(1, item_types, "table")

  local counts = {}
  local items = storages:list()
  for _, item in pairs(items) do
    if item_types[item.name] then
      counts[item.name] = (counts[item.name] or 0) + item.count
    end
  end

  return counts
end



--- Count 'important' items in the storage chests.
--- 
--- Does not require lock, as it does not alter the state.
---@return integer logs The number of logs in the storage chests.
---@return integer planks The number of planks in the storage chests.
---@return integer saplings The number of saplings in the storage chests.
---@return integer fuels The number of 'good' fuels in the storage chests.
local function count_important()
  local logs, planks, saplings, fuels = 0, 0, 0, 0
  local items = storages:list()
  for _, item in pairs(items) do
    if LOG_IDS[item.name] then
      logs = logs + item.count
    end
    if PLANK_IDS[item.name] then
      planks = planks + item.count
    end
    if SAPLING_IDS[item.name] then
      saplings = saplings + item.count
    end
    if FUEL_IDS[item.name] then
      fuels = fuels + item.count
    end
  end

  return logs, planks, saplings, fuels
end



--- Sends all items in the given inventory to storage.
--- 
--- Requires lock.
---@param inv_name string The name of the inventory to send items from.
---@return integer sent The number of items sent.
local function send_all_to_storage(inv_name)
  expect(1, inv_name, "string")

  storage_lock:await_lock()

  local sent = storages:pull_all_items(inv_name)

  storage_lock:unlock()
  return sent
end



--- Takes items from the given turtle
--- Leaves the following in the inventories:
--- 1. Fuel, x16
--- 2. Saplings, x16
--- 
--- Requires lock on intermediate chest, then storages.
---@param turtle_name string The name of the turtle to take items from.
local function take_back_items(turtle_name)
  expect(1, turtle_name, "string")

  t_log.debug("Handling", turtle_name)

  if not config.intermediate_chest or not smn.isPresent(config.intermediate_chest) then
    return 0
  end

  intermediate_lock:await_lock()

  -- Take everything from the turtle, moving it into the intermediate chest.
  for slot = 1, 16 do
    smn.call(config.intermediate_chest, "pullItems", turtle_name, slot)
  end

  -- Send 16 fuel and 16 saplings back to the turtle (if they exist).
  -- a. Fuel
  local sent_fuel = send_items(config.intermediate_chest, turtle_name, FUEL_IDS, 16)
  -- b. Saplings
  local sent_saplings = send_items(config.intermediate_chest, turtle_name, SAPLING_IDS, 16)

  t_log.debug("Sent", sent_fuel, "fuel and", sent_saplings, "saplings back to", turtle_name)

  -- And send everything else to the storages.
  send_all_to_storage(config.intermediate_chest)

  -- We're done with the intermediate chest, but we still need the storages.
  intermediate_lock:unlock()

  -- If we sent less than 16 fuel or saplings, check if there are more in the storages, and send them.
  -- However:
  -- 1. Only send fuel if there it leaves us with at least 4 fuel in the storages.
  -- 2. If less than 32 saplings and we didn't send anything back, send a single sapling.
  -- 3. Otherwise, send 16 of each.
  local _, _, saplings, fuels = count_important()
  t_log.debug("Storage Fuel:", fuels, "\nStorage Saplings:", saplings)

  if fuels - (16 - sent_fuel) >= 4 then
    t_log.debug("Sending", 16 - sent_fuel, "fuel from storage to", turtle_name)
    send_items_from_storage(turtle_name, FUEL_IDS, 16 - sent_fuel)
  end

  if saplings < 32 and sent_saplings == 0 then
    t_log.debug("Sending 1 sapling from storage to", turtle_name)
    send_items_from_storage(turtle_name, SAPLING_IDS, 1)
  else
    t_log.debug("Sending", 16 - sent_saplings, "saplings from storage to", turtle_name)
    send_items_from_storage(turtle_name, SAPLING_IDS, 16 - sent_saplings)
  end

  t_log.debug("Done handling", turtle_name)
end



--- Takes items from the current turtle
--- Leaves nothing in the inventory.
--- 
--- Requires lock on intermediate chest, then storages.
local function take_back_items_self()
  if not config.intermediate_chest or not smn.isPresent(config.intermediate_chest) then
    return 0
  end

  intermediate_lock:await_lock()

  -- Take everything from the turtle, moving it into the intermediate chest.
  for slot = 1, 16 do
    smn.call(config.intermediate_chest, "pullItems", SELF_NETWORK_ID, slot)
  end

  -- Send everything to the storages.
  send_all_to_storage(config.intermediate_chest)

  intermediate_lock:unlock()
end



--- Notifies a turtle that its okay to go.
---@param turtle_id integer The name of the turtle to notify.
local function notify_turtle(turtle_id)
  expect(1, turtle_id, "number")

  smn.transmit(TREETLE_CHANNEL, TREETLE_CHANNEL, {
    action = "treetle_go",
    turtle_id = turtle_id
  })

  t_log.debug("Notified turtle", turtle_id, "that it can continue.")
end



--- Reclaims items from the reclamation chest.
local function reclaim()
  if not config.reclamation_chest or not smn.isPresent(config.reclamation_chest) then
    r_log.debug("No reclamation chest present.")
    return
  end

  r_log.debug("Reclaiming items from reclamation chest.")
  local sent = send_all_to_storage(config.reclamation_chest)
  r_log.debugf("Reclaimed %d item%s from reclamation chest.", sent, sent == 1 and "" or "s")
end



---@class CraftingTask
---@field inputs table<integer, ItemIdentifier> The inputs to the crafting task, keys are slot numbers (1-9), values are item names.
---@field id integer The ID of the crafting task.
---@field craft_count integer? The number of times to complete the crafting task. Defaults to 1.

--- Identifies an item (or set of items) in the storage system.
--- Only one of the optional fields should be present.
---@class ItemIdentifier
---@field name string? The name of the item.
---@field names id_lookup? The names of the item.
---@field tag string? The tag of the item.
---@field tags id_lookup? The tags of the item.
---@field count integer The number of items required.


---@type CraftingTask[]
local crafting_queue = {}
local last_crafting_id = 0

--- Create a new crafting task, and add it to the crafting queue.
--- Items crafted will be sent to the storage.
---@param inputs table<integer, ItemIdentifier> The inputs to the crafting task, keys are slot numbers (1-9), values are item names.
---@return integer ID The ID of the crafting task.
---@overload fun(inputs: table<integer, string>, await: boolean): nil Awaits the crafting task, doesn't return the ID.
local function create_crafting_task(inputs, await)
  expect(1, inputs, "table")
  expect(2, await, "boolean", "nil")

  last_crafting_id = last_crafting_id + 1
  local task = {
    inputs = inputs,
    id = last_crafting_id,
    craft_count = 1
  }

  table.insert(crafting_queue, task)
  os.queueEvent("crafting_task_created")
  c_log.debug("Created crafting task", task.id)

  if await then
    repeat
      local _, task_id = os.pullEvent("crafting_task_complete") --[[@as integer]]
    until task_id == task_id
  end
end



--- Crafts the given item request, and sends the result to the storage.
---@param task CraftingTask The task to craft.
local function run_crafting_task(task)
  expect(1, task, "table")

  --- Abort: Send everything in the turtle to storage.
  local function end_task()
    os.queueEvent("crafting_task_complete", task.id)
  end

  for _ = 1, task.craft_count or 1 do
    for slot, item_identifier in pairs(task.inputs) do
      local items = storages:list()
      local found = false
      local pushed = 0

      for _, item in pairs(items) do
        if item_identifier.name and item.name == item_identifier.name then
          found = true
          pushed = storages:push_items(SELF_NETWORK_ID, item.name, item_identifier.count, slot)
          break
        elseif item_identifier.tag and item.tags[item_identifier.tag] then
          found = true
          pushed = storages:push_items(SELF_NETWORK_ID, item.name, item_identifier.count, slot)
          break
        elseif item_identifier.names and item_identifier.names[item.name] then
          found = true
          pushed = storages:push_items(SELF_NETWORK_ID, item.name, item_identifier.count, slot)
          break
        elseif item_identifier.tags then
          for tag in pairs(item_identifier.tags) do
            if item.tags[tag] then
              found = true
              pushed = storages:push_items(SELF_NETWORK_ID, item.name, item_identifier.count, slot)
              break
            end
          end
        end
      end

      if not found or pushed < item_identifier.count then
        take_back_items_self()
        end_task()
        c_log.warn("Aborting crafting task", task.id, "due to missing items.")
        return
      end
    end

    -- Craft the items.
    turtle.craft()
    take_back_items_self()
  end

  end_task()
  c_log.debug("Crafting task", task.id, "completed.")
end




--#endregion Helper Functions

--#region Main Functions



--- Displays the help screens for setup.
local function display_help()
  local pages_needed = 10 -- Tweaked as I need more help pages.
  local long_window = window.create(term.current(), T_W + 1, 1, T_W * (pages_needed + 1), T_H)
  local pages = {}
  for i = 0, pages_needed - 1 do
    pages[i + 1] = window.create(long_window, T_W * i + 1, 1, T_W, T_H)
    pages[i + 1].setBackgroundColor(palette.crust)
    pages[i + 1].setTextColor(palette.text)
    pages[i + 1].clear()
  end
  long_window.setTextColor(palette.text)
  long_window.setBackgroundColor(palette.crust)
  long_window.clear()

  --- Max width of the centered text.
  local max_width = 36

  --- Split a message by newlines.
  ---@param message string The message to split.
  ---@return string[] lines The lines of the message.
  local function split_lines(message)
    local lines = {}
    for line in message:gmatch("[^\n]+") do
      table.insert(lines, line)
    end
    return lines
  end

  --- Split a message by words, based on the maximum width.
  ---@param message string The message to split.
  ---@return string[] lines The lines of the message.
  local function split_words(message)
    local lines = {}
    local curr_line = ""
    for word in message:gmatch("%S+") do
      if #curr_line + #word + 1 > max_width then
        table.insert(lines, curr_line)
        if #word > max_width then
          repeat
            curr_line = word:sub(1, max_width)
            table.insert(lines, curr_line)
            word = word:sub(max_width + 1)
          until #word <= max_width
        end
        curr_line = word
      else
        curr_line = curr_line .. " " .. word
      end
    end
    table.insert(lines, curr_line)
    return lines
  end

  --- Write a message to the center of the window.
  ---@param page Window The window to write to.
  ---@param message string The message to write.
  ---@param color color? The color to write the message in.
  ---@param offy number? The y offset to write the message at.
  local function write_centered(page, message, color, offy)
    -- Split the message on newlines and words.
    local lines = split_lines(message)
    local finished = {}
    for _, line in ipairs(lines) do
      for _, finished_line in ipairs(split_words(line)) do
        table.insert(finished, finished_line)
      end
    end

    -- Write the lines to the page.
    local y_start = math.ceil(T_H / 2 - #finished / 2 + 0.5) + (offy or 0)
    for i, line in ipairs(finished) do
      local x_start = math.ceil(T_W / 2 - #line / 2 + 0.5)
      page.setCursorPos(x_start, y_start + i - 1)
      local old = page.getTextColor()
      if color then
        page.setTextColor(color)
      end
      page.write(line)

      if color then
        page.setTextColor(old)
      end
    end
  end

  -- Write the help pages.
  write_centered(pages[1], "Welcome to Controltle!", nil, -4)
  write_centered(pages[1], "This program is made to work with Treetle, to slowly automate fuel creation!", palette.subtext_0)
  write_centered(pages[1], "This program requires an advanced turtle.", palette.yellow, 4)

  write_centered(pages[2], "In order to run Controltle, you will need to set up a few things. If you see 'SETUP' at the top left, you likely are missing something.", nil, 1)

  write_centered(pages[3], "1. One 'intermediary' inventory to pull items from Treetles.", palette.blue, -1)
  write_centered(pages[3], "This inventory is used due to a restriction in the way turtles are registered on the network.", nil, 2)

  write_centered(pages[4], "2. At least one inventory to store items in.", palette.blue, -1)
  write_centered(pages[4], "These inventories are used for storing anything coming into the system, including fuel, saplings, and anything else.", nil, 3)

  write_centered(pages[5], "3. At least one furnace to smelt logs in.", palette.blue, -1)
  write_centered(pages[5], "The usage of these should hopefully be obvious by the title.", nil, 2)

  write_centered(pages[6], "4. An inventory to pull items from for reclamation.", palette.blue, -1)
  write_centered(pages[6], "This is optional. Pipe all the extra tree drops to this chest.", nil, 2)

  write_centered(pages[7], "When selecting the storages:", nil, -4)
  write_centered(pages[7], "Click once to designate as storage.", palette.blue, -2)
  write_centered(pages[7], "Click a second time to designate as reclamation chest.", palette.green, 1)
  write_centered(pages[7], "Click a third time to remove the designation.", palette.red, 4)

  write_centered(pages[8], "For both other selections:", nil, -3)
  write_centered(pages[8], "Click once to designate as the given type.", palette.blue, 0)
  write_centered(pages[8], "Click a second time to remove the designation.", palette.red, 3)

  write_centered(pages[9], "Once you have set up all the inventories, click the 'LOCK' buttons to lock in the selections.", nil, -1)
  write_centered(pages[9], "This prevents accidental changes to the setup.", palette.yellow, 3)

  write_centered(pages[10], "If you need help or are having issues, please contact me on GitHub:", nil, -1)
  write_centered(pages[10], "Fatboychummy-CC/Treetle-Suite", palette.blue, 2)
  write_centered(pages[10], ("\x83"):rep(29), palette.blue, 3)

  local anim_duration = 0.65
  local current_page = 0

  --- Animates a new page in, by tweening the page to the left T_W characters.
  local function animate_page_in()
    local c_x = long_window.getPosition()
    local start_time = os.clock()
    while os.clock() - start_time < anim_duration do
      local t = (os.clock() - start_time) / anim_duration
      long_window.setVisible(false)
      long_window.reposition(tween(c_x, c_x - T_W, t), 1)
      long_window.setVisible(true)
      sleep()
    end

    current_page = current_page + 1
    -- Ensure the page is properly in position.
    long_window.reposition(T_W - T_W * current_page + 1, 1)
  end

  --- Animates a page backwards.
  local function animate_page_out()
    if current_page == 1 then
      return
    end

    local c_x = long_window.getPosition()
    local start_time = os.clock()
    while os.clock() - start_time < anim_duration do
      local t = (os.clock() - start_time) / anim_duration
      long_window.setVisible(false)
      long_window.reposition(tween(c_x, c_x + T_W, t), 1)
      long_window.setVisible(true)
      sleep()
    end

    current_page = current_page - 1
    -- Ensure the page is properly in position.
    long_window.reposition(T_W - T_W * current_page + 1, 1)
  end

  MAIN_WINDOW.setBackgroundColor(palette.crust)
  MAIN_WINDOW.clear()
  MAIN_WINDOW.setVisible(false)

  animate_page_in() -- Bring in the first page.
  while current_page <= pages_needed do
    local ev, param = pull_events("mouse_click", "key")
    if ev == "mouse_click" then
      if param == 1 then
        animate_page_in()
      elseif param == 2 then
        animate_page_out()
      end
    elseif ev == "key" then
      if param == keys.enter or param == keys.space or param == keys.right or param == keys.d then
        animate_page_in()
      elseif param == keys.left or param == keys.a then
        animate_page_out()
      end
    end
  end

  animate_page_in()
end



--- Run the treetle handler.
_log.debug("Treetle Handler thread is", thread.new(function()
  t_log.info("Starting Controltle.")
  load_config()
  t_log.debug("Entering main loop.")
  while true do
    local _, _, _, _, message = os.pullEvent("modem_message")
    t_log.debug("Received message: ", textutils.serialize(message, {compact=true}))

    if type(message) == "table" and message.action == "treetle_discovery" then
      t_log.debugf("Received treetle discovery from %s, with ID %d.", message.turtle_name, message.turtle_id)
      thread.new(take_back_items, message.turtle_name)
        :after(notify_turtle, message.turtle_id)
        :on_error(t_log.error, "\n\nThe above error occurred when dealing with treetle", message.turtle_id, "as", message.turtle_name)
    end
  end
end).id)



--- UI Thread
_log.debug("UI thread is", thread.new(function()
  term.setBackgroundColor(palette.crust)
  term.setTextColor(palette.text)
  term.clear()
  sleep(0.25)
  if not next(config.furnaces) or not next(config.storages) or not config.intermediate_chest then
    t_log.info("Displaying help.")
    display_help()
  end

  t_log.debug("Fade in.")
  fade_in()

  -- ...
end).id)



--- Reclamation Thread
--- Schedules a reclamation every 2 minutes.
_log.debug("Reclamation thread is", thread.new(function()
  while true do
    reclaim()
    sleep(120)
  end
end).id)


---@type table<string, true> The furnaces that are currently smelting.
local furnaces_used = {}

--- Smelting Thread
--- Schedules individual threads for each furnace when they should be finished their smelt task.
_log.debug("Smelting thread is", thread.new(function()
  --- Determine the best fuel to use for a given number of items to smelt.
  --- Returns the best fuel, as well as the batch plan to use for it.
  ---@param fuels table<string, integer> fuel_name -> fuel_count The fuels available.
  ---@param count integer The number of items to smelt.
  ---@return string? id The ID of the best fuel to use, nil if no fuel is available.
  ---@return integer fuel_count_per_batch The fuel count per batch.
  ---@return integer item_count_per_batch The item count per batch.
  ---@return integer batches The number of batches to smelt.
  local function get_best_fuel(fuels, count)
    local best_fuel = nil
    local best_ratio = {0, 0}
    local best_item_count = 0

    for fuel_name, fuel_count in pairs(fuels) do
      local item_count = 0
      -- [1]: fuel used
      -- [2]: items smelted given the fuel
      local ratio = SMELT_FUEL_RATIOS[fuel_name]
      if ratio then
        item_count = math.floor(fuel_count / ratio[1]) * ratio[2]
      end
      if item_count > best_item_count then
        best_fuel = fuel_name
        best_item_count = item_count
        best_ratio = ratio
      end
    end

    if best_item_count == 0 then
      -- No fuel.
      return nil, 0, 0, 0
    end

    local fuel_count_per_batch = best_ratio[1]
    local item_count_per_batch = best_ratio[2]
    local batches = math.floor(count / item_count_per_batch)

    if batches == 0 then
      -- Never waste fuel.
      return nil, 0, 0, 0
    end

    return best_fuel, fuel_count_per_batch, item_count_per_batch, batches
  end



  --- Get a list of furnaces which are "open" (not currently smelting).
  --- This is determined by checking if the furnace is NOT in the list of furnace times.
  ---@return string[] The names of the open furnaces.
  local function get_open_furnaces()
    local open_furnaces = {}

    for _, furnace in ipairs(config.furnaces) do
      if not furnaces_used[furnace] then
        table.insert(open_furnaces, furnace)
      end
    end

    return open_furnaces
  end



  --- Determine the distribution of batches across the furnaces.
  ---@param n_batches integer The number of batches to distribute.
  ---@param n_furnaces integer The number of furnaces to distribute to.
  ---@return integer[] distribution The distribution of batches across the furnaces.
  local function batch_distribution(n_batches, n_furnaces)
    local distribution = {}
    local base = math.floor(n_batches / n_furnaces)
    local extra = n_batches % n_furnaces

    for i = 1, n_furnaces do
      if i <= extra then
        distribution[i] = base + 1
      else
        distribution[i] = base
      end
    end

    return distribution
  end



  while true do
    -- First, check if any furnaces are free.
    local free_furnaces = get_open_furnaces()

    -- Then, check if we have any logs to smelt (and fuels to use).
    local total_logs, _, _, total_fuels = count_important()

    if free_furnaces[1] and total_logs > 0 and total_fuels > 0 then
      s_log.debug("Smelting logs.")
      local fuels = count_items(FUEL_IDS)
      local logs = count_items(LOG_IDS)

      local sent = false
      for log_name, count in pairs(logs) do
        -- Get the best fuel to use for this log.
        local best_fuel, fuel_count_per_batch, item_count_per_batch, batches = get_best_fuel(fuels, count)

        if best_fuel then
          local distribution = batch_distribution(batches, #free_furnaces)
          s_log.debug("Distributing", batches, "batches of", log_name, "to", #free_furnaces, "furnaces.")
          s_log.debug("Best fuel is", best_fuel, "with a ratio of", fuel_count_per_batch, "to", item_count_per_batch)
          s_log.debug("Distribution is", table.concat(distribution, ", "))

          for i, furnace in ipairs(free_furnaces) do
            local batch_count = distribution[i]
            local fuel_count = batch_count * fuel_count_per_batch
            local item_count = batch_count * item_count_per_batch

            if item_count > 64 then
              -- We can't send more than 64 items at a time.
              -- Repeatedly increase the item and fuel count until we reach 64.
              item_count = item_count_per_batch
              fuel_count = fuel_count_per_batch
              while item_count < 64 do
                item_count = item_count + item_count_per_batch
                fuel_count = fuel_count + fuel_count_per_batch
              end

              if item_count > 64 then
                -- Oops, we went over.  
                item_count = item_count - item_count_per_batch
                fuel_count = fuel_count - fuel_count_per_batch
              end
            end

            -- Send the logs to the furnace.
            send_item_from_storage(furnace, log_name, item_count, 1)

            -- Send the fuel to the furnace.
            send_item_from_storage(furnace, best_fuel, fuel_count, 2)

            thread.new(function()
              furnaces_used[furnace] = true
              s_log.debug("Furnace", furnace, "will be busy for", item_count * 200 / 20, "seconds.")

              -- Wait for the furnace to finish smelting.
              sleep(item_count * 200 / 20 + 0.05) -- 200 ticks per item, 20 ticks per second.

              -- Send the items back to storage.
              send_all_to_storage(furnace)
              -- Remove the furnace from the list of furnace times.
              furnaces_used[furnace] = nil
              s_log.debug("Furnace", furnace, "is now free.")
            end):on_error(s_log.error, "\n\nThe above error occurred when smelting logs in", furnace)

            sent = true
          end
        end

        -- We want to recount everything, so we just break out and immediately loop again.
        if sent then break end
      end

      if not sent then
        s_log.debug("No logs could be smelted.")
        sleep(0.95) -- To avoid "busy waiting" while still being relatively responsive.
      end
    elseif free_furnaces[1] and total_logs > 0 and total_fuels == 0 then
      s_log.debug("No fuel to smelt with, crafting some...")
      -- We need to pull some logs to the turtle, convert them into planks,
      -- then use those as fuel for now.

      -- Make the crafting task.

      create_crafting_task({
        [1] = {names = LOG_IDS, count = 3}
      }, true)

    elseif free_furnaces[1] and total_logs == 0 and total_fuels > 0 then
      s_log.debug("No logs to smelt. Waiting for logs.")
    else
      -- No free furnaces.
      s_log.debug("No free furnaces.")
    end

    sleep(30) -- 30 seconds between each check.
  end
end).id)



--- Furnace cleaner thread. Upon startup, checks all furnaces for items. Any furnaces with items are added to `furnaces_used`
--- and will be watched until their contents no longer change after `SMELT_TIME` ticks.
--- After this, they will be cleaned out and the furnaces will be opened.
_log.debug("Furnace cleaner thread is", thread.new(function()
  local furnace_contents = {}

  local ph = new_parallelism_handler()
  ph.limit = 16

  for _, furnace in ipairs(config.furnaces) do
    ph:add_task(function()
      local items = smn.call(furnace, "list")
      if items[1] or items[2] or items[3] then
        furnaces_used[furnace] = true
        furnace_contents[furnace] = items
        s_log.debug("Furnace", furnace, "has items in it. Watching for changes.")
      end
    end)
  end
  ph:execute()

  local function compare_item(a, b)
    if not a and b or not b and a then
      return false
    end

    if not a and not b then
      return true
    end

    if a.name == b.name and a.count == b.count then
      return true
    end

    return false
  end

  while next(furnace_contents) do
    sleep(SMELT_TIME / 20 + 0.05)

    for furnace, items in pairs(furnace_contents) do
      ph:add_task(function()
        local new_items = smn.call(furnace, "list")

        local changed = false
        for i = 1, 3 do
          if not compare_item(items[i], new_items[i]) then
            changed = true
            break
          end
        end

        if changed then
          s_log.debug("Furnace", furnace, "has changed items.")
          furnace_contents[furnace] = new_items
        else
          s_log.debug("Furnace", furnace, "has not changed items.")

          -- Send the items back to storage.
          send_all_to_storage(furnace)

          furnaces_used[furnace] = nil
          furnace_contents[furnace] = nil
          s_log.debug("Furnace", furnace, "is now free.")
        end
      end)
    end
    ph:execute()
  end

  s_log.debug("Furnace cleaner thread is done.")
end).id)



--- Peripheral registration/deregistration thread.
--- This thread handles registering and de-registering peripherals from the UI and furnace threads.
_log.debug("Peripheral thread is", thread.new(function()
  while true do
    sleep(60) -- temporary. will fill in later.
  end
end).id)



--- Crafting thread. Loops through crafting tasks in the queue.
_log.debug("Crafting thread is", thread.new(function()
  while true do
    while not crafting_queue[1] do
      os.pullEvent("crafting_task_created")
    end

    local task = table.remove(crafting_queue, 1) --[[@as CraftingTask]]
    c_log.info("Running crafting task", task.id)
    run_crafting_task(task)
  end
end).id)



--- Defragmentation thread.
_log.debug("Defragmentation thread is", thread.new(function()
  while true do
    -- Acquire the lock.
    storage_lock:await_lock()

    -- Defragment the storages.
    storages:defragment()

    -- Release the lock.
    storage_lock:unlock()

    sleep(60 * 10) -- Every 10 minutes.
  end
end).id)



--#endregion Main Functions

--#region Main Program

local ok, err = xpcall(thread.run, debug.traceback)

pcall(catppuccin.reset_palette)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then
  _log.fatal(err)
  error(err, 0)
end

--#endregion Main Program