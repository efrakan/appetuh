-- aifactory.lua : natural-language control of a Create base via an LLM.
-- Switch BACKEND between "gemini" (Google AI Studio) and "claude" (Anthropic,
-- Sonnet 4.6 with low thinking, using a Claude OAuth token). You prompt it
-- ("grab some iron nuggets, press them into sheets and drop them to me") and it
-- uses tools to inspect your networked inventories and move items between them.
--
-- Wiring: this computer is on a wired-modem network with all your Create
-- inventories (item vaults, depots, basins, chests). Put one Item Vault next
-- to/with this computer that has an ALWAYS-ON funnel ejecting to you, and set
-- DROP_TARGET to that vault's peripheral name -- the AI drops items there.

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local BACKEND     = "claude"   -- "gemini" (Google AI Studio) or "claude" (Anthropic)

-- Google AI Studio
local API_KEY     = "AQ.XYZ"
local MODEL       = "gemini-3.1-flash-lite"

-- Anthropic (Claude). Use a Claude OAuth access token (e.g. from
-- `ant auth print-credentials --access-token`, or your Claude Code login).
-- It goes on Authorization: Bearer + the oauth beta header. Tokens are
-- short-lived, so refresh it when requests start failing with 401.
local CLAUDE_TOKEN    = "sk-ant-oat01-XYZ"
local CLAUDE_MODEL    = "claude-sonnet-4-6"
local CLAUDE_THINKING = true   -- low adaptive thinking (effort stays "low")

local DROP_TARGET = 'create:item_vault_7'   -- e.g. "create:item_vault_0"; the player-drop vault
local MAX_ROUNDS  = 80     -- max tool-call rounds per request

-- Free-form notes injected into the system prompt. THIS is how the AI learns
-- your factory layout -- describe which inventory feeds which machine, etc.
local USER_NOTES = [[Please refer to groups.]]

----------------------------------------------------------------------
local GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/"
  .. MODEL .. ":generateContent?key=" .. API_KEY
local CLAUDE_ENDPOINT = "https://api.anthropic.com/v1/messages"

if not http then error("HTTP API is disabled in the CC config.", 0) end
if BACKEND == "gemini" and API_KEY:find("PUT%-YOUR") then
  error("Set API_KEY at the top of the file.", 0)
end
if BACKEND == "claude" and CLAUDE_TOKEN:find("PUT%-YOUR") then
  error("Set CLAUDE_TOKEN at the top of the file.", 0)
end

-- Optional machine groups (lib/groups.lua). Degrades gracefully if absent.
local okGroups, groups = pcall(require, "lib.groups")
if not okGroups then groups = nil end

-- Optional recipe book (lib/recipes.lua).
local okRecipes, recipes = pcall(require, "lib.recipes")
if not okRecipes then recipes = nil end

----------------------------------------------------------------------
-- Monitor activity view (optional)
----------------------------------------------------------------------
local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(0.5) end
local logLines, status = {}, "idle"

local function drawMonitor()
  if not monitor then return end
  monitor.setBackgroundColor(colors.black); monitor.clear()
  local W, H = monitor.getSize()
  monitor.setCursorPos(1, 1); monitor.setTextColor(colors.white)
  monitor.write(("AI FACTORY  [%s]"):format(status):sub(1, W))
  local rows = H - 2
  local startIdx = math.max(1, #logLines - rows + 1)
  local y = 3
  for i = startIdx, #logLines do
    monitor.setCursorPos(1, y); monitor.setTextColor(logLines[i].color or colors.white)
    monitor.write(logLines[i].text:sub(1, W))
    y = y + 1
  end
end

-- log to monitor only
local function mlog(text, color)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then logLines[#logLines + 1] = { text = line, color = color } end
  end
  while #logLines > 300 do table.remove(logLines, 1) end
  drawMonitor()
end

-- print to terminal AND log to monitor
local function out(text, color)
  term.setTextColor(color or colors.white); print(text); term.setTextColor(colors.white)
  mlog(text, color)
end

local function setStatus(s) status = s; drawMonitor() end

local function summarize(name, result)
  if result.error then return "  ! " .. name .. ": " .. tostring(result.error), colors.red end
  if name == "move_items" then
    return ("  moved %d %s  %s -> %s"):format(result.moved or 0, result.item or "", result.from or "", result.to or ""), colors.lime
  elseif name == "drop_to_player" then
    return ("  dropped %d %s to player"):format(result.dropped or 0, result.item or ""), colors.lime
  elseif name == "count_item" then
    return ("  %s: %d total"):format(result.item or "", result.total or 0), colors.lightBlue
  elseif name == "list_inventories" then
    return ("  %d inventories"):format(result.inventories and #result.inventories or 0), colors.lightGray
  elseif name == "wait" then
    return ("  waited %ds"):format(result.waited or 0), colors.gray
  elseif name == "list_groups" then
    return ("  %d groups"):format(result.groups and #result.groups or 0), colors.lightGray
  elseif name == "group_distribute" then
    return ("  fed %d %s across %s (%d machines)"):format(result.moved or 0, result.item or "", result.group or "", result.members or 0), colors.lime
  elseif name == "group_collect" then
    return ("  collected %d %s from %s"):format(result.collected or 0, result.item or "", result.group or ""), colors.lime
  elseif name == "group_count" then
    return ("  %s in %s: %d (%d machines)"):format(result.item or "", result.group or "", result.total or 0, result.members or 0), colors.lightBlue
  elseif name == "list_recipes" then
    return ("  %d recipes"):format(result.recipes and #result.recipes or 0), colors.lightGray
  elseif name == "get_recipe" then
    return ("  recipe %s: %s via %s"):format(result.output or "", result.inputs_text or "?", result.group or "?"), colors.lightBlue
  elseif name == "add_recipe" then
    return ("  learned %s <- %s via %s"):format(result.output or "", result.inputs or "", result.group or ""), colors.lime
  elseif name == "forget_recipe" then
    return ("  forgot %s"):format(result.removed or ""), colors.gray
  end
  return "  " .. name .. " done", colors.lightGray
end

----------------------------------------------------------------------
-- Inventory helpers
----------------------------------------------------------------------
local function invNames()
  local t = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "inventory") then t[#t + 1] = n end
  end
  return t
end

local function matches(id, query)
  if not query or query == "" then return true end
  local q = query:lower():gsub("%s+", "_")
  return id:lower():find(q, 1, true) ~= nil
end

-- Move up to `limit` (nil = unlimited) items matching `item` from -> to.
-- Returns moved count and (if any push failed) the last error string.
local function moveCore(from, to, item, limit)
  local inv = peripheral.wrap(from)
  if not inv or not inv.list then return 0, "no such inventory: " .. tostring(from) end
  local ok, list = pcall(inv.list)
  if not ok or not list then return 0 end
  local moved, remaining, perr = 0, limit, nil
  for slot, st in pairs(list) do
    if remaining ~= nil and remaining <= 0 then break end
    if matches(st.name, item) then
      local pok, m = pcall(inv.pushItems, to, slot, remaining)
      if pok then
        moved = moved + (m or 0)
        if remaining ~= nil then remaining = remaining - (m or 0) end
      else
        perr = tostring(m)   -- e.g. target not on this inventory's network
      end
    end
  end
  return moved, perr
end

local function isConnected(name)
  for _, n in ipairs(invNames()) do if n == name then return true end end
  return false
end

-- Signature of an inventory's contents, used to detect the SAME physical
-- inventory exposed under two peripheral names (so we don't count it twice).
local function invSig(inv, list)
  local sz = 0; pcall(function() sz = inv.size() end)
  local keys = {}
  for slot, st in pairs(list) do keys[#keys + 1] = slot .. ":" .. st.name .. ":" .. st.count end
  table.sort(keys)
  return sz .. "|" .. table.concat(keys, ",")
end

----------------------------------------------------------------------
-- Tools the model can call
----------------------------------------------------------------------
local tools = {}

function tools.list_inventories()
  local out = {}
  for _, n in ipairs(invNames()) do
    out[#out + 1] = { name = n, type = peripheral.getType(n) }
  end
  return { inventories = out, drop_target = DROP_TARGET }
end

function tools.count_item(a)
  local item = a.item or ""
  local total, locs, seen = 0, {}, {}
  for _, n in ipairs(invNames()) do
    local inv = peripheral.wrap(n)
    local ok, list = pcall(inv.list)
    if ok and list then
      local sig = invSig(inv, list)
      if not seen[sig] then           -- skip the same inventory seen under another name
        seen[sig] = true
        local c = 0
        for _, st in pairs(list) do if matches(st.name, item) then c = c + st.count end end
        if c > 0 then locs[#locs + 1] = { inventory = n, count = c }; total = total + c end
      end
    end
  end
  return { item = item, total = total, locations = locs }
end

function tools.move_items(a)
  if not a.from or not a.to then return { error = "from and to are required" } end
  if not isConnected(a.to) then return { error = "'" .. tostring(a.to) .. "' is not a connected inventory" } end
  local moved, err = moveCore(a.from, a.to, a.item, a.count)
  if moved == 0 and err then
    return { error = err .. " (source and target must share ONE wired network)" }
  end
  return { moved = moved, from = a.from, to = a.to, item = a.item or "any" }
end

function tools.drop_to_player(a)
  if not DROP_TARGET then return { error = "DROP_TARGET is not configured" } end
  if not isConnected(DROP_TARGET) then
    return { error = "drop target '" .. DROP_TARGET .. "' is not a connected inventory" }
  end
  local item = a.item or ""
  local remaining = a.count
  local dropped, lastErr = 0, nil
  for _, n in ipairs(invNames()) do
    if n ~= DROP_TARGET and (remaining == nil or remaining > 0) then
      local m, e = moveCore(n, DROP_TARGET, item, remaining)
      dropped = dropped + m
      if e then lastErr = e end
      if remaining ~= nil then remaining = remaining - m end
    end
  end
  if dropped == 0 and lastErr then
    return { dropped = 0, item = item,
      error = "could not reach '" .. DROP_TARGET .. "': " .. lastErr ..
              " -- ensure the drop vault and your storage are on the SAME wired modem network" }
  end
  return { dropped = dropped, item = item }
end

-- Wait so Create machines can finish processing before collecting outputs.
function tools.wait(a)
  local s = tonumber(a.seconds) or 0
  if s < 0 then s = 0 end
  if s > 600 then s = 600 end
  sleep(s)
  return { waited = s }
end

-- Group tools: act on a whole row of identical machines at once.
function tools.list_groups()
  if not groups then return { groups = {} } end
  local out = {}
  for _, g in ipairs(groups.list()) do
    out[#out + 1] = { name = g.name, members = #g.members, description = g.def.desc }
  end
  return { groups = out }
end

function tools.group_count(a)
  if not groups then return { error = "groups not available" } end
  local members = groups.members(a.group or "")
  if #members == 0 then return { error = "group '" .. tostring(a.group) .. "' has no connected members" } end
  local total, seen = 0, {}
  for _, m in ipairs(members) do
    local inv = peripheral.wrap(m)
    local ok, list = pcall(inv.list)
    if ok and list then
      local sig = invSig(inv, list)
      if not seen[sig] then
        seen[sig] = true
        for _, st in pairs(list) do if matches(st.name, a.item) then total = total + st.count end end
      end
    end
  end
  return { group = a.group, item = a.item, total = total, members = #members }
end

function tools.group_distribute(a)
  if not groups then return { error = "groups not available" } end
  if not a.group or not a.from then return { error = "group and from are required" } end
  local members = groups.members(a.group)
  if #members == 0 then return { error = "group '" .. a.group .. "' has no connected members" } end
  local per, moved = a.per or 1, 0
  for _, m in ipairs(members) do
    if m ~= a.from then moved = moved + (moveCore(a.from, m, a.item, per)) end
  end
  return { moved = moved, group = a.group, members = #members, item = a.item or "any" }
end

function tools.group_collect(a)
  if not groups then return { error = "groups not available" } end
  if not a.group or not a.to then return { error = "group and to are required" } end
  local members = groups.members(a.group)
  if #members == 0 then return { error = "group '" .. a.group .. "' has no connected members" } end
  local remaining, moved = a.count, 0
  for _, m in ipairs(members) do
    if m ~= a.to and (remaining == nil or remaining > 0) then
      local mv = moveCore(m, a.to, a.item, remaining)
      moved = moved + mv
      if remaining ~= nil then remaining = remaining - mv end
    end
  end
  return { collected = moved, group = a.group, item = a.item or "any" }
end

-- Recipe book: what to make, from what, on which group.
function tools.list_recipes()
  if not recipes then return { recipes = {} } end
  local out = {}
  for _, r in ipairs(recipes.list()) do
    out[#out + 1] = {
      output = r.output, group = r.def.group,
      inputs = recipes.inputsToString(r.def.inputs), note = r.def.note,
    }
  end
  return { recipes = out }
end

function tools.get_recipe(a)
  if not recipes then return { error = "recipes not available" } end
  local r = recipes.get(a.output or "")
  if not r then return { error = "no recipe for '" .. tostring(a.output) .. "'" } end
  return { output = a.output, group = r.group, note = r.note,
           inputs = r.inputs, inputs_text = recipes.inputsToString(r.inputs) }
end

function tools.add_recipe(a)
  if not recipes then return { error = "recipes not available" } end
  if not a.output or not a.group then return { error = "output and group are required" } end
  local inputs = recipes.parseInputs(a.inputs or "")
  recipes.add(a.output, { group = a.group, inputs = inputs, note = a.note })
  return { output = a.output, group = a.group, inputs = recipes.inputsToString(inputs) }
end

function tools.forget_recipe(a)
  if not recipes then return { error = "recipes not available" } end
  recipes.remove(a.output or "")
  return { removed = a.output }
end

-- One canonical tool spec; each backend renders it into its own schema format.
-- props: { {name, type, desc, required} }   (type: "string" | "integer")
local TOOLSPEC = {
  { name = "list_inventories",
    desc = "List every connected inventory (peripheral name + block type) and the drop-target vault name.",
    props = {} },
  { name = "count_item",
    desc = "Count how much of an item exists across all inventories and where.",
    props = { { name = "item", type = "string", required = true,
                desc = "item id or fragment, e.g. iron_nugget or create:iron_sheet" } } },
  { name = "move_items",
    desc = "Move items matching `item` (or all if omitted) from one inventory to another, up to `count`.",
    props = {
      { name = "from",  type = "string",  required = true, desc = "source inventory peripheral name" },
      { name = "to",    type = "string",  required = true, desc = "destination inventory peripheral name" },
      { name = "item",  type = "string",  desc = "item id/fragment to move; omit to move everything" },
      { name = "count", type = "integer", desc = "max items to move; omit for all" } } },
  { name = "drop_to_player",
    desc = "Give items to the player by moving them into the drop-target vault (its always-on funnel ejects to the player).",
    props = {
      { name = "item",  type = "string",  required = true, desc = "item id/fragment to give" },
      { name = "count", type = "integer", desc = "how many; omit for all available" } } },
  { name = "wait",
    desc = "Pause for some seconds, e.g. to let Create machines finish processing before collecting their outputs.",
    props = { { name = "seconds", type = "integer", required = true, desc = "seconds to wait (max 600)" } } },
  { name = "list_groups",
    desc = "List defined machine groups (a group is a row of identical machines like depots/basins addressed together).",
    props = {} },
  { name = "group_count",
    desc = "Count an item across all machines in a group.",
    props = {
      { name = "group", type = "string", required = true, desc = "group name (from list_groups)" },
      { name = "item",  type = "string", desc = "item id/fragment; omit for any" } } },
  { name = "group_distribute",
    desc = "Feed items into every machine of a group, e.g. put one ingot on each depot in a press row.",
    props = {
      { name = "group", type = "string",  required = true, desc = "group name" },
      { name = "from",  type = "string",  required = true, desc = "source inventory peripheral name" },
      { name = "item",  type = "string",  required = true, desc = "item id/fragment to place" },
      { name = "per",   type = "integer", desc = "amount to put in each machine (default 1)" } } },
  { name = "group_collect",
    desc = "Collect items from every machine of a group into one destination inventory.",
    props = {
      { name = "group", type = "string",  required = true, desc = "group name" },
      { name = "to",    type = "string",  required = true, desc = "destination inventory peripheral name" },
      { name = "item",  type = "string",  desc = "item id/fragment; omit for all" },
      { name = "count", type = "integer", desc = "max total to collect; omit for all" } } },
  { name = "list_recipes",
    desc = "List known recipes: output item, its machine group, and inputs. Check here before crafting.",
    props = {} },
  { name = "get_recipe",
    desc = "Get the full recipe for an output item (inputs + which group makes it).",
    props = { { name = "output", type = "string", required = true, desc = "output item id" } } },
  { name = "add_recipe",
    desc = "Record a recipe so you remember it next time. Use this whenever the user teaches you how to make something.",
    props = {
      { name = "output", type = "string", required = true, desc = "output item id, e.g. create:iron_sheet" },
      { name = "group",  type = "string", required = true, desc = "machine group that makes it (from list_groups)" },
      { name = "inputs", type = "string", required = true, desc = "comma-separated inputs, each item[:count], e.g. minecraft:iron_ingot, create:zinc_ingot:2" },
      { name = "note",   type = "string", desc = "short description of the process" } } },
  { name = "forget_recipe",
    desc = "Delete a recorded recipe.",
    props = { { name = "output", type = "string", required = true, desc = "output item id" } } },
}

-- Gemini function_declarations (uppercase types; omit parameters when none).
local function geminiTools()
  local out = {}
  for _, t in ipairs(TOOLSPEC) do
    local decl = { name = t.name, description = t.desc }
    if #t.props > 0 then
      local properties, required = {}, {}
      for _, p in ipairs(t.props) do
        properties[p.name] = { type = p.type:upper(), description = p.desc }
        if p.required then required[#required + 1] = p.name end
      end
      decl.parameters = { type = "OBJECT", properties = properties }
      if #required > 0 then decl.parameters.required = required end
    end
    out[#out + 1] = decl
  end
  return out
end

-- Anthropic tools (JSON-schema input_schema; needs a non-empty properties
-- object, so no-arg tools get an ignored optional field to avoid emitting {}).
local function claudeTools()
  local out = {}
  for _, t in ipairs(TOOLSPEC) do
    local properties, required = {}, {}
    for _, p in ipairs(t.props) do
      properties[p.name] = { type = p.type, description = p.desc }
      if p.required then required[#required + 1] = p.name end
    end
    if next(properties) == nil then
      properties._ = { type = "string", description = "unused; leave empty" }
    end
    local schema = { type = "object", properties = properties }
    if #required > 0 then schema.required = required end
    out[#out + 1] = { name = t.name, description = t.desc, input_schema = schema }
  end
  return out
end

----------------------------------------------------------------------
-- System prompt
----------------------------------------------------------------------
local GROUP_LINE = "Machine groups are not available."
if groups then
  local ls = groups.list()
  if #ls > 0 then
    local lines = { "Machine groups (use these EXACT names; pick by description, not by guessing):" }
    for _, g in ipairs(ls) do
      lines[#lines + 1] = ("- %s (%d machines)%s"):format(
        g.name, #g.members, g.def.desc and (": " .. g.def.desc) or " [no description set]")
    end
    GROUP_LINE = table.concat(lines, "\n")
  else
    GROUP_LINE = "No machine groups are defined yet."
  end
end

local RECIPE_LINE = "Recipe book not available."
if recipes then
  local rs = recipes.list()
  if #rs > 0 then
    local lines = { "Recipe book (output <- inputs via group):" }
    for _, r in ipairs(rs) do
      lines[#lines + 1] = ("- %s <- %s via %s"):format(
        r.output, recipes.inputsToString(r.def.inputs), r.def.group or "?")
    end
    RECIPE_LINE = table.concat(lines, "\n")
  else
    RECIPE_LINE = "No recipes recorded yet."
  end
end

local SYSTEM = table.concat({
  "You control a Minecraft Create factory through ComputerCraft. Items live in",
  "networked inventories (Create item vaults, depots, basins, chests). You have",
  "tools to list inventories, count items, move items between inventories, and",
  "drop items to the player.",
  "",
  "GROUPS: rows of identical machines (e.g. all the depots under a press row) are",
  "addressed together as a named group. Prefer group_distribute (put items into",
  "every machine of a group) and group_collect (gather outputs from every machine)",
  "over moving to individual inventories one by one. Use list_groups to see them.",
  GROUP_LINE,
  "",
  "RECIPES: you have a recipe book (list_recipes / get_recipe). To make an item,",
  "look up its recipe to know the exact inputs and which group makes it, then",
  "group_distribute the inputs to that group, wait, and group_collect the output.",
  "If the user teaches you a new recipe, call add_recipe so you remember it.",
  RECIPE_LINE,
  "",
  "To GIVE items to the player, call drop_to_player -- there is an Item Vault",
  "named '" .. tostring(DROP_TARGET) .. "' beside the controller with an always-on",
  "funnel that ejects whatever lands in it to the player.",
  "",
  "To CRAFT/PROCESS, move the input items into the correct machine's input",
  "inventory; the Create machines run automatically; processing is NOT instant,",
  "so use the wait tool (a few seconds) before collecting the outputs from their",
  "output inventory. Use the operator notes below to know which",
  "inventory feeds which machine. Always call list_inventories first if unsure.",
  "Use precise Minecraft/Create item ids (e.g. minecraft:iron_nugget,",
  "create:iron_sheet for iron plates). Be concise; confirm what you did.",
  "",
  "Do remember that deployers are instant and do not require waiting.",
  "",
  "OPERATOR NOTES:",
  USER_NOTES,
}, "\n")

----------------------------------------------------------------------
-- HTTP helper: POST JSON, return parsed table or nil,err (reads error body)
----------------------------------------------------------------------
local function postJSON(url, bodyTable, headers)
  local body = textutils.serializeJSON(bodyTable)
  local maxRetries = 5
  for attempt = 0, maxRetries do
    local h, err, errh = http.post(url, body, headers)
    if h then
      local raw = h.readAll(); h.close()
      local data = textutils.unserializeJSON(raw)
      if not data then return nil, "could not parse response" end
      return data
    end
    -- failed: inspect status / retry-after
    local code, retryAfter, detail = nil, nil, ""
    if errh then
      if errh.getResponseCode then local ok, c = pcall(errh.getResponseCode); if ok then code = c end end
      if errh.getResponseHeaders then
        local ok, hs = pcall(errh.getResponseHeaders)
        if ok and hs then retryAfter = tonumber(hs["retry-after"] or hs["Retry-After"]) end
      end
      detail = errh.readAll() or ""; errh.close()
    end
    local retryable = code == 429 or code == 529 or (code and code >= 500)
    if retryable and attempt < maxRetries then
      local waitS = math.min(retryAfter or (2 ^ attempt), 60)
      out(("  rate limited (%s) - waiting %ds..."):format(tostring(code), waitS), colors.orange)
      sleep(waitS)
    else
      return nil, (tostring(err) .. (detail ~= "" and (": " .. detail) or "")), code
    end
  end
end

----------------------------------------------------------------------
-- Backends: each exposes userMessage(text), run() -> {texts,calls}|nil,err,
-- and toolResults(list). A "call" is {name, args, id}. A result is {id,name,result}.
----------------------------------------------------------------------
local Gemini = { contents = {} }
function Gemini.userMessage(text)
  Gemini.contents[#Gemini.contents + 1] = { role = "user", parts = { { text = text } } }
end
function Gemini.run()
  local data, err = postJSON(GEMINI_ENDPOINT, {
    system_instruction = { parts = { { text = SYSTEM } } },
    contents = Gemini.contents,
    tools = { { function_declarations = geminiTools() } },
  }, { ["Content-Type"] = "application/json" })
  if not data then return nil, err end
  if data.error then return nil, "API error: " .. tostring(data.error.message) end
  local cand = data.candidates and data.candidates[1]
  local parts = cand and cand.content and cand.content.parts or {}
  Gemini.contents[#Gemini.contents + 1] = { role = "model", parts = parts }
  local texts, calls = {}, {}
  for _, p in ipairs(parts) do
    if p.text and p.text ~= "" then texts[#texts + 1] = p.text end
    if p.functionCall then
      calls[#calls + 1] = { name = p.functionCall.name, args = p.functionCall.args or {} }
    end
  end
  return { texts = texts, calls = calls }
end
function Gemini.toolResults(list)
  local parts = {}
  for _, r in ipairs(list) do
    parts[#parts + 1] = { functionResponse = { name = r.name, response = r.result } }
  end
  Gemini.contents[#Gemini.contents + 1] = { role = "function", parts = parts }
end

local Claude = { messages = {} }
function Claude.userMessage(text)
  Claude.messages[#Claude.messages + 1] = { role = "user", content = text }
end

-- Return a copy of the history with a cache breakpoint on the latest (always a
-- user) turn, so prior turns are read from cache instead of recounted each step.
local function claudeCachedMessages(messages)
  if #messages == 0 then return messages end
  local copy = {}
  for i = 1, #messages do copy[i] = messages[i] end
  local last = copy[#copy]
  local content = last.content
  local newContent
  if type(content) == "string" then
    newContent = { { type = "text", text = content, cache_control = { type = "ephemeral" } } }
  elseif type(content) == "table" and #content > 0 then
    newContent = {}
    for i = 1, #content do newContent[i] = content[i] end
    local lb = newContent[#newContent]
    if type(lb) == "table" then
      local nb = {}; for k, v in pairs(lb) do nb[k] = v end
      nb.cache_control = { type = "ephemeral" }
      newContent[#newContent] = nb
    end
  end
  copy[#copy] = { role = last.role, content = newContent or content }
  return copy
end

function Claude.run()
  local body = {
    model = CLAUDE_MODEL,
    max_tokens = 1024,
    -- IMPORTANT for OAuth (subscription) tokens: Anthropic only accepts these
    -- tokens when the request presents as Claude Code -- the FIRST system block
    -- must be Claude Code's identity, or every request is rejected with 429.
    -- Our real instructions follow as a second (cached) block.
    system = {
      { type = "text", text = "You are Claude Code, Anthropic's official CLI for Claude." },
      { type = "text", text = SYSTEM, cache_control = { type = "ephemeral" } },
    },
    messages = claudeCachedMessages(Claude.messages),
    tools = claudeTools(),
    output_config = { effort = "low" },
  }
  if CLAUDE_THINKING then body.thinking = { type = "adaptive" } end
  local data, err = postJSON(CLAUDE_ENDPOINT, body, {
    ["Content-Type"]    = "application/json",
    ["anthropic-version"] = "2023-06-01",
    ["anthropic-beta"]  = "oauth-2025-04-20",
    ["Authorization"]   = "Bearer " .. CLAUDE_TOKEN,
  })
  if not data then return nil, err end
  if data.type == "error" then return nil, "API error: " .. tostring(data.error and data.error.message) end
  local content = data.content or {}
  Claude.messages[#Claude.messages + 1] = { role = "assistant", content = content }
  local texts, calls = {}, {}
  for _, b in ipairs(content) do
    if b.type == "text" and b.text and b.text ~= "" then texts[#texts + 1] = b.text end
    if b.type == "tool_use" then
      calls[#calls + 1] = { name = b.name, args = b.input or {}, id = b.id }
    end
  end
  return { texts = texts, calls = calls }
end
function Claude.toolResults(list)
  local content = {}
  for _, r in ipairs(list) do
    content[#content + 1] = {
      type = "tool_result", tool_use_id = r.id,
      content = textutils.serializeJSON(r.result),
    }
  end
  Claude.messages[#Claude.messages + 1] = { role = "user", content = content }
end

local backend = (BACKEND == "claude") and Claude or Gemini

----------------------------------------------------------------------
-- Agent loop (backend-agnostic)
----------------------------------------------------------------------
local function ask(userText)
  backend.userMessage(userText)
  mlog("you: " .. userText, colors.cyan)
  for _ = 1, MAX_ROUNDS do
    setStatus("thinking")
    local res, err = backend.run()
    setStatus("idle")
    if not res then out("error: " .. tostring(err), colors.red); return end
    for _, t in ipairs(res.texts) do out(t, colors.white) end
    if #res.calls == 0 then return end

    setStatus("working")
    local results = {}
    for _, c in ipairs(res.calls) do
      out(("> %s %s"):format(c.name, textutils.serializeJSON(c.args or {})), colors.gray)
      local fn = tools[c.name]
      local result = fn and fn(c.args or {}) or { error = "unknown tool" }
      local s, col = summarize(c.name, result)
      out(s, col)
      results[#results + 1] = { id = c.id, name = c.name, result = result }
    end
    setStatus("idle")
    backend.toolResults(results)
  end
  out("(stopped after " .. MAX_ROUNDS .. " tool rounds)", colors.red)
end

----------------------------------------------------------------------
local function wiredModems()
  local t = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "modem") then
      local ok, wireless = pcall(peripheral.call, n, "isWireless")
      if ok and wireless == false then t[#t + 1] = n end
    end
  end
  return t
end

local function diagnose()
  out("-- diagnose --", colors.white)
  if not DROP_TARGET then out("DROP_TARGET not set.", colors.red); return end

  -- 1) how many wired networks is this computer attached to?
  local modems = wiredModems()
  out("wired modems on this computer: " .. #modems, #modems == 1 and colors.lime or colors.orange)
  if #modems ~= 1 then
    out("Each wired modem is a SEPARATE network. Items cannot move between", colors.orange)
    out("networks. Connect everything through ONE wired modem / one cable run.", colors.orange)
  end
  for _, m in ipairs(modems) do
    local ok, names = pcall(peripheral.call, m, "getNamesRemote")
    local cnt, hasTarget = 0, false
    if ok and names then
      cnt = #names
      for _, nm in ipairs(names) do if nm == DROP_TARGET then hasTarget = true end end
    end
    out(("  modem %s: %d peripherals | drop target on it: %s"):format(m, cnt, tostring(hasTarget)),
        hasTarget and colors.lime or colors.lightGray)
    if ok and names then
      out("  inventories on this network (pick DROP_TARGET from these):", colors.lightGray)
      for _, nm in ipairs(names) do
        if peripheral.hasType(nm, "inventory") then out("    " .. nm, colors.lightBlue) end
      end
    end
  end

  -- 2) can the drop target even push to itself? (sanity check of the name)
  if isConnected(DROP_TARGET) then
    local v = peripheral.wrap(DROP_TARGET)
    local pok, err = pcall(v.pushItems, DROP_TARGET, 1, 0)
    out("self-push test on drop target: " .. (pok and "OK" or ("FAIL: " .. tostring(err))),
        pok and colors.lime or colors.red)
  else
    out("drop target '" .. DROP_TARGET .. "' not visible to computer at all.", colors.red)
  end

  -- 3) which inventories can reach the drop target
  local okc, badc = 0, 0
  for _, n in ipairs(invNames()) do
    if n ~= DROP_TARGET then
      local src = peripheral.wrap(n)
      if pcall(src.pushItems, DROP_TARGET, 1, 0) then okc = okc + 1 else badc = badc + 1 end
    end
  end
  out(("reachable %d / unreachable %d"):format(okc, badc), badc == 0 and colors.lime or colors.orange)
end

local activeModel = (BACKEND == "claude") and CLAUDE_MODEL or MODEL
print("AI factory controller (" .. activeModel .. "). Commands: <request>, diagnose, groups, exit.")
mlog("ready - " .. activeModel, colors.white)
if not DROP_TARGET then
  printError("Warning: DROP_TARGET not set - drop_to_player will fail. Edit the file.")
end
while true do
  term.setTextColor(colors.yellow); write("\n> "); term.setTextColor(colors.white)
  local q = read()
  if q == "exit" or q == "quit" then break end
  if q == "diagnose" then
    diagnose()
  elseif q == "groups" then
    if not groups then out("groups library not installed (lib/groups.lua).", colors.red)
    else
      local gs = groups.list()
      if #gs == 0 then out("No groups defined. Use the 'groupctl' program to add some.", colors.orange) end
      for _, g in ipairs(gs) do out(("%s: %d machine(s)"):format(g.name, #g.members), colors.lightBlue) end
    end
  elseif q and #q > 0 then
    local ok, err = pcall(ask, q)
    if not ok then printError(tostring(err)) end
  end
end
