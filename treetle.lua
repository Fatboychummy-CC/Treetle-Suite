--- Treetle: A turtle that watches a sapling and cuts it down when it grows.

local expect = require "cc.expect".expect

local dir = require "filesystem":programPath()
local minilogger = require "minilogger"
local catppuccin = require "catppuccin"
local palette = catppuccin.set_palette("frappe")
minilogger.set_colors {
  gray = palette.subtext_1,
  white = palette.text,
  green = palette.green,
  yellow = palette.yellow,
  red = palette.red,
  lightGray = palette.subtext_1,
  black = palette.crust,
}

--- - gray
--- - white
--- - green
--- - yellow
--- - red
--- - lightGray
--- - black

--#region Constants

local STATE_FILE = dir:file("treetle.state")

---@alias id_lookup table<string, boolean>

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

--- The item IDs of leaves that the turtle will cut down.
---@type id_lookup
local LEAF_IDS = {
  ["minecraft:oak_leaves"] = true,
  ["minecraft:spruce_leaves"] = true,
  ["minecraft:birch_leaves"] = true,
  ["minecraft:jungle_leaves"] = true,
  ["minecraft:acacia_leaves"] = true,
  ["minecraft:dark_oak_leaves"] = true,
  ["minecraft:mangrove_leaves"] = true,
  ["minecraft:cherry_leaves"] = true,
  ["minecraft:azalea_leaves"] = true,
  ["minecraft:flowering_azalea_leaves"] = true,
  ["sc-goodies:sakura_leaves"] = true,
  ["sc-goodies:maple_leaves"] = true,
  ["sc-goodies:blue_leaves"] = true
}

--- The item IDs of "good" fuels that the turtle will use to refuel.
---@type id_lookup
local FUEL_IDS = {
  ["minecraft:coal"] = true,
  ["minecraft:charcoal"] = true,
  ["minecraft:lava_bucket"] = true,
  ["minecraft:coal_block"] = true,
  ["minecraft:charcoal_block"] = true
}

--- The item IDs of "emergency" fuels that the turtle will use to refuel.
---@type id_lookup
local EMERGENCY_FUEL_IDS = {
  ["minecraft:stick"] = true
}
do
  local function copy_tbl(tbl, to)
    for k, v in pairs(tbl) do
      to[k] = v
    end
  end

  copy_tbl(FUEL_IDS, EMERGENCY_FUEL_IDS) -- Copy the FUEL_IDS table to the EMERGENCY_FUEL_IDS table.
  copy_tbl(PLANK_IDS, EMERGENCY_FUEL_IDS) -- Planks give 15 fuel.
  copy_tbl(SAPLING_IDS, EMERGENCY_FUEL_IDS) -- Saplings give 5 fuel.

  -- Annoyingly, the sc-goodies saplings are not valid fuels.
  EMERGENCY_FUEL_IDS["sc-goodies:sakura_sapling"] = nil
  EMERGENCY_FUEL_IDS["sc-goodies:maple_sapling"] = nil
  EMERGENCY_FUEL_IDS["sc-goodies:blue_sapling"] = nil
end

local EMERGENCY_FUEL_LEVEL_THRESHOLD = 1
local FUEL_LEVEL_LOW_THRESHOLD = 100
local REFUEL_TO = 1000

---@enum states
local STATES = {
  STARTING = 0,
  WAITING = 1,
  PLANTING = 2,
  WAITING_FOR_GROWTH = 3,
  DIGGING = 4,
  ERRORED = 5,
  IDLE = 7 -- In between states.
}

---@enum movements
local MOVEMENTS = {
  NONE = 0,
  FORWARD = 1,
  BACK = 2,
  UP = 3,
  DOWN = 4,
  TURN_RIGHT = 5,
  TURN_LEFT = 6
}

---@enum facings
local FACINGS = {
  NORTH = 0,
  EAST = 1,
  SOUTH = 2,
  WEST = 3,
  NZ = 0,
  PX = 1,
  PZ = 2,
  NX = 3
}

local T_W, T_H = term.getSize()

--- The information window hosts the position, facing, and fuel level of the turtle.
local INFO_WIN = window.create(term.current(), 1, 1, T_W, 2)
INFO_WIN.setBackgroundColor(palette.crust)
INFO_WIN.setTextColor(palette.text)
INFO_WIN.clear()

--- The log window hosts the log of the turtle's actions. This window is one line extra, since `print` adds a newline.
local LOG_WIN = window.create(term.current(), 1, 4, T_W, T_H - 2)

--#endregion Constants

--#region Logger

local _log = minilogger.new("treetle")
minilogger.set_log_level(... and minilogger.LOG_LEVELS[(...):upper()] or minilogger.LOG_LEVELS.INFO)
minilogger.set_log_window(LOG_WIN)

--#endregion Logger

--#region Turtle Helpers

local turtle_state = {
  position = { x = 0, y = 0, z = 0 },
  facing = 0,
  fuel_level = 0,
  state = STATES.STARTING,
  last_movement = MOVEMENTS.NONE
}



--- Collects info about all items in the turtle's inventory.
---@return table<integer, item> items The items in the turtle's inventory.
local function get_items()
  local items = {}

  for i = 1, 16 do
    items[i] = turtle.getItemDetail(i)
  end

  return items
end



--- Locates the given items in the turtle's inventory.
---@param item_ids id_lookup The item IDs to locate.
---@param items table<integer, item>? The items in the turtle's inventory. If not provided, will search manually (takes time).
---@return integer[] slots The slots that contain the items.
local function locate_items(item_ids, items)
  expect(1, item_ids, "table")

  local slots = {}

  if items then
    for slot, item in pairs(items) do
      if item and item_ids[item.name] then
        table.insert(slots, slot)
      end
    end
  else
    for slot = 1, 16 do
      local item = turtle.getItemDetail(slot)
      if item and item_ids[item.name] then
        table.insert(slots, slot)
      end
    end
  end

  return slots
end



--- Shorthand to find a single item in the turtle's inventory.
---@param item_id string The item ID to locate.
---@param items table<integer, item>? The items in the turtle's inventory. If not provided, will search manually (takes time).
---@return integer[] slots The slots that contain the item.
local function locate_item(item_id, items)
  expect(1, item_id, "string")

  return locate_items({ [item_id] = true }, items)
end



--- Determines the first empty slot in the turtle's inventory.
---@param items table<integer, item>? The items in the turtle's inventory. If not provided, will search manually (takes time).
---@return integer? slot The first empty slot, or nil if no slots are empty.
local function first_empty_slot(items)
  if items then
    for i = 1, 16 do
      if not items[i] then
        return i
      end
    end
  else
    for i = 1, 16 do
      if turtle.getItemCount(i) == 0 then
        return i
      end
    end
  end
end



--- Selects the first slot.
local function reselect()
  turtle.select(1)
end



local item_stack_limits = {}
--- Collects the stack limits of items in the turtle's inventory.
---@param items table<integer, item>? The items in the turtle's inventory. If not provided, will search manually (takes time).
local function collect_stack_limits(items)
  if items then
    for _, item in pairs(items) do
      if item and not item_stack_limits[item.name] then
        item_stack_limits[item.name] = turtle.getItemSpace(item.slot) + item.count
      end
    end
    return
  else
    for i = 1, 16 do
      local item = turtle.getItemDetail(i)

      if item and not item_stack_limits[item.name] then
        item_stack_limits[item.name] = turtle.getItemSpace(i) + item.count
      end
    end
  end
end



--- Condenses items in the inventory.
local function condense_inventory()
  local items = get_items()

  collect_stack_limits(items)

  -- Step 1: Condense all items into their respective stacks.
  for current_slot = 16, 1, -1 do
    local item = items[current_slot]
    if item then
      local slots = locate_item(item.name)
      for _, slot in ipairs(slots) do
        if slot < current_slot then -- Only move items from higher slots to lower slots.
          if turtle.getSelectedSlot() ~= current_slot then
            turtle.select(current_slot)
          end
          turtle.transferTo(slot)

          -- The turtle's inventory changed, so let's update the items table.
          items = get_items()

          -- And if we moved everything from this slot, we can stop.
          if not items[current_slot] then
            break
          end
        end
      end
    end
  end

  -- Step 2: Move all remaining items to be in the first slots.
  for current_slot = 16, 1, -1 do
    local item = turtle.getItemDetail(current_slot)
    if item then
      local first_empty = first_empty_slot()
      if first_empty and first_empty < current_slot then
        turtle.select(current_slot)
        turtle.transferTo(first_empty)
      end
    end
  end

  if not first_empty_slot() then
    _log.warn("Inventory is full.")
  end

  reselect()
end



--- Checks if the result of inspection in the given direction is a log or leaves.
---@param inspector function The function to inspect the block with.
---@return boolean is_log Whether the block is a log.
---@return boolean is_leaf Whether the block is a leaf.
local function is_log_or_leaf(inspector)
  expect(1, inspector, "function")

  local success, data = inspector()
  if not success then
    return false, false
  end

  return LOG_IDS[data.name] or false, LEAF_IDS[data.name] or false
end



--- Checks if the result of inspection in the given direction is a sapling or log.
---@param inspector function The function to inspect the block with.
---@return boolean is_sapling Whether the block is a sapling.
---@return boolean is_log Whether the block is a log.
local function is_sapling_or_log(inspector)
  expect(1, inspector, "function")

  local success, data = inspector()
  if not success then
    return false, false
  end

  return SAPLING_IDS[data.name] or false, LOG_IDS[data.name] or false
end



--- Performs a base refuel -- Attempts only to use the fuels in the FUEL_IDS table.
---@param item_lookup id_lookup? The item IDs to use for refueling, or nil to use the default FUEL_IDS.
---@return boolean success Whether the refuel was successful.
local function refuel(item_lookup)
  item_lookup = item_lookup or FUEL_IDS

  local slots = locate_items(item_lookup)
  if #slots == 0 then
    return false
  end

  local did_refuel = false
  for _, slot in ipairs(slots) do
    turtle.select(slot)
    if turtle.refuel(0) then
      turtle.refuel(64)
      did_refuel = true
    end
  end

  reselect()

  if not did_refuel then
    _log.warn("Fuel was found, but then it wasn't.")
    return false
  end

  _log.okay("Refueled.")
  return true
end



--- Performs an emergency refuel
--- If the turtle runs out of fuel while digging up a tree, will attempt to do the following:
--- 1. Base refuel. If successful, exit, otherwise continue.
--- 2. Perform a refuel using the emergency fuels in the EMERGENCY_FUEL_IDS table. Same condition as above.
--- 3. Dump everything except logs, move all the logs to one slot (if too many, dump extras)
--- 4. Craft logs into planks
--- 5. Refuel using planks
--- 
--- Throws an error on any failure.
local function emergency_refuel()
  _log.warn("Emergency refuel initiated.")

  if refuel() then
    return
  end

  if refuel(EMERGENCY_FUEL_IDS) then
    return
  end

  local logs = locate_items(LOG_IDS)
  if #logs == 0 then
    _log.error("No logs found.")
    return
  end

  -- Move all the logs into slot 1.
  for _, slot in ipairs(logs) do
    turtle.select(slot)
    turtle.transferTo(1)
  end

  -- Dump the rest of the inventory.
  for i = 2, 16 do
    if turtle.getItemCount(i) > 0 then
      turtle.select(i)
      turtle.drop()
    end
  end

  -- Craft the logs into planks.
  reselect()
  turtle.craft()

  -- Refuel using the planks.
  if refuel(PLANK_IDS) then
    _log.okay("Emergency refuel success.")
    return
  end

  error("Emergency refuel failed.")
end



--- Updates the turtle's state, and saves it.
---@param new_state states? The new state of the turtle. If nil, just saves the state.
local function update_state(new_state)
  if new_state then
    turtle_state.state = new_state
  end

  turtle_state.fuel_level = turtle.getFuelLevel()

  STATE_FILE:serialize(turtle_state, {compact = true})
end



--- Perform pre-movement tasks (update movement, save)
---@param mover function The function to move the turtle.
local function pre_move(mover)
  expect(1, mover, "function")

  turtle_state.last_movement = mover == turtle.forward and MOVEMENTS.FORWARD or
    mover == turtle.back and MOVEMENTS.BACK or
    mover == turtle.up and MOVEMENTS.UP or
    mover == turtle.down and MOVEMENTS.DOWN or
    mover == turtle.turnRight and MOVEMENTS.TURN_RIGHT or
    mover == turtle.turnLeft and MOVEMENTS.TURN_LEFT or
    MOVEMENTS.NONE

  update_state()
end



--- Perform post-movement tasks (update movement, update position, save)
---@param mover function The function to move the turtle.
---@param ok boolean Whether the turtle moved successfully.
local function post_move(mover, ok)
  turtle_state.last_movement = MOVEMENTS.NONE

  if ok then
    if mover == turtle.forward then
      if turtle_state.facing == 0 then -- North, -Z
        turtle_state.position.z = turtle_state.position.z - 1
      elseif turtle_state.facing == 1 then -- East, +X
        turtle_state.position.x = turtle_state.position.x + 1
      elseif turtle_state.facing == 2 then -- South, +Z
        turtle_state.position.z = turtle_state.position.z + 1
      elseif turtle_state.facing == 3 then -- West, -X
        turtle_state.position.x = turtle_state.position.x - 1
      else
        error(("Invalid facing: %d"):format(turtle_state.facing), 2)
      end
    elseif mover == turtle.back then
      if turtle_state.facing == 0 then -- North, -Z (inverse)
        turtle_state.position.z = turtle_state.position.z + 1
      elseif turtle_state.facing == 1 then -- East, +X (inverse)
        turtle_state.position.x = turtle_state.position.x - 1
      elseif turtle_state.facing == 2 then -- South, +Z (inverse)
        turtle_state.position.z = turtle_state.position.z - 1
      elseif turtle_state.facing == 3 then -- West, -X (inverse)
        turtle_state.position.x = turtle_state.position.x + 1
      else
        error(("Invalid facing: %d"):format(turtle_state.facing), 2)
      end
    elseif mover == turtle.up then
      turtle_state.position.y = turtle_state.position.y + 1
    elseif mover == turtle.down then
      turtle_state.position.y = turtle_state.position.y - 1
    elseif mover == turtle.turnRight then
      turtle_state.facing = (turtle_state.facing + 1) % 4
    elseif mover == turtle.turnLeft then
      turtle_state.facing = (turtle_state.facing - 1) % 4
    end
  end

  update_state()
end



--- Perform a movement.
---@param mover function The function to move the turtle.
---@return boolean success Whether the turtle moved successfully.
---@return string? error The error message, if the turtle did not move successfully.
local function move(mover)
  expect(1, mover, "function")

  local function _move()
    pre_move(mover)
    local ok, err = mover()
    post_move(mover, ok)

    return ok, err
  end

  if mover == turtle.turnRight or mover == turtle.turnLeft then
    return _move()
  end

  local fuel_level = turtle.getFuelLevel()
  if fuel_level == "unlimited" then
    _log.debug("Fuel level is unlimited.")
  elseif fuel_level <= EMERGENCY_FUEL_LEVEL_THRESHOLD then
    emergency_refuel()
  elseif fuel_level < FUEL_LEVEL_LOW_THRESHOLD then
    refuel()
  end

  return _move()
end



--- Moves the turtle forwards.
local function forward()
  while not move(turtle.forward) do
    turtle.dig()
  end
end



--- Moves the turtle backwards.
local function back()
  while not move(turtle.back) do
    turtle.turnRight()
    turtle.turnRight()
    turtle.dig()
    turtle.turnRight()
    turtle.turnRight()
  end
end



--- Moves the turtle up.
local function up()
  while not move(turtle.up) do
    turtle.digUp()
  end
end



--- Moves the turtle down.
local function down()
  while not move(turtle.down) do
    turtle.digDown()
  end
end



--- Turns the turtle to the right.
local function turn_right()
  move(turtle.turnRight)
end



--- Turns the turtle to the left.
local function turn_left()
  move(turtle.turnLeft)
end



--- Turns the turtle towards a facing.
---@param facing facings The facing to turn towards.
local function face(facing)
  expect(1, facing, "number")

  if facing < 0 or facing > 3 or facing % 1 ~= 0 then
    error("Invalid facing: " .. tostring(facing), 2)
  end

  if (turtle_state.facing + 1) % 4 == facing then
    turn_right()
  else
    while turtle_state.facing ~= facing do
      turn_left()
    end
  end
end



--- Moves the turtle to a location.
---@param x integer The X coordinate to move to.
---@param y integer The Y coordinate to move to.
---@param z integer The Z coordinate to move to.
---@param facing integer? The facing direction to end at. Leaving empty will mean the turtle will face whatever direction it arrived in.
local function move_to(x, y, z, facing)
  expect(1, x, "number")
  expect(2, y, "number")
  expect(3, z, "number")
  expect(4, facing, "number", "nil")

  local dx = x - turtle_state.position.x
  local dy = y - turtle_state.position.y
  local dz = z - turtle_state.position.z

  if dx == 0 and dy == 0 and dz == 0 then
    if facing then face(facing) end
    return
  end

  if dx ~= 0 then
    if dx > 0 then
      face(FACINGS.PX)
    else
      face(FACINGS.NX)
    end

    for _ = 1, math.abs(dx) do
      forward()
    end
  end

  if dy ~= 0 then
    for _ = 1, math.abs(dy) do
      if dy > 0 then
        up()
      else
        down()
      end
    end
  end

  if dz ~= 0 then
    if dz > 0 then
      face(FACINGS.PZ)
    else
      face(FACINGS.NZ)
    end

    for _ = 1, math.abs(dz) do
      forward()
    end
  end

  if facing then face(facing) end
  return
end



--#endregion Turtle Helpers

--#region Main Methods

--- Digs up a tree, using sophisticated logics and stuff to ensure maximal awesome and minimal derp.
---@param _r boolean? Whether the function is being called recursively (internally used)
local function dig_tree(_r)
  if not _r then
    _log.info("Digging up tree...")
    update_state(STATES.DIGGING)

    local _, is_log = is_sapling_or_log(turtle.inspect)

    if not is_log then
      _log.warn("No log in front of the turtle.")
      return
    end

    -- Step into the tree.
    forward()
  else
    _log.debug("Step in...")
  end

  -- Check around the turtle for logs or leaves
  for _ = 1, 4 do
    _log.debugf("Check %d of 4...", _)
    local is_log, is_leaves = is_log_or_leaf(turtle.inspect)

    if is_leaves then
      _log.debug("Leaves")
      turtle.dig()
    elseif is_log then
      _log.debug("Log")
      -- Recurse into the block.
      forward()
      dig_tree(true)
      back()
    end

    turn_right()
  end

  -- Check above the turtle for logs or leaves
  local is_log, is_leaves = is_log_or_leaf(turtle.inspectUp)
  if is_leaves then
    _log.debug("Leaves up")
    turtle.digUp()
  elseif is_log then
    -- Recurse into the block.
    _log.debug("Log up")
    up()
    dig_tree(true)
    down()
  end

  -- Return to the "home" position
  if not _r then
    -- Step back out of the tree.
    back()

    _log.okay("Tree dug up.")
    update_state(STATES.IDLE)
  else
    _log.debug("Step out...")
  end
end



--- Plants a sapling in front of the turtle.
local function plant_sapling()
  local is_sapling, is_log = is_sapling_or_log(turtle.inspect)
  if is_sapling then
    _log.okay("There is a sapling in front of the turtle.")
    return
  end
  if is_log then
    _log.okay("There is a log in front of the turtle.")
    return
  end

  _log.info("Planting sapling...")
  update_state(STATES.PLANTING)

  local slots
  repeat
    slots = locate_items(SAPLING_IDS)
    if #slots == 0 then
      _log.warn("No saplings found. Waiting for saplings...")
      os.pullEvent("turtle_inventory")
    end
  until next(slots)

  turtle.select(slots[1])
  if turtle.place() then
    _log.okay("Sapling planted.")
  else
    _log.warn("Failed to plant sapling.")
    update_state(STATES.IDLE)

    -- Check if the reason was because a sapling or log is in front already.
    local is_sapling, is_log = is_sapling_or_log(turtle.inspect)
    if is_sapling then
      _log.okay("There is a sapling in front of the turtle.")
      return
    elseif is_log then
      _log.okay("There is a log in front of the turtle.")
      return
    end

    sleep(30) -- Failing to plant a sapling for another reason means something is likely blocking it,
    -- Or the dirt block underneath is gone! So, we wait a while in order to not completely
    -- and utterly destroy the log file's size.
  end
  reselect()
  update_state(STATES.IDLE)
end



--- Waits for a tree to grow in front of the turtle.
local function wait_for_tree()
  _log.info("Waiting for tree...")
  update_state(STATES.WAITING_FOR_GROWTH)

  while true do
    local is_sapling, is_log = is_sapling_or_log(turtle.inspect)

    if is_log then
      break
    elseif is_sapling then
      _log.debug("Sapling still there.")
    elseif not is_sapling and not is_log then
      _log.warn("No sapling or log in front of the turtle.")
      turtle.dig()
      return
    end

    sleep(10)
  end

  _log.okay("Tree has grown.")
  update_state(STATES.IDLE)
end



--- Main loop
local function main()
  ---@TODO Add startup check to see if the turtle is in the middle of a tree, and if so, continue to dig it up.
  -- Load the turtle state.
  turtle_state = STATE_FILE:unserialize(turtle_state)

  -- If the turtle was in the middle of a movement (last_movement is not NONE), then check fuel level)
  -- to confirm if it has actually moved.
  if turtle_state.last_movement == MOVEMENTS.FORWARD
  or turtle_state.last_movement == MOVEMENTS.BACK
  or turtle_state.last_movement == MOVEMENTS.UP
  or turtle_state.last_movement == MOVEMENTS.DOWN then
    if turtle.getFuelLevel() < turtle_state.fuel_level then
      _log.info("Turtle was in the middle of movement during a shutdown, and completed the move.")
      post_move(
        turtle_state.last_movement == MOVEMENTS.FORWARD and turtle.forward or
        turtle_state.last_movement == MOVEMENTS.BACK and turtle.back or
        turtle_state.last_movement == MOVEMENTS.UP and turtle.up or
        turtle_state.last_movement == MOVEMENTS.DOWN and turtle.down or
        error("Invalid movement: " .. turtle_state.last_movement),
        true
      )
    else
      _log.info("Turtle was in the middle of a movement during a shutdown, but did not complete the move.")
    end
  end

  -- We can't load the recursive state that the turtle was in beforehand if it *was* digging up a tree,
  -- BUT, we can pretend we are just continuing to dig up the tree, then return home afterwards.
  if turtle_state.state == STATES.DIGGING then
    _log.info("Continuing to dig up tree...")
    dig_tree(true)
  end

  -- Then we can return home.
  if turtle_state.position.x ~= 0 or turtle_state.position.y ~= 0 or turtle_state.position.z ~= 0 or turtle_state.facing ~= FACINGS.NORTH then
    _log.info("Returning to start position...")
    move_to(0, 0, 0, FACINGS.NORTH)
  end

  -- Assuming we are back at the start position now, we should start with an optimal inventory.
  condense_inventory()

  while true do
    plant_sapling()
    wait_for_tree()

    if turtle.getFuelLevel() < REFUEL_TO then
      refuel()
    end

    dig_tree()
    condense_inventory()
  end
end



--- Information thread loop
--- ########################################
--- #   STATE   |####  X####  Y####  Z#### #
--- # Fuel<XXXXX#####################XXXXX>#
--- ########################################
local function info()
  term.setBackgroundColor(palette.crust)

  local state_lookup = {}
  for k, v in pairs(STATES) do
    state_lookup[v] = k
  end

  local fuel_bar_length = T_W - 4
  local turtle_max_fuel = turtle.getFuelLimit()

  -- Draw the divider on the main terminal.
  term.setCursorPos(1, 3)
  term.setTextColor(palette.overlay_0)
  term.write(('\x8c'):rep(T_W))

  while true do
    local fuel_level = turtle.getFuelLevel()
    local old = term.redirect(INFO_WIN)
    INFO_WIN.setVisible(false)

    term.clear()

    -- Write the state
    term.setCursorPos(1, 1)
    term.setTextColor(palette.overlay_0)
    term.write(state_lookup[turtle_state.state] or "UNKNOWN")

    -- Write the direction.
    term.setCursorPos(15, 1)
    term.setTextColor(palette.text)
    term.write("\x12")
    term.setBackgroundColor(palette.overlay_0)
    if turtle_state.facing == 0 then
      term.write(" N ")
    elseif turtle_state.facing == 1 then
      term.write(" E ")
    elseif turtle_state.facing == 2 then
      term.write(" S ")
    elseif turtle_state.facing == 3 then
      term.write(" W ")
    else
      term.write(" ? ")
    end

    -- Write the X position
    term.setCursorPos(20, 1)
    term.setBackgroundColor(palette.crust)
    term.write("X")
    term.setBackgroundColor(palette.overlay_0)
    term.write(("%4d"):format(turtle_state.position.x))

    -- Write the Y position
    term.setCursorPos(27, 1)
    term.setBackgroundColor(palette.crust)
    term.write("Y")
    term.setBackgroundColor(palette.overlay_0)
    term.write(("%4d"):format(turtle_state.position.y))

    -- Write the Z position
    term.setCursorPos(34, 1)
    term.setBackgroundColor(palette.crust)
    term.write("Z")
    term.setBackgroundColor(palette.overlay_0)
    term.write(("%4d"):format(turtle_state.position.z))

    -- Write the fuel level
    -- 1. Fuel word
    term.setCursorPos(1, 2)
    term.setBackgroundColor(palette.crust)
    term.write("Fuel")
    -- 2. Fuel bar
    local percent = fuel_level / turtle_max_fuel
    local length_filled = math.floor(fuel_bar_length * percent + 0.5)
    local length_empty = fuel_bar_length - length_filled
    local char_filled = colors.toBlit(palette.blue)
    local char_empty = colors.toBlit(palette.base)
    if percent < 0.1 then
      char_filled = colors.toBlit(palette.red)
    elseif percent < 0.25 then
      char_filled = colors.toBlit(palette.yellow)
    elseif percent < 0.5 then
      char_filled = colors.toBlit(palette.green)
    end
    local txt = "\x91" .. (' '):rep(fuel_bar_length - 2) .. "\x9d"
    local char_fg = colors.toBlit(palette.crust)
    -- local char_bg = colors.toBlit(palette.base)
    local fg = char_fg:rep(fuel_bar_length - 1)
    local bg = char_filled:rep(length_filled) .. char_empty:rep(length_empty)

    -- Last character needs to be inverted.
    if bg:sub(-1) == char_filled then
      fg = fg .. char_filled
    else -- inverted
      fg = fg .. char_empty
    end
    bg = bg:sub(1, -2) .. char_fg

    term.blit(txt, fg, bg)

    term.redirect(old)
    INFO_WIN.setVisible(true)

    sleep(0.5)
  end
end

--#endregion Main Methods


--#region Main Program

term.setBackgroundColor(palette.crust)
term.setTextColor(palette.text)
term.clear()
_log.info("Log started at", os.epoch "utc")
_log.info("Treetle starting...")

if not peripheral.find("workbench") then
  _log.error("A crafting table peripheral is required.")
  return
end

if not turtle.craft then
  _log.error("Please restart the turtle before running this program, the crafting table was not registered properly.")
  return
end

local ok, err = pcall(
  parallel.waitForAny,
    main,
    info
)

if not ok then
  pcall(update_state, STATES.ERRORED)
else
  pcall(update_state, STATES.IDLE)
end

_log.error(err)
term.clear()
term.setCursorPos(1, 1)
error(err, 0)

--#endregion Main Program