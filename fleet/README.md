# fleet — master/agent control for many CC computers

One **master** computer (with a monitor) watches and commands a fleet of
**agent** computers over a modem network. Designed for hundreds of nodes.

```
fleet/
  agent.lua    runs on every managed node
  master.lua   runs on the master (dashboard + command console)
```

## The channel limit (important)

A modem can have at most **128 channels open at once**. So this system does
**not** give each node its own channel — that would break at ~128 nodes.
Instead everything uses **one rednet broadcast channel** plus the master's own
ID channel. The master broadcasts a single message; all nodes (500+) receive it
on the shared broadcast channel and reply to the master's ID. Two channels
total, no matter how big the fleet.

## Setup

1. Pick a shared secret and set `SECRET` to the **same value** in both
   `agent.lua` and `master.lua` (default `"changeme"`). This stops other
   computers from issuing commands.
2. **Agents:** put `agent.lua` on each node and have it run on boot. Easiest:
   make `startup.lua` contain `shell.run("fleet-agent")` (after
   `apt install fleet-agent`) or `shell.run("agent.lua")`.
   Each node needs a modem (the same wired modem that connects it to the master
   network is fine).
3. **Master:** run `fleet-master`. The **monitor** shows the dashboard; type
   commands on the **computer's own terminal**.

## Master console commands

```
help                 list commands
run <shellcmd>       run a shell command on every node (e.g. run apt update)
lua <code>           run a Lua snippet on every node
reboot all           reboot every node
shutdown all         shut down every node
refresh              force an immediate status sweep
quit                 exit
```

After `run`/`lua`, the master collects replies for a few seconds and reports
`<N> ok, <M> failed` plus a few failure samples.

## Dashboard (monitor)

- online / known node counts
- counts by kind (computer / turtle / pocket)
- summed free / total disk across the fleet
- wired peripheral inventory (computers, drives physically attached to master)
- a paged list of nodes (id, label, kind, free space, seconds since last seen)
  that auto-cycles pages so all nodes scroll past

## Scaling notes for ~500 nodes

- **Reply bursts:** a broadcast triggers ~500 near-simultaneous replies. rednet
  queues them; the master drains them in its event loop. This is fine, but
  command-reply collection windows (`RUN_COLLECT`, default 3s) may need bumping
  if some replies arrive late.
- **Output size:** `run`/`lua` return each node's output. For 500 nodes that's
  a lot of traffic; prefer commands whose success/fail is what matters
  (`apt update`, `reboot`), not ones that print pages of text.
- **Wired vs wireless:** on a wired network all nodes share the cabled modem
  network — broadcast reaches everyone. With ender (wireless) modems it works
  the same and is range-independent.
- **Deploying the agent to 500 nodes:** bootstrap once (disk or
  `apt install fleet-agent`), set startup, then use `fleet-master`'s `reboot
  all` / `run` to manage them from then on.

## Distribute via apt

Both are packaged: `apt install fleet-agent` on nodes, `apt install
fleet-master` on the master (see the parent `apt/` system).
