local selection = require("replaice.selection")
local prompts = require("replaice.prompts")
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
assert(reviewer_prompt:find("<REPLAICE_SELECTION>\nCandidate three.\n</REPLAICE_SELECTION>", 1, true), "reviewer sees current candidate in context")

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
    assert(request.input:find("<REPLAICE_SELECTION>\nbad\n</REPLAICE_SELECTION>", 1, true), request.input)
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
      assert(request.input:find("<REPLAICE_SELECTION>\nCandidate three.\n</REPLAICE_SELECTION>", 1, true), "final review sees third candidate in context")
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
