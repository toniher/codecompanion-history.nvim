---Shim adapting `history/vectorcode.lua` to the memory provider interface.
local vectorcode = require("codecompanion._extensions.history.vectorcode")

local M = {}

---@param memory_opts CodeCompanion.History.MemoryOpts
function M.setup(memory_opts)
    vectorcode.opts = vim.tbl_deep_extend("force", vectorcode.opts, memory_opts or {})
end

---@return boolean
function M.is_available()
    return vectorcode.has_vectorcode()
end

---@param summary_data CodeCompanion.History.SummaryData?
function M.index(summary_data)
    return vectorcode.vectorise(summary_data and summary_data.path or nil)
end

---@param tool_opts CodeCompanion.History.MemoryTool.Opts
---@return CodeCompanion.Agent.Tool|{}
function M.make_memory_tool(tool_opts)
    return vectorcode.make_memory_tool(tool_opts)
end

---VectorCode has no context-injection capability
---@return boolean
function M.wants_context_injection()
    return false
end

return M
