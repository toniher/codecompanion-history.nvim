local h = require("tests.helpers")
local eq, new_set = MiniTest.expect.equality, MiniTest.new_set
local T = new_set()

local child = h.new_child_neovim()

T = new_set({
    hooks = {
        pre_once = function()
            child.setup()
            -- Setup logging once for all tests
            child.lua([[
                local log = require("codecompanion._extensions.history.log")
                log.setup_logging(false) -- Disable logging for tests
            ]])
        end,
        post_once = child.stop,
    },
})

-- Picker Resolution Tests
T["Picker Resolution"] = new_set()

T["Picker Resolution"]["should auto-resolve to valid picker"] = function()
    local result = child.lua([[
        local pickers = require("codecompanion._extensions.history.pickers")
        local resolved = pickers.history
        local valid_options = { "telescope", "fzf-lua", "snacks", "default" }
        return {
            resolved_picker = resolved,
            is_valid = vim.tbl_contains(valid_options, resolved),
            is_string = type(resolved) == "string"
        }
    ]])

    eq(true, result.is_valid)
    eq(true, result.is_string)
end

T["Picker Resolution"]["should use resolved picker in history init"] = function()
    local result = child.lua([[
        -- Test that history extension uses the auto-resolved picker
        local History = require("codecompanion._extensions.history").History
        local pickers = require("codecompanion._extensions.history.pickers")
        
        -- Create history instance (simulating extension setup)
        local opts = {
            picker = pickers.history, -- This should be auto-resolved
            dir_to_save = vim.fn.stdpath("data") .. "/test-history",
            enable_logging = false,
            summary = {}
        }
        
        local history = History.new(opts)
        
        return {
            picker_from_init = pickers.history,
            picker_from_history = history.opts.picker,
            pickers_match = pickers.history == history.opts.picker
        }
    ]])

    eq(true, result.pickers_match)
    eq("string", type(result.picker_from_init))
end

-- Picker Instance Tests
T["Picker Instances"] = new_set()

T["Picker Instances"]["keeps config on the instance, not the class"] = function()
    -- Two pickers must not share state, and the class must not retain the item
    -- list after a picker is discarded
    local result = child.lua([[
        local DefaultPicker = require("codecompanion._extensions.history.pickers.default")

        local first = DefaultPicker:new({
            item_type = "chat",
            items = { { save_id = "1", title = "First" } },
            handlers = {},
            keymaps = {},
            title = "First Picker",
        })
        local second = DefaultPicker:new({
            item_type = "summary",
            items = { { summary_id = "2", chat_title = "Second" } },
            handlers = {},
            keymaps = {},
            title = "Second Picker",
        })

        return {
            first_title = first.config.title,
            second_title = second.config.title,
            first_item_type = first.config.item_type,
            second_item_type = second.config.item_type,
            class_has_config = rawget(DefaultPicker, "config") ~= nil,
            configs_differ = first.config ~= second.config,
        }
    ]])

    eq("First Picker", result.first_title)
    eq("Second Picker", result.second_title)
    eq("chat", result.first_item_type)
    eq("summary", result.second_item_type)
    eq(true, result.configs_differ)
    eq(false, result.class_has_config)
end

T["Picker Instances"]["subclasses inherit shared formatting helpers"] = function()
    local result = child.lua([[
        local TelescopePicker = require("codecompanion._extensions.history.pickers.telescope")

        local picker = TelescopePicker:new({
            item_type = "chat",
            items = {},
            handlers = {},
            keymaps = {},
            title = "Telescope",
        })

        return {
            id = picker:get_item_id({ save_id = "42" }),
            title = picker:get_item_title({ title = "Some Chat" }),
            singular = picker:get_item_name_singular(),
            class_has_config = rawget(TelescopePicker, "config") ~= nil,
        }
    ]])

    eq("42", result.id)
    eq("Some Chat", result.title)
    eq("chat", result.singular)
    eq(false, result.class_has_config)
end

return T
