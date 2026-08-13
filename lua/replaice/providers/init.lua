local M = {}

function M.request(options, request, callback)
  if type(options.provider) == "function" then
    local ok, err = pcall(options.provider, request, callback)
    if not ok then
      callback("custom provider failed: " .. err)
    end
    return
  end

  local provider_config = options.providers[options.provider]
  if not provider_config then
    callback("unknown provider: " .. options.provider)
    return
  end
  local ok, provider = pcall(require, "replaice.providers." .. options.provider)
  if not ok then
    callback("could not load provider " .. options.provider .. ": " .. provider)
    return
  end
  provider.request(provider_config, request, callback)
end

return M
