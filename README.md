# CodeCompanion History Extension

[![Neovim](https://img.shields.io/badge/Neovim-57A143?style=flat-square&logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white)](https://www.lua.org)
[![Tests](https://github.com/toniher/codecompanion-history.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/toniher/codecompanion-history.nvim/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A history management extension for [codecompanion.nvim](https://codecompanion.olimorris.dev/) that enables saving, browsing and restoring chat sessions.

## Features

**Chat Management**
- Automatic and manual session saving
- Smart title generation with optional periodic refresh
- Browse saved chats with preview via telescope, snacks, fzf-lua, or default picker
- Restore chats with full context: messages, tools, references, adapter settings
- Project-aware filtering and chat duplication
- Optional automatic chat expiration

**Summary System**
- Generate summaries for any chat (`gm`)
- Browse all summaries (`gbs`)
- Chunked summarization for large conversations
- Configurable adapter, model, and system prompt

**Memory (`@memory` tool)**
- Two backends: [VectorCode](https://github.com/Davidyz/VectorCode) (local vector search) or [claude-mem](https://github.com/thedotmack/claude-mem) (shared cross-session memory with Claude Code)
- Auto-indexes summaries on generation
- Optional context injection into new chats (claude-mem)

**Preserved on save/restore:**

| Feature | Status |
|---------|--------|
| System Prompts | ✅ |
| Messages History | ✅ |
| Images | ✅ |
| LLM Adapter & Settings | ✅ |
| Tools & Tool Outputs | ✅ |
| Variables & References | ✅ |
| Pinned References | ✅ |
| Watchers | ⚠ requires original buffer context |

> [!NOTE]
> As this extension integrates with CodeCompanion's internal APIs, occasional compatibility issues may arise after CodeCompanion updates. Please [raise an issue](https://github.com/toniher/codecompanion-history.nvim/issues) if you encounter problems.

## Requirements

- Neovim >= 0.8.0
- [codecompanion.nvim](https://codecompanion.olimorris.dev/)
- [VectorCode CLI](https://github.com/Davidyz/VectorCode) or [claude-mem](https://github.com/thedotmack/claude-mem) (optional, for `@memory` tool)
- [snacks.nvim](https://github.com/folke/snacks.nvim), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim), or [fzf-lua](https://github.com/ibhagwan/fzf-lua) (optional, for enhanced picker)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "olimorris/codecompanion.nvim",
    dependencies = {
        "toniher/codecompanion-history.nvim"
    }
}
```

Then add the extension to your CodeCompanion config:

```lua
require("codecompanion").setup({
    extensions = {
        history = {
            enabled = true,
            opts = {
                -- Keymap to open history from chat buffer (default: gh)
                keymap = "gh",
                -- Keymap to save the current chat manually
                save_chat_keymap = "sc",
                -- Save all chats by default
                auto_save = true,
                -- Number of days after which chats are automatically deleted (0 to disable)
                expiration_days = 0,
                -- Picker interface (auto resolved to a valid picker)
                picker = "telescope", -- "telescope" | "snacks" | "fzf-lua" | "default"
                -- Optional filter function to control which chats are shown
                chat_filter = nil, -- function(chat_data) return boolean end
                -- Customize picker keymaps (optional)
                picker_keymaps = {
                    rename = { n = "r", i = "<M-r>" },
                    delete = { n = "d", i = "<M-d>" },
                    duplicate = { n = "<C-y>", i = "<C-y>" },
                    save_to_file = { n = "e", i = "<M-e>" },
                },
                auto_generate_title = true,
                title_generation_opts = {
                    adapter = nil,             -- defaults to current chat adapter
                    model = nil,               -- defaults to current chat model
                    refresh_every_n_prompts = 0,
                    max_refreshes = 3,
                    format_title = function(title) return title end,
                },
                continue_last_chat = false,
                delete_on_clearing_chat = false,
                dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history",
                enable_logging = false,

                summary = {
                    create_summary_keymap = "gm",
                    browse_summaries_keymap = "gbs",
                    generation_opts = {
                        adapter = nil,
                        model = nil,
                        context_size = 90000,
                        include_references = true,
                        include_tool_outputs = true,
                        system_prompt = nil,
                        format_summary = nil,
                    },
                },

                memory = {
                    -- "vectorcode" | "claude-mem" | nil to auto-resolve
                    provider = nil,
                    auto_create_memories_on_summary_generation = true,
                    vectorcode_exe = "vectorcode",
                    tool_opts = { default_num = 10 },
                    notify = true,
                    index_on_startup = false,
                    claude_mem = {
                        host = nil,
                        port = nil,
                        data_dir = nil,
                        timeout_ms = 5000,
                        project = nil,
                        search = "keyword", -- "keyword" | "semantic"
                        inject_context_on_new_chat = false,
                        inject_limit = 5,
                        auto_start_worker = false,
                        auto_start_timeout_ms = 15000,
                    },
                },
            }
        }
    }
})
```

> [!WARNING]
> Title and summary generation defaults to the current chat's adapter and model. Set cheaper models in `title_generation_opts` and `summary.generation_opts` to avoid using premium models.

## Usage

**Commands:**
- `:CodeCompanionHistory` - Open the history browser
- `:CodeCompanionSummaries` - Browse all summaries

**Chat buffer keymaps:**
- `gh` - Open history browser
- `sc` - Save current chat manually
- `gm` - Generate summary for current chat
- `gbs` - Browse saved summaries

**History browser actions:**
- `<CR>` - Open selected chat
- `d` / `<M-d>` - Delete selected chat(s)
- `r` / `<M-r>` - Rename selected chat
- `<C-y>` - Duplicate selected chat
- `e` / `<M-e>` - Save selected chat to file

**Summary browser actions:**
- `<CR>` - Add summary to current chat
- `d` / `<M-d>` - Delete selected summary(s)

## The `@memory` tool

Set `opts.memory.provider` to `"vectorcode"` or `"claude-mem"` to force a backend, or leave it `nil` to auto-resolve (VectorCode first, then claude-mem). Whichever backend is detected registers a `@memory` tool in new chats, letting the LLM search previous chat summaries.

**VectorCode**: Uses the [VectorCode](https://github.com/Davidyz/VectorCode) CLI to index and search summaries locally.

**claude-mem**: Talks to a local [claude-mem](https://github.com/thedotmack/claude-mem) HTTP worker (`127.0.0.1:37700` by default):
- Summaries are pushed via `POST /api/memory/save`, scoped to a project key (`vim.fs.basename(project_root)` by default; override with `memory.claude_mem.project`).
- Search is keyword-based by default; set `search = "semantic"` for Chroma-backed semantic search.
- Set `inject_context_on_new_chat = true` to silently attach recent context to every new chat.
- Set `auto_start_worker = true` to have the extension start the worker automatically on first failed request.
- The database is shared with Claude Code sessions; CodeCompanion summaries are tagged `platform_source = "codecompanion"`.

## API

```lua
local history = require("codecompanion").extensions.history

-- Chat management
history.get_location()                                 -- storage path
history.save_chat(chat?)                               -- save chat (defaults to last)
history.browse_chats(filter_fn?)                       -- open browser with optional filter
history.get_chats(filter_fn?): table<string, ChatIndexData>
history.load_chat(save_id): ChatData?
history.delete_chat(save_id): boolean
history.duplicate_chat(save_id, new_title?): string?

-- Summary management
history.generate_summary(chat?)
history.delete_summary(summary_id)
history.get_summaries(): table<string, SummaryIndexData>
history.load_summary(summary_id): string?
```

**Chat filter fields** (`ChatIndexData`):
```lua
{
    save_id = "1672531200",
    title = "Debug API endpoint",
    cwd = "/home/user/my-project",
    project_root = "/home/user/my-project",
    adapter = "openai",
    model = "gpt-4",
    updated_at = 1672531200,
    message_count = 15,
    token_estimate = 3420,
}
```

## Acknowledgements

- [Oli Morris](https://github.com/olimorris) for [CodeCompanion.nvim](https://codecompanion.olimorris.dev)
- [David](https://github.com/Davidyz) for [VectorCode](https://github.com/Davidyz/VectorCode)
- [thedotmack](https://github.com/thedotmack) for [claude-mem](https://github.com/thedotmack/claude-mem)

## License

MIT

## Fork

This is a fork of [ravitemer/codecompanion-history.nvim](https://github.com/ravitemer/codecompanion-history.nvim).
