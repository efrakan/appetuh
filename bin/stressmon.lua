-- stressmon.lua : live Create stress monitor for CC:Tweaked.
-- Shows current SU used / total on top and a chart of the last ~5 minutes.
-- Reads a Create Stressometer mirrored onto a CC:C Bridge Target Block.
--
-- Setup: Stressometer --(Display Link)--> Target Block --(modem)--> this computer.
-- Run on the terminal, or attach an advanced monitor for a bigger chart.

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local WINDOW   = 300    -- seconds of history shown across the chart (~5 min)
local TOTAL_SU = 4096   -- hardcoded total stress capacity of your network.
                        -- Set this to your network's max SU.
                        -- The Display Link must be set to
                        -- "Percentage of full capacity".

----------------------------------------------------------------------
-- Peripherals / display
----------------------------------------------------------------------
local function hasTargets()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "create_target" then return true end
  end
  return false
end
if not hasTargets() then
  error("No create_target found. Wire each Display Link to its own Target "
     .. "Block and connect them to this computer.", 0)
end

local monitor = peripheral.find("monitor")
local out = monitor or term.current()
if monitor then monitor.setTextScale(0.5) end
local restore = term.redirect(out)

----------------------------------------------------------------------
-- Read + parse stress from the mirrored Stressometer display
----------------------------------------------------------------------
-- Read the load percentage off the Target Block and derive SU from TOTAL_SU.
local function readStress()
  local p = peripheral.find("create_target")
  if not p then return nil, TOTAL_SU end
  local pct
  for _, line in ipairs(p.dump()) do
    local n = line:gsub(",", ""):match("%d+%.?%d*")
    if n then pct = tonumber(n); break end
  end
  if not pct then return nil, TOTAL_SU end
  return pct / 100 * TOTAL_SU, TOTAL_SU
end

local function fmt(n)
  if not n then return "?" end
  return tostring(math.floor(n + 0.5))
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------
local hist = {}   -- fractions used (0..1+), oldest first

local function loadColor(frac)
  if frac >= 1.0 then return colors.red
  elseif frac >= 0.8 then return colors.orange
  elseif frac >= 0.5 then return colors.yellow
  else return colors.green end
end

local function draw(used, cap)
  local W, H = term.getSize()
  local GUT     = 4              -- left gutter for % labels
  local chartX  = GUT + 1
  local chartW  = W - GUT
  local top     = 3
  local bottom  = H - 1
  local chartH  = bottom - top + 1
  if chartW < 1 or chartH < 1 then return end

  -- keep history no longer than the chart is wide
  while #hist > chartW do table.remove(hist, 1) end

  term.setBackgroundColor(colors.black)
  term.clear()

  -- header
  local frac = (cap and cap > 0) and (used / cap) or 0
  term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  term.write("Stress Monitor")
  term.setCursorPos(1, 2)
  term.setTextColor(loadColor(frac))
  local pct = frac * 100
  local hdr = string.format("%s / %s SU  (%.1f%%)", fmt(used), fmt(cap), pct)
  if used and cap and used > cap then hdr = hdr .. " OVERSTRESSED!" end
  term.write(hdr:sub(1, W))

  -- y-axis labels
  term.setTextColor(colors.lightGray)
  term.setCursorPos(1, top);                          term.write("100%")
  term.setCursorPos(1, top + math.floor((chartH-1)/2)); term.write(" 50%")
  term.setCursorPos(1, bottom);                        term.write("  0%")

  -- faint baseline
  term.setTextColor(colors.gray)
  for x = chartX, W do
    term.setCursorPos(x, bottom)
    term.write("_")
  end

  -- bars, right-aligned so the newest sample is at the right edge
  local n = #hist
  for i = 1, n do
    local f = hist[i]
    local col = chartX + (chartW - n) + (i - 1)
    if col >= chartX then
      local barH = math.floor(math.min(f, 1) * chartH + 0.5)
      term.setBackgroundColor(loadColor(f))
      for y = 0, barH - 1 do
        term.setCursorPos(col, bottom - y)
        term.write(" ")
      end
    end
  end

  -- time axis
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.gray)
  local mins = math.floor(WINDOW / 60)
  term.setCursorPos(chartX, H); term.write("-" .. mins .. "m")
  term.setCursorPos(W - 2, H);  term.write("now")
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------
local function run()
  local W = ({ term.getSize() })[1]
  local interval = math.max(1, WINDOW / math.max(1, W - 4))

  local timer = os.startTimer(0)   -- sample immediately
  while true do
    local ev, a = os.pullEventRaw()
    if ev == "timer" and a == timer then
      local used, cap = readStress()
      if used and cap then
        hist[#hist + 1] = (cap > 0) and (used / cap) or 0
      end
      draw(used, cap)
      timer = os.startTimer(interval)
    elseif ev == "terminate" then
      break
    end
  end
end

local ok, err = pcall(run)

-- cleanup
term.redirect(restore)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(tostring(err)) end
print("stressmon stopped.")
