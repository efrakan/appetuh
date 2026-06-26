-- lib/groups.lua : named groups of peripherals, so you can address a whole row
-- of identical machines (depots, basins, ...) at once instead of by number.
--
-- A group definition is one of:
--   { members = {"create:depot_3", "create:depot_4"} }   explicit list
--   { prefix = "create:depot_", from = 3, to = 10 }       numeric range (inclusive)
--   { pattern = "create:depot_%d+" }                      Lua pattern over names
--   { contains = "depot" }                                plain substring of name
-- Definitions are resolved against the currently-connected peripherals each
-- time, so missing machines are skipped and pattern/contains pick up new ones.
--
-- Persisted to /etc/groups.tbl (shared by any program that requires this lib).

local groups = {}
local FILE = "/etc/groups.tbl"

local function itemMatches(id, query)
  if not query or query == "" then return true end
  local q = query:lower():gsub("%s+", "_")
  return id:lower():find(q, 1, true) ~= nil
end

-- Every connected inventory that currently holds an item matching `query`.
function groups.byItem(query)
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "inventory") then
      local inv = peripheral.wrap(n)
      local ok, list = pcall(inv.list)
      if ok and list then
        for _, st in pairs(list) do
          if itemMatches(st.name, query) then out[#out + 1] = n; break end
        end
      end
    end
  end
  table.sort(out)
  return out
end

function groups.load()
  if not fs.exists(FILE) then return {} end
  local h = fs.open(FILE, "r"); local s = h.readAll(); h.close()
  local t = textutils.unserialize(s)
  return type(t) == "table" and t or {}
end

function groups.save(t)
  local dir = fs.getDir(FILE)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(FILE, "w"); h.write(textutils.serialize(t)); h.close()
end

function groups.define(name, def)
  local t = groups.load(); t[name] = def; groups.save(t)
end

function groups.remove(name)
  local t = groups.load(); t[name] = nil; groups.save(t)
end

-- Attach a human/AI-readable description of what this group of machines does.
function groups.describe(name, text)
  local t = groups.load()
  if not t[name] then return false end
  t[name].desc = text; groups.save(t); return true
end

-- Resolve a definition to the list of currently-connected peripheral names.
function groups.resolve(def)
  local out, have = {}, {}
  for _, n in ipairs(peripheral.getNames()) do have[n] = true end
  if def.members then
    for _, n in ipairs(def.members) do if have[n] then out[#out + 1] = n end end
  elseif def.prefix and def.from and def.to then
    for i = def.from, def.to do
      local n = def.prefix .. i
      if have[n] then out[#out + 1] = n end
    end
  elseif def.pattern then
    for _, n in ipairs(peripheral.getNames()) do
      if n:find(def.pattern) then out[#out + 1] = n end
    end
  elseif def.contains then
    for _, n in ipairs(peripheral.getNames()) do
      if n:find(def.contains, 1, true) then out[#out + 1] = n end
    end
  elseif def.item then
    return groups.byItem(def.item)   -- live: re-scans contents each call
  end
  table.sort(out)
  return out
end

-- Members of a named group (resolved). Returns {} for unknown groups.
function groups.members(name)
  local def = groups.load()[name]
  if not def then return {} end
  return groups.resolve(def)
end

-- All groups with resolved members: { {name, def, members={...}}, ... }
function groups.list()
  local t, out = groups.load(), {}
  for name, def in pairs(t) do
    out[#out + 1] = { name = name, def = def, members = groups.resolve(def) }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

return groups
