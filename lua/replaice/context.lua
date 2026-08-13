local M = {}

local function left(text, limit)
  if #text <= limit then
    return text
  end
  return "[…earlier text omitted…]\n" .. text:sub(#text - limit + 1)
end

local function right(text, limit)
  if #text <= limit then
    return text
  end
  return text:sub(1, limit) .. "\n[…later text omitted…]"
end

function M.capture(selection, options)
  local bufnr = selection.bufnr
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local max_lines = options.max_lines
  local half = math.floor(options.max_chars / 2)

  local before_start = math.max(0, selection.start_row - max_lines)
  local before
  if selection.kind == "line" then
    before = table.concat(vim.api.nvim_buf_get_lines(bufnr, before_start, selection.start_row, false), "\n")
  else
    before = table.concat(
      vim.api.nvim_buf_get_text(bufnr, before_start, 0, selection.start_row, selection.start_col, {}),
      "\n"
    )
  end

  local after_end = math.min(line_count, selection.end_row + max_lines + 1)
  local after
  if selection.kind == "line" then
    after = table.concat(vim.api.nvim_buf_get_lines(bufnr, selection.end_row, after_end, false), "\n")
  else
    local last_line = vim.api.nvim_buf_get_lines(bufnr, after_end - 1, after_end, false)[1] or ""
    after = table.concat(
      vim.api.nvim_buf_get_text(bufnr, selection.end_row, selection.end_col, after_end - 1, #last_line, {}),
      "\n"
    )
  end

  return {
    before = left(before, half),
    selected = selection.text,
    after = right(after, half),
    filetype = vim.bo[bufnr].filetype,
    filename = vim.api.nvim_buf_get_name(bufnr),
  }
end

function M.document(context, replacement)
  return table.concat({
    context.before,
    "<REPLAICE_SELECTION>",
    replacement or context.selected,
    "</REPLAICE_SELECTION>",
    context.after,
  }, "\n")
end

return M
