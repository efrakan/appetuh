-- fleet/deploy.lua : write the fleet agent + an auto-installer onto every disk
-- currently in a connected disk drive. Insert those disks into node computers
-- (or reboot nodes that share the drive) and they self-install the agent on
-- boot. Run this on the master/repo computer (where agent.lua lives).

local AGENT_SRC = "/fleet/agent.lua"   -- agent source on this computer

-- This script is written to each disk as its startup. On a node's boot it
-- copies the agent to the computer, makes it run on boot, and launches it.
local INSTALLER = [[
local here = fs.getDir(shell.getRunningProgram())
local src  = fs.combine(here, "fleet-agent.lua")
if fs.exists(src) then
  if fs.exists("/fleet-agent.lua") then fs.delete("/fleet-agent.lua") end
  fs.copy(src, "/fleet-agent.lua")
  local boot = "/startup.lua"
  local line = 'shell.run("/fleet-agent.lua")'
  if fs.exists(boot) then
    local h = fs.open(boot, "r"); local c = h.readAll(); h.close()
    if not c:find("fleet-agent", 1, true) then
      local a = fs.open(boot, "a"); a.write("\n" .. line .. "\n"); a.close()
    end
  else
    local h = fs.open(boot, "w"); h.write(line .. "\n"); h.close()
  end
  shell.run("/fleet-agent.lua")
end
]]

if not fs.exists(AGENT_SRC) then error("agent source not found: " .. AGENT_SRC, 0) end
local h = fs.open(AGENT_SRC, "r"); local agent = h.readAll(); h.close()

local n = 0
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "drive" then
    local d = peripheral.wrap(name)
    if d.isDiskPresent and d.isDiskPresent() then
      local mount = d.getMountPath()
      if mount then
        local a = fs.open(fs.combine(mount, "fleet-agent.lua"), "w"); a.write(agent); a.close()
        local s = fs.open(fs.combine(mount, "startup.lua"), "w"); s.write(INSTALLER); s.close()
        n = n + 1
        print("deployed -> " .. name .. " (" .. mount .. ")")
      end
    end
  end
end
print(("Done. Wrote agent + installer to %d disk(s)."):format(n))
if n > 0 then
  print("Insert these disks into node computers and reboot them;")
  print("each node will install and launch the agent automatically.")
end
