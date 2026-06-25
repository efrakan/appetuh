return {
  name         = "fleet-agent",
  version      = "1.0.0",
  description  = "Fleet node agent: listens for the master's broadcasts.",
  dependencies = {},
  files        = { ["bin/fleet-agent.lua"] = "/fleet/agent.lua" },
}
