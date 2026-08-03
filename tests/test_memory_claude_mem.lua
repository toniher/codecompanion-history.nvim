local h = require("tests.helpers")
local eq, new_set = MiniTest.expect.equality, MiniTest.new_set
local T = new_set()

local child = h.new_child_neovim()

local function read_stub(name)
    local Path = require("plenary.path")
    return Path:new("tests/stubs/" .. name):read()
end

T = new_set({
    hooks = {
        pre_case = function()
            child.setup()
            child.lua([[
                local log = require("codecompanion._extensions.history.log")
                log.setup_logging(false)
                claude_mem = require("codecompanion._extensions.history.memory.claude_mem")
            ]])
        end,
        post_case = function() end,
        post_once = child.stop,
    },
})

T["setup()"] = new_set()

T["setup()"]["resolves explicit host/port/data_dir over env and defaults"] = function()
    local result = child.lua([[
        claude_mem.setup({
            notify = false,
            claude_mem = {
                host = "example.test",
                port = 12345,
                data_dir = "/tmp/does-not-exist-claude-mem",
            },
        })
        return {
            host = claude_mem.opts.host,
            port = claude_mem.opts.port,
            data_dir = claude_mem.opts.data_dir,
        }
    ]])
    eq("example.test", result.host)
    eq(12345, result.port)
    eq("/tmp/does-not-exist-claude-mem", result.data_dir)
end

T["setup()"]["falls back to defaults when nothing is configured"] = function()
    local result = child.lua([[
        claude_mem.setup({})
        return {
            host = claude_mem.opts.host,
            port = claude_mem.opts.port,
            search = claude_mem.opts.search,
            inject_context_on_new_chat = claude_mem.opts.inject_context_on_new_chat,
        }
    ]])
    eq("127.0.0.1", result.host)
    eq(37700, result.port)
    eq("keyword", result.search)
    eq(false, result.inject_context_on_new_chat)
end

T["is_available()"] = new_set()

T["is_available()"]["true when data_dir/claude-mem.db exists"] = function()
    local result = child.lua([[
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local db = dir .. "/claude-mem.db"
        io.open(db, "w"):close()
        claude_mem.setup({ claude_mem = { data_dir = dir } })
        return claude_mem.is_available()
    ]])
    eq(true, result)
end

T["is_available()"]["false when data_dir/claude-mem.db is missing"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp/definitely-missing-claude-mem-dir" } })
        return claude_mem.is_available()
    ]])
    eq(false, result)
end

T["memory tool"] = new_set()

T["memory tool"]["search mode calls _request with query/limit/project and returns rendered markdown"] = function()
    local search_stub = read_stub("claude_mem_search.json")
    local result = child.lua(
        [[
        local search_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })

        local captured
        claude_mem._request = function(method, path, opts, cb)
            captured = { method = method, path = path, opts = opts }
            cb({ ok = true, data = vim.json.decode(search_stub) })
        end

        local tool = claude_mem.make_memory_tool({ default_num = 10 })
        local msg
        tool.cmds[1](nil, { keywords = { "history", "refactor" } }, {
            output_cb = function(m)
                msg = m
            end,
        })
        vim.wait(200, function()
            return msg ~= nil
        end)

        local outputs = {}
        local fake_chat = {
            add_tool_output = function(_, tool_self, content, user_message)
                table.insert(outputs, { content = content, user_message = user_message })
            end,
        }
        tool.output.success(tool, { chat = fake_chat }, nil, { msg.data })

        return {
            method = captured.method,
            path = captured.path,
            query = captured.opts.query,
            status = msg.status,
            mode = msg.data.mode,
            output_count = #outputs,
            output_contains = outputs[1] and outputs[1].content:find("Refactored history extension") ~= nil,
        }
    ]],
        { search_stub }
    )

    eq("GET", result.method)
    eq("/api/search/observations", result.path)
    eq("history refactor", result.query.query)
    eq(10, result.query.limit)
    eq("success", result.status)
    eq("search", result.mode)
    eq(1, result.output_count)
    eq(true, result.output_contains)
end

T["memory tool"]["rejects a call with no keywords and no ids"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })
        local tool = claude_mem.make_memory_tool({ default_num = 10 })
        local msg
        tool.cmds[1](nil, {}, {
            output_cb = function(m)
                msg = m
            end,
        })
        vim.wait(200, function()
            return msg ~= nil
        end)
        return msg
    ]])
    eq("error", result.status)
end

T["memory tool"]["ids mode unfolds observations"] = function()
    local observations_stub = read_stub("claude_mem_observations.json")
    local result = child.lua(
        [[
        local observations_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })

        local captured
        claude_mem._request = function(method, path, opts, cb)
            captured = { method = method, path = path, opts = opts }
            cb({ ok = true, data = vim.json.decode(observations_stub) })
        end

        local tool = claude_mem.make_memory_tool({ default_num = 10 })
        local msg
        tool.cmds[1](nil, { ids = { 42 } }, {
            output_cb = function(m)
                msg = m
            end,
        })
        vim.wait(200, function()
            return msg ~= nil
        end)

        local outputs = {}
        local fake_chat = {
            add_tool_output = function(_, tool_self, content, user_message)
                table.insert(outputs, { content = content, user_message = user_message })
            end,
        }
        tool.output.success(tool, { chat = fake_chat }, nil, { msg.data })

        return {
            path = captured.path,
            ids_query = captured.opts.query.ids,
            mode = msg.data.mode,
            output_contains = outputs[1] and outputs[1].content:find("Split init.lua") ~= nil,
        }
    ]],
        { observations_stub }
    )

    eq("/api/observations", result.path)
    eq("42", result.ids_query)
    eq("unfold", result.mode)
    eq(true, result.output_contains)
end

T["memory tool"]["surfaces a friendly error when the worker is unreachable"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", host = "127.0.0.1", port = 1 } })
        claude_mem._request = function(method, path, opts, cb)
            cb({ ok = false, error = "claude-mem worker not reachable at 127.0.0.1:1 — start Claude Code or the claude-mem worker" })
        end

        local tool = claude_mem.make_memory_tool({ default_num = 10 })
        local msg
        tool.cmds[1](nil, { keywords = { "x" } }, {
            output_cb = function(m)
                msg = m
            end,
        })
        vim.wait(200, function()
            return msg ~= nil
        end)
        return msg
    ]])
    eq("error", result.status)
    eq(true, result.data:find("not reachable") ~= nil)
end

T["index()"] = new_set()

T["index()"]["saves a single summary via POST /api/memory/save with the right project key and metadata"] = function()
    local save_stub = read_stub("claude_mem_save.json")
    local result = child.lua(
        [[
        local save_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })

        local captured
        claude_mem._request = function(method, path, opts, cb)
            captured = { method = method, path = path, body = opts.body }
            cb({ ok = true, data = vim.json.decode(save_stub) })
        end

        claude_mem.index({
            summary_id = "sum-1",
            chat_id = "chat-1",
            chat_title = "My Chat",
            generated_at = 1700000000,
            project_root = "/home/user/projects/codecompanion-history.nvim",
            content = "Summary content here",
        })

        return captured
    ]],
        { save_stub }
    )

    eq("POST", result.method)
    eq("/api/memory/save", result.path)
    eq("Summary content here", result.body.text)
    eq("My Chat", result.body.title)
    eq("codecompanion-history.nvim", result.body.project)
    eq("codecompanion-history", result.body.metadata.source)
    eq("codecompanion", result.body.metadata.platform_source)
    eq("chat-1", result.body.metadata.save_id)
    eq("sum-1", result.body.metadata.summary_id)
end

T["index()"]["respects a custom project() override"] = function()
    local save_stub = read_stub("claude_mem_save.json")
    local result = child.lua(
        [[
        local save_stub = ...
        claude_mem.setup({
            claude_mem = {
                data_dir = "/tmp",
                project = function(project_root)
                    return "custom-" .. vim.fs.basename(project_root)
                end,
            },
        })

        local captured
        claude_mem._request = function(method, path, opts, cb)
            captured = opts.body
            cb({ ok = true, data = vim.json.decode(save_stub) })
        end

        claude_mem.index({
            summary_id = "sum-2",
            chat_id = "chat-2",
            project_root = "/home/user/projects/myrepo",
            content = "content",
        })

        return captured
    ]],
        { save_stub }
    )
    eq("custom-myrepo", result.project)
end

T["index()"]["backfills every stored summary when called with nil"] = function()
    local save_stub = read_stub("claude_mem_save.json")
    local result = child.lua(
        [[
        local save_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })

        package.loaded["codecompanion._extensions.history"] = {
            exports = {
                get_summaries = function()
                    return {
                        ["s1"] = { chat_id = "c1", chat_title = "First", generated_at = 1, project_root = "/p/one" },
                        ["s2"] = { chat_id = "c2", chat_title = "Second", generated_at = 2, project_root = "/p/two" },
                    }
                end,
                load_summary = function(summary_id)
                    return "content-for-" .. summary_id
                end,
            },
        }

        local saved = {}
        claude_mem._request = function(method, path, opts, cb)
            table.insert(saved, opts.body)
            cb({ ok = true, data = vim.json.decode(save_stub) })
        end

        claude_mem.index(nil)

        table.sort(saved, function(a, b)
            return a.text < b.text
        end)
        return saved
    ]],
        { save_stub }
    )
    eq(2, #result)
    eq("content-for-s1", result[1].text)
    eq("content-for-s2", result[2].text)
end

T["get_context()"] = new_set()

T["get_context()"]["extracts markdown text from a successful response"] = function()
    local context_stub = read_stub("claude_mem_context_recent.json")
    local result = child.lua(
        [[
        local context_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", inject_limit = 3 } })

        local captured
        claude_mem._request = function(method, path, opts, cb)
            captured = { method = method, path = path, query = opts.query }
            cb({ ok = true, data = vim.json.decode(context_stub) })
        end

        local ctx
        claude_mem.get_context("/home/user/projects/myrepo", function(c)
            ctx = c
        end)
        vim.wait(200, function()
            return ctx ~= nil
        end)

        return { method = captured.method, path = captured.path, query = captured.query, ctx = ctx }
    ]],
        { context_stub }
    )
    eq("GET", result.method)
    eq("/api/context/recent", result.path)
    eq("myrepo", result.query.project)
    eq(3, result.query.limit)
    eq(true, result.ctx:find("Recent activity") ~= nil)
end

T["get_context()"]["calls back with nil when the worker request fails"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })
        claude_mem._request = function(method, path, opts, cb)
            cb({ ok = false, error = "boom" })
        end

        local called, called_with = false, "unset"
        claude_mem.get_context("/home/user/projects/myrepo", function(c)
            called = true
            called_with = c
        end)
        vim.wait(200, function()
            return called
        end)
        return { called = called, called_with = called_with }
    ]])
    eq(true, result.called)
    eq(nil, result.called_with)
end

T["_resolve_start_command()"] = new_set()

T["_resolve_start_command()"]["prefers a global claude-mem binary on PATH"] = function()
    local result = child.lua([[
        local original_executable = vim.fn.executable
        vim.fn.executable = function(name)
            if name == "claude-mem" then
                return 1
            end
            return original_executable(name)
        end

        local cmd = claude_mem._resolve_start_command()
        vim.fn.executable = original_executable
        return cmd
    ]])
    eq({ "claude-mem", "start" }, result)
end

T["_resolve_start_command()"]["falls back to the newest non-orphaned installed plugin version"] = function()
    local result = child.lua([[
        local base = vim.fn.tempname()
        vim.fn.mkdir(base, "p")
        local cache_root = base .. "/plugins/cache/thedotmack/claude-mem"
        vim.fn.mkdir(cache_root, "p")

        local function make_version(v, orphaned)
            local dir = cache_root .. "/" .. v
            vim.fn.mkdir(dir .. "/scripts", "p")
            io.open(dir .. "/scripts/bun-runner.js", "w"):close()
            io.open(dir .. "/scripts/worker-service.cjs", "w"):close()
            if orphaned then
                io.open(dir .. "/.orphaned_at", "w"):close()
            end
        end

        make_version("13.8.0", false)
        make_version("13.12.4", false)
        make_version("13.20.0", true) -- newest, but orphaned: must be skipped

        vim.env.CLAUDE_CONFIG_DIR = base

        local original_executable = vim.fn.executable
        vim.fn.executable = function(name)
            if name == "claude-mem" then
                return 0
            end
            if name == "node" then
                return 1
            end
            return original_executable(name)
        end

        local cmd = claude_mem._resolve_start_command()
        vim.fn.executable = original_executable
        vim.env.CLAUDE_CONFIG_DIR = nil

        return {
            cmd0 = cmd and cmd[1],
            picked_newest_clean = cmd and cmd[3] and cmd[3]:find("13.12.4", 1, true) ~= nil,
        }
    ]])
    eq("node", result.cmd0)
    eq(true, result.picked_newest_clean)
end

T["_resolve_start_command()"]["returns nil when no PATH binary and no plugin cache exist"] = function()
    local result = child.lua([[
        local base = vim.fn.tempname()
        vim.fn.mkdir(base, "p")
        vim.env.CLAUDE_CONFIG_DIR = base

        local original_executable = vim.fn.executable
        vim.fn.executable = function(name)
            if name == "claude-mem" or name == "node" then
                return 0
            end
            return original_executable(name)
        end

        local cmd = claude_mem._resolve_start_command()
        vim.fn.executable = original_executable
        vim.env.CLAUDE_CONFIG_DIR = nil

        return { has_cmd = cmd ~= nil }
    ]])
    eq(false, result.has_cmd)
end

T["_resolve_start_command()"]["returns nil when node is unavailable even if a plugin version exists"] = function()
    local result = child.lua([[
        local base = vim.fn.tempname()
        vim.fn.mkdir(base, "p")
        local dir = base .. "/plugins/cache/thedotmack/claude-mem/13.12.4/scripts"
        vim.fn.mkdir(dir, "p")
        io.open(dir .. "/bun-runner.js", "w"):close()
        io.open(dir .. "/worker-service.cjs", "w"):close()
        vim.env.CLAUDE_CONFIG_DIR = base

        local original_executable = vim.fn.executable
        vim.fn.executable = function(name)
            if name == "claude-mem" or name == "node" then
                return 0
            end
            return original_executable(name)
        end

        local cmd = claude_mem._resolve_start_command()
        vim.fn.executable = original_executable
        vim.env.CLAUDE_CONFIG_DIR = nil

        return { has_cmd = cmd ~= nil }
    ]])
    eq(false, result.has_cmd)
end

T["_start_worker()"] = new_set()

T["_start_worker()"]["reports false when no start command can be resolved"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })
        claude_mem._resolve_start_command = function()
            return nil
        end

        local started
        claude_mem._start_worker(function(ok)
            started = ok
        end)
        vim.wait(200, function()
            return started ~= nil
        end)
        return { started = started }
    ]])
    eq(false, result.started)
end

T["_start_worker()"]["reports true when the resolved command exits 0"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", auto_start_timeout_ms = 2000 } })
        claude_mem._resolve_start_command = function()
            return { "true" }
        end

        local started
        claude_mem._start_worker(function(ok)
            started = ok
        end)
        vim.wait(1000, function()
            return started ~= nil
        end)
        return { started = started }
    ]])
    eq(true, result.started)
end

T["_start_worker()"]["reports false when the resolved command exits non-zero"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", auto_start_timeout_ms = 2000 } })
        claude_mem._resolve_start_command = function()
            return { "false" }
        end

        local started
        claude_mem._start_worker(function(ok)
            started = ok
        end)
        vim.wait(1000, function()
            return started ~= nil
        end)
        return { started = started }
    ]])
    eq(false, result.started)
end

T["auto_start_worker via _request()"] = new_set()

T["auto_start_worker via _request()"]["starts the worker once and retries the failed request"] = function()
    local search_stub = read_stub("claude_mem_search.json")
    local result = child.lua(
        [[
        local search_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", auto_start_worker = true } })

        local curl_calls = 0
        vim.system = function(cmd, opts, cb)
            if cmd[1] == "curl" then
                curl_calls = curl_calls + 1
                if curl_calls == 1 then
                    cb({ code = 7, signal = 0, stdout = "", stderr = "curl: (7) Failed to connect" })
                else
                    cb({ code = 0, signal = 0, stdout = search_stub, stderr = "" })
                end
            else
                cb({ code = 0, signal = 0, stdout = "", stderr = "" })
            end
        end

        local start_calls = 0
        claude_mem._start_worker = function(cb)
            start_calls = start_calls + 1
            cb(true)
        end

        local result1
        claude_mem._request("GET", "/api/search/observations", { query = { query = "x" } }, function(r)
            result1 = r
        end)
        vim.wait(1000, function()
            return result1 ~= nil
        end)

        return { ok = result1.ok, start_calls = start_calls, curl_calls = curl_calls }
    ]],
        { search_stub }
    )
    eq(true, result.ok)
    eq(1, result.start_calls)
    eq(2, result.curl_calls)
end

T["auto_start_worker via _request()"]["attempts to start only once per session across repeated failures"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", auto_start_worker = true } })

        vim.system = function(cmd, opts, cb)
            cb({ code = 7, signal = 0, stdout = "", stderr = "curl: (7) Failed to connect" })
        end

        local start_calls = 0
        claude_mem._start_worker = function(cb)
            start_calls = start_calls + 1
            cb(false)
        end

        local r1, r2
        claude_mem._request("GET", "/api/search/observations", {}, function(r)
            r1 = r
        end)
        vim.wait(500, function()
            return r1 ~= nil
        end)

        claude_mem._request("GET", "/api/observations", {}, function(r)
            r2 = r
        end)
        vim.wait(500, function()
            return r2 ~= nil
        end)

        return { start_calls = start_calls, r1_ok = r1.ok, r2_ok = r2.ok }
    ]])
    eq(1, result.start_calls)
    eq(false, result.r1_ok)
    eq(false, result.r2_ok)
end

T["wants_prompt_capture()"] = new_set()

T["wants_prompt_capture()"]["false by default"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })
        return claude_mem.wants_prompt_capture()
    ]])
    eq(false, result)
end

T["wants_prompt_capture()"]["true when prompts.enabled = true"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", prompts = { enabled = true } } })
        return claude_mem.wants_prompt_capture()
    ]])
    eq(true, result)
end

T["save_prompt()"] = new_set()

T["save_prompt()"]["posts /api/import with one session and one prompt entry"] = function()
    local import_stub = read_stub("claude_mem_import.json")
    local result = child.lua(
        [[
        local import_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", prompts = { enabled = true } } })

        local captured
        claude_mem._request = function(method, path, opts, cb)
            captured = { method = method, path = path, body = opts.body }
            cb({ ok = true, data = vim.json.decode(import_stub) })
        end

        claude_mem.save_prompt({
            chat_id = "1785768156",
            chat_title = "My Chat",
            project_root = "/home/user/projects/codecompanion-history.nvim",
            prompt_number = 1,
            content = "How would it be possible to store input user prompts?",
            timestamp = 1785768156,
        })

        return captured
    ]],
        { import_stub }
    )

    eq("POST", result.method)
    eq("/api/import", result.path)
    eq(1, #result.body.sessions)
    eq(1, #result.body.prompts)

    local session = result.body.sessions[1]
    eq("codecompanion-1785768156", session.content_session_id)
    eq("codecompanion-history.nvim", session.project)
    eq("codecompanion", session.platform_source)
    eq("completed", session.status)
    eq("How would it be possible to store input user prompts?", session.user_prompt)

    local prompt = result.body.prompts[1]
    eq("codecompanion-1785768156", prompt.content_session_id)
    eq("codecompanion", prompt.platform_source)
    eq(1, prompt.prompt_number)
    eq("How would it be possible to store input user prompts?", prompt.prompt_text)
    eq(1785768156000, prompt.created_at_epoch)
end

T["save_prompt()"]["strips <private> and <system-reminder> blocks before sending"] = function()
    local import_stub = read_stub("claude_mem_import.json")
    local result = child.lua(
        [[
        local import_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", prompts = { enabled = true } } })

        local captured
        claude_mem._request = function(method, path, opts, cb)
            captured = opts.body
            cb({ ok = true, data = vim.json.decode(import_stub) })
        end

        claude_mem.save_prompt({
            chat_id = "1",
            project_root = "/tmp/repo",
            prompt_number = 1,
            content = "keep this<private>drop this</private> and keep this<system-reminder>drop too</system-reminder>end",
            timestamp = 1700000000,
        })

        return captured
    ]],
        { import_stub }
    )
    eq("keep this and keep thisend", result.prompts[1].prompt_text)
end

T["save_prompt()"]["truncates text over max_chars ending in an ellipsis"] = function()
    local import_stub = read_stub("claude_mem_import.json")
    local result = child.lua(
        [[
        local import_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", prompts = { enabled = true, max_chars = 10 } } })

        local captured
        claude_mem._request = function(method, path, opts, cb)
            captured = opts.body
            cb({ ok = true, data = vim.json.decode(import_stub) })
        end

        claude_mem.save_prompt({
            chat_id = "1",
            project_root = "/tmp/repo",
            prompt_number = 1,
            content = "0123456789ABCDEF",
            timestamp = 1700000000,
        })

        return captured.prompts[1].prompt_text
    ]],
        { import_stub }
    )
    eq("012345678", result:sub(1, 9))
    eq(10, vim.fn.strcharlen(result))
    eq("…", result:sub(-3))
end

T["save_prompt()"]["issues no request when the prompt is empty after stripping"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", prompts = { enabled = true } } })

        local called = false
        claude_mem._request = function(method, path, opts, cb)
            called = true
        end

        claude_mem.save_prompt({
            chat_id = "1",
            project_root = "/tmp/repo",
            prompt_number = 1,
            content = "<private>only private content</private>",
            timestamp = 1700000000,
        })

        return called
    ]])
    eq(false, result)
end

T["memory tool"]["scope = prompts calls /api/search with type=prompts and renders results"] = function()
    local prompts_stub = read_stub("claude_mem_search_prompts.json")
    local result = child.lua(
        [[
        local prompts_stub = ...
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })

        local captured
        claude_mem._request = function(method, path, opts, cb)
            captured = { method = method, path = path, query = opts.query }
            cb({ ok = true, data = vim.json.decode(prompts_stub) })
        end

        local tool = claude_mem.make_memory_tool({ default_num = 10 })
        local msg
        tool.cmds[1](nil, { keywords = { "claude-mem" }, scope = "prompts" }, {
            output_cb = function(m)
                msg = m
            end,
        })
        vim.wait(200, function()
            return msg ~= nil
        end)

        local outputs = {}
        local fake_chat = {
            add_tool_output = function(_, tool_self, content, user_message)
                table.insert(outputs, { content = content, user_message = user_message })
            end,
        }
        tool.output.success(tool, { chat = fake_chat }, nil, { msg.data })

        return {
            method = captured.method,
            path = captured.path,
            query_type = captured.query.type,
            query_format = captured.query.format,
            mode = msg.data.mode,
            output_contains = outputs[1] and outputs[1].content:find("store input user prompts") ~= nil,
        }
    ]],
        { prompts_stub }
    )

    eq("GET", result.method)
    eq("/api/search", result.path)
    eq("prompts", result.query_type)
    eq("json", result.query_format)
    eq("prompts", result.mode)
    eq(true, result.output_contains)
end

T["memory tool"]["scope = prompts with 0 results reports 0 prompts found"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp" } })
        claude_mem._request = function(method, path, opts, cb)
            cb({ ok = true, data = { observations = {}, sessions = {}, prompts = {}, totalResults = 0 } })
        end

        local tool = claude_mem.make_memory_tool({ default_num = 10 })
        local msg
        tool.cmds[1](nil, { keywords = { "nothing" }, scope = "prompts" }, {
            output_cb = function(m)
                msg = m
            end,
        })
        vim.wait(200, function()
            return msg ~= nil
        end)

        local outputs = {}
        local fake_chat = {
            add_tool_output = function(_, tool_self, content, user_message)
                table.insert(outputs, content)
            end,
        }
        tool.output.success(tool, { chat = fake_chat }, nil, { msg.data })

        return outputs[1]
    ]])
    eq(true, result:find("0 prompts") ~= nil)
end

T["auto_start_worker via _request()"]["never attempts to start the worker when the flag is off"] = function()
    local result = child.lua([[
        claude_mem.setup({ claude_mem = { data_dir = "/tmp", auto_start_worker = false } })

        vim.system = function(cmd, opts, cb)
            cb({ code = 7, signal = 0, stdout = "", stderr = "curl: (7) Failed to connect" })
        end

        local start_calls = 0
        claude_mem._start_worker = function(cb)
            start_calls = start_calls + 1
            cb(true)
        end

        local r
        claude_mem._request("GET", "/api/search/observations", {}, function(res)
            r = res
        end)
        vim.wait(500, function()
            return r ~= nil
        end)

        return { start_calls = start_calls, ok = r.ok }
    ]])
    eq(0, result.start_calls)
    eq(false, result.ok)
end

return T
