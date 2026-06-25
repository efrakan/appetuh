-- factory.lua : multi-panel Create dashboard. Each CC:C Bridge Target Block
-- becomes a row: label + value + load bar (green->orange->red), with alerts.
-- Auto-discovers all create_target peripherals, or set PANELS for custom
-- labels / max values / units.

local REFRESH   = 2
local ALERT_PCT = 90
local PANELS = {
  -- { target = "create_target_0", label = "Main stress", max = 100,  unit = "%"  },
  -- { target = "create_target_1", label = "Steam",       max = 1000, unit = "mb" },
}

local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(0.5) end
local dev = monitor or term.current()

local function discover()
  local ps = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "create_target" then
      ps[#ps + 1] = { target = name, label = name, max = nil, unit = "" }
    end
  end
  return ps
end

local panels = (#PANELS > 0) and PANELS or discover()
local rmax = {}   -- running max per panel (when no fixed max given)

local function readVal(name)
  local p = peripheral.wrap(name)
  if not p then return nil end
  local ok, lines = pcall(p.dump)
  if not ok or not lines then return nil end
  for _, line in ipairs(lines) do
    local n = line:gsub(",", ""):match("%d+%.?%d*")
    if n then return tonumber(n) end
  end
  return nil
end

local function loadColor(pct)
  if pct >= ALERT_PCT then return colors.red
  elseif pct >= 70 then return colors.orange
  elseif pct >= 40 then return colors.yellow
  else return colors.green end
end

local function draw()
  dev.setBackgroundColor(colors.black); dev.clear()
  local W, H = dev.getSize()
  dev.setCursorPos(1, 1); dev.setTextColor(colors.white); dev.write("FACTORY DASHBOARD")
  if #panels == 0 then
    dev.setCursorPos(1, 3); dev.setTextColor(colors.red)
    dev.write("No create_target peripherals found.")
    return
  end
  local y = 3
  for _, panel in ipairs(panels) do
    if y > H then break end
    local v = readVal(panel.target)
    local maxv = panel.max
    if not maxv then
      rmax[panel.target] = math.max(rmax[panel.target] or 1, v or 1)
      maxv = rmax[panel.target]
    end
    local pct = (v and maxv > 0) and math.min(100, v / maxv * 100) or 0

    dev.setCursorPos(1, y); dev.setTextColor(colors.white)
    dev.write((("%-14s %s%s"):format(
      panel.label:sub(1, 14),
      v and tostring(v) or "?",
      panel.unit ~= "" and (" " .. panel.unit) or "")):sub(1, W))
    if pct >= ALERT_PCT then
      dev.setTextColor(colors.red); dev.setCursorPos(W - 1, y); dev.write("!!")
    end

    y = y + 1
    if y > H then break end
    local barW = W - 2
    local fill = math.floor(pct / 100 * barW + 0.5)
    dev.setCursorPos(1, y)
    dev.setBackgroundColor(loadColor(pct)); dev.write(string.rep(" ", fill))
    dev.setBackgroundColor(colors.gray);    dev.write(string.rep(" ", barW - fill))
    dev.setBackgroundColor(colors.black)
    y = y + 2
  end
end

while true do
  draw()
  sleep(REFRESH)
end
