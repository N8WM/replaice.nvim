if vim.g.loaded_replaice then
  return
end
vim.g.loaded_replaice = true

vim.api.nvim_create_user_command("Replaice", function(command)
  require("replaice").replace(command.args ~= "" and command.args or nil)
end, {
  nargs = "*",
  desc = "Rewrite the most recent visual selection with AI",
})
