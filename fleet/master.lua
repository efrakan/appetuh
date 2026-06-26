-- fleet/master.lua : control plane for a fleet of fleet-agent nodes.
--   * Dashboard (stats) is drawn on the attached monitor.
--   * Commands are typed on the computer's own terminal.
--
-- IMPORTANT (channel limit): a modem allows at most 128 open channels, so we
-- never assign a channel per node. Everything goes over ONE rednet broadcast
-- channel plus the master's own ID channel. One broadcast reaches all 500.

local PROTOCOL     = "fleet"
local SECRET       = "changeme"   -- MUST match the agents' SECRET
local STATUS_EVERY = 5            -- seconds between status sweeps
local RUN_COLLECT  = 3            -- seconds to gather replies after a RUN
local OFFLINE_AFTER = STATUS_EVERY * 3

----------------------------------------------------------------------
local function openModem()
  if rednet.isOpen() then return end
  for _, s in ipairs(peripheral.getNames()) do
    if peripheral.getType(s) == "modem" then rednet.open(s); return end
  end
  error("fleet-master: no modem attached", 0)
end
openModem()

local monitor = peripheral.find("monitor")
if monitor then monitor.setTextScale(0.5) end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local nodes      = {}    -- id -> { stats = {...}, last = os.clock() }
local nextReq    = 0
local input      = ""
local lastResult = "Type 'help' then Enter."
local page       = 0
local running    = true

local function newReq() nextReq = nextReq + 1; return nextReq end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function bytes(n)
  if not n then return "?" end
  if n >= 1e6 then return ("%.1fM"):format(n / 1e6) end
  if n >= 1e3 then return ("%.1fk"):format(n / 1e3) end
  return tostring(n)
end

local function sweep()
  rednet.broadcast({ secret = SECRET, cmd = "STATUS", reqId = newReq() }, PROTOCOL)
end

----------------------------------------------------------------------
-- Dashboard (monitor)
----------------------------------------------------------------------
local function physical()
  local comp, drive = 0, 0
  for _, s in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(s)
    if t == "computer" then comp = comp + 1
    elseif t == "drive" then drive = drive + 1 end
  end
  return comp, drive
end

local function drawDashboard()
  local mon = monitor
  if not mon then return end
  mon.setBackgroundColor(colors.black); mon.clear()
  local W, H = mon.getSize()
  local now = os.clock()

  local online, byKind, totFree, totCap = 0, {}, 0, 0
  for _, n in pairs(nodes) do
    if now - n.last <= OFFLINE_AFTER then
      online = online + 1
      byKind[n.stats.kind] = (byKind[n.stats.kind] or 0) + 1
      totFree = totFree + (n.stats.free or 0)
      totCap  = totCap + (n.stats.capacity or 0)
    end
  end

  mon.setCursorPos(1, 1); mon.setTextColor(colors.white); mon.write("FLEET MONITOR")
  mon.setCursorPos(1, 2); mon.setTextColor(colors.lightGray)
  mon.write(("online %d / known %d"):format(online, count(nodes)))
  local kp = {}; for k, v in pairs(byKind) do kp[#kp + 1] = k .. ":" .. v end
  mon.setCursorPos(1, 3); mon.write("kinds " .. (table.concat(kp, " ") ~= "" and table.concat(kp, " ") or "-"))
  mon.setCursorPos(1, 4); mon.write(("disk free %s / %s"):format(bytes(totFree), bytes(totCap)))
  local pc, pd = physical()
  mon.setCursorPos(1, 5); mon.write(("wired: %d computers, %d drives"):format(pc, pd))

  -- paged node list
  local ids = {}; for id in pairs(nodes) do ids[#ids + 1] = id end
  table.sort(ids)
  local startY = 7
  local rows = H - startY
  if rows < 1 then return end
  local pages = math.max(1, math.ceil(#ids / rows))
  page = page % pages
  mon.setCursorPos(1, 6); mon.setTextColor(colors.gray)
  mon.write(("nodes (page %d/%d)"):format(page + 1, pages))
  for i = 1, rows do
    local id = ids[page * rows + i]
    if id then
      local n = nodes[id]
      local age = math.floor(now - n.last)
      mon.setCursorPos(1, startY + i - 1)
      mon.setTextColor(age <= OFFLINE_AFTER and colors.lime or colors.red)
      local line = ("#%-4d %-10s %-8s %s %ds"):format(
        id, (n.stats.label or ""):sub(1, 10), n.stats.kind or "?",
        bytes(n.stats.free), age)
      mon.write(line:sub(1, W))
    end
  end
end

----------------------------------------------------------------------
-- Console (terminal)
----------------------------------------------------------------------
local function drawConsole()
  local W, H = term.getSize()
  term.setBackgroundColor(colors.black)
  term.setCursorPos(1, 1); term.clearLine(); term.setTextColor(colors.white)
  term.write("Fleet Master Console")
  term.setCursorPos(1, 2); term.clearLine(); term.setTextColor(colors.lightGray)
  term.write("help | run <cmd> | lua <code> | reboot all | shutdown all | refresh | quit")
  for y = 4, H - 1 do term.setCursorPos(1, y); term.clearLine() end
  term.setTextColor(colors.white)
  local y = 4
  for line in (tostring(lastResult) .. "\n"):gmatch("([^\n]*)\n") do
    if y > H - 1 then break end
    term.setCursorPos(1, y); term.write(line:sub(1, W)); y = y + 1
  end
  term.setCursorPos(1, H); term.clearLine(); term.setTextColor(colors.yellow)
  term.write("> " .. input)
  term.setCursorBlink(true)
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local function collectRun(req, seconds)
  local okc, failc, fails = 0, 0, {}
  local timer = os.startTimer(seconds)
  while true do
    local e = { os.pullEventRaw() }
    if e[1] == "rednet_message" and e[4] == PROTOCOL
       and type(e[3]) == "table" and e[3].reqId == req then
      local m = e[3]
      if m.ok then okc = okc + 1
      else
        failc = failc + 1
        if #fails < 6 then
          fails[#fails + 1] = ("#%d %s"):format(m.id or -1,
            ((m.output or "") .. ""):gsub("\n", " "):sub(1, 40))
        end
      end
    elseif e[1] == "timer" and e[2] == timer then
      break
    elseif e[1] == "terminate" then
      running = false; break
    end
  end
  local r = ("%d ok, %d failed"):format(okc, failc)
  if #fails > 0 then r = r .. "\n" .. table.concat(fails, "\n") end
  return r
end

local function exec(line)
  local cmd, rest = line:match("^(%S+)%s*(.-)%s*$")
  if not cmd then return end
  cmd = cmd:lower()
  if cmd == "help" then
    lastResult = "run <shellcmd>  - run on every node\n"
      .. "lua <code>      - run lua on every node\n"
      .. "reboot all / shutdown all\nrefresh - status sweep now\nquit"
  elseif cmd == "run" then
    if rest == "" then lastResult = "usage: run <command>" else
      local req = newReq()
      rednet.broadcast({ secret = SECRET, cmd = "RUN", run = rest, reqId = req }, PROTOCOL)
      lastResult = "RUN '" .. rest .. "'\n" .. collectRun(req, RUN_COLLECT)
    end
  elseif cmd == "lua" then
    if rest == "" then lastResult = "usage: lua <code>" else
      local req = newReq()
      rednet.broadcast({ secret = SECRET, cmd = "RUN", code = rest, reqId = req }, PROTOCOL)
      lastResult = "LUA\n" .. collectRun(req, RUN_COLLECT)
    end
  elseif cmd == "reboot" then
    rednet.broadcast({ secret = SECRET, cmd = "REBOOT", reqId = newReq() }, PROTOCOL)
    lastResult = "reboot broadcast sent to all nodes"
  elseif cmd == "shutdown" then
    rednet.broadcast({ secret = SECRET, cmd = "SHUTDOWN", reqId = newReq() }, PROTOCOL)
    lastResult = "shutdown broadcast sent to all nodes"
  elseif cmd == "refresh" then
    sweep(); lastResult = "status sweep sent"
  elseif cmd == "quit" or cmd == "exit" then
    running = false
  else
    lastResult = "unknown command: " .. cmd
  end
end

----------------------------------------------------------------------
-- Main loop (single-threaded; one place receives rednet)
----------------------------------------------------------------------
local function main()
  sweep()
  drawDashboard(); drawConsole()
  local sweepT = os.startTimer(STATUS_EVERY)
  local drawT  = os.startTimer(1)
  while running do
    local e = { os.pullEventRaw() }
    local ev = e[1]
    if ev == "rednet_message" and e[4] == PROTOCOL and type(e[3]) == "table" then
      local m = e[3]
      if m.stats then nodes[m.stats.id] = { stats = m.stats, last = os.clock() } end
    elseif ev == "timer" and e[2] == sweepT then
      sweep(); page = page + 1; drawDashboard(); sweepT = os.startTimer(STATUS_EVERY)
    elseif ev == "timer" and e[2] == drawT then
      drawDashboard(); drawT = os.startTimer(1)
    elseif ev == "char" then
      input = input .. e[2]; drawConsole()
    elseif ev == "key" then
      if e[2] == keys.enter then
        local l = input; input = ""; exec(l); drawDashboard(); drawConsole()
      elseif e[2] == keys.backspace then
        input = input:sub(1, #input - 1); drawConsole()
      end
    elseif ev == "term_resize" then drawConsole()
    elseif ev == "monitor_resize" then drawDashboard()
    elseif ev == "terminate" then running = false
    end
  end
end

local ok, err = pcall(main)
term.setCursorBlink(false)
term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
term.clear(); term.setCursorPos(1, 1)
if not ok then printError(tostring(err)) end
print("fleet-master stopped.")
