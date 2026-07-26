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
            ]])
        end,
        post_case = function() end,
        post_once = child.stop,
    },
})

T["Provider Resolution"] = new_set()

T["Provider Resolution"]["auto-resolves to vectorcode when only vectorcode is available"] = function()
    local result = child.lua([[
        local memory = require("codecompanion._extensions.history.memory")
        local vectorcode = require("codecompanion._extensions.history.memory.vectorcode")
        local claude_mem = require("codecompanion._extensions.history.memory.claude_mem")
        vectorcode.is_available = function() return true end
        claude_mem.is_available = function() return false end

        local provider, name = memory.resolve({ auto_create_memories_on_summary_generation = true })
        return { name = name, has_provider = provider ~= nil }
    ]])
    eq("vectorcode", result.name)
    eq(true, result.has_provider)
end

T["Provider Resolution"]["auto-resolves to claude-mem when only claude-mem is available"] = function()
    local result = child.lua([[
        local memory = require("codecompanion._extensions.history.memory")
        local vectorcode = require("codecompanion._extensions.history.memory.vectorcode")
        local claude_mem = require("codecompanion._extensions.history.memory.claude_mem")
        vectorcode.is_available = function() return false end
        claude_mem.is_available = function() return true end

        local provider, name = memory.resolve({ auto_create_memories_on_summary_generation = true })
        return { name = name, has_provider = provider ~= nil }
    ]])
    eq("claude-mem", result.name)
    eq(true, result.has_provider)
end

T["Provider Resolution"]["explicit provider is honoured over availability order"] = function()
    local result = child.lua([[
        local memory = require("codecompanion._extensions.history.memory")
        local vectorcode = require("codecompanion._extensions.history.memory.vectorcode")
        local claude_mem = require("codecompanion._extensions.history.memory.claude_mem")
        vectorcode.is_available = function() return true end
        claude_mem.is_available = function() return true end

        local provider, name = memory.resolve({ provider = "claude-mem" })
        return { name = name }
    ]])
    eq("claude-mem", result.name)
end

T["Provider Resolution"]["returns nil when nothing is available"] = function()
    local result = child.lua([[
        local memory = require("codecompanion._extensions.history.memory")
        local vectorcode = require("codecompanion._extensions.history.memory.vectorcode")
        local claude_mem = require("codecompanion._extensions.history.memory.claude_mem")
        vectorcode.is_available = function() return false end
        claude_mem.is_available = function() return false end

        local provider, name = memory.resolve({})
        return { has_provider = provider ~= nil, name = name }
    ]])
    eq(false, result.has_provider)
    eq(nil, result.name)
end

T["Extension wiring"] = new_set()

T["Extension wiring"]["stores the resolved provider on the history instance and registers the memory tool"] = function()
    local result = child.lua([[
        local claude_mem = require("codecompanion._extensions.history.memory.claude_mem")
        claude_mem.is_available = function() return true end

        local extension = require("codecompanion._extensions.history")
        extension.setup({
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-provider-test",
            memory = { provider = "claude-mem" },
        })

        local cc_config = require("codecompanion.config").config
        return {
            has_tool = cc_config.interactions.chat.tools["memory"] ~= nil,
        }
    ]])
    eq(true, result.has_tool)
end

T["Extension wiring"]["repeat setup with claude-mem forced available does not duplicate the summary autocmd"] = function()
    local result = child.lua([[
        local claude_mem = require("codecompanion._extensions.history.memory.claude_mem")
        claude_mem.is_available = function() return true end

        local extension = require("codecompanion._extensions.history")
        local ok1 = pcall(extension.setup, {
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-provider-test",
            memory = { provider = "claude-mem" },
        })
        local ok2 = pcall(extension.setup, {
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-provider-test",
            memory = { provider = "claude-mem" },
        })

        local autocmds = vim.api.nvim_get_autocmds({
            event = "User",
            pattern = "CodeCompanionHistorySummarySaved",
        })

        return { ok1 = ok1, ok2 = ok2, count = #autocmds }
    ]])
    eq(true, result.ok1)
    eq(true, result.ok2)
    eq(1, result.count)
end

T["Extension wiring"]["falls back gracefully when neither backend is available"] = function()
    local result = child.lua([[
        local vectorcode = require("codecompanion._extensions.history.memory.vectorcode")
        local claude_mem = require("codecompanion._extensions.history.memory.claude_mem")
        vectorcode.is_available = function() return false end
        claude_mem.is_available = function() return false end

        local extension = require("codecompanion._extensions.history")
        local ok = pcall(extension.setup, {
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-provider-test-none",
        })

        local cc_config = require("codecompanion.config").config
        return { ok = ok, has_tool = cc_config.interactions.chat.tools["memory"] ~= nil }
    ]])
    eq(true, result.ok)
end

T["Context injection"] = new_set()

T["Context injection"]["injects context into the chat when the provider opts in"] = function()
    local result = child.lua([[
        local History = require("codecompanion._extensions.history").History
        local history = History.new({
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-inject-unit-test",
            summary = {},
        })

        history.memory_provider = {
            get_context = function(project_root, cb)
                cb("## Recent activity\n- did stuff\n")
            end,
            wants_context_injection = function()
                return true
            end,
        }

        local captured = {}
        local fake_chat = {
            add_context = function(self, data, source, id, opts)
                table.insert(captured, { content = data.content, source = source, id = id, opts = opts })
            end,
        }

        history:_maybe_inject_memory_context(fake_chat)

        return {
            count = #captured,
            source = captured[1] and captured[1].source,
            visible = captured[1] and captured[1].opts.visible,
            content_ok = captured[1] and captured[1].content:find("did stuff") ~= nil,
        }
    ]])
    eq(1, result.count)
    eq("claude-mem", result.source)
    eq(false, result.visible)
    eq(true, result.content_ok)
end

T["Context injection"]["does nothing when the provider has no get_context"] = function()
    local result = child.lua([[
        local History = require("codecompanion._extensions.history").History
        local history = History.new({
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-inject-unit-test",
            summary = {},
        })

        -- e.g. the vectorcode shim: no get_context field at all
        history.memory_provider = {
            wants_context_injection = function()
                return false
            end,
        }

        local captured = {}
        local fake_chat = {
            add_context = function(self, data, source, id, opts)
                table.insert(captured, { source = source })
            end,
        }

        history:_maybe_inject_memory_context(fake_chat)

        return { count = #captured }
    ]])
    eq(0, result.count)
end

T["Context injection"]["does nothing when wants_context_injection() is false"] = function()
    local result = child.lua([[
        local History = require("codecompanion._extensions.history").History
        local history = History.new({
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-inject-unit-test",
            summary = {},
        })

        history.memory_provider = {
            get_context = function(project_root, cb)
                cb("## Recent activity\n- did stuff\n")
            end,
            wants_context_injection = function()
                return false
            end,
        }

        local captured = {}
        local fake_chat = {
            add_context = function(self, data, source, id, opts)
                table.insert(captured, { source = source })
            end,
        }

        history:_maybe_inject_memory_context(fake_chat)

        return { count = #captured }
    ]])
    eq(0, result.count)
end

T["Context injection"]["swallows errors from a failing get_context without raising"] = function()
    local result = child.lua([[
        local History = require("codecompanion._extensions.history").History
        local history = History.new({
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-inject-unit-test",
            summary = {},
        })

        history.memory_provider = {
            get_context = function(project_root, cb)
                error("simulated failure fetching context")
            end,
            wants_context_injection = function()
                return true
            end,
        }

        local fake_chat = {
            add_context = function() end,
        }

        local ok = pcall(function()
            history:_maybe_inject_memory_context(fake_chat)
        end)

        return { ok = ok }
    ]])
    eq(true, result.ok)
end

T["Context injection"]["swallows errors from a failing add_context without raising"] = function()
    local result = child.lua([[
        local History = require("codecompanion._extensions.history").History
        local history = History.new({
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-inject-unit-test",
            summary = {},
        })

        history.memory_provider = {
            get_context = function(project_root, cb)
                cb("some context")
            end,
            wants_context_injection = function()
                return true
            end,
        }

        local fake_chat = {
            add_context = function()
                error("simulated failure adding context to the chat buffer")
            end,
        }

        local ok = pcall(function()
            history:_maybe_inject_memory_context(fake_chat)
        end)

        return { ok = ok }
    ]])
    eq(true, result.ok)
end

return T
