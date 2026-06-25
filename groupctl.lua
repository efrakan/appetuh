-- groupctl.lua : define and inspect machine groups (rows of identical
-- depots/basins/etc.) used by aifactory and other tools.
local groups = require("lib.groups")

local function usage()
  print("groupctl - manage machine groups")
  print("Usage:")
  print("  groupctl list                         show groups + member counts")
  print("  groupctl show <name>                  list a group's members")
  print("  groupctl scan [substr]                list connected peripherals")
  print("  groupctl overlaps                     show groups that share machines")
  print("  groupctl add <name> range <prefix> <from> <to>")
  print("  groupctl add <name> contains <substr> [--live]")
  print("  groupctl add <name> pattern <luapattern> [--live]")
  print("  groupctl add <name> item <itemid> [--live]   inventories holding itemid")
  print("  groupctl add <name> list <peri> [peri ...]")
  print("    contains/pattern/item: default = snapshot now; --live = re-match each use")
  print("  groupctl desc <name> <text...>        describe what the group does (the AI reads this)")
  print("  groupctl remove <name>")
  print("Examples:")
  print("  groupctl add presses range create:depot_ 3 12")
  print("  groupctl add mixers contains basin")
  print("  groupctl desc presses \"depots under mechanical presses: press metal ingots into sheets\"")
end

local args = { ... }
local cmd = table.remove(args, 1)

if cmd == "list" then
  local gs = groups.list()
  if #gs == 0 then print("No groups defined.") end
  for _, g in ipairs(gs) do
    print(("%-16s %d member(s)"):format(g.name, #g.members))
    if g.def.desc then print("    " .. g.def.desc) end
  end

elseif cmd == "show" then
  local name = args[1]
  if not name then usage(); return end
  local def = groups.load()[name]
  if def and def.desc then print("desc: " .. def.desc) end
  local members = groups.members(name)
  if #members == 0 then print("(no connected members - undefined or all offline)") end
  for _, m in ipairs(members) do print("  " .. m) end

elseif cmd == "desc" then
  local name = args[1]
  if not name or not args[2] then usage(); return end
  local text = {}
  for i = 2, #args do text[#text + 1] = args[i] end
  if groups.describe(name, table.concat(text, " ")) then
    print("Set description for " .. name)
  else
    print("No such group: " .. name)
  end

elseif cmd == "scan" then
  local filter = args[1]
  for _, n in ipairs(peripheral.getNames()) do
    if not filter or n:find(filter, 1, true) then
      print(("%s  (%s)"):format(n, peripheral.getType(n)))
    end
  end

elseif cmd == "add" then
  local name, kind = args[1], args[2]
  if not name or not kind then usage(); return end
  -- --live keeps the rule (re-matches each use); default snapshots the
  -- current matches into a fixed member list.
  local live = false
  for i = 3, #args do if args[i] == "--live" then live = true end end

  local def
  if kind == "range" then
    local prefix, from, to = args[3], tonumber(args[4]), tonumber(args[5])
    if not prefix or not from or not to then usage(); return end
    def = { prefix = prefix, from = from, to = to }   -- always a fixed range
  elseif kind == "list" then
    local members = {}
    for i = 3, #args do
      if args[i] ~= "--live" then members[#members + 1] = args[i] end
    end
    if #members == 0 then usage(); return end
    def = { members = members }                       -- always explicit
  elseif kind == "contains" or kind == "pattern" or kind == "item" then
    local val = args[3]
    if not val then usage(); return end
    local rule
    if kind == "contains" then rule = { contains = val }
    elseif kind == "pattern" then rule = { pattern = val }
    else rule = { item = val } end
    if live then
      def = rule                                      -- dynamic: re-match each use
    else
      def = { members = groups.resolve(rule) }        -- snapshot: freeze current matches
      if #def.members == 0 then
        print("Nothing matched right now, so nothing was added.")
        print("(Add --live to store the rule and match machines as they appear.)")
        return
      end
    end
  else
    usage(); return
  end

  groups.define(name, def)
  local members = groups.resolve(def)
  local mode = live and "live" or "snapshot"
  if kind == "range" then mode = "range" elseif kind == "list" then mode = "explicit" end
  print(("Defined '%s' (%s) -> %d member(s):"):format(name, mode, #members))
  for _, m in ipairs(members) do print("  " .. m) end
  -- warn if this group shares machines with another (the usual "both groups
  -- match all basins" mistake: a contains/pattern rule isn't specific enough)
  local mine = {}; for _, m in ipairs(members) do mine[m] = true end
  for _, g in ipairs(groups.list()) do
    if g.name ~= name then
      local shared = 0
      for _, m in ipairs(g.members) do if mine[m] then shared = shared + 1 end end
      if shared > 0 then
        printError(("WARNING: %d machine(s) also in group '%s' - groups overlap."):format(shared, g.name))
        printError("Use 'list' or 'range' to give each group its own machines.")
      end
    end
  end

elseif cmd == "overlaps" then
  local gs = groups.list()
  local found = false
  for i = 1, #gs do
    local set = {}; for _, m in ipairs(gs[i].members) do set[m] = true end
    for j = i + 1, #gs do
      local shared = 0
      for _, m in ipairs(gs[j].members) do if set[m] then shared = shared + 1 end end
      if shared > 0 then
        found = true
        print(("%s <-> %s : %d shared machine(s)"):format(gs[i].name, gs[j].name, shared))
      end
    end
  end
  if not found then print("No overlaps - all groups are disjoint.") end

elseif cmd == "remove" then
  if not args[1] then usage(); return end
  groups.remove(args[1])
  print("Removed group: " .. args[1])

else
  usage()
end
