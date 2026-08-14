# replaice.nvim

Rewrite exactly the text you select—nothing else.

Replaice is a small Neovim plugin for prose files such as Markdown and plain text. Select a passage, press `<leader>r`, and describe the change. Leave the prompt empty to let the configured model improve the passage on its own.

## Safety model

Replaice does not ask a model for a patch. The model can return only replacement text, and Neovim inserts that text at the captured visual range.

- Only characterwise and linewise visual selections are accepted.
- The captured buffer `changedtick` and original selected text are checked again before applying.
- If the buffer changed while the model was working, the edit is rejected rather than guessed.
- The model sees bounded context around the selection, but its output is applied only to the selection.
- The picker stays read-only and requires explicit acceptance before any edit. You can inspect versions, accept one, create another from one, or cancel.
- The optional reviewer loop inserts each candidate into the surrounding context for review, then retries with feedback up to a configured limit.
- Provider calls remain stateless, while the plugin explicitly gives both roles the complete candidate-and-review history.
- A persistent picker shows the selected version's user-instruction lineage at the top, lists user-requested versions on the left, and highlights the selected replacement inline in its original context on the right.

This is a structural boundary in the plugin, not merely a sentence in the prompt.

## Requirements

- Neovim 0.10+
- `curl` for the built-in HTTP providers
- One of OpenAI, an OpenAI-compatible server, Ollama, or a custom Lua provider

## Installation

With lazy.nvim:

```lua
{
  "N8WM/replaice.nvim",
  config = function()
    require("replaice").setup()
  end,
}
```

Set `OPENAI_API_KEY` in the environment that starts Neovim. The default setup uses OpenAI's Responses API:

```lua
require("replaice").setup({
  provider = "openai",
  model = "gpt-5.6-luna",
})
```

For Ollama:

```lua
require("replaice").setup({
  provider = "ollama",
  model = "qwen3:8b",
})
```

For LM Studio, llama.cpp, or another OpenAI-compatible chat-completions server:

```lua
require("replaice").setup({
  provider = "openai_compatible",
  model = "your-local-model",
  providers = {
    openai_compatible = {
      endpoint = "http://127.0.0.1:1234/v1/chat/completions",
      -- api_key_env = "LOCAL_LLM_API_KEY", -- only if your server needs one
    },
  },
})
```

## Use

1. Make a characterwise (`v`) or linewise (`V`) selection.
2. Press `<leader>r`.
3. Enter instructions such as `make this warmer and more concise`, or press Enter for the default improvement prompt.
4. Use `j`/`k` or the arrow keys to inspect versions, `a` to accept the selected version, `r` to create a new version from it with more guidance, or `q` to cancel. You can accept or branch from any generated version, not only the latest one.

The read-only picker uses native Neovim floating-window APIs and has no UI-plugin dependency. Its contextual preview highlights the exact replacement inline, keeps fragment boundaries visible, and centers that location when surrounding context permits. The list shows a compact excerpt of each replacement rather than internal review state. Instruction and retry prompts use `vim.ui.input`, so Noice and other UI replacements can enhance those inputs automatically. Closing either main pane cancels the session and ignores any provider response that arrives afterward.

You can also run `:Replaice make this more formal` after a visual selection. Run `:checkhealth replaice` to check the local setup.

## Configuration

```lua
require("replaice").setup({
  provider = "openai",
  model = "gpt-5.6-luna",
  keymap = "<leader>r", -- false disables the default visual mapping
  prompt = "Rewrite the selection so it is clear, natural, and fits its surrounding context.",
  preview = true,
  context = {
    max_chars = 12000, -- total approximate character budget around the selection
    max_lines = 200,   -- maximum lines examined on each side
  },
  refine = {
    enabled = true,
    max_tries = 3, -- generation attempts, including reviewer-directed retries
  },
  providers = {
    openai = {
      endpoint = "https://api.openai.com/v1/responses",
      api_key_env = "OPENAI_API_KEY",
      timeout = 120,
    },
  },
})
```

### Custom provider

Pass a function as `provider` to integrate any CLI, local process, or API. It receives the normalized request and a callback:

```lua
require("replaice").setup({
  model = "my-model",
  provider = function(request, done)
    -- request.model, request.instructions, request.input
    -- Call exactly once with done(nil, replacement_text) or done(error_message).
    my_async_model(request, done)
  end,
})
```

The same adapter is used for generation and review. Keep it asynchronous so Neovim remains responsive.

## Why a bounded reviewer loop?

The reviewer sees the candidate programmatically inserted between the original surrounding text, which catches awkward transitions better than reviewing the replacement alone. Every later editor call receives all prior candidates and reviews, and every later reviewer call receives earlier findings so it can catch regressions. These are explicit stateless requests rather than provider-managed conversation state.

The loop is bounded by `refine.max_tries` to prevent runaway latency or API cost. Every candidate, including the last allowed attempt, is reviewed. Automatic candidates and verdicts remain private implementation details: one user-triggered generation produces one visible version. With `preview = false`, Replaice still emits a warning before automatically applying a result that exhausted the internal refinement limit.

## Development

Run the headless test suite:

```sh
nvim -n --headless -u tests/minimal_init.lua -i NONE -l tests/run.lua
```

## License

MIT
