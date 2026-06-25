return {
  name         = "aifactory",
  version      = "1.0.0",
  description  = "Natural-language Create base control via Google Gemini.",
  dependencies = {},
  files        = {
    ["bin/aifactory.lua"]   = "/aifactory.lua",
    ["bin/lib/groups.lua"]  = "/lib/groups.lua",   -- aifactory require("lib.groups")
    ["bin/lib/recipes.lua"] = "/lib/recipes.lua",  -- aifactory require("lib.recipes")
  },
}
