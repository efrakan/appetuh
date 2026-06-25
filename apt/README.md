# apt — a package manager for CC:Tweaked (over rednet)

A miniature APT: a **repository server** hosts packages and serves them to
**client** computers over a modem (wired or wireless). Clients can update their
package lists, install packages with automatic dependency resolution, remove,
upgrade, search and inspect them.

```
apt/
  apt.lua            client CLI (run on each client computer)
  aptd.lua           repository server daemon (run on the repo computer)
  lib/proto.lua      shared rednet protocol (required by both)
  repo/              example repository with two packages
    packages/
      hello/         control.lua + files/bin/hello.lua
      welcome/       depends on hello
```

## Requirements

- Every computer (server + clients) needs a **modem** attached (wireless ender
  modems work network-wide; wired modems work along connected cable).
- The server and clients must be on the **same modem network**.

## 1. Set up the server

Put `aptd.lua`, `lib/proto.lua`, and a `repo/` folder on the server computer
(the example `repo/` here is ready to use), then run:

```
aptd                 # serves /apt/repo
aptd /path/to/repo   # or point it at a different repository
```

The server prints what it's serving and listens until you stop it (`Ctrl+T`).
It **re-scans the repo on every request**, so you can add packages without
restarting it. Consider adding it to `startup.lua` so it runs on boot.

## 2. Use a client

Put `apt.lua` and `lib/proto.lua` on a client computer, then:

```
apt update             # discover repos and fetch package lists
apt list               # see what's available
apt search hello       # search names/descriptions
apt show welcome       # details, including dependencies
apt install welcome    # installs 'hello' (dependency) then 'welcome'
apt list --installed
apt upgrade            # upgrade everything to newer versions
apt remove welcome
```

### Running installed programs

Packages in the example install programs into `/bin`. `/bin` isn't on the shell
path by default, so either run them by path (`/bin/welcome.lua`) or add `/bin`
to your path for the session:

```
shell.setPath(shell.path() .. ":/bin")
```

To make that permanent, put it in the client's `startup.lua`.

## 3. Create your own package

A package is a folder under `repo/packages/<name>/`:

```
repo/packages/mytool/
  control.lua            metadata
  files/                 payload, laid out by install path
    bin/mytool.lua
    lib/mytool/util.lua
```

`control.lua` returns a table:

```lua
return {
  name         = "mytool",
  version      = "1.2.0",                 -- dotted numeric version
  description  = "Does useful things.",
  dependencies = { "hello" },             -- other package names
  files        = { "bin/mytool.lua",      -- each path is read from files/<path>
                   "lib/mytool/util.lua" }, -- and installed to /<path> on clients
}
```

Drop the folder into the server's `repo/packages/`, and clients will see it
after the next `apt update`. Bump `version` to push an upgrade.

## How it works

- **Discovery** — the server calls `rednet.host("apt", <label>)`; clients call
  `rednet.lookup("apt")` to find all repos.
- **Protocol** — JSON-like Lua tables over rednet:
  - `{cmd="LIST"}` → `{ok=true, packages={ {name,version,description,dependencies,size}, ... }}`
  - `{cmd="FETCH", name=...}` → `{ok=true, version=..., files={ ["dest/path"]=contents, ... }}`
- **Client state** lives in `/var/apt/`: `lists.tbl` (cached index) and
  `installed.tbl` (which packages/files are installed, for clean removal).
- **Dependencies** are resolved depth-first before install; versions are
  compared numerically (`1.10.0` > `1.9.0`).

## Tip: ship these as compiled binaries

Because the client/server `require("lib.proto")`, you can pack each into a
single distributable binary with the `ccc` compiler in the parent folder:

```
ccc apt/apt.lua  apt        # bundles lib.proto -> single 'apt' binary
ccc apt/aptd.lua aptd
```
