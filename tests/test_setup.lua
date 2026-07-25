local h = require("tests.helpers")
local eq, new_set = MiniTest.expect.equality, MiniTest.new_set
local T = new_set()
local child = h.new_child_neovim()

T = new_set({
    hooks = {
        pre_case = function()
            child.setup()
            child.lua([[
              h = require('tests.helpers')
              cc_h = require('tests.cc_helpers')
              codecompanion = cc_h.setup_plugin({
                extensions = {
                  history = {
                    enabled = true,
                    opts = {
                      keymap = "gh",
                      auto_generate_title = true,
                      continue_last_chat = false,
                      delete_on_clearing_chat = false,
                      picker = "default", -- Use default picker to avoid telescope dependency
                      enable_logging = true,
                      dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-test",
                    }
                  }
                }
              })
            ]])
        end,
        post_case = function() end,

        post_once = child.stop,
    },
})

-- Test the History module initialization
T["History module"] = new_set()

T["History module"]["should be loaded"] = function()
    local history_exists = child.lua_get([[
      package.loaded["codecompanion._extensions.history"] ~= nil
  ]])
    eq(true, history_exists)
end

T["History module"]["available in codecompanion"] = function()
    local has_property = child.lua_get([[
      codecompanion.extensions.history ~= nil
    ]])
    eq(true, has_property)
end

T["History module"]["should register :CodeCompanionHistory command"] = function()
    local has_command = child.lua_get([[
      vim.fn.exists(":CodeCompanionHistory") == 2
    ]])
    eq(true, has_command)
end

T["History module"]["should register keymap"] = function()
    local has_keymap = child.lua([[
      local keymap = require("codecompanion.config").interactions.chat.keymaps["Saved Chats"]
      return keymap and keymap.modes.n == "gh"
    ]])
    eq(true, has_keymap)
end

-- Repeat setup (e.g. a config reload) must not throw or duplicate handlers
T["Repeat setup"] = new_set()

T["Repeat setup"]["tolerates being called again with sparse opts"] = function()
    local result = child.lua([[
        -- The memory branch is only reached when the VectorCode CLI is present
        local vectorcode = require("codecompanion._extensions.history.vectorcode")
        vectorcode.has_vectorcode = function()
            return true
        end

        local extension = require("codecompanion._extensions.history")

        -- Second call supplies no `memory` key at all, which used to be indexed directly
        local ok_sparse, err_sparse = pcall(extension.setup, {
            dir_to_save = vim.fn.stdpath("data") .. "/codecompanion-history-test",
        })
        -- And a third with no opts whatsoever
        local ok_empty, err_empty = pcall(extension.setup)

        local autocmds = vim.api.nvim_get_autocmds({
            event = "User",
            pattern = "CodeCompanionHistorySummarySaved",
        })

        return {
            ok_sparse = ok_sparse,
            err_sparse = tostring(err_sparse),
            ok_empty = ok_empty,
            err_empty = tostring(err_empty),
            summary_autocmd_count = #autocmds,
        }
    ]])

    eq(true, result.ok_sparse)
    eq(true, result.ok_empty)
    -- Repeat calls must not stack duplicate summary handlers
    eq(1, result.summary_autocmd_count)
end

return T
