-- aptd.lua : APT repository server for CC:Tweaked.
-- Scans a repository folder and serves its packages to apt clients over rednet.
-- Usage: aptd [repoPath]   (default repoPath = /apt/repo)
local proto = require("lib.proto")

local args = { ... }
local REPO = args[1] or "/apt/repo"

-- Load a package control file in a sandbox (empty environment, so it can only
-- return a table — no access to globals).
local function loadControl(path)
  local h = fs.open(path, "r"); local s = h.readAll(); h.close()
  local f = load(s, "@" .. path, "t", {})
  if not f then return nil end
  local ok, t = pcall(f)
  if ok and type(t) == "table" and t.name and t.version then return t end
  return nil
end

-- Build a fresh index by scanning <repo>/packages/<name>/control.lua
local function buildIndex()
  local index = {}
  local pdir = fs.combine(REPO, "packages")
  if not fs.isDir(pdir) then return index end
  for _, name in ipairs(fs.list(pdir)) do
    local dir  = fs.combine(pdir, name)
    local ctrl = fs.combine(dir, "control.lua")
    if fs.isDir(dir) and fs.exists(ctrl) then
      local c = loadControl(ctrl)
      if c then index[c.name] = { control = c, dir = dir } end
    end
  end
  return index
end

-- control.files may be either:
--   an array of dest paths  -> read from <pkgdir>/files/<dest>, or
--   a map dest -> sourcePath -> read from that path on the server's filesystem.
-- Returns a map: dest -> absolute source path.
local function resolveFiles(entry)
  local f = entry.control.files or {}
  local map = {}
  if f[1] ~= nil then
    for _, dest in ipairs(f) do map[dest] = fs.combine(entry.dir, "files", dest) end
  else
    for dest, src in pairs(f) do map[dest] = src end
  end
  return map
end

local function packageSize(entry)
  local total = 0
  for _, src in pairs(resolveFiles(entry)) do
    if fs.exists(src) then total = total + fs.getSize(src) end
  end
  return total
end

local function readPackageFiles(entry)
  local files = {}
  for dest, src in pairs(resolveFiles(entry)) do
    if fs.exists(src) then
      local h = fs.open(src, "r"); files[dest] = h.readAll(); h.close()
    end
  end
  return files
end

local function handle(id, msg)
  local index = buildIndex()   -- rebuild each request so new packages appear live
  if msg.cmd == "LIST" then
    local packages = {}
    for _, entry in pairs(index) do
      local c = entry.control
      packages[#packages + 1] = {
        name = c.name, version = c.version, description = c.description,
        dependencies = c.dependencies or {}, size = packageSize(entry),
      }
    end
    rednet.send(id, { ok = true, packages = packages }, proto.PROTOCOL)
    print(("LIST  -> #%d  (%d packages)"):format(id, #packages))

  elseif msg.cmd == "FETCH" then
    local entry = index[msg.name]
    if not entry then
      rednet.send(id, { ok = false, error = "no such package" }, proto.PROTOCOL)
      print(("FETCH %s -> #%d  NOT FOUND"):format(tostring(msg.name), id))
      return
    end
    rednet.send(id, {
      ok = true, name = entry.control.name, version = entry.control.version,
      files = readPackageFiles(entry),
    }, proto.PROTOCOL)
    print(("FETCH %s (%s) -> #%d"):format(entry.control.name, entry.control.version, id))

  else
    rednet.send(id, { ok = false, error = "unknown command" }, proto.PROTOCOL)
  end
end

----------------------------------------------------------------------
-- Startup
----------------------------------------------------------------------
proto.open()
if not os.getComputerLabel() then
  os.setComputerLabel("apt-repo-" .. os.getComputerID())
end
rednet.host(proto.PROTOCOL, os.getComputerLabel())

local idx = buildIndex()
local n = 0; for _ in pairs(idx) do n = n + 1 end
print("=== apt repository server ===")
print("  repo path: " .. REPO)
print("  hostname:  " .. os.getComputerLabel())
print("  serving:   " .. n .. " package(s)")
print("Listening for clients (hold Ctrl+T to stop)...")

while true do
  local id, msg = rednet.receive(proto.PROTOCOL)
  if type(msg) == "table" and msg.cmd then
    local ok, err = pcall(handle, id, msg)
    if not ok then
      printError("error handling request from #" .. id .. ": " .. tostring(err))
      pcall(rednet.send, id, { ok = false, error = "server error" }, proto.PROTOCOL)
    end
  end
end
