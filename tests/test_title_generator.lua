-- Test file for the title generator module
---@brief [[
--- Tests for title generator functionality
---
--- This test suite verifies the functionality of the title generator module in the
--- CodeCompanion history extension. It tests:
---
--- 1. Basic Title Generation:
---    - Generation from user messages
---    - Title formatting and validation
---    - Empty message handling
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
                -- Setup logging first
                local log = require("codecompanion._extensions.history.log")
                log.setup_logging(false) -- Disable logging for tests

                h = require("tests.helpers")
                
                -- Create title generator instance with mocked adapter request
                local TitleGenerator = require("codecompanion._extensions.history.title_generator")
                test_title_gen = TitleGenerator.new({
                    auto_generate_title = true,
                    default_buf_title = "[CodeCompanion]"
                })

                -- Mock the _make_adapter_request method
                TitleGenerator._make_adapter_request = function(self, chat, prompt, callback)
                    -- Store the prompt for verification
                    self.last_prompt = prompt
                    
                    -- Clear previous stored values
                    self.last_title = nil

                    -- Simulate async response
                    vim.schedule(function()
                        self.last_title = "Generated Title"
                        callback(self.last_title)
                    end)
                end
            ]])
        end,
        post_case = function() end,
        post_once = child.stop,
    },
})

-- Basic Title Generation Tests
T["Title Generation"] = new_set()

T["Title Generation"]["generates title from user message"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false
        local generated_title = nil

        -- Mock chat with simple user message
        local chat = {
            opts = {},
            messages = {
                {
                    role = "user",
                    content = "How do I create a new file in Vim?"
                }
            }
        }
        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, title)
            if title ~= "Deciding title..." then
                completed = true
            end
        end)

        -- Wait for completion
        vim.wait(1000, function() return completed end)


        local final_prompt = test_title_gen.last_prompt or ""
        return {
            first_title = title_sequence[1],
            final_title = title_sequence[#title_sequence],
            completed = completed,
            has_example = final_prompt:find("Capital of France") ~= nil,
            has_query = final_prompt:find("How do I create a new file in Vim?") ~= nil,
            prompt_empty = final_prompt == ""
        }
    ]])

    eq("Deciding title...", result.first_title)
    eq("Generated Title", result.final_title)
    eq(true, result.completed)
    eq(true, result.has_example) -- Verify prompt includes examples
end

T["Title Generation"]["handles empty user message"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with empty message
        local chat = {
            opts = {},
            messages = {
                {
                    role = "user",
                    content = ""
                }
            }
        }

        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, tostring(title))
            completed = true
        end)

        -- Wait for completion
        vim.wait(100, function() return completed end)

        return {
            first_title = title_sequence[1],
            completed = completed,
            prompt_called = test_title_gen.last_prompt ~= nil
        }
    ]])

    eq("nil", result.first_title) -- Should return nil immediately for empty messages
    eq(true, result.completed)
    eq(false, result.prompt_called) -- Should not even call the adapter
end

T["Title Generation"]["filters out system messages"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with system and user messages
        local chat = {
            opts = {},
            messages = {
                {
                    role = "system",
                    content = "System prompt",
                    opts = { visible = false }
                },
                {
                    role = "user",
                    content = "Actual user message"
                },
                {
                    role = "system",
                    content = "Another system message",
                    opts = { visible = false }
                }
            }
        }

        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, title)
            if title ~= "Deciding title..." then
                completed = true
            end
        end)

        -- Wait for completion
        vim.wait(1000, function() return completed end)

        return {
            first_title = title_sequence[1],
            final_title = title_sequence[#title_sequence],
            completed = completed,
            has_system_message = (test_title_gen.last_prompt or ""):find("System prompt") ~= nil,
            has_user_message = (test_title_gen.last_prompt or ""):find("Actual user message") ~= nil
        }
    ]])

    eq(true, result.completed)
    eq("Deciding title...", result.first_title)
    eq("Generated Title", result.final_title)
    eq(false, result.has_system_message)
    eq(true, result.has_user_message)
end

-- Configuration Tests
T["Configuration"] = new_set()

T["Configuration"]["respects auto_generate_title=false"] = function()
    local result = child.lua([[              
        -- Create title generator with auto-generate disabled
        local TitleGenerator = require("codecompanion._extensions.history.title_generator")
        local no_auto_gen = TitleGenerator.new({
            auto_generate_title = false,
            default_buf_title = "[CodeCompanion]"
        })

        local completed = false
        
        -- Mock chat with user message
        local chat = {
            opts = {},
            messages = {
                {
                    role = "user",
                    content = "Test message"
                }
            }
        }

        -- Try to generate title
        no_auto_gen:generate(chat, function(title)
            completed = true
        end)

        -- Wait briefly
        vim.wait(100)

        return {
            completed = completed,
            prompt_called = no_auto_gen.last_prompt ~= nil
        }
    ]])

    eq(false, result.completed) -- Should not complete
    eq(false, result.prompt_called) -- Should not make request
end

T["Configuration"]["respects existing chat.opts.title"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with existing title
        local chat = {
            opts = {
                title = "Existing Title"
            },
            messages = {
                {
                    role = "user",
                    content = "This should be ignored"
                }
            }
        }

        -- Try to generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, title)
            completed = true
        end)

        vim.wait(100)

        return {
            title = title_sequence[1],
            completed = completed,
            prompt_called = test_title_gen.last_prompt ~= nil
        }
    ]])

    eq("Existing Title", result.title)
    eq(true, result.completed)
    eq(false, result.prompt_called) -- Should not try to generate new title
end

-- Content Handling Tests
T["Content Handling"] = new_set()

T["Content Handling"]["handles multiple user messages"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with multiple user messages
        local chat = {
            opts = {},
            messages = {
                {
                    role = "user",
                    content = "First message"
                },
                {
                    role = "llm",
                    content = "Some response"
                },
                {
                    role = "user",
                    content = "Second message"
                }
            }
        }

        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, title)
            if title ~= "Deciding title..." then
                completed = true
            end
        end)

        vim.wait(1000, function() return completed end)

        return {
            first_title = title_sequence[1],
            final_title = title_sequence[#title_sequence],
            prompt = test_title_gen.last_prompt or "",
            completed = completed
        }
    ]])

    eq("Deciding title...", result.first_title)
    eq("Generated Title", result.final_title)
    eq(true, result.completed)
    eq(true, result.prompt:find("First message") ~= nil) -- Should use first user message
end

T["Content Handling"]["truncates long messages"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with very long message
        local chat = {
            opts = {},
            messages = {
                {
                    role = "user",
                    content = string.rep("This is a very long message. ", 100)
                }
            }
        }

        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, title)
            if title ~= "Deciding title..." then
                completed = true
            end
        end)

        vim.wait(1000, function() return completed end)

        return {
            first_title = title_sequence[1],
            final_title = title_sequence[#title_sequence],
            prompt_length = #(test_title_gen.last_prompt or ""),
            has_ellipsis = (test_title_gen.last_prompt or ""):find("...") ~= nil,
            completed = completed
        }
    ]])

    eq("Deciding title...", result.first_title)
    eq("Generated Title", result.final_title)
    eq(true, result.completed)
    eq(true, result.prompt_length <= 2000) -- Ensure prompt is truncated
    eq(true, result.has_ellipsis) -- Should have ellipsis for truncated content
end

T["Content Handling"]["handles messages with special characters"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with special characters
        local chat = {
            opts = {},
            messages = {
                {
                    role = "user",
                    content = "Test with special chars: !@#$%^&*()_+-=[]{}\\|;:'\",./<>?"
                }
            }
        }

        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, title)
            if title ~= "Deciding title..." then
                completed = true
            end
        end)

        vim.wait(1000, function() return completed end)

        return {
            first_title = title_sequence[1],
            final_title = title_sequence[#title_sequence],
            prompt = test_title_gen.last_prompt or "",
            completed = completed
        }
    ]])

    eq("Deciding title...", result.first_title)
    eq("Generated Title", result.final_title)
    eq(true, result.completed)
    eq(true, result.prompt:find("special chars") ~= nil) -- Ensure special chars are included in prompt
end

T["Content Handling"]["filters out tagged user messages"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with tagged and non-tagged user messages
        local chat = {
            opts = {},
            messages = {
                {
                    role = "user",
                    content = "Tagged message to ignore",
                    opts = { tag = "some_tag" }
                },
                {
                    role = "user",
                    content = "Referenced message to ignore",
                    opts = { reference = true }
                },
                {
                    role = "user",
                    content = "Regular user message to use"
                },
                {
                    role = "user",
                    content = "Another regular message"
                }
            }
        }

        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, title)
            if title ~= "Deciding title..." then
                completed = true
            end
        end)

        vim.wait(1000, function() return completed end)

        return {
            first_title = title_sequence[1],
            final_title = title_sequence[#title_sequence],
            prompt = test_title_gen.last_prompt or "",
            completed = completed
        }
    ]])

    eq("Deciding title...", result.first_title)
    eq("Generated Title", result.final_title)
    eq(true, result.completed)
    eq(true, result.prompt:find("Regular user message to use") ~= nil) -- Should use first non-tagged message
    eq(false, result.prompt:find("Tagged message to ignore") ~= nil) -- Should not include tagged message
    eq(false, result.prompt:find("Referenced message to ignore") ~= nil) -- Should not include referenced message
end

T["Content Handling"]["filters out context messages with _meta.tag and context.id"] = function()
    local result = child.lua([[
        local title_sequence = {}
        local completed = false

        -- Replicate the message structure CodeCompanion creates with add_context()
        -- _meta.tag and context.id are stripped from opts by add_message() and moved
        -- to their own top-level fields.
        local chat = {
            opts = {},
            messages = {
                {
                    role = "user",
                    content = "This is CLAUDE.md rules content that should be ignored for title generation",
                    _meta = { tag = "rules" },
                    context = { id = "<rules>CLAUDE.md</rules>" },
                    opts = { visible = false },
                },
                {
                    role = "user",
                    content = "Do you like basketball?"
                }
            }
        }

        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, title)
            if title ~= "Deciding title..." then
                completed = true
            end
        end)

        vim.wait(1000, function() return completed end)

        local prompt = test_title_gen.last_prompt or ""
        return {
            first_title = title_sequence[1],
            final_title = title_sequence[#title_sequence],
            completed = completed,
            has_context = prompt:find("CLAUDE.md rules content") ~= nil,
            has_question = prompt:find("Do you like basketball") ~= nil,
        }
    ]])

    eq("Deciding title...", result.first_title)
    eq("Generated Title", result.final_title)
    eq(true, result.completed)
    eq(false, result.has_context) -- context message must be excluded
    eq(true, result.has_question) -- actual question must be used
end

-- ACP Adapter Tests
T["ACP Adapter"] = new_set()

T["ACP Adapter"]["skips title generation silently when chat adapter is ACP"] = function()
    local result = child.lua([[
        local TitleGenerator = require("codecompanion._extensions.history.title_generator")
        local acp_gen = TitleGenerator.new({ auto_generate_title = true })

        local adapter_request_called = false
        acp_gen._make_adapter_request = function(self, chat, prompt, callback)
            adapter_request_called = true
            callback("Should not reach here")
        end

        local chat = {
            opts = {},
            adapter = { type = "acp" },
            messages = {
                { role = "user", content = "Hello" }
            }
        }

        local titles = {}
        local completed = false
        acp_gen:generate(chat, function(title)
            table.insert(titles, tostring(title))
            completed = true
        end)

        vim.wait(500, function() return completed end)

        return {
            adapter_request_called = adapter_request_called,
            title_count = #titles,
            final_title = titles[1],
        }
    ]])

    eq(false, result.adapter_request_called) -- _make_adapter_request must not be called
    eq(1, result.title_count) -- exactly one callback (nil, no feedback flash)
    eq("nil", result.final_title)
end

T["ACP Adapter"]["returns error when title_generation_opts.adapter is explicitly ACP"] = function()
    local result = child.lua([[
        local TitleGenerator = require("codecompanion._extensions.history.title_generator")
        local adapters = require("codecompanion.adapters")

        -- Stub adapters.resolve to return an ACP adapter
        local orig_resolve = adapters.resolve
        adapters.resolve = function(name)
            return { type = "acp" }
        end

        local acp_gen = TitleGenerator.new({
            auto_generate_title = true,
            title_generation_opts = { adapter = "some-acp-adapter" },
        })

        local chat = {
            opts = {},
            adapter = { type = "acp" },
            messages = {
                { role = "user", content = "Hello" }
            }
        }

        local got_error = nil
        local got_title = "unset"
        acp_gen:generate(chat, function(title, err)
            got_title = tostring(title)
            got_error = err
        end)

        adapters.resolve = orig_resolve

        return {
            got_title = got_title,
            has_error = got_error ~= nil,
        }
    ]])

    eq("nil", result.got_title)
    eq(true, result.has_error)
end

-- Error Handling Tests
T["Error Handling"] = new_set()

T["Error Handling"]["handles adapter request errors"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Create title generator with error-producing adapter request
        local TitleGenerator = require("codecompanion._extensions.history.title_generator")
        local error_gen = TitleGenerator.new({
            auto_generate_title = true
        })

        -- Mock error in _make_adapter_request
        error_gen._make_adapter_request = function(self, chat, prompt, callback)
            callback(nil) -- Simulate error response
        end

        local chat = {
            opts = {},
            messages = {
                {
                    role = "user",
                    content = "Test message"
                }
            }
        }

        -- Try to generate title
        error_gen:generate(chat, function(title)
            table.insert(title_sequence, tostring(title))
            if title ~= "Deciding title..." then
                completed = true
            end
        end)

        vim.wait(1000, function() return completed end)

        return {
            first_title = title_sequence[1],
            final_title = title_sequence[2] or nil,
            completed = completed
        }
    ]])

    eq("Deciding title...", result.first_title)
    eq("nil", result.final_title) -- Should return nil on error
end

-- Edge Cases Tests
T["Edge Cases"] = new_set()

T["Edge Cases"]["handles nil messages table"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with nil messages
        local chat = {
            opts = {}
            -- messages field intentionally omitted
        }

        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, tostring(title))
            completed = true
        end)

        vim.wait(100)

        return {
            completed = completed,
            first_title = title_sequence[1]
        }
    ]])

    eq(true, result.completed)
    eq("nil", result.first_title) -- Should return nil immediately for nil messages
end

T["Edge Cases"]["handles chat with no user messages"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with only system and llm messages
        local chat = {
            opts = {},
            messages = {
                {
                    role = "system",
                    content = "System message"
                },
                {
                    role = "llm",
                    content = "LLM response"
                }
            }
        }

        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, tostring(title))
            completed = true
        end)

        vim.wait(100)

        return {
            completed = completed,
            first_title = title_sequence[1],
            prompt_called = test_title_gen.last_prompt ~= nil
        }
    ]])

    eq(true, result.completed)
    eq("Deciding title...", result.first_title) -- Should return nil immediately for no user messages
    eq(false, result.prompt_called)
end

T["Edge Cases"]["handles nil message content"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock chat with nil content in message
        local chat = {
            opts = {},
            messages = {
                {
                    role = "user"
                    -- content field intentionally omitted
                }
            }
        }

        -- Generate title
        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, tostring(title))
            completed = true
        end)

        vim.wait(100)

        return {
            completed = completed,
            first_title = title_sequence[1],
            prompt_called = test_title_gen.last_prompt ~= nil
        }
    ]])

    eq(true, result.completed)
    eq("nil", result.first_title) -- Should return nil immediately for nil content
    eq(false, result.prompt_called)
end

-- Title Refresh Tests
T["Title Refresh"] = new_set()

T["Title Refresh"]["should_generate returns false when auto_generate_title disabled"] = function()
    local result = child.lua([[              
        local TitleGenerator = require("codecompanion._extensions.history.title_generator")
        local disabled_gen = TitleGenerator.new({
            auto_generate_title = false
        })

        local chat = {
            opts = {},
            messages = {
                { role = "user", content = "Test message" }
            }
        }

        local should_generate, is_refresh = disabled_gen:should_generate(chat)
        return { should_generate = should_generate, is_refresh = is_refresh }
    ]])

    eq(false, result.should_generate)
    eq(false, result.is_refresh)
end

T["Title Refresh"]["should_generate returns true for new chat without title"] = function()
    local result = child.lua([[              
        local chat = {
            opts = {},
            messages = {
                { role = "user", content = "Test message" }
            }
        }

        local should_generate, is_refresh = test_title_gen:should_generate(chat)
        return { should_generate = should_generate, is_refresh = is_refresh }
    ]])

    eq(true, result.should_generate)
    eq(false, result.is_refresh)
end

T["Title Refresh"]["should_generate returns false for existing title without refresh config"] = function()
    local result = child.lua([[              
        local chat = {
            opts = { title = "Existing Title" },
            messages = {
                { role = "user", content = "Test message" }
            }
        }

        local should_generate, is_refresh = test_title_gen:should_generate(chat)
        return { should_generate = should_generate, is_refresh = is_refresh }
    ]])

    eq(false, result.should_generate)
    eq(false, result.is_refresh)
end

T["Title Refresh"]["should_generate returns true when refresh conditions met"] = function()
    local result = child.lua([[              
        local TitleGenerator = require("codecompanion._extensions.history.title_generator")
        local refresh_gen = TitleGenerator.new({
            auto_generate_title = true,
            title_generation_opts = {
                refresh_every_n_prompts = 3,
                max_refreshes = 2
            }
        })

        local chat = {
            opts = { 
                title = "Existing Title",
                title_refresh_count = 0
            },
            messages = {
                { role = "user", content = "Message 1" },
                { role = "llm", content = "Response 1" },
                { role = "user", content = "Message 2" },
                { role = "llm", content = "Response 2" },
                { role = "user", content = "Message 3" } -- This is the 3rd user message
            }
        }

        local should_generate, is_refresh = refresh_gen:should_generate(chat)
        return { should_generate = should_generate, is_refresh = is_refresh }
    ]])

    eq(true, result.should_generate)
    eq(true, result.is_refresh)
end

T["Title Refresh"]["should_generate returns false when max refreshes reached"] = function()
    local result = child.lua([[              
        local TitleGenerator = require("codecompanion._extensions.history.title_generator")
        local refresh_gen = TitleGenerator.new({
            auto_generate_title = true,
            title_generation_opts = {
                refresh_every_n_prompts = 3,
                max_refreshes = 2
            }
        })

        local chat = {
            opts = { 
                title = "Existing Title",
                title_refresh_count = 2 -- Already at max
            },
            messages = {
                { role = "user", content = "Message 1" },
                { role = "user", content = "Message 2" },
                { role = "user", content = "Message 3" }
            }
        }

        local should_generate, is_refresh = refresh_gen:should_generate(chat)
        return { should_generate = should_generate, is_refresh = is_refresh }
    ]])

    eq(false, result.should_generate)
    eq(false, result.is_refresh)
end

T["Title Refresh"]["_count_user_messages counts only non-tagged messages with content"] = function()
    local result = child.lua([[              
        local chat = {
            opts = {},
            messages = {
                { role = "user", content = "Valid message 1" },
                { role = "user", content = "Valid message 2" },
                { role = "user", content = "", opts = {} }, -- Empty content
                { role = "user", content = "Tagged message", opts = { tag = "system" } }, -- Tagged
                { role = "user", content = "Reference message", opts = { reference = true } }, -- Reference
                { role = "llm", content = "Assistant response" }, -- Not user
                { role = "user", content = "Valid message 3" }
            }
        }

        local count = test_title_gen:_count_user_messages(chat)
        return { count = count }
    ]])

    eq(3, result.count) -- Only the 3 valid user messages
end

T["Title Refresh"]["generate shows different feedback for refresh vs initial"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Test refresh feedback
        local chat_refresh = {
            opts = { title = "Existing" },
            messages = {
                { role = "user", content = "Test message" },
                { role = "llm", content = "Response" }
            }
        }

        test_title_gen:generate(chat_refresh, function(title)
            table.insert(title_sequence, title)
            if title ~= "Refreshing title..." then
                completed = true
            end
        end, true) -- is_refresh = true

        vim.wait(1000, function() return completed end)

        local refresh_feedback = title_sequence[1]

        -- Reset for initial generation test
        title_sequence = {}
        completed = false

        local chat_initial = {
            opts = {},
            messages = {
                { role = "user", content = "Test message" }
            }
        }

        test_title_gen:generate(chat_initial, function(title)
            table.insert(title_sequence, title)
            if title ~= "Deciding title..." then
                completed = true
            end
        end, false) -- is_refresh = false

        vim.wait(1000, function() return completed end)

        local initial_feedback = title_sequence[1]

        return {
            refresh_feedback = refresh_feedback,
            initial_feedback = initial_feedback
        }
    ]])

    eq("Refreshing title...", result.refresh_feedback)
    eq("Deciding title...", result.initial_feedback)
end

T["Title Refresh"]["refresh uses recent conversation context"] = function()
    local result = child.lua([[              
        local title_sequence = {}
        local completed = false

        -- Mock with recent conversation context
        local chat = {
            opts = { title = "Old Title" },
            messages = {
                { role = "user", content = "Old message 1" },
                { role = "llm", content = "Old response 1" },
                { role = "user", content = "Old message 2" },
                { role = "llm", content = "Old response 2" },
                { role = "user", content = "Recent message 1" },
                { role = "llm", content = "Recent response 1" },
                { role = "user", content = "Recent message 2" },
                { role = "llm", content = "Recent response 2" }
            }
        }

        test_title_gen:generate(chat, function(title)
            table.insert(title_sequence, title)
            if title ~= "Refreshing title..." then
                completed = true
            end
        end, true) -- is_refresh = true

        vim.wait(1000, function() return completed end)

        local prompt = test_title_gen.last_prompt or ""
        
        return {
            has_original_title = prompt:find("Old Title") ~= nil,
            has_recent_context = prompt:find("Recent message") ~= nil,
            has_old_context = prompt:find("Old message 1") ~= nil,
            completed = completed
        }
    ]])

    eq(true, result.has_original_title) -- Should include original title
    eq(true, result.has_recent_context) -- Should include recent messages
    eq(false, result.has_old_context) -- Should not include very old messages
    eq(true, result.completed)
end

-- Adapter request tests
--
-- The other groups stub `_make_adapter_request` wholesale; these exercise the real
-- method against a stubbed HTTP client, since that is where the terminal-callback
-- and double-invocation handling lives.
T["Adapter Request"] = new_set()

---Build the child-side scaffolding: a stubbed `codecompanion.http` whose request
---replays `invocations`, plus a freshly required (unmocked) TitleGenerator.
---@param invocations string Lua source for a list of {err, data} pairs to replay
---@return string
local function adapter_request_harness(invocations)
    return string.format(
        [[
        local fake_adapter = {
            name = "fake",
            type = "http",
            handlers = {
                chat_output = function(_, data)
                    return data and data.parsed or nil
                end,
            },
            map_schema_to_params = function()
                return { opts = {} }
            end,
            map_roles = function(_, messages)
                return messages
            end,
        }

        local invocations = %s

        -- Stub the client before requiring the generator, which captures it at load time
        package.loaded["codecompanion.http"] = {
            new = function()
                return {
                    request = function(_, _, actions)
                        for _, invocation in ipairs(invocations) do
                            actions.callback(invocation.err, invocation.data, fake_adapter)
                        end
                    end,
                }
            end,
        }
        package.loaded["codecompanion._extensions.history.title_generator"] = nil
        local TitleGenerator = require("codecompanion._extensions.history.title_generator")

        local generator = TitleGenerator.new({ auto_generate_title = true })
        local chat = {
            opts = { save_id = "1" },
            settings = { model = "test-model" },
            adapter = fake_adapter,
        }

        local calls = {}
        generator:_make_adapter_request(chat, "Some prompt", function(title, error_msg)
            table.insert(calls, { title = title or "<nil>", error_msg = error_msg or "<nil>" })
        end)

        return calls
    ]],
        invocations
    )
end

T["Adapter Request"]["resolves the callback when the response has no usable status"] = function()
    -- Otherwise the buffer stays stuck on the "Deciding title..." feedback forever
    local calls = child.lua(adapter_request_harness([[{ { err = nil, data = { parsed = nil } } }]]))

    eq(1, #calls)
    eq("<nil>", calls[1].title)
    eq("<nil>", calls[1].error_msg)
end

T["Adapter Request"]["resolves the callback when the response is empty"] = function()
    local calls = child.lua(adapter_request_harness([[{ { err = nil, data = nil } }]]))

    eq(1, #calls)
    eq("<nil>", calls[1].title)
end

T["Adapter Request"]["returns the generated title on success"] = function()
    local calls = child.lua(adapter_request_harness([[
        { { err = nil, data = { parsed = { status = "success", output = { content = "  My Title  " } } } } }
    ]]))

    eq(1, #calls)
    eq("My Title", calls[1].title)
end

T["Adapter Request"]["unwraps table content in a successful response"] = function()
    local calls = child.lua(adapter_request_harness([[
        { { err = nil, data = { parsed = { status = "success", output = { content = { content = "Nested" } } } } } }
    ]]))

    eq(1, #calls)
    eq("Nested", calls[1].title)
end

T["Adapter Request"]["calls back once when the client reports an error after data"] = function()
    -- On HTTP errors the client fires its callback twice: once with the body as
    -- `data`, then again with `err` set. The caller must only see one result.
    local calls = child.lua(adapter_request_harness([[
        {
            { err = nil, data = { parsed = { status = "success", output = { content = "My Title" } } } },
            { err = { message = "500 error", stderr = { status = 500, body = "server exploded" } }, data = nil },
        }
    ]]))

    eq(1, #calls)
    eq("My Title", calls[1].title)
end

T["Adapter Request"]["handles a response table as the error payload"] = function()
    -- Regression: this payload used to be concatenated into a notify message,
    -- which raised "attempt to concatenate a table value"
    local calls = child.lua(adapter_request_harness([[
        {
            {
                err = { message = "429 error", stderr = { status = 429, body = '{"error":"rate limited"}' } },
                data = nil,
            },
        }
    ]]))

    eq(1, #calls)
    eq("<nil>", calls[1].title)
end

T["Adapter Request"]["ignores the empty stderr sentinel"] = function()
    -- `stderr == "{}"` means "no error"; the response should still be parsed
    local calls = child.lua(adapter_request_harness([[
        {
            {
                err = { stderr = "{}" },
                data = { parsed = { status = "success", output = { content = "Parsed Anyway" } } },
            },
        }
    ]]))

    eq(1, #calls)
    eq("Parsed Anyway", calls[1].title)
end

T["Adapter Request"]["reports a string stderr from a streaming failure"] = function()
    local calls = child.lua(adapter_request_harness([[
        { { err = { stderr = "connection reset" }, data = nil } }
    ]]))

    eq(1, #calls)
    eq("<nil>", calls[1].title)
end

return T
