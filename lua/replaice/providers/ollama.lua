local http = require("replaice.providers.http")

local M = {}

function M.request(config, request, callback)
  http.post(config.endpoint, {
    model = request.model,
    messages = {
      { role = "system", content = request.instructions },
      { role = "user", content = request.input },
    },
    stream = false,
  }, {}, config.timeout, function(err, response)
    if err then
      callback(err)
      return
    end
    local text = response.message and response.message.content
    if type(text) ~= "string" then
      callback("Ollama response did not contain message.content")
      return
    end
    callback(nil, text)
  end)
end

return M
