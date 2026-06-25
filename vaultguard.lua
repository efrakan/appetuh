-- vaultguard.lua : touch-GUI controller for a brass funnel based on a vault's
-- contents. AUTO mode enables the funnel at ON_AT and disables it at OFF_AT.
-- TOGGLE FUNNEL is a manual override (works regardless of count); RESUME AUTO
-- hands control back to the thresholds; +/- buttons adjust the thresholds live
-- (persisted to disk).
--
-- Setup: wired modem on the vault -> cable -> computer (enable the channel).
--        Funnel on FUNNEL_SIDE of the computer (or redstone wired there).
--        Optional: attach an advanced monitor (it becomes the touch screen).

----------------------------------------------------------------------
-- Config (defaults; thresholds can be changed live and are saved)
----------------------------------------------------------------------
local ITEM        = "create:crimsite"   -- item id to watch
local ON_AT       = 210000              -- default: enable funnel at/above this
local OFF_AT      = 200000              -- default: disable at/below this
local STEP        = 10000               -- +/- button increment
local FUNNEL_SIDE = "bottom"            -- computer side that powers the funnel
local POLL        = 2                   -- seconds between vault polls
local VAULT_NAME  = nil                 -- peripheral name, or nil to auto-detect
local CONFIG      = "/var/vaultguard.tbl"

----------------------------------------------------------------------
-- Peripherals / display
----------------------------------------------------------------------
local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(0.5) end
local out = monitor or term.current()
local restore = term.redirect(out)
local useTouch = monitor ~= nil

local function findVault()
  if VAULT_NAME then return peripheral.wrap(VAULT_NAME) end
  return peripheral.find("inventory")
end
local vault = findVault()

local function countItem(inv, item)
  if not inv then return nil end
  local ok, list = pcall(inv.list)
  if not ok or not list then return nil end
  local total = 0
  for _, stack in pairs(list) do
    if stack.name == item then total = total + stack.count end
  end
  return total
end

-- A redstone signal DISABLES a brass funnel, so funnel-on == redstone-off.
local function setFunnel(on) redstone.setOutput(FUNNEL_SIDE, not on) end

----------------------------------------------------------------------
-- State + persistence
----------------------------------------------------------------------
local state = {
  auto     = true,
  funnelOn = not redstone.getOutput(FUNNEL_SIDE),
  count    = nil,
  onAt     = ON_AT,
  offAt    = OFF_AT,
  running  = true,
}

local function saveConfig()
  local dir = fs.getDir(CONFIG)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(CONFIG, "w")
  h.write(textutils.serialize({ onAt = state.onAt, offAt = state.offAt }))
  h.close()
end

local function loadConfig()
  if not fs.exists(CONFIG) then return end
  local h = fs.open(CONFIG, "r"); local s = h.readAll(); h.close()
  local t = textutils.unserialize(s)
  if type(t) == "table" then
    if tonumber(t.onAt)  then state.onAt  = t.onAt end
    if tonumber(t.offAt) then state.offAt = t.offAt end
  end
end
loadConfig()

-- Keep onAt strictly above offAt by at least STEP, and both >= 0.
local function adjOn(d)
  local v = state.onAt + d
  if v < state.offAt + STEP then v = state.offAt + STEP end
  state.onAt = v; saveConfig()
end
local function adjOff(d)
  local v = state.offAt + d
  if v < 0 then v = 0 end
  if v > state.onAt - STEP then v = state.onAt - STEP end
  state.offAt = v; saveConfig()
end

local function poll()
  state.count = countItem(vault, ITEM)
  if state.auto and state.count then
    if not state.funnelOn and state.count >= state.onAt then
      state.funnelOn = true
    elseif state.funnelOn and state.count <= state.offAt then
      state.funnelOn = false
    end
  end
  setFunnel(state.funnelOn)
end

----------------------------------------------------------------------
-- Buttons + drawing
----------------------------------------------------------------------
local buttons = {}

local function layout()
  local W, H = term.getSize()
  buttons = {
    -- threshold adjusters (small, on the limit rows)
    { id="onMinus",  x=W-11, y=8, w=5, h=1, label="-", action=function() adjOn(-STEP) end },
    { id="onPlus",   x=W-5,  y=8, w=5, h=1, label="+", action=function() adjOn( STEP) end },
    { id="offMinus", x=W-11, y=9, w=5, h=1, label="-", action=function() adjOff(-STEP) end },
    { id="offPlus",  x=W-5,  y=9, w=5, h=1, label="+", action=function() adjOff( STEP) end },
    -- main controls
    { id="toggle", x=2, y=H-7, w=W-2, h=3, label="TOGGLE FUNNEL",
      action=function() state.funnelOn = not state.funnelOn; state.auto = false end },
    { id="auto", x=2, y=H-3, w=W-2, h=2, label="RESUME AUTO",
      action=function() state.auto = true end },
    { id="quit", x=W-6, y=1, w=6, h=1, label=" QUIT ",
      action=function() state.running = false end },
  }
end

local function drawButton(b, bg, fg)
  term.setBackgroundColor(bg)
  for yy = b.y, b.y + b.h - 1 do
    term.setCursorPos(b.x, yy); term.write(string.rep(" ", b.w))
  end
  term.setTextColor(fg)
  local lx = b.x + math.max(0, math.floor((b.w - #b.label) / 2))
  local ly = b.y + math.floor((b.h - 1) / 2)
  term.setCursorPos(lx, ly); term.write(b.label)
end

local function statusLine(y, label, value, color)
  term.setBackgroundColor(colors.black)
  term.setCursorPos(1, y)
  term.setTextColor(colors.lightGray); term.write(label)
  term.setTextColor(color or colors.white); term.write(value)
end

local function draw()
  layout()
  term.setBackgroundColor(colors.black); term.clear()

  term.setCursorPos(2, 1); term.setTextColor(colors.white)
  term.write("Vault Funnel Control")

  statusLine(3, "Item:   ", ITEM)
  statusLine(4, "Count:  ", state.count and tostring(state.count) or "?",
             state.count and colors.white or colors.red)
  statusLine(5, "Mode:   ", state.auto and "AUTO" or "MANUAL",
             state.auto and colors.cyan or colors.yellow)
  statusLine(6, "Funnel: ", state.funnelOn and "ON" or "OFF",
             state.funnelOn and colors.lime or colors.red)

  statusLine(8, "ON  >= ", tostring(state.onAt))
  statusLine(9, "OFF <= ", tostring(state.offAt))

  for _, b in ipairs(buttons) do
    local bg = colors.gray
    if     b.id == "toggle" then bg = state.funnelOn and colors.green or colors.red
    elseif b.id == "auto"   then bg = state.auto and colors.gray or colors.blue
    elseif b.id == "quit"   then bg = colors.red
    elseif b.id:find("Minus") then bg = colors.orange
    elseif b.id:find("Plus")  then bg = colors.lime end
    drawButton(b, bg, colors.white)
  end
  term.setBackgroundColor(colors.black)
end

local function handleClick(x, y)
  for _, b in ipairs(buttons) do
    if x >= b.x and x <= b.x + b.w - 1 and y >= b.y and y <= b.y + b.h - 1 then
      b.action(); return
    end
  end
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------
local function run()
  poll(); draw()
  local timer = os.startTimer(POLL)
  while state.running do
    local e = { os.pullEventRaw() }
    local ev = e[1]
    if ev == "timer" and e[2] == timer then
      poll(); draw()
      timer = os.startTimer(POLL)
    elseif useTouch and ev == "monitor_touch" then
      handleClick(e[3], e[4]); poll(); draw()
    elseif (not useTouch) and ev == "mouse_click" then
      handleClick(e[3], e[4]); poll(); draw()
    elseif ev == "term_resize" or ev == "monitor_resize" then
      draw()
    elseif ev == "terminate" then
      state.running = false
    end
  end
end

local ok, err = pcall(run)

term.redirect(restore)
term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
term.clear(); term.setCursorPos(1, 1)
if not ok then printError(tostring(err)) end
print("vaultguard stopped.")
