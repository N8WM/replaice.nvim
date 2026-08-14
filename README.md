# replaice.nvim

Rewrite exactly the text you select—nothing else.

Replaice is a Neovim plugin for editing prose in Markdown, plain text, and similar files. Select some text, describe how you want it changed, and choose the version you prefer. Leave the instructions empty when you just want the model to improve it.

## Requirements

- Neovim 0.10+
- `curl`
- OpenAI, Ollama, an OpenAI-compatible server, or a custom provider

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

The default configuration uses OpenAI. Set `OPENAI_API_KEY` in the environment that starts Neovim.

To use Ollama instead:

```lua
require("replaice").setup({
  provider = "ollama",
  model = "qwen3:8b",
})
```

For LM Studio, llama.cpp, or another OpenAI-compatible server:

```lua
require("replaice").setup({
  provider = "openai_compatible",
  model = "your-local-model",
  providers = {
    openai_compatible = {
      endpoint = "http://127.0.0.1:1234/v1/chat/completions",
      -- api_key_env = "LOCAL_LLM_API_KEY",
    },
  },
})
```

Claude also works through [Anthropic's OpenAI-compatible endpoint](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/openai-sdk). Set `ANTHROPIC_API_KEY`, then use:

```lua
require("replaice").setup({
  provider = "openai_compatible",
  model = "claude-sonnet-4-6",
  providers = {
    openai_compatible = {
      endpoint = "https://api.anthropic.com/v1/chat/completions",
      api_key_env = "ANTHROPIC_API_KEY",
    },
  },
})
```

## Usage

1. Make a characterwise (`v`) or linewise (`V`) selection.
2. Press `<leader>r`.
3. Enter instructions, or press Enter to let the model improve the selection automatically.
4. Choose a version in the picker.

Picker controls:

- `j`/`k` or arrow keys: inspect versions
- `a`: accept the selected version
- `r`: create another version with additional guidance
- `q`: cancel

You can navigate back to, accept, or create a new version from any previous version. After accepting, the replacement remains selected so you can immediately run Replaice again.

You can also run `:Replaice make this more formal` after making a visual selection. Run `:checkhealth replaice` to check your setup.

## Selection safety

Replaice only replaces the captured visual selection. If the document changes while a replacement is being generated, Replaice refuses to apply it and asks you to select the text again.

## Configuration

```lua
require("replaice").setup({
  provider = "openai",
  model = "gpt-5.6-luna",
  keymap = "<leader>r", -- false disables the default mapping
  prompt = "Rewrite the selection so it is clear, natural, and fits its surrounding context.",
  preview = true,
  context = {
    max_chars = 12000,
    max_lines = 200,
  },
  refine = {
    enabled = true,
    max_tries = 3,
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

Pass a function as `provider` to connect another API or local process:

```lua
require("replaice").setup({
  model = "my-model",
  provider = function(request, done)
    my_async_model(request, function(error, replacement)
      done(error, replacement)
    end)
  end,
})
```

The provider receives `request.model`, `request.instructions`, and `request.input`. Call `done` once with an error or the replacement text.

## License

MIT
