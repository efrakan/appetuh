return {
  name         = "groupctl",
  version      = "1.0.0",
  description  = "Define/inspect machine groups (rows of depots/basins) for tools.",
  dependencies = {},
  files        = {
    ["bin/groupctl.lua"]   = "/groupctl.lua",
    ["bin/lib/groups.lua"] = "/lib/groups.lua",
  },
}
