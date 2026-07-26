---Memory backend auto-resolution for codecompanion-history extension
---Same pattern as the picker auto-resolution in `pickers/init.lua`

---@class CodeCompanion.History.MemoryProvider
---@field setup fun(memory_opts: CodeCompanion.History.MemoryOpts)
---@field is_available fun(): boolean
---@field index fun(summary_data: CodeCompanion.History.SummaryData?)
---@field make_memory_tool fun(tool_opts: CodeCompanion.History.MemoryTool.Opts): CodeCompanion.Agent.Tool|{}
---@field wants_context_injection fun(): boolean
---@field get_context (fun(project_root: string, cb: fun(context: string?)))?

local M = {}

---@type table<string, string>
local provider_modules = {
    vectorcode = "codecompanion._extensions.history.memory.vectorcode",
    ["claude-mem"] = "codecompanion._extensions.history.memory.claude_mem",
}

---Resolve which memory provider to use, calling `setup` on each candidate so
---availability checks (which may depend on resolved config) are accurate.
---@param opts CodeCompanion.History.MemoryOpts
---@return CodeCompanion.History.MemoryProvider? provider
---@return string? name
function M.resolve(opts)
    local order = opts.provider and { opts.provider } or { "vectorcode", "claude-mem" }
    for _, name in ipairs(order) do
        local module_name = provider_modules[name]
        if module_name then
            local ok, provider = pcall(require, module_name)
            if ok then
                provider.setup(opts)
                if provider.is_available() then
                    return provider, name
                end
            end
        end
    end
    return nil, nil
end

return M
