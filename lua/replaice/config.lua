local M = {}

M.defaults = {
  provider = "openai",
  model = "gpt-5.6-luna",
  prompt = "Rewrite the selection so it is clear, natural, and fits its surrounding context.",
  context = {
    max_chars = 12000,
    max_lines = 200,
  },
  refine = {
    enabled = true,
    max_tries = 3,
  },
  preview = true,
  keymap = "<leader>r",
  providers = {
    openai = {
      endpoint = "https://api.openai.com/v1/responses",
      api_key_env = "OPENAI_API_KEY",
      timeout = 120,
    },
    openai_compatible = {
      endpoint = "http://127.0.0.1:1234/v1/chat/completions",
      api_key_env = nil,
      timeout = 120,
    },
    ollama = {
      endpoint = "http://127.0.0.1:11434/api/chat",
      timeout = 120,
    },
  },
}

M.options = vim.deepcopy(M.defaults)

local function validate(options)
  vim.validate({
    provider = { options.provider, { "string", "function" } },
    model = { options.model, "string" },
    prompt = { options.prompt, "string" },
    context = { options.context, "table" },
    refine = { options.refine, "table" },
    providers = { options.providers, "table" },
  })
  assert(options.context.max_chars > 0, "replaice: context.max_chars must be positive")
  assert(options.context.max_lines > 0, "replaice: context.max_lines must be positive")
  assert(options.refine.max_tries > 0, "replaice: refine.max_tries must be positive")
end

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), options or {})
  validate(M.options)
  return M.options
end

return M
