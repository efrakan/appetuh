-- ccc : ComputerCraft Code "Compiler" / packer
-- Turns a .lua source file (plus everything it require()s / dofile()s /
-- loadfile()s) into a single shareable "binary" that does not expose readable
-- source: it bundles dependencies into one chunk, strips comments, minifies,
-- renames local variables, then XOR-encrypts + base64-encodes the result inside
-- a tiny self-decrypting loader. The output runs exactly like the original.
--
-- NOTE ON PROTECTION: CC:Tweaked removed string.dump / bytecode loading, so the
-- only way to run code is to hand source text to load(). That means a packed
-- program MUST rebuild its source in memory at runtime, and a determined person
-- can recover it (e.g. by hooking load). This tool stops casual copying, not a
-- skilled reverse engineer. There is no stronger option on this VM.
--
-- Usage:  ccc <input.lua> [output] [options]
--   --asset=<path>  : embed a file or folder as a read-only virtual filesystem
--                     (repeatable); the binary serves these via fs.* at runtime.
--                     Use --asset=src@mount to expose it at a different path.
--   --lock=<id,...> : only run on the listed computer IDs (os.getComputerID());
--                     the check is inside the encrypted payload, not the loader
--   --no-bundle     : do not follow require/dofile/loadfile; pack only this file
--   --no-minify     : skip comment/whitespace stripping and renaming (encrypt only)
--   --no-rename     : strip comments/whitespace but keep original local names (safest)
--
-- Examples:
--   ccc app.lua                              pack app.lua (+ its deps) -> app
--   ccc app.lua --asset=data --asset=cfg.txt embed the data/ folder and cfg.txt
--   ccc app.lua --lock=7,12                  only runs on computers #7 and #12

----------------------------------------------------------------------
-- Keyword table (Lua 5.2, the dialect CC:Tweaked uses)
----------------------------------------------------------------------
local KEYWORDS = {
  ["and"]=true,["break"]=true,["do"]=true,["else"]=true,["elseif"]=true,
  ["end"]=true,["false"]=true,["for"]=true,["function"]=true,["goto"]=true,
  ["if"]=true,["in"]=true,["local"]=true,["nil"]=true,["not"]=true,["or"]=true,
  ["repeat"]=true,["return"]=true,["then"]=true,["true"]=true,["until"]=true,
  ["while"]=true,
}

----------------------------------------------------------------------
-- Lexer : source string -> array of tokens (comments/whitespace dropped)
-- token = { type = name|keyword|number|string|op|eof, value=, raw=, idx= }
----------------------------------------------------------------------
local function lex(src)
  local toks, i, n = {}, 1, #src
  local function push(t, v, raw)
    local e = { type = t, value = v, raw = raw or v }
    toks[#toks+1] = e
    e.idx = #toks
  end
  while i <= n do
    local c = src:sub(i, i)
    local ws = src:match("^%s+", i)
    if ws then
      i = i + #ws
    elseif c == "-" and src:sub(i+1, i+1) == "-" then
      -- comment (line or long), dropped
      i = i + 2
      local eq = src:match("^%[(=*)%[", i)
      if eq then
        local close = "]" .. eq .. "]"
        local s = src:find(close, i, true)
        if not s then error("unfinished long comment", 0) end
        i = s + #close
      else
        local rest = src:match("^[^\n]*", i)
        i = i + #rest
      end
    elseif c == "[" and (src:sub(i+1,i+1) == "[" or src:sub(i+1,i+1) == "=") then
      local eq = src:match("^%[(=*)%[", i)
      if eq then
        local close = "]" .. eq .. "]"
        local s = src:find(close, i + #("[" .. eq .. "["), true)
        if not s then error("unfinished long string", 0) end
        local raw = src:sub(i, s + #close - 1)
        push("string", raw, raw); i = i + #raw
      else
        push("op", "["); i = i + 1
      end
    elseif c == '"' or c == "'" then
      local q, j = c, i + 1
      while true do
        local ch = src:sub(j, j)
        if ch == "" or ch == "\n" then error("unfinished string", 0) end
        if ch == "\\" then j = j + 2
        elseif ch == q then j = j + 1; break
        else j = j + 1 end
      end
      local raw = src:sub(i, j - 1); push("string", raw, raw); i = j
    elseif c:match("%d") or (c == "." and src:sub(i+1, i+1):match("%d")) then
      local j, hex = i, false
      if src:sub(j, j) == "0" and src:sub(j+1, j+1):lower() == "x" then hex = true; j = j + 2 end
      local digits = hex and "%x" or "%d"
      local expc  = hex and "pP" or "eE"
      while true do
        local ch = src:sub(j, j)
        if ch:match(digits) or ch == "." then
          j = j + 1
        elseif ch ~= "" and expc:find(ch, 1, true) then
          j = j + 1
          if src:sub(j, j) == "+" or src:sub(j, j) == "-" then j = j + 1 end
        else
          break
        end
      end
      local raw = src:sub(i, j - 1); push("number", raw, raw); i = j
    elseif c:match("[%a_]") then
      local id = src:match("^[%w_]+", i)
      push(KEYWORDS[id] and "keyword" or "name", id, id); i = i + #id
    else
      local three = src:sub(i, i+2)
      local two   = src:sub(i, i+1)
      if three == "..." then
        push("op", "..."); i = i + 3
      elseif two == ".." or two == "==" or two == "~=" or two == "<="
          or two == ">=" or two == "::" then
        push("op", two); i = i + 2
      elseif c:match("[%+%-%*/%%%^#<>=%(%)%{%}%[%];:,%.&|~]") then
        push("op", c); i = i + 1
      else
        error("unexpected character '" .. c .. "'", 0)
      end
    end
  end
  push("eof", "")
  return toks
end

----------------------------------------------------------------------
-- Parser : walks tokens to classify every NAME as a local binding /
-- local reference (rename) vs a field / global (keep). It does NOT build
-- an AST; it only fills renameId[tokenIdx] -> localId and collects the set
-- of global names used (so renamed locals never collide with them).
----------------------------------------------------------------------
local function parse(toks)
  local p = 1
  local renameId, globals, scopes, idc = {}, {}, {}, 0

  local function tt() return toks[p].type end
  local function tv() return toks[p].value end
  local function nxt() p = p + 1 end
  local function check(v) return toks[p].value == v and (tt() == "op" or tt() == "keyword") end
  local function accept(v) if check(v) then p = p + 1; return true end return false end
  local function expect(v)
    if not check(v) then error("parse: expected '" .. v .. "' near '" .. tostring(tv()) .. "'", 0) end
    p = p + 1
  end
  local function pushScope() scopes[#scopes+1] = {} end
  local function popScope() scopes[#scopes] = nil end
  local function declare(name, idx)
    idc = idc + 1
    scopes[#scopes][name] = idc
    if name ~= "self" then renameId[idx] = idc end
    return idc
  end
  local function resolve(name)
    for s = #scopes, 1, -1 do
      local id = scopes[s][name]
      if id then return id end
    end
    return nil
  end
  local function useName(idx, name)
    local id = resolve(name)
    if id then
      if name ~= "self" then renameId[idx] = id end
    else
      globals[name] = true
    end
  end

  -- forward declarations
  local expr, operand, prefixexp, suffixes, callargs, explist
  local tableconstructor, funcbody, statlist, statement, exprstat

  local function isUnary()
    return (tt() == "op" and (tv() == "-" or tv() == "#" or tv() == "~"))
        or (tt() == "keyword" and tv() == "not")
  end
  local function isBinop()
    if tt() == "keyword" then return tv() == "and" or tv() == "or" end
    if tt() == "op" then
      local v = tv()
      return v=="+" or v=="-" or v=="*" or v=="/" or v=="%" or v=="^" or v==".."
          or v=="==" or v=="~=" or v=="<" or v==">" or v=="<=" or v==">="
          or v=="&" or v=="|" or v=="~"
    end
    return false
  end

  expr = function()
    while isUnary() do nxt() end
    operand()
    while isBinop() do
      nxt()
      while isUnary() do nxt() end
      operand()
    end
  end

  operand = function()
    local t, v = tt(), tv()
    if t == "number" or t == "string" then nxt()
    elseif t == "keyword" and (v == "nil" or v == "true" or v == "false") then nxt()
    elseif t == "op" and v == "..." then nxt()
    elseif t == "keyword" and v == "function" then nxt(); funcbody(false)
    elseif t == "op" and v == "{" then tableconstructor()
    else prefixexp() end
  end

  prefixexp = function()
    if accept("(") then
      expr(); expect(")")
    elseif tt() == "name" then
      local idx, nm = toks[p].idx, tv(); nxt(); useName(idx, nm)
    else
      error("parse: unexpected '" .. tostring(tv()) .. "'", 0)
    end
    suffixes()
  end

  suffixes = function()
    while true do
      if accept(".") then
        if tt() ~= "name" then error("parse: expected field name", 0) end
        nxt()                                   -- field: not renamed
      elseif accept("[") then
        expr(); expect("]")
      elseif accept(":") then
        if tt() ~= "name" then error("parse: expected method name", 0) end
        nxt()                                   -- method name: not renamed
        callargs()
      elseif check("(") or tt() == "string" or check("{") then
        callargs()
      else
        break
      end
    end
  end

  callargs = function()
    if accept("(") then
      if not check(")") then explist() end
      expect(")")
    elseif tt() == "string" then
      nxt()
    elseif check("{") then
      tableconstructor()
    else
      error("parse: expected arguments", 0)
    end
  end

  explist = function()
    expr()
    while accept(",") do expr() end
  end

  tableconstructor = function()
    expect("{")
    while not check("}") do
      if accept("[") then
        expr(); expect("]"); expect("="); expr()
      elseif tt() == "name" and toks[p+1] and toks[p+1].type == "op"
             and toks[p+1].value == "=" then
        nxt(); expect("="); expr()             -- Name = exp : key not renamed
      else
        expr()
      end
      if not (accept(",") or accept(";")) then break end
    end
    expect("}")
  end

  funcbody = function(isMethod)
    pushScope()
    if isMethod then scopes[#scopes]["self"] = -1 end
    expect("(")
    if not check(")") then
      while true do
        if accept("...") then break end
        if tt() ~= "name" then error("parse: expected parameter", 0) end
        local idx, nm = toks[p].idx, tv(); nxt(); declare(nm, idx)
        if not accept(",") then break end
      end
    end
    expect(")")
    statlist()
    expect("end")
    popScope()
  end

  local function blockEnd()
    if tt() == "eof" then return true end
    if tt() == "keyword" then
      local v = tv()
      return v == "end" or v == "else" or v == "elseif" or v == "until"
    end
    return false
  end

  statlist = function()
    while not blockEnd() do
      if check("return") then
        nxt()
        if not blockEnd() and not check(";") then explist() end
        accept(";")
        break
      else
        statement()
      end
    end
  end

  exprstat = function()
    prefixexp()
    if check("=") or check(",") then
      while accept(",") do prefixexp() end
      expect("=")
      explist()
    end
  end

  statement = function()
    if accept(";") then return
    elseif accept("::") then
      if tt() ~= "name" then error("parse: expected label", 0) end
      nxt(); expect("::"); return
    elseif accept("break") then return
    elseif accept("goto") then
      if tt() ~= "name" then error("parse: expected goto label", 0) end
      nxt(); return
    elseif accept("do") then
      pushScope(); statlist(); popScope(); expect("end"); return
    elseif accept("while") then
      expr(); expect("do"); pushScope(); statlist(); popScope(); expect("end"); return
    elseif accept("repeat") then
      pushScope(); statlist(); expect("until"); expr(); popScope(); return
    elseif accept("if") then
      expr(); expect("then"); pushScope(); statlist(); popScope()
      while accept("elseif") do expr(); expect("then"); pushScope(); statlist(); popScope() end
      if accept("else") then pushScope(); statlist(); popScope() end
      expect("end"); return
    elseif accept("for") then
      if tt() ~= "name" then error("parse: expected loop variable", 0) end
      local firstIdx, firstNm = toks[p].idx, tv(); nxt()
      if check("=") then
        nxt(); expr(); expect(","); expr(); if accept(",") then expr() end
        expect("do"); pushScope(); declare(firstNm, firstIdx)
        statlist(); popScope(); expect("end")
      else
        local names = { { firstNm, firstIdx } }
        while accept(",") do
          if tt() ~= "name" then error("parse: expected loop variable", 0) end
          names[#names+1] = { tv(), toks[p].idx }; nxt()
        end
        expect("in"); explist(); expect("do"); pushScope()
        for _, nm in ipairs(names) do declare(nm[1], nm[2]) end
        statlist(); popScope(); expect("end")
      end
      return
    elseif accept("function") then
      if tt() ~= "name" then error("parse: expected function name", 0) end
      local idx, nm = toks[p].idx, tv(); nxt(); useName(idx, nm)
      local isMethod = false
      while true do
        if accept(".") then
          if tt() ~= "name" then error("parse: expected name", 0) end; nxt()
        elseif accept(":") then
          if tt() ~= "name" then error("parse: expected name", 0) end; nxt()
          isMethod = true; break
        else
          break
        end
      end
      funcbody(isMethod); return
    elseif accept("local") then
      if accept("function") then
        if tt() ~= "name" then error("parse: expected name", 0) end
        local idx, nm = toks[p].idx, tv(); nxt()
        declare(nm, idx)            -- visible inside its own body (recursion)
        funcbody(false); return
      else
        local names = {}
        if tt() ~= "name" then error("parse: expected name", 0) end
        names[#names+1] = { tv(), toks[p].idx }; nxt()
        while accept(",") do
          if tt() ~= "name" then error("parse: expected name", 0) end
          names[#names+1] = { tv(), toks[p].idx }; nxt()
        end
        if accept("=") then explist() end   -- RHS resolved in OUTER scope
        for _, nm in ipairs(names) do declare(nm[1], nm[2]) end
        return
      end
    else
      exprstat(); return
    end
  end

  pushScope()
  statlist()
  if tt() ~= "eof" then error("parse: unexpected '" .. tostring(tv()) .. "'", 0) end
  popScope()
  return renameId, globals, idc
end

----------------------------------------------------------------------
-- Rename allocation : every localId gets a unique short name that is not a
-- keyword and not equal to any global the program actually uses.
----------------------------------------------------------------------
local LETTERS = "abcdefghijklmnopqrstuvwxyz"
local function genName(k)
  local s = ""
  while k > 0 do
    local r = (k - 1) % 26
    s = LETTERS:sub(r+1, r+1) .. s
    k = math.floor((k - 1) / 26)
  end
  return s
end

local function buildNames(idc, globals)
  local out, k = {}, 0
  for id = 1, idc do
    local nm
    repeat
      k = k + 1
      nm = genName(k)
    until not globals[nm] and not KEYWORDS[nm] and nm ~= "self" and nm ~= "_ENV"
    out[id] = nm
  end
  return out
end

----------------------------------------------------------------------
-- Emitter : reconstruct minimal source from tokens, applying renames and
-- inserting a space only when two adjacent tokens would otherwise merge.
----------------------------------------------------------------------
local function needSpace(a, b)
  local la, fb = a:sub(-1), b:sub(1, 1)
  local function word(ch) return ch:match("[%w_]") ~= nil end
  if word(la) and word(fb) then return true end
  if la == "-" and fb == "-" then return true end
  if (la == "=" or la == "<" or la == ">" or la == "~") and fb == "=" then return true end
  if la == "." and fb == "." then return true end
  if la == ":" and fb == ":" then return true end
  if la == "[" and fb == "[" then return true end
  if la == "." and fb:match("%d") then return true end
  if la:match("%d") and fb == "." then return true end
  return false
end

local function emit(toks, renameId, newNames)
  local out, prev = {}, nil
  for i = 1, #toks do
    local t = toks[i]
    if t.type == "eof" then break end
    local text
    if t.type == "name" and renameId[t.idx] then
      text = newNames[renameId[t.idx]]
    else
      text = t.raw
    end
    if prev and needSpace(prev, text) then out[#out+1] = " " end
    out[#out+1] = text
    prev = text
  end
  return table.concat(out)
end

----------------------------------------------------------------------
-- Packing : base64 + XOR
----------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64encode(data)
  local t = {}
  for i = 1, #data, 3 do
    local a = data:byte(i)
    local b = data:byte(i+1)
    local c = data:byte(i+2)
    local n = a*65536 + (b or 0)*256 + (c or 0)
    t[#t+1] = B64:sub(math.floor(n/262144)%64 + 1, math.floor(n/262144)%64 + 1)
    t[#t+1] = B64:sub(math.floor(n/4096)%64 + 1,   math.floor(n/4096)%64 + 1)
    t[#t+1] = b and B64:sub(math.floor(n/64)%64 + 1, math.floor(n/64)%64 + 1) or "="
    t[#t+1] = c and B64:sub(n%64 + 1, n%64 + 1) or "="
  end
  return table.concat(t)
end

local function genKey(len)
  local t = {}
  for i = 1, len do t[i] = string.char(math.random(0, 255)) end
  return table.concat(t)
end

local function xorCrypt(data, key)
  local t, kl = {}, #key
  for i = 1, #data do
    t[i] = string.char(bit32.bxor(data:byte(i), key:byte((i-1) % kl + 1)))
  end
  return table.concat(t)
end

----------------------------------------------------------------------
-- Bundler : follow require()/dofile()/loadfile() with string-literal args,
-- pull every reachable .lua file into one chunk with a module registry and
-- shims. Resolution is rooted at the entry program's directory, matching how
-- CC:Tweaked sets up package.path for a program. Computed (non-literal)
-- arguments are left alone and fall back to the real functions at runtime.
----------------------------------------------------------------------
local DEP_KIND = { require = "require", dofile = "path", loadfile = "path" }

-- Scan a token stream for global require/dofile/loadfile calls with a single
-- string-literal argument. Returns a list of { kind = "require"|"path", value }.
local function scanDeps(toks)
  local deps = {}
  for i = 1, #toks do
    local t = toks[i]
    if t.type == "name" and DEP_KIND[t.value] then
      local prev = toks[i-1]
      local isField = prev and prev.type == "op" and (prev.value == "." or prev.value == ":")
      if not isField then
        local strtok
        local nt = toks[i+1]
        if nt and nt.type == "op" and nt.value == "(" then
          local a, b = toks[i+2], toks[i+3]
          if a and a.type == "string" and b and b.type == "op" and b.value == ")" then
            strtok = a
          end
        elseif nt and nt.type == "string" then
          strtok = nt
        end
        if strtok then
          local ok, val = pcall(function() return load("return " .. strtok.raw)() end)
          if ok and type(val) == "string" then
            deps[#deps+1] = { kind = DEP_KIND[t.value] == "require" and "require" or "path", value = val }
          end
        end
      end
    end
  end
  return deps
end

local function resolveRequire(name, root)
  local rel = name:gsub("%.", "/")
  for _, cand in ipairs({ rel, rel .. ".lua", rel .. "/init.lua" }) do
    local path = fs.combine(root, cand)
    if fs.exists(path) and not fs.isDir(path) then return path end
  end
  return nil
end

local function resolvePath(path, root)
  for _, cand in ipairs({ path, fs.combine(root, path), path .. ".lua", fs.combine(root, path .. ".lua") }) do
    if fs.exists(cand) and not fs.isDir(cand) then return cand end
  end
  return nil
end

local function readFileOrErr(path)
  local h = fs.open(path, "r")
  if not h then error("cannot read dependency: " .. path, 0) end
  local c = h.readAll(); h.close(); return c
end

local function serializeMap(m)
  local t = { "{" }
  for k, v in pairs(m) do
    t[#t+1] = "[" .. ("%q"):format(k) .. "]='" .. v .. "',"
  end
  t[#t+1] = "}"
  return table.concat(t)
end

-- Recursively read asset files (files and/or directories) into a map of
-- normalized-path -> raw bytes. Used to embed a read-only virtual filesystem.
-- Each entry is "src" (embedded at its own path) or "src@mount" (embedded so
-- the program reads it at <mount> instead of <src>).
local function gatherAssets(entries)
  local files = {}
  local function walk(realpath, key)
    if not fs.exists(realpath) then error("asset not found: " .. realpath, 0) end
    if fs.isDir(realpath) then
      for _, c in ipairs(fs.list(realpath)) do walk(fs.combine(realpath, c), key .. "/" .. c) end
    else
      local h = fs.open(realpath, "rb")
      if not h then error("cannot read asset: " .. realpath, 0) end
      files[fs.combine("", key)] = h.readAll(); h.close()
    end
  end
  for _, e in ipairs(entries) do
    local src, mount = e:match("^(.-)@(.+)$")
    if not src then src, mount = e, e end
    walk(src, mount)
  end
  return files
end

-- Serialize the embedded files into Lua source for three tables:
--   __FS[path]=bytes   __FD[dir]=true   __FL[dir]={child names}
local function buildFsTables(files)
  local dirset, listset = {}, {}
  local function reg(child)
    local parent, name = fs.getDir(child), fs.getName(child)
    listset[parent] = listset[parent] or {}
    listset[parent][name] = true
    if parent ~= "" then dirset[parent] = true; reg(parent) end
  end
  for n in pairs(files) do reg(n) end

  local fsP = { "{" }
  for n, data in pairs(files) do
    fsP[#fsP+1] = "[" .. ("%q"):format(n) .. "]=" .. ("%q"):format(data) .. ",\n"
  end
  fsP[#fsP+1] = "}"
  local fdP = { "{" }
  for d in pairs(dirset) do fdP[#fdP+1] = "[" .. ("%q"):format(d) .. "]=true," end
  fdP[#fdP+1] = "}"
  local flP = { "{" }
  for dir, names in pairs(listset) do
    flP[#flP+1] = "[" .. ("%q"):format(dir) .. "]={"
    for name in pairs(names) do flP[#flP+1] = ("%q"):format(name) .. "," end
    flP[#flP+1] = "},"
  end
  flP[#flP+1] = "}"
  return table.concat(fsP), table.concat(fdP), table.concat(flP)
end

-- Runtime VFS: a read-only fs proxy that serves embedded files first and
-- falls through to the real fs. Shadows the global `fs` for all bundled code.
local VFS_RUNTIME = [[
local __fs0=fs
local function __vnorm(p) return __fs0.combine("",p) end
local function __vhandle(data)
  local pos=1
  return {
    readAll=function() if pos>#data then return nil end local r=data:sub(pos) pos=#data+1 return r end,
    readLine=function(t)
      if pos>#data then return nil end
      local nl=data:find("\n",pos,true) local l
      if nl then l=data:sub(pos,t and nl or nl-1) pos=nl+1 else l=data:sub(pos) pos=#data+1 end
      return l
    end,
    read=function(c)
      if pos>#data then return nil end
      if c==nil then local b=data:byte(pos) pos=pos+1 return b end
      local r=data:sub(pos,pos+c-1) pos=pos+#r return r
    end,
    seek=function(w,o)
      w=w or "cur" o=o or 0
      if w=="set" then pos=o+1 elseif w=="end" then pos=#data+1+o else pos=pos+o end
      return pos-1
    end,
    close=function() end,
  }
end
local __vfs=setmetatable({},{__index=__fs0})
function __vfs.exists(p) local n=__vnorm(p) if __FS[n]~=nil or __FD[n] then return true end return __fs0.exists(p) end
function __vfs.isDir(p) local n=__vnorm(p) if __FD[n] then return true end if __FS[n]~=nil then return false end return __fs0.isDir(p) end
function __vfs.isReadOnly(p) local n=__vnorm(p) if __FS[n]~=nil or __FD[n] then return true end return __fs0.isReadOnly(p) end
function __vfs.getSize(p) local n=__vnorm(p) if __FS[n] then return #__FS[n] end return __fs0.getSize(p) end
function __vfs.list(p)
  local n=__vnorm(p) local seen,res={},{}
  if __fs0.exists(p) and __fs0.isDir(p) then for _,x in ipairs(__fs0.list(p)) do if not seen[x] then seen[x]=true res[#res+1]=x end end end
  if __FL[n] then for _,x in ipairs(__FL[n]) do if not seen[x] then seen[x]=true res[#res+1]=x end end end
  if not __fs0.exists(p) and not __FD[n] and not __FL[n] then error("/"..n..": Not a directory",2) end
  table.sort(res) return res
end
function __vfs.open(p,mode)
  local n=__vnorm(p)
  if (mode==nil or mode=="r" or mode=="rb") and __FS[n]~=nil then return __vhandle(__FS[n]) end
  return __fs0.open(p,mode)
end
local fs=__vfs
]]

-- Core require/dofile/loadfile machinery (assumes package/require/dofile/loadfile
-- and, when assets are present, the fs proxy are already declared above it).
local HARNESS_CORE = [[
local function __req(id)
  local c=__C[id]; if c~=nil then return c end
  local r=__M[id](); if r==nil then r=true end
  __C[id]=r; return r
end
local function __loadpath(path)
  if not fs.exists(path) or fs.isDir(path) then return nil,"file not found: "..path end
  local h=fs.open(path,"r"); local s=h.readAll(); h.close()
  local env=setmetatable({require=require,package=package},{__index=_ENV})
  return load(s,"@"..path,"t",env)
end
local function __search(name)
  local rel=name:gsub("%.","/")
  local roots={"","/rom/modules/main/","/rom/modules/turtle/","/rom/modules/command/"}
  for _,root in ipairs(roots) do
    for _,suf in ipairs({rel..".lua",rel.."/init.lua",rel}) do
      local p=root..suf
      if fs.exists(p) and not fs.isDir(p) then return p end
    end
  end
  return nil
end
local function __loadmod(name)
  local p=__search(name)
  if not p then return nil end
  local fn,e=__loadpath(p)
  if not fn then error(e,2) end
  local v=fn(name,p); if v==nil then v=true end
  return v
end
require=function(name)
  local id=__reqmap[name]
  if id then return __req(id) end
  if package.loaded and package.loaded[name]~=nil then return package.loaded[name] end
  if package.preload and package.preload[name] then
    local v=package.preload[name](name); if v==nil then v=true end
    if package.loaded then package.loaded[name]=v end
    return v
  end
  if __require0 then return __require0(name) end
  local v=__loadmod(name)
  if v~=nil then if package.loaded then package.loaded[name]=v end return v end
  error("module '"..tostring(name).."' not found",2)
end
dofile=function(path,...)
  local id=__pathmap[path]
  if id then return __M[id](...) end
  if __dofile0 then return __dofile0(path,...) end
  local fn,e=__loadpath(path); if not fn then error(e,2) end
  return fn(...)
end
loadfile=function(path,...)
  local id=__pathmap[path]
  if id then return __M[id] end
  if __loadfile0 then return __loadfile0(path,...) end
  return __loadpath(path)
end
]]

-- Build a single bundled source from the entry file. Returns the bundle string
-- and the number of bundled modules. Embeds asset files as a read-only VFS.
local function bundle(mainPath, assetPaths)
  local root = fs.getDir(mainPath)
  local modules, reqmap, pathmap, byfile, counter = {}, {}, {}, {}, 0

  local addFile
  addFile = function(path)
    if byfile[path] then return byfile[path] end
    counter = counter + 1
    local id = "m" .. counter
    byfile[path] = id                       -- set before recursing (cycle-safe)
    local src = readFileOrErr(path)
    local f, e = load(src, "@" .. path)
    if not f then error("syntax error in dependency '" .. path .. "': " .. tostring(e), 0) end
    modules[id] = src
    for _, dep in ipairs(scanDeps(lex(src))) do
      if dep.kind == "require" then
        if reqmap[dep.value] == nil then
          local rp = resolveRequire(dep.value, root)
          if rp then reqmap[dep.value] = addFile(rp) end
        end
      else
        if pathmap[dep.value] == nil then
          local rp = resolvePath(dep.value, root)
          if rp then pathmap[dep.value] = addFile(rp) end
        end
      end
    end
    return id
  end

  local mainId = addFile(mainPath)

  local files = (assetPaths and #assetPaths > 0) and gatherAssets(assetPaths) or {}
  local hasAssets = next(files) ~= nil

  -- Nothing to bundle and no assets: pack the source as-is.
  if counter == 1 and next(reqmap) == nil and next(pathmap) == nil and not hasAssets then
    return modules[mainId], 1
  end

  local p = {
    "local __M={}\nlocal __C={}\n",
    "local __require0=require\nlocal __dofile0=dofile\n",
    "local __loadfile0=loadfile\nlocal __package0=package\n",
    "local __reqmap=" .. serializeMap(reqmap) .. "\n",
    "local __pathmap=" .. serializeMap(pathmap) .. "\n",
  }
  if hasAssets then
    local fsT, fdT, flT = buildFsTables(files)
    p[#p+1] = "local __FS=" .. fsT .. "\nlocal __FD=" .. fdT .. "\nlocal __FL=" .. flT .. "\n"
  end
  p[#p+1] = 'local package=__package0 or {loaded={},preload={},path="?;?.lua;?/init.lua",cpath="",config=""}\n'
  p[#p+1] = "local require,dofile,loadfile\n"
  if hasAssets then p[#p+1] = VFS_RUNTIME end
  p[#p+1] = HARNESS_CORE
  for id, src in pairs(modules) do
    p[#p+1] = "__M['" .. id .. "']=function(...)\n" .. src .. "\nend\n"
  end
  p[#p+1] = "return __M['" .. mainId .. "'](...)\n"
  return table.concat(p), counter
end

----------------------------------------------------------------------
-- Loader template : the self-decrypting program that gets written out.
----------------------------------------------------------------------
local function buildLoader(keyB64, ctB64, name)
  return table.concat({
    "-- Compiled with ccc. Do not edit; source is packed below.\n",
    "local B='", keyB64, "'\n",
    "local C='", ctB64, "'\n",
    "local N='", name, "'\n",
    [[
local bc="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local lut={} for i=1,#bc do lut[bc:sub(i,i)]=i-1 end
local function dec(s)
  local o,i={},1
  while i<=#s do
    local a=lut[s:sub(i,i)] or 0
    local b=lut[s:sub(i+1,i+1)] or 0
    local c=s:sub(i+2,i+2)
    local e=s:sub(i+3,i+3)
    local n=a*262144+b*4096+(lut[c] or 0)*64+(lut[e] or 0)
    o[#o+1]=string.char(math.floor(n/65536)%256)
    if c~="=" and c~="" then o[#o+1]=string.char(math.floor(n/256)%256) end
    if e~="=" and e~="" then o[#o+1]=string.char(n%256) end
    i=i+4
  end
  return table.concat(o)
end
local key,ct=dec(B),dec(C)
local kl,src=#key,{}
for i=1,#ct do src[i]=string.char(bit32.bxor(ct:byte(i),key:byte((i-1)%kl+1))) end
local fn,err=load(table.concat(src),"@"..N)
if not fn then error("ccc: corrupted binary ("..tostring(err)..")",0) end
return fn(...)
]],
  })
end

----------------------------------------------------------------------
-- CLI
----------------------------------------------------------------------
local function readFile(path)
  if not fs.exists(path) then error("input not found: " .. path, 0) end
  local h = fs.open(path, "r"); local c = h.readAll(); h.close(); return c
end
local function writeFile(path, data)
  if fs.isDir(path) then error("output path is a directory: " .. path, 0) end
  if fs.isReadOnly(path) then error("output path is read-only: " .. path, 0) end
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h, err = fs.open(path, "w")
  if not h then error("cannot write '" .. path .. "': " .. tostring(err), 0) end
  h.write(data); h.close()
end

-- Prologue that locks the binary to specific computer IDs.
local function licensePrologue(ids)
  local t = { "local __cid=os.getComputerID() if not ({" }
  for _, id in ipairs(ids) do t[#t+1] = "[" .. id .. "]=true," end
  t[#t+1] = "})[__cid] then printError(\"This program is not licensed for computer #\"..__cid)"
  t[#t+1] = " error(\"ccc: unlicensed computer\",0) end\n"
  return table.concat(t)
end

local function main(...)
  local argv = { ... }
  local input, output
  local doMinify, doRename, doBundle = true, true, true
  local assetPaths, lockIds = {}, {}
  for _, a in ipairs(argv) do
    if a == "--no-minify" then doMinify = false
    elseif a == "--no-rename" then doRename = false
    elseif a == "--no-bundle" then doBundle = false
    elseif a:match("^%-%-asset=") then assetPaths[#assetPaths+1] = a:sub(9)
    elseif a:match("^%-%-lock=") then
      for id in a:sub(8):gmatch("[^,]+") do
        local nid = tonumber(id)
        if nid then lockIds[#lockIds+1] = nid end
      end
    elseif not input then input = a
    elseif not output then output = a end
  end
  if not input then
    print("Usage: ccc <input.lua> [output] [options]")
    print("  --asset=<path>   embed a file or folder as a read-only VFS (repeatable)")
    print("  --lock=<id,...>  only run on these computer IDs (os.getComputerID)")
    print("  --no-bundle      do not follow require/dofile/loadfile")
    print("  --no-rename      keep original local names (safest minify)")
    print("  --no-minify      encrypt only, no minify/rename")
    return
  end

  local base = input:gsub("%.lua$", "")
  if not output then
    output = base
    -- avoid colliding with the input itself or an existing directory
    if output == input or fs.isDir(output) then output = base .. ".cc" end
  end
  local appname = fs.getName(output):gsub("'", "")

  math.randomseed(os.epoch("utc"))

  local source = readFile(input)

  -- 1. validate the ORIGINAL source first
  local okf, okerr = load(source, "@" .. input)
  if not okf then
    printError("Source has syntax errors, aborting:")
    printError(tostring(okerr))
    return
  end

  -- 2. bundle dependencies + embed assets into one chunk
  local nmods = 1
  if doBundle or #assetPaths > 0 then
    local ok, res, n = pcall(bundle, input, assetPaths)
    if not ok then
      printError("Bundling failed, aborting:")
      printError(tostring(res))
      return
    end
    source, nmods = res, n
  end

  -- 3. lock to specific computer IDs (runs before everything else)
  if #lockIds > 0 then source = licensePrologue(lockIds) .. source end

  -- 4. minify / rename (optional)
  local code = source
  if doMinify then
    local toks = lex(source)
    local renameId, newNames = {}, {}
    if doRename then
      local rid, globals, idc = parse(toks)
      renameId, newNames = rid, buildNames(idc, globals)
    end
    code = emit(toks, renameId, newNames)
  end

  -- 5. SAFETY NET: the packed code must still compile. If not, refuse to
  --    write a broken binary and tell the user how to recover.
  local mf, me = load(code, "@" .. input)
  if not mf then
    printError("Internal: packed output failed to load, aborting.")
    printError(tostring(me))
    printError("Re-run with --no-rename (or --no-minify) and please report this.")
    return
  end

  -- 6. encrypt + encode + wrap
  local key = genKey(16)
  local loader = buildLoader(b64encode(key), b64encode(xorCrypt(code, key)), appname)
  writeFile(output, loader)

  print(("ccc: %s -> %s"):format(input, output))
  if nmods > 1 then print(("  bundled  %d modules"):format(nmods)) end
  if #assetPaths > 0 then print(("  assets   %d path(s) embedded"):format(#assetPaths)) end
  if #lockIds > 0 then print(("  locked   to computer #%s"):format(table.concat(lockIds, ", #"))) end
  print(("  source   %d bytes"):format(#source))
  if doMinify then print(("  minified %d bytes"):format(#code)) end
  print(("  binary   %d bytes"):format(#loader))
end

main(...)
