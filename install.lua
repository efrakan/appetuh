-- install.lua : bootstrap installer that pulls the toolkit from a GitHub (or
-- any HTTP) base URL.
--
-- How to use:
--   1. Upload your files to a GitHub repo, KEEPING the same relative paths
--      shown in FILES below (e.g. apt/apt.lua, ccc.lua, fleet/agent.lua, ...).
--   2. Set BASE_URL to your repo's raw root (must end with a slash):
--        https://raw.githubusercontent.com/<user>/<repo>/<branch>/
--   3. Re-upload THIS file too, then on any computer run:
--        wget run https://raw.githubusercontent.com/<user>/<repo>/<branch>/install.lua
--
-- Installed programs go in /bin and are added to your shell PATH (live + on
-- reboot), so you can run them from any directory by name (apt, ccc, factory).

local BASE_URL = "https://raw.githubusercontent.com/USER/REPO/main/"

-- Fallback list, used only if manifest.lua can't be fetched from BASE_URL.
-- remote path (relative to BASE_URL)  ->  local install path
local FILES = {
  ["apt/apt.lua"]       = "/bin/apt.lua",
  ["apt/aptd.lua"]      = "/bin/aptd.lua",
  ["apt/lib/proto.lua"] = "/bin/lib/proto.lua",   -- apt/aptd require this
  ["ccc.lua"]           = "/bin/ccc.lua",
  ["stressmon.lua"]     = "/bin/stressmon.lua",
  ["stressdiag.lua"]    = "/bin/stressdiag.lua",
  ["vaultguard.lua"]    = "/bin/vaultguard.lua",
  ["factory.lua"]       = "/bin/factory.lua",
  ["stockkeeper.lua"]   = "/bin/stockkeeper.lua",
  ["chatops.lua"]       = "/bin/chatops.lua",
  ["fleet/agent.lua"]   = "/bin/fleet-agent.lua",
  ["fleet/master.lua"]  = "/bin/fleet-master.lua",
  ["fleet/deploy.lua"]  = "/bin/fleet-deploy.lua",
}

if not http then error("HTTP API is disabled; enable it in the CC config.", 0) end

local function fetch(url)
  local h, err = http.get(url)
  if not h then return nil, tostring(err) end
  local data = h.readAll(); h.close(); return data
end

local function writeFile(path, data)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(path, "w"); h.write(data); h.close()
end

local function dirOf(path)
  local d = fs.getDir(path)
  if d == "" then return "/" end
  if d:sub(1, 1) ~= "/" then d = "/" .. d end
  return d
end

-- Prefer the repo's manifest.lua (single source of truth); fall back to FILES.
do
  local mtext = fetch(BASE_URL .. "manifest.lua")
  if mtext then
    local f = load(mtext, "@manifest", "t", {})
    local ok, m = pcall(f)
    if ok and type(m) == "table" and type(m.files) == "table" then
      FILES = m.files
      print("Using manifest" .. (m.version and (" v" .. m.version) or ""))
    end
  end
end

print("Installing from " .. BASE_URL)
local dirs, n, fail = {}, 0, 0
for remote, dest in pairs(FILES) do
  write("  " .. remote .. " ... ")
  local data, err = fetch(BASE_URL .. remote)
  if data then
    writeFile(dest, data)
    dirs[dirOf(dest)] = true
    n = n + 1; print("ok")
  else
    fail = fail + 1; print("FAILED (" .. err .. ")")
  end
end

----------------------------------------------------------------------
-- Add install dirs to PATH (live + persisted in /startup.lua)
----------------------------------------------------------------------
if shell then
  local p = shell.path()
  for d in pairs(dirs) do
    if not ((":" .. p .. ":"):find(":" .. d .. ":", 1, true)) then p = p .. ":" .. d end
  end
  shell.setPath(p)
end

local MARK1, MARK2 = "--[[apt-path]]", "--[[/apt-path]]"
local START = "/startup.lua"
local function stripBlock(s)
  local a = s:find(MARK1, 1, true); if not a then return s end
  local b = s:find(MARK2, a, true)
  if not b then return (s:sub(1, a - 1):gsub("%s*$", "")) end
  local before = s:sub(1, a - 1):gsub("%s*$", "")
  local after  = s:sub(b + #MARK2):gsub("^%s*", "")
  if before ~= "" and after ~= "" then return before .. "\n" .. after end
  return before ~= "" and (before .. "\n") or after
end
do
  local list = {}
  for d in pairs(dirs) do list[#list + 1] = ("%q"):format(d) end
  table.sort(list)
  local block = MARK1 .. "\nfor _,d in ipairs({" .. table.concat(list, ",") .. "}) do\n"
    .. "  if not ((':'..shell.path()..':'):find(':'..d..':',1,true)) then shell.setPath(shell.path()..':'..d) end\n"
    .. "end\n" .. MARK2 .. "\n"
  local existing = ""
  if fs.exists(START) then local h = fs.open(START, "r"); existing = h.readAll(); h.close() end
  local body = stripBlock(existing)
  if body ~= "" and body:sub(-1) ~= "\n" then body = body .. "\n" end
  local h = fs.open(START, "w"); h.write(body .. block); h.close()
end

-- Remember the base URL so `apt selfupdate` can re-pull apt later.
if not fs.exists("/etc/apt") then fs.makeDir("/etc/apt") end
local bh = fs.open("/etc/apt/base.url", "w"); bh.write(BASE_URL); bh.close()

print(("Done: %d installed, %d failed."):format(n, fail))
if fail == 0 then
  print("On your PATH now and after reboot. Try: apt | ccc | factory | fleet-master")
else
  print("Some files failed - check BASE_URL and that the paths exist in your repo.")
end
