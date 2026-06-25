-- stockkeeper.lua : keep several items within min/max by toggling a redstone
-- output per rule (e.g. a brass-funnel filler). Fills below max, stops at max,
-- resumes once the count drops to min. A redstone signal DISABLES a funnel, so
-- output is ON while "full" and OFF while "filling". Edit RULES below.

local POLL = 2
local RULES = {
  { item = "create:crimsite", min = 200000, max = 210000, side = "bottom", label = "crimsite" },
  -- { item = "minecraft:iron_ingot", min = 1000, max = 5000, side = "left",  label = "iron" },
  -- inv = "minecraft:chest_3"   -- optional: count only this inventory
}

local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(0.5) end
local dev = monitor or term.current()

local function count(rule)
  local total = 0
  local names = rule.inv and { rule.inv } or peripheral.getNames()
  for _, name in ipairs(names) do
    if rule.inv or peripheral.getType(name) == "inventory" then
      local inv = peripheral.wrap(name)
      if inv and inv.list then
        local ok, list = pcall(inv.list)
        if ok and list then
          for _, st in pairs(list) do
            if st.name == rule.item then total = total + st.count end
          end
        end
      end
    end
  end
  return total
end

-- initialise filling state from current outputs (funnel-on == redstone-off)
for _, r in ipairs(RULES) do r.filling = not redstone.getOutput(r.side) end

local function draw()
  dev.setBackgroundColor(colors.black); dev.clear()
  local W, H = dev.getSize()
  dev.setCursorPos(1, 1); dev.setTextColor(colors.white); dev.write("STOCK KEEPER")
  local y = 3
  for _, r in ipairs(RULES) do
    if y > H then break end
    dev.setCursorPos(1, y); dev.setTextColor(colors.white)
    dev.write((r.label or r.item):sub(1, 14))
    dev.setCursorPos(16, y); dev.setTextColor(colors.lightGray)
    dev.write(("%d (%d-%d)"):format(r.count or 0, r.min, r.max))
    dev.setCursorPos(math.max(16, W - 8), y)
    if r.filling then dev.setTextColor(colors.lime); dev.write("FILLING")
    else dev.setTextColor(colors.red); dev.write("FULL") end
    y = y + 1
  end
  dev.setBackgroundColor(colors.black)
end

while true do
  for _, r in ipairs(RULES) do
    r.count = count(r)
    if r.filling and r.count >= r.max then r.filling = false
    elseif (not r.filling) and r.count <= r.min then r.filling = true end
    redstone.setOutput(r.side, not r.filling)   -- ON disables the funnel
  end
  draw()
  sleep(POLL)
end
