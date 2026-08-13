local config = require("replaice.config")
local context_module = require("replaice.context")
local prompts = require("replaice.prompts")
local providers = require("replaice.providers")
local selection_module = require("replaice.selection")
local ui = require("replaice.ui")

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
    local session = ui.open({ request = request, context = context })
    local epoch = 0
    local retry_prompt_open = false

    local function call(input_text, callback, instructions)
      local call_epoch = epoch
      providers.request(options, {
        model = options.model,
        instructions = instructions or prompts.system,
        input = input_text,
      }, function(err, value)
        if session:is_cancelled() or call_epoch ~= epoch then
          return
        end
        callback(err, value)
      end)
    end

    local generate
    local function apply(replacement)
      local ok, err = selection_module.apply(selection, replacement)
      if not ok then
        return false, err
      end
      return true
    end

    local function retry(previous, selected_index)
      if retry_prompt_open then
        return
      end
      retry_prompt_open = true
      ask("", function(extra)
        retry_prompt_open = false
        if extra == nil then
          return
        end
        local guidance = vim.trim(extra) ~= "" and extra or "Try a different approach."
        epoch = epoch + 1
        session:supersede_pending()
        table.insert(history, { candidate = previous, user_feedback = guidance })
        session:add_user_guidance(selected_index, guidance)
        tries = 0
        generate()
      end)
    end

    session:set_callbacks({ accept = apply, retry = retry })

    local function finish(candidate, approved, index)

      if not options.preview then
        if approved == false then
          notify(
            "Retry limit reached; applying a candidate the reviewer did not approve because preview is disabled",
            vim.log.levels.WARN
          )
        end
        local ok, err = apply(candidate)
        if not ok then
          session:show_error(err)
          return
        end
        session:close(false)
        return
      end
      session:ready(index, approved)
    end

    generate = function()
      tries = tries + 1
      local ui_index = session:generating(tries, options.refine.max_tries)
      call(prompts.rewrite(context, request, history), function(err, candidate)
        if err then
          session:show_error(err, ui_index)
          return
        end
        local attempt = { candidate = candidate }
        table.insert(history, attempt)
        session:add_candidate(ui_index, candidate)
        if not options.refine.enabled then
          finish(candidate, nil, ui_index)
          return
        end

        session:reviewing_candidate(ui_index)
        call(prompts.review(context, request, history), function(review_error, verdict)
          if review_error then
            session:show_error(review_error, ui_index)
            return
          end
          local approved, review_feedback = prompts.review_result(verdict)
          if approved then
            attempt.review = { approved = true }
            session:add_review(ui_index, true)
            finish(candidate, true, ui_index)
          elseif approved == false then
            attempt.review = { approved = false, feedback = review_feedback }
            session:add_review(ui_index, false, review_feedback)
            if tries < options.refine.max_tries then
              generate()
            else
              finish(candidate, false, ui_index)
            end
          else
            session:show_error(review_feedback)
          end
        end, prompts.review_system)
      end)
    end

    generate()
  end)
end

return M
