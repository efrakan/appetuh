-- lib/proto.lua : shared rednet protocol + helpers for the apt system.
-- Required by both the client (apt.lua) and the server (aptd.lua).
local proto = {}

proto.PROTOCOL = "apt"   -- rednet protocol string
proto.TIMEOUT  = 5       -- default seconds to wait for a reply

-- Open the first attached modem (wired or wireless) for rednet.
function proto.open()
  if rednet.isOpen() then return end
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      rednet.open(side)
      return side
    end
  end
  error("no modem attached (attach a wired or wireless modem)", 0)
end

-- Discover all computers currently hosting the apt protocol.
-- Returns a list of computer IDs.
function proto.findRepos()
  proto.open()
  return { rednet.lookup(proto.PROTOCOL) }
end

-- Send a request table to a specific repo and wait for its reply.
-- Returns the reply table, or nil on timeout.
function proto.request(id, msg, timeout)
  timeout = timeout or proto.TIMEOUT
  proto.open()
  rednet.send(id, msg, proto.PROTOCOL)
  local timer = os.startTimer(timeout)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and a == id and c == proto.PROTOCOL then
      return b
    elseif ev == "timer" and a == timer then
      return nil
    end
  end
end

-- Compare two dotted numeric version strings. Returns -1, 0 or 1.
function proto.vercmp(a, b)
  local function parts(v)
    local t = {}
    for num in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(num) end
    return t
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

return proto
