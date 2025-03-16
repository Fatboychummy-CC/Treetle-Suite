--- Controltle: a turtle that smelts wood into charcoal.
--- The smeltery collects wood and other stuff from the turtles (and reclamation chest),
--- then smelts the wood into charcoal.
--- 
--- To begin, it crafts some logs into planks, then uses those as fuel.

local expect = require "cc.expect".expect

local dir = require "filesystem":programPath()
local minilogger = require "minilogger"
local _log = minilogger.new("Controltle")
local catppuccin = require "catppuccin"
local palette = catppuccin.set_palette("mocha")
local smn = require "single_modem_network"
local thread = require "thread"
minilogger.set_log_level(... and minilogger.LOG_LEVELS[(...):upper()] or minilogger.LOG_LEVELS.INFO)
term.setBackgroundColor(palette.crust)
term.setTextColor(palette.text)
term.clear()

--#region Setup
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
---@type id_lookup
local FUEL_IDS = {
  ["minecraft:coal_block"] = true,
  ["minecraft:charcoal"] = true,
  ["minecraft:coal"] = true,
  ["minecraft:lava_bucket"] = true,
  ["minecraft:dried_kelp_block"] = true,
  ["minecraft:blaze_rod"] = true
}

---@alias fuel_lookup table<string, integer> Maps fuel to their burn time.

--- The item IDs of fuels that will be used in smelting, mapped to their burn time (in ticks).
---@type fuel_lookup
local SMELT_FUEL_IDS = {
  ["minecraft:coal"] = 1600,
  ["minecraft:charcoal"] = 1600,
  ["minecraft:lava_bucket"] = 20000,
  ["minecraft:coal_block"] = 16000,
  ["minecraft:dried_kelp_block"] = 4000,
  ["minecraft:blaze_rod"] = 2400,
}
for name in pairs(PLANK_IDS) do
  SMELT_FUEL_IDS[name] = 300
end

--- The amount of time it takes to smelt a single item, in ticks.
local SMELT_TIME = 200

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
  config = CONFIG_FILE:unserialize(config)
end



--- Saves the configuration to the config file.
local function save_config()
  CONFIG_FILE:serialize(config, {compact=true})
end


--#endregion Configuration

--#region logs

local ui_log = minilogger.new("ui")
local main_log = minilogger.new("main")

--#endregion logs

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
  main_log.debug("Sent", sent, "of", n, "items (", table.concat(names, ", "), ") to", turtle_name, "from", inv_name)

  return sent
end



--- Sends `n` items of the given type to the given turtle, from storage.
---@param turtle_name string The name of the turtle to send items to.
---@param item_types id_lookup The type of item to send.
---@param n integer The number of items to send.
---@return integer sent The number of items actually sent.
local function send_items_from_storage(turtle_name, item_types, n)
  expect(1, turtle_name, "string")
  expect(2, item_types, "table")
  expect(3, n, "number")

  local sent = 0

  for _, storage in ipairs(config.storages) do
    sent = sent + send_items(storage, turtle_name, item_types, n - sent)

    if sent >= n then
      break
    end
  end

  return sent
end



--- Count 'important' items in the storage chests.
---@return integer logs The number of logs in the storage chests.
---@return integer planks The number of planks in the storage chests.
---@return integer saplings The number of saplings in the storage chests.
---@return integer fuels The number of 'good' fuels in the storage chests.
local function count_important()
  local funcs = {}

  local logs, planks, saplings, fuels = 0, 0, 0, 0
  for _, inventory_name in ipairs(config.storages) do
    table.insert(funcs, function()
      local items = smn.call(inventory_name, "list")
      for _, item in pairs(items) do
        if LOG_IDS[item.name] then
          logs = logs + item.count
        elseif PLANK_IDS[item.name] then
          planks = planks + item.count
        elseif SAPLING_IDS[item.name] then
          saplings = saplings + item.count
        elseif FUEL_IDS[item.name] then
          fuels = fuels + item.count
        end
      end
    end)
  end

  parallel.waitForAll(table.unpack(funcs)) -- Hopefully people don't use more than 256 storages.

  return logs, planks, saplings, fuels
end



--- Sends all items in the given inventory to storage.
---@param inv_name string The name of the inventory to send items from.
---@return boolean success False if any item failed to move.
local function send_all_to_storage(inv_name)
  expect(1, inv_name, "string")

  --- Attempt to move all items in the inventory into the given storage, once.
  ---@param storage string The name of the storage to move items to.
  ---@return boolean success False if any item failed to move.
  local function attempt_once(storage)
    local funcs = {}
    local items = smn.call(inv_name, "list")

    for slot, item in pairs(items) do
      table.insert(funcs, function()
        smn.call(inv_name, "pushItems", storage, slot, item.count)
      end)
    end

    parallel.waitForAll(table.unpack(funcs))

    return next(smn.call(inv_name, "list")) == nil
  end

  for _, storage in ipairs(config.storages) do
    if attempt_once(storage) then
      return true
    end
  end

  return false
end



local intermediate_locked = false
--- Takes items from the given turtle
--- Leaves the following in the inventories:
--- 1. Fuel, x16
--- 2. Saplings, x16
---@param turtle_name string The name of the turtle to take items from.
local function take_back_items(turtle_name)
  expect(1, turtle_name, "string")

  main_log.debug("Handling", turtle_name)

  if not config.intermediate_chest or not smn.isPresent(config.intermediate_chest) then
    return 0
  end

  while intermediate_locked do
    sleep()
  end

  intermediate_locked = true

  -- Take everything from the turtle, moving it into the intermediate chest.
  for slot = 1, 16 do
    smn.call(config.intermediate_chest, "pullItems", turtle_name, slot)
  end

  -- Determine what is now in the intermediate chest.
  local items = smn.call(config.intermediate_chest, "list")

  -- Send 16 fuel and 16 saplings back to the turtle (if they exist).
  -- a. Fuel
  local sent_fuel = send_items(config.intermediate_chest, turtle_name, FUEL_IDS, 16)
  -- b. Saplings
  local sent_saplings = send_items(config.intermediate_chest, turtle_name, SAPLING_IDS, 16)

  main_log.debug("Sent", sent_fuel, "fuel and", sent_saplings, "saplings back to", turtle_name)

  -- And send everything else to the storages.
  send_all_to_storage(config.intermediate_chest)

  -- If we sent less than 16 fuel or saplings, check if there are more in the storages, and send them.
  -- However:
  -- 1. Only send fuel if there it leaves us with at least 4 fuel in the storages.
  -- 2. If less than 32 saplings and we didn't send anything back, send a single sapling.
  -- 3. Otherwise, send 16 of each.
  local _, _, saplings, fuels = count_important()
  main_log.debug("Storage Fuel:", fuels, "\nStorage Saplings:", saplings)

  if fuels - (16 - sent_fuel) >= 4 then
    main_log.debug("Sending", 16 - sent_fuel, "fuel from storage to", turtle_name)
    send_items_from_storage(turtle_name, FUEL_IDS, 16 - sent_fuel)
  end

  if saplings < 32 and sent_saplings == 0 then
    main_log.debug("Sending", 1, "sapling from storage to", turtle_name)
    send_items_from_storage(turtle_name, SAPLING_IDS, 1)
  else
    main_log.debug("Sending", 16 - sent_saplings, "saplings from storage to", turtle_name)
    send_items_from_storage(turtle_name, SAPLING_IDS, 16 - sent_saplings)
  end

  main_log.debug("Done handling", turtle_name)

  intermediate_locked = false
end



--- Notifies a turtle that its okay to go.
---@param turtle_id integer The name of the turtle to notify.
local function notify_turtle(turtle_id)
  expect(1, turtle_id, "number")

  sleep(2) -- Ensure the turtle has had time to do whatever it needs to do.

  smn.transmit(TREETLE_CHANNEL, TREETLE_CHANNEL, {
    action = "treetle_go",
    turtle_id = turtle_id
  })

  main_log.debug("Notified turtle", turtle_id, "that it can continue.")
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



--- Run the main system.
_log.debug("Main thread is", thread.new(function()
  main_log.info("Starting Controltle.")
  load_config()
  main_log.debug("Entering main loop.")
  while true do
    local _, _, _, _, message = os.pullEvent("modem_message")
    main_log.debug("Received message: ", textutils.serialize(message, {compact=true}))

    if type(message) == "table" and message.action == "treetle_discovery" then
      main_log.debugf("Received treetle discovery from %s, with ID %d.", message.turtle_name, message.turtle_id)
      thread.new(take_back_items, message.turtle_name)
        :after(notify_turtle, message.turtle_id)
        :on_error(main_log.error, "\n\nThe above error occurred when dealing with treetle", message.turtle_id, "as", message.turtle_name)
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
    main_log.info("Displaying help.")
    display_help()
  end

  main_log.debug("Fade in.")
  fade_in()

  -- ...
end).id)



--#endregion Main Functions

--#region Main Program

local ok, err = pcall(thread.run)

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