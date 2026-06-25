-- chatops.lua : Advanced Peripherals Chat Box bot. Run fleet / stress / stock
-- queries from in-game chat. Messages must start with PREFIX (default "$").
--
-- Needs: a Chat Box. For fleet commands, also a modem (talks to fleet-agents).

local PREFIX         = "&"
local ADMINS         = nil          -- e.g. {"Steve"}; nil = everyone allowed
local FLEET_PROTOCOL = "fleet"
local FLEET_SECRET   = "changeme"   -- must match your fleet SECRET

local chat = peripheral.find("chat_box")
if not chat then error("no Chat Box attached", 0) end

local hasModem = false
for _, s in ipairs(peripheral.getNames()) do
  if peripheral.getType(s) == "modem" then
    if not rednet.isOpen() then rednet.open(s) end
    hasModem = true; break
  end
end

local function reply(msg) pcall(chat.sendMessage, msg, "Fleet", "[]") end

local function isAdmin(user)
  if not ADMINS then return true end
  for _, a in ipairs(ADMINS) do if a == user then return true end end
  return false
end

----------------------------------------------------------------------
-- fleet helpers
----------------------------------------------------------------------
local req = 0
local function broadcast(t)
  req = req + 1; t.secret = FLEET_SECRET; t.reqId = req
  rednet.broadcast(t, FLEET_PROTOCOL); return req
end
local function collect(r, secs)
  local ok, fail = 0, 0
  local timer = os.startTimer(secs or 2)
  while true do
    local e = { os.pullEvent() }
    if e[1] == "rednet_message" and e[4] == FLEET_PROTOCOL
       and type(e[3]) == "table" and e[3].reqId == r then
      if e[3].ok then ok = ok + 1 else fail = fail + 1 end
    elseif e[1] == "timer" and e[2] == timer then break end
  end
  return ok, fail
end

local function readStress()
  local t = peripheral.find("create_target")
  if not t then return nil end
  for _, line in ipairs(t.dump()) do
    local n = line:gsub(",", ""):match("%d+%.?%d*")
    if n then return tonumber(n) end
  end
end

local function countItem(item)
  local total = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "inventory" then
      local inv = peripheral.wrap(name)
      local ok, list = pcall(inv.list)
      if ok and list then
        for _, st in pairs(list) do if st.name == item then total = total + st.count end end
      end
    end
  end
  return total
end

----------------------------------------------------------------------
-- commands
----------------------------------------------------------------------
local H = {}
function H.help()
  reply(("cmds: %shelp %sstress %sstock <id> %snodes %srun <cmd> %sreboot all")
    :format(PREFIX, PREFIX, PREFIX, PREFIX, PREFIX, PREFIX))
end
function H.stress()
  local v = readStress()
  reply(v and ("stress load: " .. v .. "%") or "no stress reading")
end
function H.stock(a)
  if not a[1] then reply("usage: stock <itemid>"); return end
  reply(a[1] .. ": " .. countItem(a[1]))
end
function H.nodes()
  if not hasModem then reply("no modem attached"); return end
  local ok = collect(broadcast({ cmd = "STATUS" }), 2)
  reply("online nodes: " .. ok)
end
function H.run(a, user)
  if not isAdmin(user) then reply("not allowed"); return end
  if not hasModem then reply("no modem attached"); return end
  local cmd = table.concat(a, " ")
  if cmd == "" then reply("usage: run <command>"); return end
  local ok, fail = collect(broadcast({ cmd = "RUN", run = cmd }), 3)
  reply(("run: %d ok, %d fail"):format(ok, fail))
end
function H.reboot(a, user)
  if not isAdmin(user) then reply("not allowed"); return end
  if a[1] == "all" then broadcast({ cmd = "REBOOT" }); reply("reboot sent to all")
  else reply("usage: reboot all") end
end

----------------------------------------------------------------------
print("chatops running. prefix '" .. PREFIX .. "'. Ctrl+T to stop.")
while true do
  local _, user, message = os.pullEvent("chat")
  if message:sub(1, #PREFIX) == PREFIX then
    local parts = {}
    for w in message:sub(#PREFIX + 1):gmatch("%S+") do parts[#parts + 1] = w end
    local cmd = table.remove(parts, 1)
    if cmd and H[cmd] then
      local ok, err = pcall(H[cmd], parts, user)
      if not ok then reply("error: " .. tostring(err)) end
    end
  end
end
