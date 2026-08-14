local M = {}
local pending_namespace = vim.api.nvim_create_namespace("replaice_pending")

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
    winid = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_get_current_win() or nil,
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

function M.clear_highlight(selection)
  if selection.pending_highlight and vim.api.nvim_buf_is_valid(selection.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, selection.bufnr, pending_namespace, selection.pending_highlight)
  end
  selection.pending_highlight = nil
end

function M.highlight(selection)
  if not vim.api.nvim_buf_is_valid(selection.bufnr) then
    return false
  end
  M.clear_highlight(selection)
  vim.api.nvim_set_hl(0, "ReplaicePending", { link = "Visual", default = true })
  selection.pending_highlight = vim.api.nvim_buf_set_extmark(
    selection.bufnr,
    pending_namespace,
    selection.start_row,
    selection.start_col,
    {
      end_row = selection.end_row,
      end_col = selection.end_col,
      hl_group = "ReplaicePending",
      hl_eol = selection.kind == "line",
      priority = 200,
    }
  )
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

local function source_window(selection)
  if selection.winid
      and vim.api.nvim_win_is_valid(selection.winid)
      and vim.api.nvim_win_get_buf(selection.winid) == selection.bufnr then
    return selection.winid
  end
  for _, winid in ipairs(vim.fn.win_findbuf(selection.bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      return winid
    end
  end
end

local function last_character_col(text)
  local byte = #text
  while byte > 1 do
    local value = text:byte(byte)
    if value < 0x80 or value > 0xBF then
      break
    end
    byte = byte - 1
  end
  return byte - 1
end

function M.reselect(selection, replacement)
  if not vim.api.nvim_buf_is_valid(selection.bufnr) then
    return false
  end
  local winid = source_window(selection)
  if not winid then
    return false
  end

  local lines = vim.split(replacement, "\n", { plain = true })
  vim.api.nvim_set_current_win(winid)
  vim.cmd("normal! \27")
  vim.api.nvim_win_set_cursor(winid, { selection.start_row + 1, selection.start_col })

  if replacement == "" then
    return true
  end
  if selection.kind == "line" then
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(winid, { selection.start_row + #lines, 0 })
    return true
  end

  local end_row = selection.start_row + #lines - 1
  local end_col
  if vim.o.selection == "exclusive" then
    end_col = #lines[#lines]
  elseif lines[#lines] ~= "" then
    end_col = last_character_col(lines[#lines])
  else
    local previous = #lines - 1
    while previous > 0 and lines[previous] == "" do
      previous = previous - 1
    end
    if previous == 0 then
      return true
    end
    end_row = selection.start_row + previous - 1
    end_col = last_character_col(lines[previous])
  end
  if end_row == selection.start_row then
    end_col = selection.start_col + end_col
  end
  vim.cmd("normal! v")
  vim.api.nvim_win_set_cursor(winid, { end_row + 1, end_col })
  return true
end

return M
