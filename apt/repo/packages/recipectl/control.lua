return {
  name         = "recipectl",
  version      = "1.0.0",
  description  = "Manage the factory recipe book (output -> inputs + group) for aifactory.",
  dependencies = {},
  files        = {
    ["bin/recipectl.lua"]   = "/recipectl.lua",
    ["bin/lib/recipes.lua"] = "/lib/recipes.lua",
  },
}
