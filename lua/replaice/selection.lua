local M = {}

function M.capture(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local active_mode = vim.fn.mode()
  local is_active = active_mode == "v" or active_mode == "V" or active_mode == "\022"
  local mode = is_active and active_mode or vim.fn.visualmode()
  if mode == "\022" then
    return nil, "blockwise selections are not supported"
  end
  if mode ~= "v" and mode ~= "V" then
    return nil, "make a visual selection first"
  end

  local anchor = is_active and vim.fn.getpos("v") or vim.fn.getpos("'<")
  local cursor = is_active and vim.fn.getpos(".") or vim.fn.getpos("'>")
  if anchor[2] == 0 or cursor[2] == 0 then
    return nil, "make a visual selection first"
  end
  anchor[1] = bufnr
  cursor[1] = bufnr
  local region_options = { type = mode, exclusive = vim.o.selection == "exclusive", eol = true }
  local regions = vim.fn.getregionpos(anchor, cursor, region_options)
  local selected_lines = vim.fn.getregion(anchor, cursor, region_options)
  if #regions == 0 then
    return nil, "could not resolve the visual selection"
  end
  local first = regions[1][1]
  local last = regions[#regions][2]
  if first[4] ~= 0 or last[4] ~= 0 then
    return nil, "selections inside virtual columns are not supported"
  end

  local selection = {
    bufnr = bufnr,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    kind = mode == "V" and "line" or "char",
    was_active = is_active,
    start_row = first[2] - 1,
  }

  if selection.kind == "line" then
    selection.start_col = 0
    selection.end_row = last[2]
    selection.end_col = 0
    selection.lines = selected_lines
  else
    selection.start_col = first[3] - 1
    selection.end_row = last[2] - 1
    local end_line = vim.api.nvim_buf_get_lines(bufnr, selection.end_row, selection.end_row + 1, false)[1]
    if last[3] == 2147483647 then
      selection.end_col = #end_line
    else
      -- getregionpos() reports an inclusive ending byte column. Neovim's
      -- buffer APIs expect an exclusive zero-based byte offset; numerically
      -- those values are the same (and this also handles multibyte text).
      selection.end_col = math.min(#end_line, last[3])
    end
    selection.lines = selected_lines
  end

  selection.text = table.concat(selection.lines, "\n")
  return selection
end

local function current_lines(selection)
  if selection.kind == "line" then
    return vim.api.nvim_buf_get_lines(selection.bufnr, selection.start_row, selection.end_row, false)
  end
  return vim.api.nvim_buf_get_text(
    selection.bufnr,
    selection.start_row,
    selection.start_col,
    selection.end_row,
    selection.end_col,
    {}
  )
end

function M.validate(selection)
  if not vim.api.nvim_buf_is_valid(selection.bufnr) then
    return false, "the original buffer no longer exists"
  end
  if not vim.bo[selection.bufnr].modifiable then
    return false, "the original buffer is not modifiable"
  end
  if vim.api.nvim_buf_get_changedtick(selection.bufnr) ~= selection.changedtick then
    return false, "the buffer changed while Replaice was working; select the text again"
  end
  if table.concat(current_lines(selection), "\n") ~= selection.text then
    return false, "the selected text changed while Replaice was working"
  end
  return true
end

function M.apply(selection, replacement)
  local ok, err = M.validate(selection)
  if not ok then
    return false, err
  end

  local lines = vim.split(replacement, "\n", { plain = true })
  if selection.kind == "line" then
    vim.api.nvim_buf_set_lines(selection.bufnr, selection.start_row, selection.end_row, false, lines)
  else
    vim.api.nvim_buf_set_text(
      selection.bufnr,
      selection.start_row,
      selection.start_col,
      selection.end_row,
      selection.end_col,
      lines
    )
  end
  return true
end

return M
