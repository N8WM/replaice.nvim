local config = require("replaice.config")
local context_module = require("replaice.context")
local preview = require("replaice.preview")
local prompts = require("replaice.prompts")
local providers = require("replaice.providers")
local selection_module = require("replaice.selection")

local M = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Replaice" })
end

local function ask(prompt, callback)
  vim.ui.input({
    prompt = "Replaice instructions (Enter = improve automatically): ",
    default = prompt or "",
    completion = nil,
  }, callback)
end

function M.run(initial_prompt)
  local options = config.options
  local selection, capture_error = selection_module.capture()
  if not selection then
    notify(capture_error, vim.log.levels.ERROR)
    return
  end
  if selection.was_active then
    vim.cmd("normal! \27")
  end
  local context = context_module.capture(selection, options.context)

  ask(initial_prompt, function(input)
    if input == nil then
      return
    end
    local request = vim.trim(input) ~= "" and input or options.prompt
    local tries = 0
    local history = {}

    local function call(input_text, callback, instructions)
      providers.request(options, {
        model = options.model,
        instructions = instructions or prompts.system,
        input = input_text,
      }, callback)
    end

    local generate
    local function finish(candidate, approved)
      local function apply(replacement)
        local ok, err = selection_module.apply(selection, replacement)
        if not ok then
          notify(err, vim.log.levels.ERROR)
          return
        end
        notify("Replaced the selected text")
      end

      if not options.preview then
        if approved == false then
          notify("Retry limit reached; applying a candidate the reviewer did not approve because preview is disabled", vim.log.levels.WARN)
        end
        apply(candidate)
        return
      end
      preview.open(candidate, context.filetype, {
        approved = approved,
        accept = apply,
        retry = function(previous)
          ask("", function(extra)
            if extra == nil then
              return
            end
            local guidance = vim.trim(extra) ~= "" and extra or "Try a different approach."
            local latest = history[#history]
            latest.candidate = previous
            latest.user_feedback = guidance
            tries = 0
            generate()
          end)
        end,
      })
    end

    generate = function()
      tries = tries + 1
      notify(("Generating replacement (try %d/%d)…"):format(tries, options.refine.max_tries))
      call(prompts.rewrite(context, request, history), function(err, candidate)
        if err then
          notify(err, vim.log.levels.ERROR)
          return
        end
        local attempt = { candidate = candidate }
        table.insert(history, attempt)
        if not options.refine.enabled then
          finish(candidate, nil)
          return
        end

        notify("Reviewing replacement…")
        call(prompts.review(context, request, history), function(review_error, verdict)
          if review_error then
            notify(review_error, vim.log.levels.ERROR)
            return
          end
          local approved, review_feedback = prompts.review_result(verdict)
          if approved then
            attempt.review = { approved = true }
            finish(candidate, true)
          elseif approved == false then
            attempt.review = { approved = false, feedback = review_feedback }
            if tries < options.refine.max_tries then
              generate()
            else
              finish(candidate, false)
            end
          else
            notify(review_feedback, vim.log.levels.ERROR)
          end
        end, prompts.review_system)
      end)
    end

    generate()
  end)
end

return M
