local http = require("replaice.providers.http")

local M = {}

function M.request(config, request, callback)
  local headers = {}
  local api_key = config.api_key or (config.api_key_env and vim.env[config.api_key_env])
  if api_key and api_key ~= "" then
    table.insert(headers, "Authorization: Bearer " .. api_key)
  end
  http.post(config.endpoint, {
    model = request.model,
    messages = {
      { role = "system", content = request.instructions },
      { role = "user", content = request.input },
    },
    stream = false,
  }, headers, config.timeout, function(err, response)
    if err then
      callback(err)
      return
    end
    local text = response.choices
      and response.choices[1]
      and response.choices[1].message
      and response.choices[1].message.content
    if type(text) ~= "string" then
      callback("OpenAI-compatible response did not contain choices[1].message.content")
      return
    end
    callback(nil, text)
  end)
end

return M
