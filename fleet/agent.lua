-- fleet/agent.lua : runs on each managed computer. Listens for the master's
-- broadcasts over rednet, reports status, and runs commands. Put it in
-- startup.lua (or `apt install fleet-agent`) so every node runs it on boot.
--
-- Channel use: rednet only (the node's own ID channel + the broadcast
-- channel) -- two channels total, regardless of fleet size.

local PROTOCOL = "fleet"
local SECRET   = "changeme"   -- MUST match the master's SECRET

----------------------------------------------------------------------
local function openModem()
  if rednet.isOpen() then return end
  for _, s in ipairs(peripheral.getNames()) do
    if peripheral.getType(s) == "modem" then rednet.open(s); return end
  end
  error("fleet-agent: no modem attached", 0)
end

local function stats()
  local kind = "computer"
  if turtle then kind = "turtle" elseif pocket then kind = "pocket" end
  local fuel
  if turtle then local ok, f = pcall(turtle.getFuelLevel); if ok then fuel = f end end
  return {
    id       = os.getComputerID(),
    label    = os.getComputerLabel(),
    kind     = kind,
    uptime   = math.floor(os.clock()),
    free     = fs.getFreeSpace("/"),
    capacity = fs.getCapacity and fs.getCapacity("/") or nil,
    fuel     = fuel,
  }
end

-- Run a shell command, capturing its terminal output via an offscreen window.
local function runShell(cmd)
  if not shell then return false, "no shell on this node" end
  local w, h = term.getSize()
  local win  = window.create(term.current(), 1, 1, w, h, false)
  local prev = term.redirect(win)
  local ranOk, shellOk = pcall(function() return shell.run(cmd) end)
  term.redirect(prev)
  local lines = {}
  for y = 1, h do
    local ok, text = pcall(win.getLine, y)
    if ok and text then
      text = text:gsub("%s+$", "")
      if #text > 0 then lines[#lines + 1] = text end
    end
  end
  local out = table.concat(lines, "\n")
  if not ranOk then return false, out .. "\n[error] " .. tostring(shellOk) end
  return shellOk ~= false, out
end

-- Run a Lua snippet, capturing print/write output.
local function runCode(code)
  local buf = {}
  local env = setmetatable({
    print = function(...)
      local t = { ... }; for i = 1, #t do t[i] = tostring(t[i]) end
      buf[#buf + 1] = table.concat(t, "\t")
    end,
    write = function(s) buf[#buf + 1] = tostring(s) end,
  }, { __index = _ENV })
  local fn, e = load(code, "@cmd", "t", env)
  if not fn then return false, "compile error: " .. tostring(e) end
  local ok, res = pcall(fn)
  if not ok then buf[#buf + 1] = "[error] " .. tostring(res) end
  return ok, table.concat(buf, "\n")
end

----------------------------------------------------------------------
openModem()
if not os.getComputerLabel() then os.setComputerLabel("node-" .. os.getComputerID()) end
print("fleet-agent online: #" .. os.getComputerID() .. " (" .. (os.getComputerLabel() or "") .. ")")
print("protocol '" .. PROTOCOL .. "'. Ctrl+T to stop.")

while true do
  local sender, msg = rednet.receive(PROTOCOL)
  if type(msg) == "table" and msg.secret == SECRET then
    local reqId, base = msg.reqId, { reqId = msg.reqId, id = os.getComputerID() }
    if msg.cmd == "STATUS" then
      base.ok = true; base.stats = stats()
      rednet.send(sender, base, PROTOCOL)
    elseif msg.cmd == "RUN" then
      local ok, out
      if msg.run then ok, out = runShell(msg.run)
      elseif msg.code then ok, out = runCode(msg.code)
      else ok, out = false, "no run/code given" end
      base.ok = ok; base.label = os.getComputerLabel(); base.output = out
      rednet.send(sender, base, PROTOCOL)
    elseif msg.cmd == "REBOOT" then
      base.ok = true; rednet.send(sender, base, PROTOCOL)
      sleep(0.2); os.reboot()
    elseif msg.cmd == "SHUTDOWN" then
      base.ok = true; rednet.send(sender, base, PROTOCOL)
      sleep(0.2); os.shutdown()
    end
  end
end
