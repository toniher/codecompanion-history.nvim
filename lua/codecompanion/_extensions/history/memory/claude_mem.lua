---claude-mem memory provider: talks to the local claude-mem HTTP worker
---(https://github.com/thedotmack/claude-mem) over `curl`, matching the
---transport pattern used by `history/vectorcode.lua`.
---@module "codecompanion"

local log = require("codecompanion._extensions.history.log")
local utils = require("codecompanion._extensions.history.utils")

---@class CodeCompanion.History.ClaudeMemResolvedOpts
---@field host string
---@field port number
---@field data_dir string
---@field timeout_ms number
---@field project? fun(project_root: string): string
---@field search "keyword"|"semantic"
---@field inject_context_on_new_chat boolean
---@field inject_limit number
---@field auto_start_worker boolean
---@field auto_start_timeout_ms number

---@class CodeCompanion.History.ClaudeMem
---@field opts CodeCompanion.History.ClaudeMemResolvedOpts
local M = {
    opts = {
        host = "127.0.0.1",
        port = 37700,
        data_dir = vim.fs.joinpath(vim.fn.expand("~"), ".claude-mem"),
        timeout_ms = 5000,
        project = nil,
        search = "keyword",
        inject_context_on_new_chat = false,
        inject_limit = 5,
        auto_start_worker = false,
        auto_start_timeout_ms = 15000,
    },
    notify = true,
}

-- Only attempt an auto-start once per Neovim session, even if requests keep failing.
local worker_start_attempted = false

---Read claude-mem's own settings.json, if present
---@param data_dir string
---@return table
local function read_settings(data_dir)
    local result = utils.read_json(vim.fs.joinpath(data_dir, "settings.json"))
    return result.ok and result.data or {}
end

---Merge/resolve config: explicit opts > env vars > settings.json > defaults
---@param memory_opts CodeCompanion.History.MemoryOpts
function M.setup(memory_opts)
    local claude_mem_opts = (memory_opts and memory_opts.claude_mem) or {}

    M.notify = memory_opts and memory_opts.notify
    if M.notify == nil then
        M.notify = true
    end

    local data_dir = claude_mem_opts.data_dir
        or os.getenv("CLAUDE_MEM_DATA_DIR")
        or vim.fs.joinpath(vim.fn.expand("~"), ".claude-mem")

    local settings = read_settings(data_dir)

    local host = claude_mem_opts.host
        or os.getenv("CLAUDE_MEM_WORKER_HOST")
        or settings.CLAUDE_MEM_WORKER_HOST
        or "127.0.0.1"

    local port = claude_mem_opts.port
        or tonumber(os.getenv("CLAUDE_MEM_WORKER_PORT"))
        or tonumber(settings.CLAUDE_MEM_WORKER_PORT)
        or 37700

    M.opts = {
        host = host,
        port = port,
        data_dir = data_dir,
        timeout_ms = claude_mem_opts.timeout_ms or 5000,
        project = claude_mem_opts.project,
        search = claude_mem_opts.search or "keyword",
        inject_context_on_new_chat = claude_mem_opts.inject_context_on_new_chat or false,
        inject_limit = claude_mem_opts.inject_limit or 5,
        auto_start_worker = claude_mem_opts.auto_start_worker or false,
        auto_start_timeout_ms = claude_mem_opts.auto_start_timeout_ms or 15000,
    }
end

---claude-mem's own SQLite database is the marker that the plugin is installed
---and has run at least once; the worker itself is checked lazily, per-request.
---@return boolean
function M.is_available()
    if not M.opts.data_dir then
        return false
    end
    local stat = vim.uv.fs_stat(vim.fs.joinpath(M.opts.data_dir, "claude-mem.db"))
    return stat ~= nil
end

---Build a `basename(project_root)` project key, or use the user override
---@param project_root string?
---@return string?
local function project_key(project_root)
    if not project_root then
        return nil
    end
    if M.opts.project then
        local ok, key = pcall(M.opts.project, project_root)
        if ok and type(key) == "string" and key ~= "" then
            return key
        end
        log:error("[claude-mem] project() override failed: %s", key)
    end
    return vim.fs.basename(project_root)
end

---@param query table<string, string|number>?
---@return string
local function encode_query(query)
    if not query or vim.tbl_isempty(query) then
        return ""
    end
    local parts = {}
    for k, v in pairs(query) do
        if v ~= nil then
            table.insert(parts, string.format("%s=%s", k, vim.uri_encode(tostring(v))))
        end
    end
    return "?" .. table.concat(parts, "&")
end

---Parse a `MAJOR.MINOR.PATCH`-style directory name into a comparable version
---@param dir string
---@return {[1]: number, [2]: number, [3]: number}?
local function parse_version(dir)
    local major, minor, patch = vim.fs.basename(dir):match("^(%d+)%.(%d+)%.(%d+)")
    if not major then
        return nil
    end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

---@param a {[1]: number, [2]: number, [3]: number}
---@param b {[1]: number, [2]: number, [3]: number}
---@return boolean
local function is_newer_version(a, b)
    for i = 1, 3 do
        if a[i] ~= b[i] then
            return a[i] > b[i]
        end
    end
    return false
end

---Find the newest, non-orphaned installed claude-mem plugin version under the
---Claude Code plugin cache (mirrors the resolution the plugin's own hooks do in bash).
---@return string? plugin_root
local function find_plugin_root()
    local config_dir = os.getenv("CLAUDE_CONFIG_DIR") or vim.fs.joinpath(vim.fn.expand("~"), ".claude")
    local cache_root = vim.fs.joinpath(config_dir, "plugins", "cache", "thedotmack", "claude-mem")

    local best_dir, best_version
    for _, dir in ipairs(vim.fn.glob(vim.fs.joinpath(cache_root, "*"), false, true)) do
        local stat = vim.uv.fs_stat(dir)
        local orphaned = vim.uv.fs_stat(vim.fs.joinpath(dir, ".orphaned_at"))
        if stat and stat.type == "directory" and not orphaned then
            local version = parse_version(dir)
            if version and (not best_version or is_newer_version(version, best_version)) then
                best_version, best_dir = version, dir
            end
        end
    end
    return best_dir
end

---Resolve a command that starts the claude-mem worker: a global `claude-mem`
---binary on PATH first, else the newest installed plugin version's own scripts.
---@return string[]? cmd
function M._resolve_start_command()
    if vim.fn.executable("claude-mem") == 1 then
        return { "claude-mem", "start" }
    end

    if vim.fn.executable("node") ~= 1 then
        return nil
    end

    local plugin_root = find_plugin_root()
    if not plugin_root then
        return nil
    end

    local bun_runner = vim.fs.joinpath(plugin_root, "scripts", "bun-runner.js")
    local worker_service = vim.fs.joinpath(plugin_root, "scripts", "worker-service.cjs")
    if vim.uv.fs_stat(bun_runner) and vim.uv.fs_stat(worker_service) then
        return { "node", bun_runner, worker_service, "start" }
    end
    return nil
end

---Attempt to start the claude-mem worker. Safe to call when it's already
---running (both the global CLI and the plugin's own script are idempotent).
---@param cb fun(started: boolean)
function M._start_worker(cb)
    local cmd = M._resolve_start_command()
    if not cmd then
        log:error(
            "[claude-mem] auto_start_worker is enabled but no start command could be resolved "
                .. "(no `claude-mem` on PATH and no installed plugin found under the Claude Code plugin cache)"
        )
        return cb(false)
    end

    if M.notify then
        vim.schedule(function()
            vim.notify("Starting claude-mem worker...", vim.log.levels.INFO, { title = "CodeCompanion-History" })
        end)
    end

    vim.system(cmd, { timeout = M.opts.auto_start_timeout_ms }, function(out)
        if out.code ~= 0 then
            log:error("[claude-mem] failed to start worker (exit %s): %s", out.code, out.stderr)
            return cb(false)
        end
        cb(true)
    end)
end

---Talk to the claude-mem worker over curl (mirrors vectorcode.lua's `vim.system` usage)
---@param method "GET"|"POST"
---@param path string
---@param opts {query?: table<string, string|number>, body?: table}?
---@param cb fun(result: {ok: boolean, data: any, error: string?})
function M._request(method, path, opts, cb)
    opts = opts or {}
    local url = string.format("http://%s:%d%s%s", M.opts.host, M.opts.port, path, encode_query(opts.query))

    local cmd = { "curl", "-sS", "-m", tostring(math.max(1, math.ceil(M.opts.timeout_ms / 1000))), "-X", method, url }
    if opts.body then
        local ok, encoded = pcall(vim.json.encode, opts.body)
        if not ok then
            return cb({ ok = false, error = "Failed to encode request body" })
        end
        vim.list_extend(cmd, { "-H", "Content-Type: application/json", "-d", encoded })
    end

    local reachable_error = string.format(
        "claude-mem worker not reachable at %s:%d — start Claude Code or the claude-mem worker",
        M.opts.host,
        M.opts.port
    )

    ---@param on_fail fun(out: table)
    local function attempt(on_fail)
        vim.system(cmd, {}, function(out)
            if out.code ~= 0 then
                log:debug("[claude-mem] curl failed (code %s): %s", out.code, out.stderr)
                return on_fail(out)
            end

            local ok, decoded = pcall(vim.json.decode, out.stdout, { luanil = { object = true, array = true } })
            if not ok then
                log:error("[claude-mem] Failed to decode response from %s: %s", path, out.stdout)
                return cb({ ok = false, error = "Failed to decode claude-mem response" })
            end
            if type(decoded) == "table" and decoded.error then
                return cb({ ok = false, error = decoded.error })
            end
            cb({ ok = true, data = decoded })
        end)
    end

    attempt(function()
        if not M.opts.auto_start_worker or worker_start_attempted or path == "/api/health" then
            return cb({ ok = false, error = reachable_error })
        end

        worker_start_attempted = true
        M._start_worker(function(started)
            if not started then
                return cb({ ok = false, error = reachable_error })
            end
            -- Give the HTTP server a moment to bind before retrying.
            vim.defer_fn(function()
                attempt(function()
                    cb({ ok = false, error = reachable_error })
                end)
            end, 300)
        end)
    end)
end

---@param opts CodeCompanion.History.MemoryTool.Opts
---@return CodeCompanion.Agent.Tool|{}
function M.make_memory_tool(opts)
    opts = vim.tbl_deep_extend("force", { default_num = 10 }, opts or {})
    return {
        name = "memory",
        schema = {
            type = "function",
            ["function"] = {
                name = "memory",
                description = [[
                This tool gives you access to previous conversations, stored in claude-mem.
                Use this tool when users mentioned a previous conversation, or when you feel like you can make use of previous chats.
                Call it with `keywords` to search for relevant memories; each result carries an id.
                Call it again with `ids` (from a prior search) to unfold the full detail of specific memories.
                ]],
                parameters = {
                    type = "object",
                    properties = {
                        keywords = {
                            type = "array",
                            items = { type = "string" },
                            description = "A list of keywords used to search for relevant memories. Include words with similar meanings to improve the search.",
                        },
                        count = {
                            type = "integer",
                            description = string.format(
                                "Number of memories to fetch. If the user did not specify, use %d",
                                opts.default_num
                            ),
                        },
                        ids = {
                            type = "array",
                            items = { type = "integer" },
                            description = "Memory ids to unfold into full detail. Use ids returned by a previous search call.",
                        },
                    },
                    additionalProperties = false,
                },
            },
        },
        cmds = {
            ---@param action CodeCompanion.History.MemoryTool.Args
            function(_, action, cmd_opts)
                -- `_request`'s callback runs in a libuv fast-event context; schedule
                -- so `output_cb` can safely touch the chat buffer.
                local cb = vim.schedule_wrap(cmd_opts.output_cb)
                local project = project_key(utils.find_project_root())

                if vim.islist(action.ids or {}) and #(action.ids or {}) > 0 then
                    M._request(
                        "GET",
                        "/api/observations",
                        { query = { ids = table.concat(action.ids, ",") } },
                        function(result)
                            if not result.ok then
                                return cb({ status = "error", data = result.error })
                            end
                            cb({ status = "success", data = { mode = "unfold", items = result.data } })
                        end
                    )
                    return
                end

                if not vim.islist(action.keywords or {}) or #(action.keywords or {}) == 0 then
                    return cb({
                        status = "error",
                        data = "You must provide a non-empty list of keywords to search for memories, or a list of ids to unfold.",
                    })
                end

                local query_text = table.concat(action.keywords, " ")
                local limit = action.count or opts.default_num

                if M.opts.search == "semantic" then
                    M._request(
                        "POST",
                        "/api/context/semantic",
                        { body = { query = query_text, project = project, limit = limit } },
                        function(result)
                            if not result.ok then
                                return cb({ status = "error", data = result.error })
                            end
                            cb({ status = "success", data = { mode = "search", result = result.data } })
                        end
                    )
                else
                    M._request(
                        "GET",
                        "/api/search/observations",
                        { query = { query = query_text, limit = limit, project = project } },
                        function(result)
                            if not result.ok then
                                return cb({ status = "error", data = result.error })
                            end
                            cb({ status = "success", data = { mode = "search", result = result.data } })
                        end
                    )
                end
            end,
        },
        output = {
            ---@param agent CodeCompanion.Tools
            error = function(self, agent, cmd, stderr)
                local errors = vim.iter(stderr):flatten():join("\n")
                agent.chat:add_tool_output(
                    self,
                    string.format(
                        [[**Memory Tool**: Ran with an error:

````txt
%s
````]],
                        errors
                    )
                )
            end,
            ---@param agent CodeCompanion.Tools
            success = function(self, agent, cmd, stdout)
                ---@type {mode: string, result: any, items: any}
                local payload = stdout[1]
                local chat = agent.chat

                if payload.mode == "unfold" then
                    local items = payload.items
                    if not items or (vim.islist(items) and #items == 0) then
                        chat:add_tool_output(self, "No memories found for the given ids.")
                        return
                    end
                    local list = vim.islist(items) and items or { items }
                    for i, item in ipairs(list) do
                        local user_message = i == 1 and string.format("Unfolded %d memories.", #list) or ""
                        local body = table.concat({
                            item.title and ("Title: " .. item.title) or nil,
                            item.subtitle and ("Subtitle: " .. item.subtitle) or nil,
                            item.narrative or item.facts or "",
                        }, "\n")
                        chat:add_tool_output(self, string.format("<memory>\n%s\n</memory>", body), user_message)
                    end
                    return
                end

                -- Search results already come back as a rendered markdown table
                local text = payload.result
                    and payload.result.content
                    and payload.result.content[1]
                    and payload.result.content[1].text
                if not text or text == "" then
                    chat:add_tool_output(self, "The memory tool found 0 memories.")
                    return
                end
                chat:add_tool_output(self, string.format("<memory>\n%s\n</memory>", text), "Retrieved memories.")
            end,
        },
    }
end

---Push a single summary to claude-mem via `POST /api/memory/save`
---@param summary_data CodeCompanion.History.SummaryData
local function save_summary(summary_data)
    M._request("POST", "/api/memory/save", {
        body = {
            text = summary_data.content,
            title = summary_data.chat_title or "CodeCompanion chat summary",
            project = project_key(summary_data.project_root),
            metadata = {
                source = "codecompanion-history",
                platform_source = "codecompanion",
                save_id = summary_data.chat_id,
                summary_id = summary_data.summary_id,
                generated_at = summary_data.generated_at,
            },
        },
    }, function(result)
        if not result.ok then
            log:error("[claude-mem] Failed to save summary %s: %s", summary_data.summary_id, result.error)
            if M.notify then
                vim.schedule(function()
                    vim.notify(
                        "Failed to save summary to claude-mem: " .. result.error,
                        vim.log.levels.WARN,
                        { title = "CodeCompanion-History" }
                    )
                end)
            end
            return
        end
        if M.notify then
            vim.schedule(function()
                vim.notify("Summary saved to claude-mem.", vim.log.levels.INFO, { title = "CodeCompanion-History" })
            end)
        end
    end)
end

---Save a summary to claude-mem, or backfill every stored summary when `summary_data` is nil
---@param summary_data CodeCompanion.History.SummaryData?
function M.index(summary_data)
    if summary_data then
        return save_summary(summary_data)
    end

    local history = require("codecompanion._extensions.history")
    local summaries_index = history.exports.get_summaries()
    for summary_id, meta in pairs(summaries_index) do
        local content = history.exports.load_summary(summary_id)
        if content then
            save_summary({
                summary_id = summary_id,
                chat_id = meta.chat_id,
                chat_title = meta.chat_title,
                generated_at = meta.generated_at,
                project_root = meta.project_root,
                content = content,
            })
        end
    end
end

---Whether the user opted in to injecting recent claude-mem context into new chats
---@return boolean
function M.wants_context_injection()
    return M.opts.inject_context_on_new_chat == true
end

---Fetch claude-mem's recent-context markdown block for a project
---@param project_root string
---@param cb fun(context: string?) Scheduled onto the main loop, safe to touch buffers from
function M.get_context(project_root, cb)
    cb = vim.schedule_wrap(cb)
    local project = project_key(project_root)
    M._request(
        "GET",
        "/api/context/recent",
        { query = { project = project, limit = M.opts.inject_limit } },
        function(result)
            if not result.ok then
                log:debug("[claude-mem] get_context failed: %s", result.error)
                return cb(nil)
            end

            local data = result.data
            local text
            if type(data) == "string" then
                text = data
            elseif type(data) == "table" then
                if data.content and data.content[1] and type(data.content[1].text) == "string" then
                    text = data.content[1].text
                elseif type(data.markdown) == "string" then
                    text = data.markdown
                elseif type(data.context) == "string" then
                    text = data.context
                end
            end
            cb(text)
        end
    )
end

return M
