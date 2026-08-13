local M = {}

function M.setup(options)
  local config = require("replaice.config")
  local resolved = config.setup(options)

  if resolved.keymap and resolved.keymap ~= "" then
    vim.keymap.set("x", resolved.keymap, function()
      require("replaice.workflow").run()
    end, { desc = "Rewrite selected text with AI" })
  end
end

function M.replace(prompt)
  require("replaice.workflow").run(prompt)
end

return M
