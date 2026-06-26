-- storage.lua : a storage system over many Create Item Vaults (or any
-- inventories) on a wired-modem network. Type to search, click to withdraw,
-- and items dropped into the INPUT inventory are auto-absorbed into storage.
--
-- Setup: wire all your storage vaults + an input inventory + an output
-- inventory to the computer via wired modems (one shared network). Then set
-- the names below. Run on an Advanced Computer (mouse + keyboard).

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local STORAGE_MATCH  = "item_vault"     -- name substring identifying storage inventories
local INPUT_NAME     = nil              -- e.g. "minecraft:barrel_0"; items here are pulled into storage
local OUTPUT_NAME    = nil              -- e.g. "minecraft:chest_0"; withdrawals are pushed here
local AUTO_DEPOSIT   = true             -- absorb the INPUT inventory automatically
local REFRESH        = 5                -- seconds between rescans / auto-deposit
local WITHDRAW_STACK = 64               -- left-click withdraw amount (right-click = all)

----------------------------------------------------------------------
local function matches(id, q)
  if not q or q == "" then return true end
  q = q:lower():gsub("%s+", "_")
  return id:lower():find(q, 1, true) ~= nil
end

-- detect the same physical inventory exposed under two names (don't double-count)
local function invSig(inv, list)
  local sz = 0; pcall(function() sz = inv.size() end)
  local keys = {}
  for slot, st in pairs(list) do keys[#keys + 1] = slot .. ":" .. st.name .. ":" .. st.count end
  table.sort(keys)
  return sz .. "|" .. table.concat(keys, ",")
end

local function storageNames()
  local t = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "inventory") and n:find(STORAGE_MATCH, 1, true)
       and n ~= INPUT_NAME and n ~= OUTPUT_NAME then
      t[#t + 1] = n
    end
  end
  return t
end

-- Aggregate item -> count across all storage (deduped). Returns sorted array.
local function aggregate()
  local agg, seen = {}, {}
  for _, n in ipairs(storageNames()) do
    local inv = peripheral.wrap(n)
    local ok, list = pcall(inv.list)
    if ok and list then
      local sig = invSig(inv, list)
      if not seen[sig] then
        seen[sig] = true
        for _, st in pairs(list) do agg[st.name] = (agg[st.name] or 0) + st.count end
      end
    end
  end
  local arr, total = {}, 0
  for item, count in pairs(agg) do arr[#arr + 1] = { item = item, count = count }; total = total + count end
  table.sort(arr, function(a, b) return a.count > b.count end)
  return arr, total
end

-- Pull everything from INPUT into storage vaults.
local function deposit()
  if not INPUT_NAME then return 0 end
  local input = peripheral.wrap(INPUT_NAME)
  if not input or not input.list then return 0 end
  local ok, list = pcall(input.list)
  if not ok or not list then return 0 end
  local stores, moved = storageNames(), 0
  for slot, st in pairs(list) do
    local remaining = st.count
    for _, s in ipairs(stores) do
      if remaining <= 0 then break end
      local pok, m = pcall(input.pushItems, s, slot, remaining)
      if pok and m and m > 0 then moved = moved + m; remaining = remaining - m end
    end
  end
  return moved
end

-- Push up to `count` of an exact item id from storage to OUTPUT.
local function withdraw(item, count)
  if not OUTPUT_NAME then return 0, "no OUTPUT configured" end
  local remaining, moved = count, 0
  for _, n in ipairs(storageNames()) do
    if remaining <= 0 then break end
    local inv = peripheral.wrap(n)
    local ok, list = pcall(inv.list)
    if ok and list then
      for slot, st in pairs(list) do
        if remaining <= 0 then break end
        if st.name == item then
          local pok, m = pcall(inv.pushItems, OUTPUT_NAME, slot, remaining)
          if pok then moved = moved + (m or 0); remaining = remaining - (m or 0) end
        end
      end
    end
  end
  return moved
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(0.5) end

local items, total = {}, 0
local query = ""
local statusMsg = "ready"
local filtered, rowMap = {}, {}

local function shortName(id) return (id:gsub("^[^:]+:", "")) end

local function drawMonitor()
  if not monitor then return end
  monitor.setBackgroundColor(colors.black); monitor.clear()
  local W, H = monitor.getSize()
  monitor.setCursorPos(1, 1); monitor.setTextColor(colors.white)
  monitor.write(("STORAGE  %d items / %d vaults"):format(total, #storageNames()):sub(1, W))
  local y = 3
  for i = 1, math.min(#items, H - 2) do
    monitor.setCursorPos(1, y); monitor.setTextColor(colors.lightBlue)
    monitor.write(("%7d %s"):format(items[i].count, shortName(items[i].item)):sub(1, W))
    y = y + 1
  end
end

local function draw()
  local W, H = term.getSize()
  term.setBackgroundColor(colors.black); term.clear()
  term.setCursorPos(1, 1); term.setTextColor(colors.white)
  term.write(("STORAGE  %d items / %d vaults"):format(total, #storageNames()):sub(1, W))
  term.setCursorPos(1, 2); term.setTextColor(colors.yellow)
  term.write(("search: %s"):format(query):sub(1, W))

  -- filter
  local q = query:lower():gsub("%s+", "_")
  filtered, rowMap = {}, {}
  for _, e in ipairs(items) do
    if q == "" or e.item:lower():find(q, 1, true) then filtered[#filtered + 1] = e end
  end

  local top, bottom = 4, H - 1
  for i = 1, (bottom - top + 1) do
    local e = filtered[i]
    if not e then break end
    local y = top + i - 1
    rowMap[y] = i
    term.setCursorPos(1, y); term.setTextColor(colors.lightBlue)
    term.write(("%7d  %s"):format(e.count, e.item):sub(1, W))
  end

  term.setCursorPos(1, H); term.setBackgroundColor(colors.gray); term.setTextColor(colors.white)
  term.clearLine()
  term.write((" %s | type=search  L-click=+%d  R-click=all  enter=deposit  ^T=quit"):format(statusMsg, WITHDRAW_STACK):sub(1, W))
  term.setBackgroundColor(colors.black)
  drawMonitor()
end

local function refresh() items, total = aggregate() end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------
statusMsg = "scanning..."; draw()
refresh()
local running = true
local timer = os.startTimer(REFRESH)
draw()
while running do
  local e = { os.pullEventRaw() }
  local ev = e[1]
  if ev == "timer" and e[2] == timer then
    if AUTO_DEPOSIT and INPUT_NAME then
      local d = deposit()
      if d > 0 then statusMsg = "absorbed " .. d end
    end
    refresh(); draw()
    timer = os.startTimer(REFRESH)
  elseif ev == "char" then
    query = query .. e[2]; draw()
  elseif ev == "key" then
    if e[2] == keys.backspace then query = query:sub(1, #query - 1); draw()
    elseif e[2] == keys.enter then
      local d = deposit(); statusMsg = "deposited " .. d; refresh(); draw()
    end
  elseif ev == "mouse_click" or ev == "monitor_touch" then
    local x, y = (ev == "mouse_click") and e[3] or e[3], (ev == "mouse_click") and e[4] or e[4]
    local idx = rowMap[y]
    if idx and filtered[idx] then
      local it = filtered[idx]
      local amount = (ev == "mouse_click" and e[2] == 2) and it.count or WITHDRAW_STACK
      local got = withdraw(it.item, amount)
      statusMsg = ("withdrew %d %s"):format(got, shortName(it.item))
      refresh(); draw()
    end
  elseif ev == "term_resize" or ev == "monitor_resize" then
    draw()
  elseif ev == "terminate" then
    running = false
  end
end
term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
term.clear(); term.setCursorPos(1, 1)
print("storage stopped.")
