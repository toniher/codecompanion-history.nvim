-- Test file for the UI module
---@brief [[
--- Tests for the chat preview rendering used by every picker backend
---
--- 1. Context item rendering, including the all-hidden case
--- 2. Message content that is not a plain string
---]]

local h = require("tests.helpers")
local eq, new_set = MiniTest.expect.equality, MiniTest.new_set
local T = new_set()

local child = h.new_child_neovim()

T = new_set({
    hooks = {
        pre_case = function()
            child.setup()
            child.lua([[
                local log = require("codecompanion._extensions.history.log")
                log.setup_logging(false)

                local cc_helpers = require("tests.cc_helpers")
                cc_helpers.setup_plugin()

                local UI = require("codecompanion._extensions.history.ui")
                local Storage = require("codecompanion._extensions.history.storage")
                local storage = Storage.new({
                    dir_to_save = vim.fn.tempname() .. "/history",
                    expiration_days = 0,
                })
                test_ui = UI.new({
                    default_buf_title = "[CodeCompanion]",
                    picker = "default",
                    picker_keymaps = {},
                }, storage, nil)

                ---Render a preview and return its lines
                ---@param chat_data table
                render_preview = function(chat_data)
                    return test_ui:_get_preview_lines(chat_data)
                end
            ]])
        end,
        post_once = child.stop,
    },
})

T["Preview Context Items"] = new_set()

T["Preview Context Items"]["renders visible context items under a header"] = function()
    local lines = child.lua([[
        return render_preview({
            messages = { { role = "user", content = "Hi", opts = { visible = true } } },
            context_items = {
                { id = "<file>init.lua</file>" },
                { id = "<file>utils.lua</file>" },
            },
        })
    ]])

    eq(true, vim.tbl_contains(lines, "> Context:"))
    eq(true, vim.tbl_contains(lines, "> - <file>init.lua</file>"))
    eq(true, vim.tbl_contains(lines, "> - <file>utils.lua</file>"))
end

T["Preview Context Items"]["omits the header when every context item is hidden"] = function()
    -- The header is inserted optimistically, so it has to be withdrawn when no
    -- item ends up being rendered
    local lines = child.lua([[
        return render_preview({
            messages = { { role = "user", content = "Hi", opts = { visible = true } } },
            context_items = {
                { id = "<file>hidden.lua</file>", opts = { visible = false } },
            },
        })
    ]])

    eq(false, vim.tbl_contains(lines, "> Context:"))
    eq(false, vim.tbl_contains(lines, "> - <file>hidden.lua</file>"))
end

T["Preview Context Items"]["omits the header when there are no context items"] = function()
    local lines = child.lua([[
        return render_preview({
            messages = { { role = "user", content = "Hi", opts = { visible = true } } },
            context_items = {},
        })
    ]])

    eq(false, vim.tbl_contains(lines, "> Context:"))
end

T["Preview Context Items"]["reads the legacy refs field"] = function()
    local lines = child.lua([[
        return render_preview({
            messages = { { role = "user", content = "Hi", opts = { visible = true } } },
            refs = { { id = "<file>legacy.lua</file>" } },
        })
    ]])

    eq(true, vim.tbl_contains(lines, "> Context:"))
    eq(true, vim.tbl_contains(lines, "> - <file>legacy.lua</file>"))
end

T["Preview Message Content"] = new_set()

T["Preview Message Content"]["renders plain string content"] = function()
    local lines = child.lua([[
        return render_preview({
            messages = {
                { role = "user", content = "First line\nSecond line", opts = { visible = true } },
            },
        })
    ]])

    eq(true, vim.tbl_contains(lines, "First line"))
    eq(true, vim.tbl_contains(lines, "Second line"))
end

T["Preview Message Content"]["unwraps anthropic style table content"] = function()
    local lines = child.lua([[
        return render_preview({
            messages = {
                { role = "user", content = "Question", opts = { visible = true } },
                {
                    role = "llm",
                    content = { type = "tool_result", content = "Nested tool output" },
                    opts = { visible = true },
                },
            },
        })
    ]])

    eq(true, vim.tbl_contains(lines, "Nested tool output"))
end

T["Preview Message Content"]["falls back for table content with no text"] = function()
    local lines = child.lua([[
        return render_preview({
            messages = {
                { role = "user", content = "Question", opts = { visible = true } },
                { role = "llm", content = { unexpected = true }, opts = { visible = true } },
            },
        })
    ]])

    eq(true, vim.tbl_contains(lines, "[Message Cannot Be Displayed]"))
end

return T
