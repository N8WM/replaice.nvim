local M = {}

local function dimensions(lines)
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, math.floor(vim.o.columns * 0.8))
  local height = math.min(math.max(#lines, 3), math.floor(vim.o.lines * 0.7))
  return width, height
end

function M.open(text, filetype, callbacks)
  local lines = vim.split(text, "\n", { plain = true })
  local width, height = dimensions(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = filetype
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local status = callbacks.approved == true and "reviewer approved"
    or callbacks.approved == false and "not reviewer-approved"
    or "review disabled"
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Replaice: " .. status .. " — a accept · r retry · q cancel ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function value()
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end

  vim.keymap.set("n", "a", function()
    local replacement = value()
    close()
    callbacks.accept(replacement)
  end, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "r", function()
    local replacement = value()
    close()
    callbacks.retry(replacement)
  end, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "q", function()
    close()
    if callbacks.cancel then
      callbacks.cancel()
    end
  end, { buffer = bufnr, nowait = true })
end

return M
