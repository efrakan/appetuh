-- lib/recipes.lua : a recipe book for the factory. CC can't read the game's
-- recipe registry, so recipes are recorded here (by you via recipectl, or by
-- the AI when you teach it). Each recipe maps an output item to its inputs and
-- the machine GROUP that makes it (see lib/groups.lua).
--
-- Persisted to /etc/recipes.tbl. Recipe shape:
--   recipes["create:iron_sheet"] = {
--     group = "presses",
--     inputs = { {item="minecraft:iron_ingot", count=1} },
--     note = "press iron ingots into sheets",
--   }

local recipes = {}
local FILE = "/etc/recipes.tbl"

function recipes.load()
  if not fs.exists(FILE) then return {} end
  local h = fs.open(FILE, "r"); local s = h.readAll(); h.close()
  local t = textutils.unserialize(s)
  return type(t) == "table" and t or {}
end

function recipes.save(t)
  local dir = fs.getDir(FILE)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(FILE, "w"); h.write(textutils.serialize(t)); h.close()
end

-- Parse "minecraft:iron_ingot:1, create:andesite_alloy" -> {{item,count}, ...}
-- (count defaults to 1; the optional :N must be the trailing segment).
function recipes.parseInputs(str)
  local out = {}
  for token in tostring(str):gmatch("[^,]+") do
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    if #token > 0 then
      local item, count = token:match("^(.-):(%d+)$")
      if item then out[#out + 1] = { item = item, count = tonumber(count) }
      else out[#out + 1] = { item = token, count = 1 } end
    end
  end
  return out
end

function recipes.inputsToString(inputs)
  local parts = {}
  for _, i in ipairs(inputs or {}) do
    parts[#parts + 1] = i.item .. (i.count and i.count ~= 1 and (":" .. i.count) or "")
  end
  return table.concat(parts, ", ")
end

function recipes.add(output, def) local t = recipes.load(); t[output] = def; recipes.save(t) end
function recipes.remove(output) local t = recipes.load(); t[output] = nil; recipes.save(t) end
function recipes.get(output) return recipes.load()[output] end

function recipes.list()
  local t, out = recipes.load(), {}
  for output, def in pairs(t) do out[#out + 1] = { output = output, def = def } end
  table.sort(out, function(a, b) return a.output < b.output end)
  return out
end

return recipes
