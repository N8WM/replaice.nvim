local M = {}

local namespace = vim.api.nvim_create_namespace("replaice_picker")
local active_session

local Session = {}
Session.__index = Session

local function split(text)
  return vim.split(text or "", "\n", { plain = true })
end

local function append(lines, text, prefix)
  for _, line in ipairs(split(text)) do
    table.insert(lines, (prefix or "") .. line)
  end
end

local function set_lines(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

local function offset_position(text, offset)
  local prefix = text:sub(1, offset)
  local lines = split(prefix)
  return #lines - 1, #(lines[#lines] or "")
end

local function contextual_preview(context, candidate)
  local prefix
  local suffix
  if context.kind == "line" then
    prefix = context.before ~= "" and (context.before .. "\n") or ""
    suffix = context.after ~= "" and ("\n" .. context.after) or ""
  else
    prefix = context.before
    suffix = context.after
  end

  local document = prefix .. candidate .. suffix
  local start_row, start_col = offset_position(document, #prefix)
  local end_row, end_col = offset_position(document, #prefix + #candidate)
  return split(document), {
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
  }
end

local function status_label(attempt)
  if attempt.review then
    return attempt.review.approved and "approved" or "needs revision"
  end
  return attempt.status or "generated"
end

function Session:_render_prompt()
  set_lines(self.buffers.prompt, split(self.request))
end

function Session:_render_attempts()
  if self.closed then
    return
  end
  local lines = {}
  if #self.attempts == 0 then
    table.insert(lines, "  Waiting for first candidate…")
  else
    for index, attempt in ipairs(self.attempts) do
      table.insert(lines, ("  %d  %s"):format(index, status_label(attempt)))
    end
  end
  set_lines(self.buffers.attempts, lines)
  vim.api.nvim_buf_clear_namespace(self.buffers.attempts, namespace, 0, -1)
  if self.selected > 0 and self.selected <= #lines then
    vim.api.nvim_buf_set_extmark(self.buffers.attempts, namespace, self.selected - 1, 0, {
      line_hl_group = "Visual",
      virt_text = { { "›", "Special" } },
      virt_text_pos = "overlay",
    })
    if vim.api.nvim_win_is_valid(self.windows.attempts) then
      pcall(vim.api.nvim_win_set_cursor, self.windows.attempts, { self.selected, 0 })
    end
  end
  if vim.api.nvim_win_is_valid(self.windows.attempts) then
    local config = vim.api.nvim_win_get_config(self.windows.attempts)
    config.title = " Attempts — " .. self.status .. " "
    vim.api.nvim_win_set_config(self.windows.attempts, config)
  end
end

function Session:_render_preview()
  if self.closed then
    return
  end
  local attempt = self.attempts[self.selected]
  if not attempt then
    set_lines(self.buffers.preview, { "Select a generated candidate to preview it in context." })
    return
  end
  if not attempt.candidate then
    local lines = { ("Candidate %d · %s"):format(self.selected, status_label(attempt)), "" }
    if attempt.error then
      table.insert(lines, "Error")
      append(lines, attempt.error, "  ")
    else
      table.insert(lines, attempt.status or "Waiting…")
    end
    set_lines(self.buffers.preview, lines)
    return
  end

  local document, range = contextual_preview(self.context, attempt.candidate)
  local verdict = status_label(attempt)
  local lines = { ("Candidate %d · %s"):format(self.selected, verdict), "" }
  local document_start = #lines
  vim.list_extend(lines, document)
  table.insert(lines, "")
  table.insert(lines, "Review")
  if attempt.review then
    if attempt.review.approved then
      table.insert(lines, "  OK")
    else
      append(lines, attempt.review.feedback, "  ")
    end
  else
    table.insert(lines, "  " .. (attempt.status or "pending"))
  end
  if attempt.user_feedback then
    table.insert(lines, "")
    table.insert(lines, "Retry guidance")
    append(lines, attempt.user_feedback, "  ")
  end
  if attempt.error then
    table.insert(lines, "")
    table.insert(lines, "Error")
    append(lines, attempt.error, "  ")
  end

  set_lines(self.buffers.preview, lines)
  vim.api.nvim_buf_clear_namespace(self.buffers.preview, namespace, 0, -1)
  local start_row = document_start + range.start_row
  local end_row = document_start + range.end_row
  if start_row == end_row and range.start_col == range.end_col then
    vim.api.nvim_buf_set_extmark(self.buffers.preview, namespace, start_row, range.start_col, {
      virt_text = { { "▏", "ReplaiceSelection" } },
      virt_text_pos = "overlay",
    })
  else
    vim.api.nvim_buf_set_extmark(self.buffers.preview, namespace, start_row, range.start_col, {
      end_row = end_row,
      end_col = range.end_col,
      hl_group = "ReplaiceSelection",
      hl_mode = "combine",
    })
  end
  if vim.api.nvim_win_is_valid(self.windows.preview) then
    pcall(vim.api.nvim_win_set_cursor, self.windows.preview, { start_row + 1, range.start_col })
  end
end

function Session:_render()
  self:_render_attempts()
  self:_render_preview()
end

function Session:is_cancelled()
  return self.cancelled or self.closed
end

function Session:set_callbacks(callbacks)
  self.callbacks = callbacks
end

function Session:generating(attempt, max_tries)
  self.status = ("generating %d/%d"):format(attempt, max_tries)
  self.pending_index = #self.attempts + 1
  self.attempts[self.pending_index] = { status = "generating…" }
  self.selected = self.pending_index
  self:_render()
  return self.pending_index
end

function Session:add_candidate(index, candidate)
  local attempt = self.attempts[index] or {}
  attempt.candidate = candidate
  attempt.status = "generated"
  self.attempts[index] = attempt
  self.selected = index
  self.status = "candidate generated"
  self:_render()
end

function Session:reviewing_candidate(index)
  self.attempts[index].status = "reviewing…"
  self.status = "reviewing"
  self:_render()
end

function Session:add_review(index, approved, feedback)
  self.attempts[index].status = nil
  self.attempts[index].review = { approved = approved, feedback = feedback }
  self.status = approved and "approved" or "revision requested"
  self:_render()
end

function Session:add_user_guidance(index, guidance)
  if self.attempts[index] then
    self.attempts[index].user_feedback = guidance
  end
  self.status = "retry requested"
  self:_render()
end

function Session:supersede_pending()
  for _, attempt in ipairs(self.attempts) do
    if attempt.status == "generating…" or attempt.status == "reviewing…" then
      attempt.status = "superseded"
    end
  end
  self:_render()
end

function Session:show_error(message, index)
  index = index or self.selected
  if index > 0 and self.attempts[index] then
    self.attempts[index].status = "error"
    self.attempts[index].error = message
  end
  self.status = "error"
  self:_render()
end

function Session:ready(index, approved)
  self.selected = index
  self.status = approved == true and "ready · approved"
    or approved == false and "ready · not approved"
    or "ready · review disabled"
  self:_render()
end

function Session:select(delta)
  if #self.attempts == 0 then
    return
  end
  self.selected = math.min(#self.attempts, math.max(1, self.selected + delta))
  self:_render()
end

function Session:selected_attempt()
  return self.attempts[self.selected], self.selected
end

function Session:accept_selected()
  local attempt = self:selected_attempt()
  if not attempt or not attempt.candidate or not self.callbacks then
    return
  end
  local ok, err = self.callbacks.accept(attempt.candidate)
  if ok == false then
    self:show_error(err)
    return
  end
  self:close(false)
end

function Session:retry_selected()
  local attempt, index = self:selected_attempt()
  if not attempt or not attempt.candidate or not self.callbacks then
    return
  end
  self.callbacks.retry(attempt.candidate, index)
end

function Session:close(cancelled)
  if self.closed then
    return
  end
  self.cancelled = cancelled == true
  self.closed = true
  for _, winid in pairs(self.windows) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end
  for _, bufnr in pairs(self.buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  if active_session == self then
    active_session = nil
  end
end

local function new_buffer(filetype)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype
  return bufnr
end

local function dimensions()
  local width = math.min(math.max(60, math.floor(vim.o.columns * 0.9)), math.max(1, vim.o.columns - 4))
  local height = math.min(math.max(16, math.floor(vim.o.lines * 0.78)), math.max(1, vim.o.lines - 4))
  local prompt_height = math.min(4, math.max(2, height - 8))
  local help_height = 1
  local body_height = math.max(3, height - prompt_height - help_height - 6)
  local left_width = math.max(16, math.floor((width - 2) * 0.3))
  local right_width = math.max(16, width - left_width - 4)
  return width, height, prompt_height, help_height, body_height, left_width, right_width
end

function M.open(options)
  if active_session and not active_session.closed then
    active_session:close(true)
  end
  options = options or {}
  local width, height, prompt_height, help_height, body_height, left_width, right_width = dimensions()
  local row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local buffers = {
    prompt = new_buffer("replaice"),
    attempts = new_buffer("replaice"),
    preview = new_buffer(options.context and options.context.filetype or "text"),
    help = new_buffer("replaice"),
  }
  local common = { relative = "editor", style = "minimal", border = "rounded" }
  local windows = {}
  windows.prompt = vim.api.nvim_open_win(buffers.prompt, false, vim.tbl_extend("force", common, {
    width = width - 2,
    height = prompt_height,
    row = row,
    col = col,
    title = " Prompt ",
    focusable = false,
  }))
  windows.attempts = vim.api.nvim_open_win(buffers.attempts, true, vim.tbl_extend("force", common, {
    width = left_width,
    height = body_height,
    row = row + prompt_height + 2,
    col = col,
    title = " Attempts ",
  }))
  windows.preview = vim.api.nvim_open_win(buffers.preview, false, vim.tbl_extend("force", common, {
    width = right_width,
    height = body_height,
    row = row + prompt_height + 2,
    col = col + left_width + 2,
    title = " Contextual preview ",
  }))
  windows.help = vim.api.nvim_open_win(buffers.help, false, vim.tbl_extend("force", common, {
    width = width - 2,
    height = help_height,
    row = row + prompt_height + body_height + 4,
    col = col,
    focusable = false,
  }))
  vim.wo[windows.prompt].wrap = true
  vim.wo[windows.preview].wrap = true
  vim.wo[windows.attempts].cursorline = false
  set_lines(buffers.help, { " j/k navigate   a accept selected   r retry selected   q cancel " })

  local session = setmetatable({
    buffers = buffers,
    windows = windows,
    request = options.request or "",
    context = options.context or { before = "", after = "", kind = "char" },
    attempts = {},
    selected = 0,
    status = "starting",
    closed = false,
    cancelled = false,
  }, Session)
  active_session = session
  vim.api.nvim_set_hl(0, "ReplaiceSelection", { link = "IncSearch", default = true })

  local function cancel()
    local callbacks = session.callbacks
    session:close(true)
    if callbacks and callbacks.cancel then
      callbacks.cancel()
    end
  end
  for _, bufnr in ipairs({ buffers.attempts, buffers.preview }) do
    vim.keymap.set("n", "j", function() session:select(1) end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Down>", function() session:select(1) end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "k", function() session:select(-1) end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Up>", function() session:select(-1) end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "gg", function() session.selected = 1; session:_render() end, { buffer = bufnr })
    vim.keymap.set("n", "G", function() session.selected = #session.attempts; session:_render() end, { buffer = bufnr })
    vim.keymap.set("n", "a", function() session:accept_selected() end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "r", function() session:retry_selected() end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "q", cancel, { buffer = bufnr, nowait = true })
  end
  for _, winid in ipairs({ windows.attempts, windows.preview }) do
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(winid),
      once = true,
      callback = function()
        if not session.closed then
          vim.schedule(cancel)
        end
      end,
    })
  end

  session:_render_prompt()
  session:_render()
  return session
end

return M
