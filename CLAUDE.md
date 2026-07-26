# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make test                                    # Run all tests
make test_file FILE=tests/test_storage.lua   # Run a single test file
make format                                  # Format Lua code with stylua
make docs                                    # Regenerate vimdoc from scripts/vimdoc.md
make deps                                    # Clone/update all test dependencies into deps/
make force-update-codecompanion              # Force re-clone codecompanion (bypasses 1h cache)
```

Tests run headless Neovim via [Mini.Test](https://github.com/echasnovski/mini.nvim/tree/main/lua/mini/test). The `scripts/minimal_init.lua` bootstraps the runtime for tests.

## Code Style

Formatting is enforced by `stylua` (config in `stylua.toml`): 4-space indent, 120-column width, double-quote strings, sorted requires. Run `make format` before committing.

## Architecture

This is a [CodeCompanion.nvim](https://codecompanion.olimorris.dev/) extension. All source lives under `lua/codecompanion/_extensions/history/`. It is registered by users via `codecompanion.setup({ extensions = { history = { ... } } })`.

### Module layout

| File | Role |
|------|------|
| `init.lua` | Extension entry point. Creates the singleton `History` instance, registers Neovim autocommands and user commands, wires chat keymaps into `cc_config.interactions.chat.keymaps`. Exports the public API under `require("codecompanion").extensions.history`. |
| `storage.lua` | Persistence layer. Maintains `{dir_to_save}/index.json` (lightweight metadata for all chats) and individual chat JSON files under `{dir_to_save}/chats/`. Also manages the summaries index at `{dir_to_save}/summaries_index.json`, with summary content under `{dir_to_save}/summaries/`. Uses `plenary.path` for I/O. |
| `title_generator.lua` | Async title generation via the chat's configured LLM adapter. Handles initial generation and periodic refreshes (`refresh_every_n_prompts`). Silently skips when the chat's native adapter is ACP (local model); surfaces an error via callback when the user explicitly configures an ACP adapter in `generation_opts.adapter`. |
| `summary_generator.lua` | Chunked conversation summarization via LLM. Filters out noise (context messages, tool schemas) before summarizing. Same ACP adapter handling as `title_generator.lua`. |
| `ui.lua` | Buffer-title management and summary indicator logic. Delegates history/summary browsing to pickers. |
| `pickers/` | One file per picker backend: `telescope.lua`, `snacks.lua`, `fzf-lua.lua`, `default.lua`. `pickers/init.lua` auto-resolves which backend to use. |
| `vectorcode.lua` | Optional VectorCode CLI integration (the underlying implementation). Indexes summaries for vector search and builds the `@memory` tool. Wrapped by `memory/vectorcode.lua`. |
| `memory/` | Memory-provider abstraction, mirroring the `pickers/` auto-resolution pattern. `init.lua` resolves a provider (`opts.memory.provider`, or vectorcode-then-claude-mem auto-detection) via each provider's `setup()`/`is_available()`. `vectorcode.lua` shims the existing `history/vectorcode.lua`. `claude_mem.lua` talks to a local [claude-mem](https://github.com/thedotmack/claude-mem) HTTP worker over `curl`: builds the `@memory` tool (keyword/semantic search + id unfold), pushes generated summaries via `POST /api/memory/save`, and optionally fetches recent context for injection into new chats (`get_context`/`wants_context_injection`). When `claude_mem.auto_start_worker = true`, a failed request triggers one auto-start attempt per session (`_resolve_start_command`/`_start_worker`): a global `claude-mem` binary on PATH first, else the newest non-orphaned plugin version under the Claude Code plugin cache, invoked via `node bun-runner.js worker-service.cjs start`. |
| `types.lua` | LuaLS type annotations shared across modules. |
| `utils.lua` | Utilities: `fire()` for User autocmd events; `find_project_root()` (walks up from cwd looking for `.git`, `package.json`, etc.); file I/O helpers (`read_file`, `write_file`, `read_json`, `write_json`, `delete_file`); `get_editor_info()` for buffer state; `format_relative_time` for timestamps; `remove_functions` for JSON serialisation of chat data; `message_text()` to normalise message content that some adapters store as a table; `format_adapter_error()` to normalise HTTP client error payloads. |
| `log.lua` | Logging wrapper; activated only when `enable_logging = true`. |

### Event-driven lifecycle

The extension does not monkey-patch CodeCompanion. It exclusively listens to CodeCompanion's User autocmd events:

- `CodeCompanionChatCreated` - assigns a `save_id`, sets buffer title, optionally restores last chat.
- `CodeCompanionChatSubmitted` - triggers title generation/refresh; saves chat if `auto_save = true`.
- `CodeCompanion*Finished` (`RequestFinished`, `ToolsFinished`) - saves chat state after LLM/tool response.
- `CodeCompanionChatCleared` - optionally deletes the chat; resets `save_id` and title.

The extension fires its own event `CodeCompanionHistorySummarySaved` (data: `{summary, path}`) when a summary is saved, which the resolved memory provider (`history_instance.memory_provider`) listens to for auto-indexing/saving.

### Chat identity

Each chat gets a `save_id` (Unix timestamp string) stored in `chat.opts.save_id`. This is monkey-patched onto the CodeCompanion `Chat` instance as `CodeCompanion.History.ChatArgs`. The same field is also the key in `index.json`.

### Storage schema

`index.json` holds `ChatIndexData` (lightweight): `save_id`, `title`, `cwd`, `project_root`, `adapter`, `model`, `updated_at`, `message_count`, `token_estimate`.

Individual chat files hold the full `ChatData` blob: message history, tool schemas, tool outputs, references, pinned references, adapter config, system prompt.

### Testing conventions

Test files are in `tests/`. Shared setup helpers live in `tests/helpers.lua` and `tests/cc_helpers.lua`. `tests/cc_config.lua` is the CodeCompanion config fixture used by `cc_helpers`. `tests/stubs/` holds additional fixture data (`chat_data.json`, `weather.lua`, `claude_mem_*.json`).

Test files and their coverage:

| File | Coverage |
|------|----------|
| `test_storage.lua` | Persistence layer (save/load, index, expiry) |
| `test_title_generator.lua` | Title generation including ACP adapter skip/error cases |
| `test_summary.lua` | Summary generation including ACP adapter skip/error cases |
| `test_filtering.lua` | Project root detection, `cwd`/`project_root` capture on save, `get_chats`/`get_last_chat` filter functions |
| `test_providers.lua` | Picker backend auto-resolution, picker instance state isolation |
| `test_memory_providers.lua` | Memory-provider auto-resolution (`memory/init.lua`), extension wiring (tool registration, repeat-`setup()` idempotency), context-injection helper (`History:_maybe_inject_memory_context`) |
| `test_memory_claude_mem.lua` | claude-mem provider: config resolution, `is_available()`, `@memory` tool (search/unfold/error paths), `index()` save/backfill, `get_context()` |
| `test_setup.lua` | Extension initialisation, `:CodeCompanionHistory` command, keymap registration, repeat `setup()` calls |
| `test_ui.lua` | Chat preview rendering: context items and non-string message content |
| `test_utils.lua` | `message_text`, `format_adapter_error`, `format_relative_time` normalisation helpers |
