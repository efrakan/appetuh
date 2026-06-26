-- apt.lua : APT-style package manager client for CC:Tweaked (over rednet).
-- Commands: update, install, remove, upgrade, list, search, show, help.
local proto = require("lib.proto")

local DIR       = "/var/apt"
local LISTS     = fs.combine(DIR, "lists.tbl")      -- cached package index
local INSTALLED = fs.combine(DIR, "installed.tbl")  -- local install database

----------------------------------------------------------------------
-- Persistence (textutils-serialized tables)
----------------------------------------------------------------------
local function loadTbl(path, default)
  if not fs.exists(path) then return default end
  local h = fs.open(path, "r"); local s = h.readAll(); h.close()
  local t = textutils.unserialize(s)
  if type(t) == "table" then return t end
  return default
end

local function saveTbl(path, t)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(path, "w"); h.write(textutils.serialize(t)); h.close()
end

local function requireIndex()
  local index = loadTbl(LISTS, nil)
  if not index then error("no package lists; run 'apt update' first", 0) end
  return index
end

----------------------------------------------------------------------
-- PATH integration: make installed programs runnable from any directory.
-- Each install dir is added to shell.path() now and persisted via a managed
-- block in /startup.lua (so it survives reboots).
----------------------------------------------------------------------
local PATHS = fs.combine(DIR, "paths.tbl")
local START = "/startup.lua"
local MARK1, MARK2 = "--[[apt-path]]", "--[[/apt-path]]"

local function normDir(path)
  local d = fs.getDir(path)
  if d == "" then return "/" end
  if d:sub(1, 1) ~= "/" then d = "/" .. d end
  return d
end

local function applyLive(set)
  if not shell then return end
  local p = shell.path()
  for d in pairs(set) do
    if not ((":" .. p .. ":"):find(":" .. d .. ":", 1, true)) then p = p .. ":" .. d end
  end
  shell.setPath(p)
end

local function stripBlock(s)
  local a = s:find(MARK1, 1, true)
  if not a then return s end
  local b = s:find(MARK2, a, true)
  if not b then return (s:sub(1, a - 1):gsub("%s*$", "")) end
  local before = s:sub(1, a - 1):gsub("%s*$", "")
  local after  = s:sub(b + #MARK2):gsub("^%s*", "")
  if before ~= "" and after ~= "" then return before .. "\n" .. after end
  return before ~= "" and (before .. "\n") or after
end

local function maintainStartup(set)
  local dirs = {}
  for d in pairs(set) do dirs[#dirs + 1] = ("%q"):format(d) end
  table.sort(dirs)
  local block = MARK1 .. "\n"
    .. "for _,d in ipairs({" .. table.concat(dirs, ",") .. "}) do\n"
    .. "  if not ((':'..shell.path()..':'):find(':'..d..':',1,true)) then shell.setPath(shell.path()..':'..d) end\n"
    .. "end\n" .. MARK2 .. "\n"
  local existing = ""
  if fs.exists(START) then local h = fs.open(START, "r"); existing = h.readAll(); h.close() end
  local body = stripBlock(existing)
  if body ~= "" and body:sub(-1) ~= "\n" then body = body .. "\n" end
  local h = fs.open(START, "w"); h.write(body .. block); h.close()
end

local function registerPaths(filesList)
  local set = loadTbl(PATHS, {})
  for _, f in ipairs(filesList) do set[normDir(f)] = true end
  saveTbl(PATHS, set)
  applyLive(set)
  maintainStartup(set)
end

----------------------------------------------------------------------
-- Install planning + execution
----------------------------------------------------------------------
-- Walk dependencies depth-first; append packages that need (re)installing.
local function planResolve(name, index, installed, plan, seen, force)
  if seen[name] then return end
  seen[name] = true
  local p = index[name]
  if not p then error("package not found: " .. name, 0) end
  for _, dep in ipairs(p.dependencies or {}) do
    planResolve(dep, index, installed, plan, seen, false)
  end
  local inst = installed[name]
  if force or not inst or proto.vercmp(p.version, inst.version) ~= 0 then
    plan[#plan + 1] = p
  end
end

local function doInstall(p, installed)
  local reply = proto.request(p.repo, { cmd = "FETCH", name = p.name })
  if not reply or not reply.ok then
    error("failed to fetch " .. p.name .. (reply and (": " .. tostring(reply.error)) or " (no response)"), 0)
  end
  -- remove previously installed files (clean upgrade/reinstall)
  local old = installed[p.name]
  if old and old.files then
    for _, f in ipairs(old.files) do if fs.exists(f) then fs.delete(f) end end
  end
  local written = {}
  for dest, content in pairs(reply.files) do
    local target = "/" .. dest
    local d = fs.getDir(target)
    if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
    local h = fs.open(target, "w"); h.write(content); h.close()
    written[#written + 1] = target
  end
  installed[p.name] = {
    version      = p.version,
    description  = p.description,
    dependencies = p.dependencies or {},
    files        = written,
  }
end

local function runPlan(plan, installed)
  if #plan == 0 then print("Nothing to do; everything is up to date."); return end
  local names = {}
  for _, p in ipairs(plan) do names[#names + 1] = p.name .. " (" .. p.version .. ")" end
  print("The following packages will be installed:")
  print("  " .. table.concat(names, ", "))
  local installedFiles = {}
  for _, p in ipairs(plan) do
    write("  " .. p.name .. " ... ")
    doInstall(p, installed)
    saveTbl(INSTALLED, installed)   -- persist after each package
    for _, f in ipairs(installed[p.name].files or {}) do
      installedFiles[#installedFiles + 1] = f
    end
    print("ok")
  end
  if #installedFiles > 0 then
    registerPaths(installedFiles)
    print("Added to PATH - run installed programs from anywhere.")
  end
  print("Complete.")
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local cmds = {}

function cmds.update()
  local repos = proto.findRepos()
  if #repos == 0 then
    printError("No apt repositories found on the network.")
    return
  end
  local index = {}
  for _, id in ipairs(repos) do
    local reply = proto.request(id, { cmd = "LIST" })
    if reply and reply.ok and reply.packages then
      for _, p in ipairs(reply.packages) do
        local cur = index[p.name]
        if not cur or proto.vercmp(p.version, cur.version) > 0 then
          p.repo = id
          index[p.name] = p
        end
      end
      print(("repo #%d: %d package(s)"):format(id, #reply.packages))
    end
  end
  local n = 0; for _ in pairs(index) do n = n + 1 end
  saveTbl(LISTS, index)
  print(("Done. %d package(s) available."):format(n))
end

function cmds.install(...)
  local names = { ... }
  if #names == 0 then error("usage: apt install <package> [...]", 0) end
  local index = requireIndex()
  local installed = loadTbl(INSTALLED, {})
  local plan, seen = {}, {}
  for _, n in ipairs(names) do planResolve(n, index, installed, plan, seen, true) end
  runPlan(plan, installed)
end

function cmds.upgrade()
  local index = requireIndex()
  local installed = loadTbl(INSTALLED, {})
  local plan, seen = {}, {}
  for name, inst in pairs(installed) do
    local p = index[name]
    if p and proto.vercmp(p.version, inst.version) > 0 then
      planResolve(name, index, installed, plan, seen, false)
    end
  end
  runPlan(plan, installed)
end

function cmds.remove(...)
  local names = { ... }
  if #names == 0 then error("usage: apt remove <package> [...]", 0) end
  local installed = loadTbl(INSTALLED, {})
  for _, n in ipairs(names) do
    local inst = installed[n]
    if not inst then
      printError(n .. " is not installed")
    else
      local dependents = {}
      for other, info in pairs(installed) do
        if other ~= n then
          for _, d in ipairs(info.dependencies or {}) do
            if d == n then dependents[#dependents + 1] = other end
          end
        end
      end
      if #dependents > 0 then
        printError(("warning: %s is required by %s"):format(n, table.concat(dependents, ", ")))
      end
      for _, f in ipairs(inst.files or {}) do if fs.exists(f) then fs.delete(f) end end
      installed[n] = nil
      print("Removed " .. n)
    end
  end
  saveTbl(INSTALLED, installed)
end

function cmds.list(filter)
  local installed = loadTbl(INSTALLED, {})
  if filter == "--installed" then
    for name, info in pairs(installed) do
      print(("%s/%s  [installed]"):format(name, info.version))
    end
  else
    local index = requireIndex()
    for name, p in pairs(index) do
      print(("%s/%s%s"):format(name, p.version, installed[name] and "  [installed]" or ""))
    end
  end
end

function cmds.search(term)
  if not term then error("usage: apt search <term>", 0) end
  local index = requireIndex()
  term = term:lower()
  for name, p in pairs(index) do
    local desc = p.description or ""
    if name:lower():find(term, 1, true) or desc:lower():find(term, 1, true) then
      print(("%s/%s - %s"):format(name, p.version, desc))
    end
  end
end

function cmds.show(name)
  if not name then error("usage: apt show <package>", 0) end
  local index = requireIndex()
  local p = index[name]
  if not p then printError("no such package: " .. name); return end
  print("Package:     " .. p.name)
  print("Version:     " .. p.version)
  print("Description: " .. (p.description or ""))
  local deps = p.dependencies or {}
  print("Depends:     " .. (#deps > 0 and table.concat(deps, ", ") or "(none)"))
  if p.size then print("Size:        " .. p.size .. " bytes") end
  local installed = loadTbl(INSTALLED, {})
  if installed[name] then print("Status:      installed (" .. installed[name].version .. ")") end
end

-- Pull apt itself (apt.lua, aptd.lua, lib/proto.lua) from the GitHub base URL
-- recorded by install.lua at /etc/apt/base.url.
function cmds.selfupdate()
  if not http then error("HTTP API is disabled in the CC config", 0) end
  local base
  if fs.exists("/etc/apt/base.url") then
    local h = fs.open("/etc/apt/base.url", "r"); base = h.readAll(); h.close()
    base = base:gsub("%s+$", "")
  end
  if not base or base == "" then
    error("no base url; run install.lua first or write it to /etc/apt/base.url", 0)
  end
  local dir = fs.getDir(shell.getRunningProgram())   -- where apt is installed
  local targets = {
    ["apt/apt.lua"]       = fs.combine(dir, "apt.lua"),
    ["apt/aptd.lua"]      = fs.combine(dir, "aptd.lua"),
    ["apt/lib/proto.lua"] = fs.combine(dir, "lib/proto.lua"),
  }
  print("Self-updating apt from " .. base)
  for remote, dest in pairs(targets) do
    write("  " .. remote .. " ... ")
    local h, err = http.get(base .. remote)
    if h then
      local data = h.readAll(); h.close()
      local d = fs.getDir(dest)
      if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
      local out = fs.open(dest, "w"); out.write(data); out.close()
      print("ok")
    else
      print("FAILED (" .. tostring(err) .. ")")
    end
  end
  print("Done. Re-run apt to use the updated version.")
end

function cmds.help()
  print("apt - package manager for CC:Tweaked")
  print("Usage: apt <command> [args]")
  print("  update              refresh package lists from repositories")
  print("  install <pkg>...    install package(s) and dependencies")
  print("  remove  <pkg>...    uninstall package(s)")
  print("  upgrade             upgrade all installed packages")
  print("  list [--installed]  list available (or installed) packages")
  print("  search <term>       search package names and descriptions")
  print("  show <pkg>          show details about a package")
  print("  selfupdate          re-pull apt itself from your GitHub base URL")
end

----------------------------------------------------------------------
-- Dispatch
----------------------------------------------------------------------
local argv = { ... }
local cmd = table.remove(argv, 1)
if not cmd or not cmds[cmd] then
  cmds.help()
  return
end
local ok, err = pcall(cmds[cmd], table.unpack(argv))
if not ok then printError("apt: " .. tostring(err)) end
