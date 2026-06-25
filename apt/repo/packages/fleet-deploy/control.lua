return {
  name         = "fleet-deploy",
  version      = "1.0.0",
  description  = "Write the fleet agent + auto-installer to disks in drives.",
  dependencies = {},
  files        = { ["bin/fleet-deploy.lua"] = "/fleet/deploy.lua" },
}
