local M = {}

local namespace = vim.api.nvim_create_namespace("replaice_picker")
local active_session

local Session = {}
Session.__index = Session

local function split(text)
  return vim.split(text or "", "\n", { plain = true })
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
  local lines = split(text:sub(1, offset))
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

local function compact(text)
  return vim.trim((text or ""):gsub("%s+", " "))
end

local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local result = ""
  local index = 0
  while index < vim.fn.strchars(text) do
    local next_char = vim.fn.strcharpart(text, index, 1)
    if vim.fn.strdisplaywidth(result .. next_char .. "…") > width then
      break
    end
    result = result .. next_char
    index = index + 1
  end
  return result .. "…"
end

function Session:_render_prompt()
  local version = self.versions[self.selected]
  local instructions = version and version.instructions or self.initial_instructions
  local lines = {}
  for _, instruction in ipairs(instructions or {}) do
    for line_index, line in ipairs(split(instruction)) do
      table.insert(lines, (line_index == 1 and "• " or "  ") .. line)
    end
  end
  if #lines == 0 then
    lines = { "• Improve automatically" }
  end
  set_lines(self.buffers.prompt, lines)
  vim.api.nvim_buf_clear_namespace(self.buffers.prompt, namespace, 0, -1)
  for row, line in ipairs(lines) do
    if line:sub(1, 2) == "• " then
      vim.api.nvim_buf_add_highlight(self.buffers.prompt, namespace, "ReplaiceAccent", row - 1, 0, 2)
    end
  end
  if vim.api.nvim_win_is_valid(self.windows.prompt) then
    local config = vim.api.nvim_win_get_config(self.windows.prompt)
    config.title = self.selected > 0 and (" Instructions for version %d "):format(self.selected) or " Instructions "
    vim.api.nvim_win_set_config(self.windows.prompt, config)
  end
end


function Session:_render_versions()
  local lines = {}
  if #self.versions == 0 then
    lines = { "  Creating first version…" }
  else
    local excerpt_width = math.max(8, self.left_width - 7)
    for index, version in ipairs(self.versions) do
      local label
      if version.candidate then
        label = truncate(compact(version.candidate), excerpt_width)
      elseif version.error then
        label = "Could not generate"
      else
        label = version.status or "Generating…"
      end
      table.insert(lines, ("  %d  %s"):format(index, label))
    end
  end
  set_lines(self.buffers.versions, lines)
  vim.api.nvim_buf_clear_namespace(self.buffers.versions, namespace, 0, -1)
  for index = 1, #self.versions do
    vim.api.nvim_buf_add_highlight(self.buffers.versions, namespace, "ReplaiceAccent", index - 1, 2, 2 + #tostring(index))
    if not self.versions[index].candidate then
      vim.api.nvim_buf_add_highlight(self.buffers.versions, namespace, "ReplaiceMuted", index - 1, 5, -1)
    end
  end
  if self.selected > 0 and self.selected <= #self.versions then
    vim.api.nvim_buf_set_extmark(self.buffers.versions, namespace, self.selected - 1, 0, {
      line_hl_group = "Visual",
      virt_text = { { "›", "ReplaiceAccent" } },
      virt_text_pos = "overlay",
    })
    pcall(vim.api.nvim_win_set_cursor, self.windows.versions, { self.selected, 0 })
  end
end

function Session:_render_preview()
  local version = self.versions[self.selected]
  if not version then
    set_lines(self.buffers.preview, { "The selected version will appear here in context." })
    return
  end
  if not version.candidate then
    local lines = { ("Version %d"):format(self.selected), "", version.error or version.status or "Generating…" }
    set_lines(self.buffers.preview, lines)
    vim.api.nvim_buf_clear_namespace(self.buffers.preview, namespace, 0, -1)
    vim.api.nvim_buf_add_highlight(self.buffers.preview, namespace, "ReplaiceAccent", 0, 0, -1)
    if version.error then
      vim.api.nvim_buf_add_highlight(self.buffers.preview, namespace, "DiagnosticError", 2, 0, -1)
    end
    return
  end

  local document, range = contextual_preview(self.context, version.candidate)
  local lines = { ("Version %d"):format(self.selected), "" }
  local document_start = #lines
  vim.list_extend(lines, document)
  set_lines(self.buffers.preview, lines)
  vim.api.nvim_buf_clear_namespace(self.buffers.preview, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(self.buffers.preview, namespace, "ReplaiceAccent", 0, 0, -1)

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
    pcall(vim.api.nvim_win_call, self.windows.preview, function()
      vim.cmd("normal! zz")
    end)
  end
end

function Session:_render()
  if self.closed then
    return
  end
  self:_render_prompt()
  self:_render_versions()
  self:_render_preview()
end

function Session:is_cancelled()
  return self.cancelled or self.closed
end

function Session:set_callbacks(callbacks)
  self.callbacks = callbacks
end

function Session:start_version(instructions)
  local index = #self.versions + 1
  self.versions[index] = {
    instructions = vim.deepcopy(instructions or self.initial_instructions),
    status = "Generating…",
  }
  self.selected = index
  self:_render()
  return index
end

function Session:set_working(index, message)
  if self.versions[index] then
    self.versions[index].status = message or "Generating…"
    self:_render()
  end
end

function Session:complete_version(index, candidate)
  local version = self.versions[index]
  if not version then
    return
  end
  version.candidate = candidate
  version.status = nil
  self.selected = index
  self:_render()
end

function Session:stop_pending()
  for _, version in ipairs(self.versions) do
    if not version.candidate and not version.error then
      version.status = "Stopped"
    end
  end
  self:_render()
end

function Session:show_error(message, index)
  index = index or self.selected
  if self.versions[index] then
    self.versions[index].status = nil
    self.versions[index].error = message
  end
  self:_render()
end

function Session:select(delta)
  if #self.versions == 0 then
    return
  end
  self.selected = math.min(#self.versions, math.max(1, self.selected + delta))
  self:_render()
end

function Session:selected_version()
  return self.versions[self.selected], self.selected
end

function Session:accept_selected()
  local version = self:selected_version()
  if not version or not version.candidate or not self.callbacks then
    return
  end
  local ok, err = self.callbacks.accept(version.candidate)
  if ok == false then
    self:show_error(err)
  else
    self:close(false)
  end
end

function Session:retry_selected()
  local version, index = self:selected_version()
  if version and version.candidate and self.callbacks then
    self.callbacks.retry(version.candidate, index)
  end
end

function Session:close(cancelled)
  if self.closed then
    return
  end
  self.cancelled = cancelled == true
  local cancel_callback = self.cancelled and self.callbacks and self.callbacks.cancel
  self.closed = true
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
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
  if cancel_callback then
    cancel_callback()
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
  local prompt_height = math.min(4, math.max(1, height - 8))
  local help_height = 1
  local body_height = math.max(1, height - prompt_height - help_height - 6)
  local max_left_width = math.max(1, width - 5)
  local left_width = math.min(math.max(16, math.floor((width - 2) * 0.3)), max_left_width)
  local right_width = math.max(1, width - left_width - 4)
  return width, height, prompt_height, help_height, body_height, left_width, right_width
end

function Session:_layout()
  if self.closed then
    return
  end

  local width, height, prompt_height, help_height, body_height, left_width, right_width = dimensions()
  local row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local layouts = {
    prompt = {
      width = width - 2,
      height = prompt_height,
      row = row,
      col = col,
    },
    versions = {
      width = left_width,
      height = body_height,
      row = row + prompt_height + 2,
      col = col,
    },
    preview = {
      width = right_width,
      height = body_height,
      row = row + prompt_height + 2,
      col = col + left_width + 2,
    },
    help = {
      width = width - 2,
      height = help_height,
      row = row + prompt_height + body_height + 4,
      col = col,
    },
  }

  self.left_width = left_width
  for name, layout in pairs(layouts) do
    local winid = self.windows[name]
    if vim.api.nvim_win_is_valid(winid) then
      local config = vim.api.nvim_win_get_config(winid)
      for key, value in pairs(layout) do
        config[key] = value
      end
      vim.api.nvim_win_set_config(winid, config)
    end
  end
  self:_render()
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
    versions = new_buffer("replaice"),
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
    title = " Instructions ",
  }))
  windows.versions = vim.api.nvim_open_win(buffers.versions, true, vim.tbl_extend("force", common, {
    width = left_width,
    height = body_height,
    row = row + prompt_height + 2,
    col = col,
    title = " Versions ",
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
  set_lines(buffers.help, { " j/k navigate   a accept   r new version   q cancel " })

  local session = setmetatable({
    buffers = buffers,
    windows = windows,
    context = options.context or { before = "", after = "", kind = "char" },
    initial_instructions = options.instructions or { options.request or "Improve automatically" },
    versions = {},
    selected = 0,
    left_width = left_width,
    closed = false,
    cancelled = false,
  }, Session)
  active_session = session
  session.augroup = vim.api.nvim_create_augroup("replaice_picker_" .. tostring(buffers.versions), { clear = true })
  vim.api.nvim_set_hl(0, "ReplaiceSelection", { link = "IncSearch", default = true })
  vim.api.nvim_set_hl(0, "ReplaiceAccent", { link = "Function", default = true })
  vim.api.nvim_set_hl(0, "ReplaiceMuted", { link = "Comment", default = true })
  for _, item in ipairs({ { "j/k", 3 }, { "a accept", 1 }, { "r new version", 1 }, { "q cancel", 1 } }) do
    local start = assert(string.find(vim.api.nvim_buf_get_lines(buffers.help, 0, 1, false)[1], item[1], 1, true)) - 1
    vim.api.nvim_buf_add_highlight(buffers.help, namespace, "ReplaiceAccent", 0, start, start + item[2])
  end

  local function cancel()
    session:close(true)
  end
  for _, bufnr in ipairs({ buffers.prompt, buffers.versions, buffers.preview }) do
    vim.keymap.set("n", "j", function() session:select(1) end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Down>", function() session:select(1) end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "k", function() session:select(-1) end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Up>", function() session:select(-1) end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "gg", function() session.selected = 1; session:_render() end, { buffer = bufnr })
    vim.keymap.set("n", "G", function() session.selected = #session.versions; session:_render() end, { buffer = bufnr })
    vim.keymap.set("n", "a", function() session:accept_selected() end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "r", function() session:retry_selected() end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "q", cancel, { buffer = bufnr, nowait = true })
  end
  for _, winid in ipairs({ windows.prompt, windows.versions, windows.preview }) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = session.augroup,
      pattern = tostring(winid),
      once = true,
      callback = function()
        if not session.closed then
          vim.schedule(cancel)
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("VimResized", {
    group = session.augroup,
    callback = function()
      vim.schedule(function()
        if not session.closed then
          session:_layout()
        end
      end)
    end,
  })

  session:_render()
  return session
end

return M
