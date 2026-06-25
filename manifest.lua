-- manifest.lua : single source of truth for what install.lua fetches.
-- Edit this file in your repo to add/remove/relocate programs; install.lua and
-- `apt selfupdate` read it automatically. Keys are remote paths (relative to
-- your repo's raw base URL); values are local install paths.
return {
  version = "1.0.0",
  files = {
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
    ["aifactory.lua"]     = "/bin/aifactory.lua",
    ["groupctl.lua"]      = "/bin/groupctl.lua",
    ["recipectl.lua"]     = "/bin/recipectl.lua",
    ["recipe_presets.lua"] = "/bin/recipe_presets.lua",
    ["storage.lua"]       = "/bin/storage.lua",
    ["lib/groups.lua"]    = "/bin/lib/groups.lua",   -- required by aifactory & groupctl
    ["lib/recipes.lua"]   = "/bin/lib/recipes.lua",  -- required by aifactory & recipectl
    ["fleet/agent.lua"]   = "/bin/fleet-agent.lua",
    ["fleet/master.lua"]  = "/bin/fleet-master.lua",
    ["fleet/deploy.lua"]  = "/bin/fleet-deploy.lua",
  },
}
