local selection = require("replaice.selection")
local prompts = require("replaice.prompts")
local context_module = require("replaice.context")
local workflow_ui = require("replaice.ui")
require("replaice.workflow")

local function eq(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(("%s\nexpected: %s\nactual: %s"):format(label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello brave world", "second line" })
-- Force the visual mode recorded by visualmode() while retaining the test marks.
vim.cmd("normal! 1G7|v4l\27")
local captured = assert(selection.capture(buf))
eq(captured.text, "brave", "captures an inclusive characterwise selection")
local ok, err = selection.apply(captured, "gentle")
assert(ok, err)
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "hello gentle world", "second line" }, "changes only selection")

local fragment_line = "The launch was kind of successful, despite the delay."
local fragment = "kind of successful"
local fragment_start = assert(fragment_line:find(fragment, 1, true)) - 1
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { fragment_line })
vim.api.nvim_win_set_cursor(0, { 1, fragment_start })
vim.cmd("normal! v")
vim.api.nvim_win_set_cursor(0, { 1, fragment_start + #fragment - 1 })
local fragment_selection = assert(selection.capture(buf))
vim.cmd("normal! \27")
eq(fragment_selection.text, fragment, "captures only the mid-sentence fragment")
local fragment_context = context_module.capture(fragment_selection, { max_chars = 12000, max_lines = 200 })
eq(
  context_module.document(fragment_context),
  "The launch was <REPLAICE_SELECTION>kind of successful</REPLAICE_SELECTION>, despite the delay.",
  "captured fragment is tagged at its exact document boundaries"
)

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello first", "second world", "third" })
vim.cmd("normal! gg7|vj6|\27")
local multiline = assert(selection.capture(buf))
eq(multiline.text, "first\nsecond", "captures a multiline characterwise selection")
ok, err = selection.apply(multiline, "joined")
assert(ok, err)
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "hello joined world", "third" }, "multiline replacement preserves both sides")

vim.cmd("normal! ggVj\27")
local line_selection = assert(selection.capture(buf))
eq(line_selection.kind, "line", "captures linewise mode")
ok, err = selection.apply(line_selection, "replacement")
assert(ok, err)
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "replacement" }, "linewise replacement")

vim.o.selection = "exclusive"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcde" })
vim.cmd("normal! gg0v2l")
local exclusive = assert(selection.capture(buf))
eq(exclusive.was_active, true, "captures an active visual selection")
eq(exclusive.text, "ab", "honors exclusive selection mode")
vim.cmd("normal! \27")
ok, err = selection.apply(exclusive, "XY")
assert(ok, err)
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "XYcde" }, "exclusive replacement changes only selected bytes")
vim.o.selection = "inclusive"

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aéz" })
vim.cmd("normal! gg0lv\27")
local unicode = assert(selection.capture(buf))
eq(unicode.text, "é", "captures a multibyte character")
ok, err = selection.apply(unicode, "E")
assert(ok, err)
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "aEz" }, "replaces a multibyte character safely")

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha beta" })
vim.cmd("normal! gg0v4l\27")
local stale = assert(selection.capture(buf))
vim.api.nvim_buf_set_text(buf, 0, 6, 0, 10, { "BETA" })
ok, err = selection.apply(stale, "omega")
eq(ok, false, "rejects a stale selection")
assert(err:find("buffer changed", 1, true), err)
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "alpha BETA" }, "stale apply makes no edit")

eq(prompts.review_result("OK"), true, "accepts reviewer approval")
local approved, feedback = prompts.review_result("REVISE: make it shorter")
eq(approved, false, "accepts reviewer rejection")
eq(feedback, "make it shorter", "extracts reviewer feedback")

local prompt_context = {
  before = "Before.",
  selected = "Original.",
  after = "After.",
  kind = "char",
  filetype = "markdown",
}
local prompt_history = {
  { candidate = "Candidate one.", review = { approved = false, feedback = "Preserve the meaning." } },
  { candidate = "Candidate two.", review = { approved = false, feedback = "Make it shorter." } },
}
local editor_prompt = prompts.rewrite(prompt_context, "Polish it.", prompt_history)
assert(editor_prompt:find("Candidate one.", 1, true), "editor receives candidate one")
assert(editor_prompt:find("Preserve the meaning.", 1, true), "editor receives review one")
assert(editor_prompt:find("Candidate two.", 1, true), "editor receives candidate two")
assert(editor_prompt:find("Make it shorter.", 1, true), "editor receives review two")

table.insert(prompt_history, { candidate = "Candidate three." })
local reviewer_prompt = prompts.review(prompt_context, "Polish it.", prompt_history)
assert(reviewer_prompt:find("Candidate one.", 1, true), "reviewer receives earlier candidate one")
assert(reviewer_prompt:find("Candidate two.", 1, true), "reviewer receives earlier candidate two")
assert(reviewer_prompt:find("Before.<REPLAICE_SELECTION>Candidate three.</REPLAICE_SELECTION>After.", 1, true), "reviewer sees exact characterwise boundaries")
assert(reviewer_prompt:find("concrete, material defect", 1, true), "reviewer uses a material approval threshold")
assert(reviewer_prompt:find("Reject candidates that duplicate, consume, or attempt to rewrite surrounding text.", 1, true), "reviewer checks replacement boundaries")

eq(context_module.document({
  before = "The launch was ",
  selected = "kind of successful",
  after = ", despite the delay.",
  kind = "char",
}), "The launch was <REPLAICE_SELECTION>kind of successful</REPLAICE_SELECTION>, despite the delay.", "characterwise tags preserve fragment adjacency")

eq(context_module.document({
  before = "Paragraph before.",
  selected = "Selected line one.\nSelected line two.",
  after = "Paragraph after.",
  kind = "line",
}), "Paragraph before.\n<REPLAICE_SELECTION>\nSelected line one.\nSelected line two.\n</REPLAICE_SELECTION>\nParagraph after.", "linewise tags remain a distinct block")

local ui_session = workflow_ui.open({
  instructions = { "Make this more concise." },
  context = {
    before = table.concat(vim.tbl_map(function(index) return "Earlier context " .. index end, vim.fn.range(1, 20)), "\n") .. "\nThe launch was ",
    after = ", despite the delay.\n" .. table.concat(vim.tbl_map(function(index) return "Later context " .. index end, vim.fn.range(1, 20)), "\n"),
    kind = "char",
    filetype = "markdown",
  },
})
local first_ui_index = ui_session:start_version({ "Make this more concise." })
eq(first_ui_index, 1, "first user generation gets the first visible version")
ui_session:complete_version(1, "more successful")
local second_ui_index = ui_session:start_version({ "Make this more concise.", "Keep it understated." })
eq(second_ui_index, 2, "a user retry creates the next visible version")
ui_session:complete_version(2, "a modest success")
local accepted_from_picker
local retried_from_picker
ui_session:set_callbacks({
  accept = function(candidate)
    accepted_from_picker = candidate
    return true
  end,
  retry = function(candidate, index)
    retried_from_picker = candidate
    eq(index, 1, "retry identifies the selected version")
  end,
})
local prompt_text = table.concat(vim.api.nvim_buf_get_lines(ui_session.buffers.prompt, 0, -1, false), "\n")
local version_text = table.concat(vim.api.nvim_buf_get_lines(ui_session.buffers.versions, 0, -1, false), "\n")
local preview_text = table.concat(vim.api.nvim_buf_get_lines(ui_session.buffers.preview, 0, -1, false), "\n")
assert(prompt_text:find("Make this more concise.", 1, true), "selected version shows the original request")
assert(prompt_text:find("Keep it understated.", 1, true), "selected version shows its retry guidance")
assert(version_text:find("1  more success", 1, true), "version list uses a useful replacement excerpt")
assert(version_text:find("2  a modest succ", 1, true), "version list remains chronological")
assert(not version_text:find("approved", 1, true), "version list hides reviewer mechanics")
assert(preview_text:find("The launch was a modest success, despite the delay.", 1, true), "preview inserts selected version into context")
assert(not preview_text:find("Review", 1, true), "preview hides automatic review details")
assert(#vim.api.nvim_buf_get_extmarks(ui_session.buffers.preview, -1, 0, -1, {}) > 0, "preview highlights the exact replacement range")
local centered_view = vim.api.nvim_win_call(ui_session.windows.preview, function()
  return { topline = vim.fn.winsaveview().topline, cursor = vim.api.nvim_win_get_cursor(0)[1], height = vim.api.nvim_win_get_height(0) }
end)
assert(centered_view.topline > 1, "preview scrolls toward the highlighted replacement")
assert(math.abs((centered_view.cursor - centered_view.topline) - math.floor(centered_view.height / 2)) <= 2, "highlighted replacement is approximately vertically centered")
eq(vim.bo[ui_session.buffers.versions].modifiable, false, "version picker is read-only")
eq(vim.bo[ui_session.buffers.preview].modifiable, false, "context preview is read-only")
local original_columns = vim.o.columns
local original_lines = vim.o.lines
local original_prompt_config = vim.api.nvim_win_get_config(ui_session.windows.prompt)
vim.api.nvim_set_current_win(ui_session.windows.preview)
vim.o.columns = original_columns + 20
vim.o.lines = original_lines + 6
vim.api.nvim_exec_autocmds("VimResized", {})
vim.wait(1000, function()
  return vim.api.nvim_win_get_config(ui_session.windows.prompt).width ~= original_prompt_config.width
end, 10)
local resized_prompt_config = vim.api.nvim_win_get_config(ui_session.windows.prompt)
assert(resized_prompt_config.width > original_prompt_config.width, "open picker expands when the editor is resized")
eq(
  math.floor(resized_prompt_config.col),
  math.floor((vim.o.columns - resized_prompt_config.width - 2) / 2),
  "resized picker remains horizontally centered"
)
eq(ui_session.selected, 2, "resizing preserves the selected version")
eq(vim.api.nvim_get_current_win(), ui_session.windows.preview, "resizing preserves the active picker pane")
vim.o.columns = 30
vim.o.lines = 15
vim.api.nvim_exec_autocmds("VimResized", {})
vim.wait(1000, function()
  return vim.api.nvim_win_get_config(ui_session.windows.prompt).width < resized_prompt_config.width
end, 10)
local compact_prompt_config = vim.api.nvim_win_get_config(ui_session.windows.prompt)
local compact_preview_config = vim.api.nvim_win_get_config(ui_session.windows.preview)
assert(compact_prompt_config.width + 2 <= vim.o.columns, "picker fits after a narrow resize")
assert(compact_preview_config.width >= 1 and compact_preview_config.height >= 1, "picker panes remain valid at compact dimensions")
vim.o.columns = original_columns
vim.o.lines = original_lines
vim.api.nvim_exec_autocmds("VimResized", {})
vim.wait(1000, function()
  return vim.api.nvim_win_get_config(ui_session.windows.prompt).width == original_prompt_config.width
end, 10)
ui_session:select(-1)
prompt_text = table.concat(vim.api.nvim_buf_get_lines(ui_session.buffers.prompt, 0, -1, false), "\n")
preview_text = table.concat(vim.api.nvim_buf_get_lines(ui_session.buffers.preview, 0, -1, false), "\n")
eq(prompt_text, "• Make this more concise.", "navigating updates the visible instruction lineage")
assert(preview_text:find("The launch was more successful, despite the delay.", 1, true), "navigating updates contextual preview")
ui_session:retry_selected()
eq(retried_from_picker, "more successful", "retry operates on the navigated version")
ui_session:accept_selected()
eq(accepted_from_picker, "more successful", "accept operates on the navigated version")
eq(ui_session.closed, true, "accept closes the picker")

local cancelled_ui = workflow_ui.open()
cancelled_ui:close(true)
eq(cancelled_ui:is_cancelled(), true, "closing a workflow as cancelled suppresses late results")

local externally_closed_ui = workflow_ui.open()
vim.api.nvim_win_close(externally_closed_ui.windows.versions, true)
vim.wait(1000, function() return externally_closed_ui:is_cancelled() end, 10)
eq(externally_closed_ui:is_cancelled(), true, "closing the floating window externally cancels its workflow")

local real_http = package.loaded["replaice.providers.http"]
package.loaded["replaice.providers.http"] = {
  post = function(endpoint, body, headers, _, callback)
    eq(endpoint, "https://example.test/v1/responses", "uses configured OpenAI endpoint")
    eq(body.instructions, "system", "sends Responses API instructions")
    eq(headers, { "Authorization: Bearer test-key" }, "sends configured API key")
    callback(nil, {
      output = {
        { type = "reasoning" },
        { type = "message", content = { { type = "output_text", text = "first" } } },
        { type = "message", content = { { type = "output_text", text = " second" } } },
      },
    })
  end,
}
package.loaded["replaice.providers.openai"] = nil
local openai_result
require("replaice.providers.openai").request({
  endpoint = "https://example.test/v1/responses",
  api_key = "test-key",
}, { model = "test-model", instructions = "system", input = "user" }, function(err, value)
  assert(not err, err)
  openai_result = value
end)
eq(openai_result, "first second", "aggregates all Responses API output text")
package.loaded["replaice.providers.openai"] = nil
package.loaded["replaice.providers.http"] = real_http

require("replaice.config").setup({
  provider = function(request, done)
    assert(request.input:find("<REPLAICE_SELECTION>bad</REPLAICE_SELECTION>", 1, true), request.input)
    done(nil, "better")
  end,
  preview = false,
  refine = { enabled = false },
})
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "bad text" })
vim.cmd("normal! gg0v2l")
local original_input = vim.ui.input
vim.ui.input = function(_, callback)
  callback("")
end
require("replaice.workflow").run()
vim.ui.input = original_input
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "better text" }, "end-to-end workflow edits only active selection")

local provider_calls = 0
require("replaice.config").setup({
  provider = function(request, done)
    provider_calls = provider_calls + 1
    if provider_calls == 1 then
      assert(not request.input:find("Candidate one.", 1, true), "first generation has no attempt history")
      done(nil, "Candidate one.")
    elseif provider_calls == 2 then
      eq(request.instructions, prompts.review_system, "second call is the reviewer")
      done(nil, "REVISE: Preserve the original meaning.")
    elseif provider_calls == 3 then
      assert(request.input:find("Candidate one.", 1, true), "second generation receives candidate one")
      assert(request.input:find("Preserve the original meaning.", 1, true), "second generation receives review one")
      done(nil, "Candidate two.")
    elseif provider_calls == 4 then
      done(nil, "REVISE: Make the wording more concise.")
    elseif provider_calls == 5 then
      assert(request.input:find("Candidate one.", 1, true), "third generation retains candidate one")
      assert(request.input:find("Preserve the original meaning.", 1, true), "third generation retains review one")
      assert(request.input:find("Candidate two.", 1, true), "third generation receives candidate two")
      assert(request.input:find("Make the wording more concise.", 1, true), "third generation receives review two")
      done(nil, "Candidate three.")
    elseif provider_calls == 6 then
      eq(request.instructions, prompts.review_system, "final candidate is reviewed")
      assert(request.input:find("Candidate one.", 1, true), "final review retains first attempt")
      assert(request.input:find("Candidate two.", 1, true), "final review retains second attempt")
      assert(request.input:find("<REPLAICE_SELECTION>Candidate three.</REPLAICE_SELECTION>", 1, true), "final review sees third candidate in context")
      done(nil, "OK")
    else
      error("unexpected provider call " .. provider_calls)
    end
  end,
  preview = false,
  refine = { enabled = true, max_tries = 3 },
})
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "bad text" })
vim.cmd("normal! gg0v2l")
vim.ui.input = function(_, callback)
  callback("Polish it.")
end
require("replaice.workflow").run()
vim.ui.input = original_input
eq(provider_calls, 6, "three candidates are each followed by a review")
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "Candidate three. text" }, "approved third candidate is applied")

local real_ui_open = workflow_ui.open
local visible_versions = {}
local picker_callbacks
workflow_ui.open = function(options)
  eq(options.instructions, { "Polish the fragment." }, "picker receives the effective original request")
  return {
    is_cancelled = function() return false end,
    set_callbacks = function(_, callbacks) picker_callbacks = callbacks end,
    start_version = function(_, instructions)
      table.insert(visible_versions, { instructions = vim.deepcopy(instructions) })
      return #visible_versions
    end,
    set_working = function() end,
    complete_version = function(_, index, candidate) visible_versions[index].candidate = candidate end,
    stop_pending = function() end,
    show_error = function(_, message) error(message) end,
    close = function() end,
  }
end
local private_calls = 0
require("replaice.config").setup({
  provider = function(request, done)
    private_calls = private_calls + 1
    if private_calls == 1 then
      done(nil, "private candidate one")
    elseif private_calls == 2 then
      done(nil, "REVISE: retain the fragment boundary")
    elseif private_calls == 3 then
      done(nil, "private candidate two")
    elseif private_calls == 4 then
      done(nil, "REVISE: make it more natural")
    elseif private_calls == 5 then
      done(nil, "visible version one")
    elseif private_calls == 6 then
      done(nil, "OK")
    elseif private_calls == 7 then
      assert(request.input:find("visible version one", 1, true), "new version branches from the selected replacement")
      assert(request.input:find("Keep it fragmentary.", 1, true), "new version receives user retry guidance")
      done(nil, "visible version two")
    elseif private_calls == 8 then
      done(nil, "OK")
    else
      error("unexpected private workflow call " .. private_calls)
    end
  end,
  preview = true,
  refine = { enabled = true, max_tries = 3 },
})
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "bad text" })
vim.cmd("normal! gg0v2l")
local private_input_count = 0
vim.ui.input = function(_, callback)
  private_input_count = private_input_count + 1
  callback(private_input_count == 1 and "Polish the fragment." or "Keep it fragmentary.")
end
require("replaice.workflow").run()
eq(#visible_versions, 1, "automatic refinement produces only one visible version")
eq(visible_versions[1].candidate, "visible version one", "only the resolved internal candidate becomes visible")
picker_callbacks.retry(visible_versions[1].candidate, 1)
eq(#visible_versions, 2, "an explicit user retry creates another visible version")
eq(visible_versions[2].instructions, { "Polish the fragment.", "Keep it fragmentary." }, "new version exposes its complete user instruction lineage")
eq(visible_versions[2].candidate, "visible version two", "user retry resolves into the next version")
local accepted, accept_error = picker_callbacks.accept(visible_versions[2].candidate)
assert(accepted, accept_error)
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "visible version two text" }, "selected visible version remains selection-scoped")
workflow_ui.open = real_ui_open
vim.ui.input = original_input

local unapproved_calls = 0
local saw_unapproved_warning = false
local original_notify = vim.notify
vim.notify = function(message, level)
  if level == vim.log.levels.WARN and tostring(message):find("did not approve", 1, true) then
    saw_unapproved_warning = true
  end
end
require("replaice.config").setup({
  provider = function(_, done)
    unapproved_calls = unapproved_calls + 1
    if unapproved_calls % 2 == 1 then
      done(nil, "Unapproved " .. math.ceil(unapproved_calls / 2) .. ".")
    else
      done(nil, "REVISE: Still needs work.")
    end
  end,
  preview = false,
  refine = { enabled = true, max_tries = 2 },
})
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "bad text" })
vim.cmd("normal! gg0v2l")
vim.ui.input = function(_, callback)
  callback("Polish it.")
end
require("replaice.workflow").run()
vim.ui.input = original_input
vim.notify = original_notify
eq(unapproved_calls, 4, "last allowed candidate is still reviewed")
eq(saw_unapproved_warning, true, "warns before applying an unapproved candidate without preview")
eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "Unapproved 2. text" }, "last candidate is applied when preview is disabled")

print("replaice: all tests passed")
