local http = require("replaice.providers.http")

local M = {}

local function output_text(response)
  local chunks = {}
  for _, item in ipairs(response.output or {}) do
    if item.type == "message" then
      for _, content in ipairs(item.content or {}) do
        if content.type == "output_text" and content.text then
          table.insert(chunks, content.text)
        end
      end
    end
  end
  return table.concat(chunks)
end

function M.request(config, request, callback)
  local api_key = config.api_key or (config.api_key_env and vim.env[config.api_key_env])
  if not api_key or api_key == "" then
    callback("missing OpenAI API key; set " .. (config.api_key_env or "providers.openai.api_key"))
    return
  end
  http.post(config.endpoint, {
    model = request.model,
    instructions = request.instructions,
    input = request.input,
  }, { "Authorization: Bearer " .. api_key }, config.timeout, function(err, response)
    if err then
      callback(err)
      return
    end
    local text = output_text(response)
    if text == "" then
      callback("OpenAI response did not contain output text")
      return
    end
    callback(nil, text)
  end)
end

return M
