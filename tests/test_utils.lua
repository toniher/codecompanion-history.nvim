-- Test file for the utils module
---@brief [[
--- Tests for the shared utility helpers
---
--- Covers the normalisation helpers relied on by the title generator, the
--- summary generator and the chat preview:
---
--- 1. `message_text`: message content that is not a plain string
--- 2. `format_adapter_error`: the differing error payload shapes from the HTTP client
--- 3. `format_relative_time`: missing timestamps
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
                utils = require("codecompanion._extensions.history.utils")
            ]])
        end,
        post_once = child.stop,
    },
})

T["message_text"] = new_set()

T["message_text"]["returns plain string content unchanged"] = function()
    eq("hello", child.lua_get([[utils.message_text("hello")]]))
end

T["message_text"]["returns empty string for nil content"] = function()
    -- nil must not become the fallback, otherwise empty user messages would
    -- render as placeholder text in the preview
    eq("", child.lua_get([[utils.message_text(nil)]]))
    eq("", child.lua_get([[utils.message_text(nil, "[fallback]")]]))
end

T["message_text"]["unwraps anthropic style table content"] = function()
    eq("tool result", child.lua_get([[utils.message_text({ type = "tool_result", content = "tool result" })]]))
end

T["message_text"]["falls back when a table holds no text"] = function()
    eq("[fallback]", child.lua_get([[utils.message_text({ type = "tool_result" }, "[fallback]")]]))
    eq("", child.lua_get([[utils.message_text({ nested = { "a" } })]]))
end

T["message_text"]["result is always safe to concatenate and trim"] = function()
    -- This is the property the generators depend on
    eq("prefix: tool result", child.lua_get([[("prefix: " .. utils.message_text({ content = "tool result" }))]]))
    eq("", child.lua_get([[vim.trim(utils.message_text({ unexpected = true }))]]))
end

T["format_adapter_error"] = new_set()

T["format_adapter_error"]["returns nil when there is no error"] = function()
    eq(vim.NIL, child.lua_get([[utils.format_adapter_error(nil)]]))
    -- "{}" is the sentinel the client uses for "no error"
    eq(vim.NIL, child.lua_get([[utils.format_adapter_error({ stderr = "{}" })]]))
    eq(vim.NIL, child.lua_get([[utils.format_adapter_error({ stderr = "" })]]))
    eq(vim.NIL, child.lua_get([[utils.format_adapter_error({ message = "no stderr" })]]))
end

T["format_adapter_error"]["passes through string stderr from streaming failures"] = function()
    eq("boom", child.lua_get([[utils.format_adapter_error({ stderr = "boom" })]]))
end

T["format_adapter_error"]["extracts the body from a non-streaming response table"] = function()
    -- Non-streaming HTTP errors set stderr to the whole response table
    eq(
        '{"error":"rate limited"}',
        child.lua_get([[utils.format_adapter_error({ stderr = { status = 429, body = '{"error":"rate limited"}' } })]])
    )
end

T["format_adapter_error"]["encodes a table without a body"] = function()
    local result = child.lua_get([[utils.format_adapter_error({ stderr = { status = 500 } })]])
    eq("string", type(result))
    eq(true, result:find("500", 1, true) ~= nil)
end

T["format_adapter_error"]["result is always safe to concatenate"] = function()
    -- Guards the regression where a response table was concatenated directly
    eq("Error: boom", child.lua_get([[("Error: " .. utils.format_adapter_error({ stderr = { body = "boom" } }))]]))
end

T["format_relative_time"] = new_set()

T["format_relative_time"]["formats recent timestamps"] = function()
    eq("0s", child.lua_get([[utils.format_relative_time(os.time())]]))
    eq("2m", child.lua_get([[utils.format_relative_time(os.time() - 120)]]))
    eq("3h", child.lua_get([[utils.format_relative_time(os.time() - (3 * 3600))]]))
    eq("2d", child.lua_get([[utils.format_relative_time(os.time() - (2 * 86400))]]))
end

T["format_relative_time"]["handles a missing timestamp"] = function()
    -- Summary index entries are not guaranteed to carry `generated_at`
    eq("?", child.lua_get([[utils.format_relative_time(nil)]]))
end

T["visible_user_prompts"] = new_set()

T["visible_user_prompts"]["keeps real prompts in order, with their _meta.id"] = function()
    local result = child.lua([[
        local config = require("codecompanion.config")
        local messages = {
            { role = config.constants.USER_ROLE, content = "first", opts = { visible = true }, _meta = { id = "a" } },
            { role = config.constants.LLM_ROLE, content = "reply", opts = { visible = true }, _meta = { id = "b" } },
            { role = config.constants.USER_ROLE, content = "second", opts = { visible = true }, _meta = { id = "c" } },
        }
        return utils.visible_user_prompts(messages)
    ]])
    eq(2, #result)
    eq("first", result[1].text)
    eq("a", result[1].id)
    eq("second", result[2].text)
    eq("c", result[2].id)
end

T["visible_user_prompts"]["drops invisible context messages"] = function()
    local result = child.lua([[
        local config = require("codecompanion.config")
        local messages = {
            { role = config.constants.USER_ROLE, content = "real prompt", opts = { visible = true } },
            {
                role = config.constants.USER_ROLE,
                content = "injected context",
                opts = { visible = false },
                context = { id = "claude-mem-recent" },
                _meta = { tag = "claude-mem" },
            },
        }
        return utils.visible_user_prompts(messages)
    ]])
    eq(1, #result)
    eq("real prompt", result[1].text)
end

T["visible_user_prompts"]["drops tagged, context_id and reference messages"] = function()
    local result = child.lua([[
        local config = require("codecompanion.config")
        local messages = {
            { role = config.constants.USER_ROLE, content = "real prompt", opts = { visible = true } },
            { role = config.constants.USER_ROLE, content = "slash command", opts = { visible = true, tag = "from_config" } },
            { role = config.constants.USER_ROLE, content = "file ref", opts = { visible = true, context_id = "buf1" } },
            { role = config.constants.USER_ROLE, content = "variable ref", opts = { visible = true, reference = "@foo" } },
            { role = config.constants.USER_ROLE, content = "meta tagged", opts = { visible = true }, _meta = { tag = "system" } },
        }
        return utils.visible_user_prompts(messages)
    ]])
    eq(1, #result)
    eq("real prompt", result[1].text)
end

T["visible_user_prompts"]["drops empty or whitespace-only content"] = function()
    local result = child.lua([[
        local config = require("codecompanion.config")
        local messages = {
            { role = config.constants.USER_ROLE, content = "   ", opts = { visible = true } },
            { role = config.constants.USER_ROLE, content = "", opts = { visible = true } },
            { role = config.constants.USER_ROLE, content = "real", opts = { visible = true } },
        }
        return utils.visible_user_prompts(messages)
    ]])
    eq(1, #result)
    eq("real", result[1].text)
end

return T
