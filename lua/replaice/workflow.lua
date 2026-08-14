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
    local session = ui.open({ context = context, instructions = { request } })
    local versions = {}
    local epoch = 0
    local retry_prompt_open = false

    local function apply(replacement)
      local ok, err = selection_module.apply(selection, replacement)
      if not ok then
        return false, err
      end
      return true
    end

    local start_run
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
        local source = versions[selected_index]
        if not source then
          return
        end

        local history = vim.deepcopy(source.history)
        local latest = history[#history]
        if latest and latest.candidate == previous then
          latest.user_feedback = guidance
        else
          table.insert(history, { candidate = previous, user_feedback = guidance })
        end
        local instructions = vim.deepcopy(source.instructions)
        table.insert(instructions, guidance)

        session:stop_pending()
        start_run(history, instructions)
      end)
    end

    session:set_callbacks({ accept = apply, retry = retry })

    start_run = function(base_history, instructions)
      epoch = epoch + 1
      local run = {
        epoch = epoch,
        history = vim.deepcopy(base_history or {}),
        instructions = vim.deepcopy(instructions),
        tries = 0,
      }
      local version_index = session:start_version(run.instructions)
      versions[version_index] = run

      local function call(input_text, callback, system_instructions)
        providers.request(options, {
          model = options.model,
          instructions = system_instructions or prompts.system,
          input = input_text,
        }, function(err, value)
          if session:is_cancelled() or run.epoch ~= epoch then
            return
          end
          callback(err, value)
        end)
      end

      local function finish(candidate, approved)
        run.approved = approved
        session:complete_version(version_index, candidate)
        if options.preview then
          return
        end
        if approved == false then
          notify(
            "Retry limit reached; applying a candidate the reviewer did not approve because preview is disabled",
            vim.log.levels.WARN
          )
        end
        local ok, err = apply(candidate)
        if not ok then
          session:show_error(err, version_index)
          return
        end
        session:close(false)
      end

      local generate
      generate = function()
        run.tries = run.tries + 1
        session:set_working(version_index, "Generating…")
        call(prompts.rewrite(context, request, run.history), function(err, candidate)
          if err then
            session:show_error(err, version_index)
            return
          end
          local attempt = { candidate = candidate }
          table.insert(run.history, attempt)
          if not options.refine.enabled then
            finish(candidate, nil)
            return
          end

          call(prompts.review(context, request, run.history), function(review_error, verdict)
            if review_error then
              session:show_error(review_error, version_index)
              return
            end
            local approved, review_feedback = prompts.review_result(verdict)
            if approved then
              attempt.review = { approved = true }
              finish(candidate, true)
            elseif approved == false then
              attempt.review = { approved = false, feedback = review_feedback }
              if run.tries < options.refine.max_tries then
                generate()
              else
                finish(candidate, false)
              end
            else
              session:show_error(review_feedback, version_index)
            end
          end, prompts.review_system)
        end)
      end

      generate()
    end

    start_run({}, { request })
  end)
end

return M
