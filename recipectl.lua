-- recipectl.lua : manage the factory recipe book used by aifactory.
local recipes = require("lib.recipes")

local function usage()
  print("recipectl - manage factory recipes")
  print("Usage:")
  print("  recipectl list")
  print("  recipectl show <output>")
  print("  recipectl add <output> group <group> in <item[:n]> [item[:n] ...] [note <text...>]")
  print("  recipectl remove <output>")
  print("Example:")
  print("  recipectl add create:iron_sheet group presses in minecraft:iron_ingot note press iron into sheets")
end

local args = { ... }
local cmd = table.remove(args, 1)

local function indexOf(kw, from)
  for i = (from or 1), #args do if args[i] == kw then return i end end
end

if cmd == "list" then
  local rs = recipes.list()
  if #rs == 0 then print("No recipes defined.") end
  for _, r in ipairs(rs) do
    print(("%s  (group: %s)"):format(r.output, r.def.group or "?"))
    print("    in: " .. recipes.inputsToString(r.def.inputs))
    if r.def.note then print("    " .. r.def.note) end
  end

elseif cmd == "show" then
  local r = recipes.get(args[1] or "")
  if not r then print("No such recipe: " .. tostring(args[1])); return end
  print("output: " .. args[1])
  print("group:  " .. (r.group or "?"))
  print("inputs: " .. recipes.inputsToString(r.inputs))
  if r.note then print("note:   " .. r.note) end

elseif cmd == "add" then
  local output = args[1]
  local gi, ii, ni = indexOf("group"), indexOf("in"), indexOf("note")
  if not output or not gi or not ii then usage(); return end
  local group = args[gi + 1]
  local inEnd = (ni and ni - 1) or #args
  local inputs = {}
  for i = ii + 1, inEnd do
    for _, parsed in ipairs(recipes.parseInputs(args[i])) do inputs[#inputs + 1] = parsed end
  end
  local note
  if ni then
    local t = {}
    for i = ni + 1, #args do t[#t + 1] = args[i] end
    note = #t > 0 and table.concat(t, " ") or nil
  end
  recipes.add(output, { group = group, inputs = inputs, note = note })
  print(("Recipe '%s' -> via %s from %s"):format(output, group or "?", recipes.inputsToString(inputs)))

elseif cmd == "remove" then
  if not args[1] then usage(); return end
  recipes.remove(args[1]); print("Removed recipe: " .. args[1])

else
  usage()
end
