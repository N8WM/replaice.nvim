local M = {}

function M.check()
  vim.health.start("replaice.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim 0.10+")
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl is available")
  else
    vim.health.error("curl is required by the built-in providers")
  end

  local options = require("replaice.config").options
  if type(options.provider) == "function" then
    vim.health.ok("custom provider configured")
  elseif options.providers[options.provider] then
    vim.health.ok("provider configured: " .. options.provider)
  else
    vim.health.error("unknown provider: " .. tostring(options.provider))
  end

  if options.provider == "openai" then
    local provider = options.providers.openai
    local key = provider.api_key or (provider.api_key_env and vim.env[provider.api_key_env])
    if key and key ~= "" then
      vim.health.ok("OpenAI API key is available")
    else
      vim.health.warn("OpenAI API key is missing; set " .. (provider.api_key_env or "providers.openai.api_key"))
    end
  end
end

return M
