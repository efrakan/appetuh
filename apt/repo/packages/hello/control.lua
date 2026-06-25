return {
  name         = "hello",
  version      = "1.0.0",
  description  = "Prints a friendly greeting.",
  dependencies = {},
  -- Files are stored under this package's files/ folder and installed to
  -- the given paths (relative to root) on the client.
  files        = { "bin/hello.lua" },
}
