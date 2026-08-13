local M = {}

local namespace = vim.api.nvim_create_namespace("replaice_workflow")
local active_session

local Session = {}
Session.__index = Session

local function append_text(lines, text, prefix)
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    table.insert(lines, (prefix or "") .. line)
  end
end

local function window_size()
  local width = math.max(30, math.floor(vim.o.columns * 0.8))
  local height = math.max(10, math.floor(vim.o.lines * 0.7))
  return math.min(width, math.max(1, vim.o.columns - 4)), math.min(height, math.max(1, vim.o.lines - 4))
end

function Session:_lines()
  local lines = { "Status: " .. self.status, "" }

  table.insert(lines, "Attempt history")
  if #self.attempts == 0 then
    table.insert(lines, "  No candidates yet.")
  end
  for index, attempt in ipairs(self.attempts) do
    table.insert(lines, "")
    table.insert(lines, ("Candidate %d"):format(index))
    append_text(lines, attempt.candidate, "  ")
    if attempt.review then
      if attempt.review.approved then
        table.insert(lines, "  Review: OK")
      else
        table.insert(lines, "  Review: revision requested")
        append_text(lines, attempt.review.feedback, "    ")
      end
    elseif self.reviewing == index then
      table.insert(lines, "  Review: in progress…")
    elseif attempt.user_feedback then
      table.insert(lines, "  Review: user requested another attempt")
    else
      table.insert(lines, "  Review: pending")
    end
    if attempt.user_feedback then
      table.insert(lines, "  User guidance:")
      append_text(lines, attempt.user_feedback, "    ")
    end
  end

  if self.error_message then
    table.insert(lines, "")
    table.insert(lines, "Error")
    append_text(lines, self.error_message, "  ")
  end

  if self.final then
    table.insert(lines, "")
    local verdict = self.final.approved == true and "reviewer approved"
      or self.final.approved == false and "not reviewer-approved"
      or "review disabled"
    table.insert(lines, "Editable replacement — " .. verdict)
    table.insert(lines, "Press a to accept, r to retry with guidance, or q to cancel.")
    table.insert(lines, "")
    local candidate_start = #lines
    append_text(lines, self.final.candidate)
    return lines, candidate_start
  end

  table.insert(lines, "")
  table.insert(lines, "Press q to cancel.")
  return lines
end

function Session:_render()
  if self.closed or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  local lines, candidate_start = self:_lines()
  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.bufnr, namespace, 0, -1)
  self.candidate_mark = nil
  if candidate_start then
    self.candidate_mark = vim.api.nvim_buf_set_extmark(self.bufnr, namespace, candidate_start, 0, {
      right_gravity = false,
    })
    vim.bo[self.bufnr].modifiable = true
    if vim.api.nvim_get_current_win() == self.winid then
      pcall(vim.api.nvim_win_set_cursor, self.winid, { candidate_start + 1, 0 })
    end
  else
    vim.bo[self.bufnr].modifiable = false
  end
end

function Session:is_cancelled()
  return self.cancelled or self.closed
end

function Session:generating(attempt, max_tries, candidate_number)
  self.final = nil
  self.error_message = nil
  self.reviewing = nil
  self.status = ("Generating candidate %d (attempt %d/%d)…"):format(candidate_number, attempt, max_tries)
  self:_render()
end

function Session:add_candidate(index, candidate)
  self.attempts[index] = self.attempts[index] or {}
  self.attempts[index].candidate = candidate
  self.status = ("Candidate %d generated"):format(index)
  self:_render()
end

function Session:reviewing_candidate(index)
  self.reviewing = index
  self.status = ("Reviewing candidate %d…"):format(index)
  self:_render()
end

function Session:add_review(index, approved, feedback)
  self.reviewing = nil
  self.attempts[index].review = { approved = approved, feedback = feedback }
  self.status = approved and ("Candidate %d approved"):format(index)
    or ("Candidate %d needs revision"):format(index)
  self:_render()
end

function Session:add_user_retry(index, candidate, guidance)
  self.attempts[index] = {
    candidate = candidate,
    user_feedback = guidance,
  }
  self.status = "Retry requested"
  self:_render()
end

function Session:waiting_for_retry()
  self.status = "Waiting for retry instructions…"
  self:_render()
end

function Session:show_error(message)
  self.final = nil
  self.reviewing = nil
  self.error_message = message
  self.status = "Workflow stopped"
  self:_render()
end

function Session:replacement()
  if not self.final or not self.candidate_mark or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return self.final and self.final.candidate or ""
  end
  local position = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, namespace, self.candidate_mark, {})
  if #position == 0 then
    return self.final.candidate
  end
  return table.concat(vim.api.nvim_buf_get_lines(self.bufnr, position[1], -1, false), "\n")
end

function Session:finish(candidate, approved, callbacks)
  self.callbacks = callbacks
  self.error_message = nil
  self.final = { candidate = candidate, approved = approved }
  self.status = approved == true and "Ready — reviewer approved"
    or approved == false and "Ready — retry limit reached without approval"
    or "Ready — review disabled"
  self:_render()
end

function Session:close(cancelled)
  if self.closed then
    return
  end
  self.cancelled = cancelled == true
  self.closed = true
  if vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_close(self.winid, true)
  end
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_delete(self.bufnr, { force = true })
  end
  if active_session == self then
    active_session = nil
  end
end

function M.open()
  if active_session and not active_session.closed then
    active_session:close(true)
  end

  local width, height = window_size()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "replaice"
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Replaice workflow ",
    title_pos = "center",
  })
  vim.wo[winid].wrap = true

  local session = setmetatable({
    bufnr = bufnr,
    winid = winid,
    status = "Starting…",
    attempts = {},
    closed = false,
    cancelled = false,
  }, Session)
  active_session = session

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      if session.closed then
        return
      end
      session.cancelled = true
      session.closed = true
      if active_session == session then
        active_session = nil
      end
      if session.callbacks and session.callbacks.cancel then
        session.callbacks.cancel()
      end
    end,
  })

  vim.keymap.set("n", "q", function()
    local callbacks = session.callbacks
    session:close(true)
    if callbacks and callbacks.cancel then
      callbacks.cancel()
    end
  end, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "a", function()
    if not session.final or not session.callbacks then
      return
    end
    local ok, err = session.callbacks.accept(session:replacement())
    if ok == false then
      session:show_error(err)
    else
      session:close(false)
    end
  end, { buffer = bufnr, nowait = true })
  vim.keymap.set("n", "r", function()
    if not session.final or not session.callbacks then
      return
    end
    session.callbacks.retry(session:replacement())
  end, { buffer = bufnr, nowait = true })

  session:_render()
  return session
end

return M
