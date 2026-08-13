local M = {}

function M.post(endpoint, body, headers, timeout, callback)
  if vim.fn.executable("curl") ~= 1 then
    callback("replaice requires curl for built-in HTTP providers")
    return
  end

  local command = {
    "curl",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--max-time",
    tostring(timeout or 120),
    "--request",
    "POST",
    endpoint,
    "--header",
    "Content-Type: application/json",
  }
  for _, header in ipairs(headers or {}) do
    vim.list_extend(command, { "--header", header })
  end
  vim.list_extend(command, { "--data-binary", vim.json.encode(body) })

  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = vim.trim(table.concat({ result.stderr or "", result.stdout or "" }, "\n"))
        callback(("request failed (%d): %s"):format(result.code, message))
        return
      end
      local ok, decoded = pcall(vim.json.decode, result.stdout)
      if not ok then
        callback("provider returned invalid JSON: " .. decoded)
        return
      end
      callback(nil, decoded)
    end)
  end)
end

return M
