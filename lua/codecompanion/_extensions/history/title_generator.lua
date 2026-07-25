local client = require("codecompanion.http")
local config = require("codecompanion.config")
local log = require("codecompanion._extensions.history.log")
local schema = require("codecompanion.schema")
local utils = require("codecompanion._extensions.history.utils")

local CONSTANTS = {
    STATUS_ERROR = "error",
    STATUS_SUCCESS = "success",
}

---@class CodeCompanion.History.TitleGenerator
---@field opts CodeCompanion.History.Opts
local TitleGenerator = {}

---@param opts CodeCompanion.History.Opts
---@return CodeCompanion.History.TitleGenerator
function TitleGenerator.new(opts)
    local self = setmetatable({}, {
        __index = TitleGenerator,
    })
    self.opts = opts
    return self --[[@as CodeCompanion.History.TitleGenerator]]
end

---Count user messages in chat (excluding tagged/reference messages)
---@param chat CodeCompanion.History.Chat
---@return number
function TitleGenerator:_count_user_messages(chat)
    if not chat.messages or #chat.messages == 0 then
        return 0
    end

    local user_messages = vim.tbl_filter(function(msg)
        return msg.role == config.constants.USER_ROLE
    end, chat.messages)

    local actual_user_messages = vim.tbl_filter(function(msg)
        local has_content = vim.trim(utils.message_text(msg.content)) ~= ""
        return has_content
            and not (msg.opts and msg.opts.tag)
            and not (msg.opts and (msg.opts.reference or msg.opts.context_id))
    end, user_messages)

    return #actual_user_messages
end

---Check if title should be generated or refreshed
---@param chat CodeCompanion.History.Chat
---@return boolean should_generate, boolean is_refresh
function TitleGenerator:should_generate(chat)
    if not self.opts.auto_generate_title then
        return false, false
    end

    if not chat.opts.title then
        return true, false
    end

    local refresh_opts = self.opts.title_generation_opts or {}
    if refresh_opts.refresh_every_n_prompts and refresh_opts.refresh_every_n_prompts > 0 then
        local user_message_count = self:_count_user_messages(chat)
        local refresh_count = chat.opts.title_refresh_count or 0
        local max_refreshes = refresh_opts.max_refreshes or 3

        if
            user_message_count > 0
            and user_message_count % refresh_opts.refresh_every_n_prompts == 0
            and refresh_count < max_refreshes
        then
            return true, true
        end
    end

    return false, false
end

---Generate title for chat
---@param chat CodeCompanion.History.Chat The chat object containing messages and ID
---@param callback fun(title: string|nil) Callback function to receive the generated title
---@param is_refresh? boolean Whether this is a title refresh (default: false)
function TitleGenerator:generate(chat, callback, is_refresh)
    if not self.opts.auto_generate_title then
        return
    end

    is_refresh = is_refresh or false

    -- Early return for disabled auto-generation, but allow refresh if explicitly requested
    if not is_refresh and chat.opts.title then
        log:trace("Using existing chat title: %s", chat.opts.title)
        return callback(chat.opts.title)
    end

    -- Return early if no messages or messages is nil
    if not chat.messages or #chat.messages == 0 then
        log:trace("No messages found in chat, skipping title generation")
        return callback(nil)
    end

    -- Filter relevant messages (both user and assistant, excluding tagged/reference messages)
    local relevant_messages = vim.tbl_filter(function(msg)
        -- Include user and assistant messages with actual content
        local has_content = vim.trim(utils.message_text(msg.content)) ~= ""
        local is_relevant_role = msg.role == config.constants.USER_ROLE or msg.role == config.constants.LLM_ROLE
        local not_tagged = not (msg.opts and (msg.opts.tag or msg.opts.reference or msg.opts.context_id))
            and not (msg._meta and msg._meta.tag)
            and not (msg.context and msg.context.id)
        return has_content and is_relevant_role and not_tagged
    end, chat.messages)

    if #relevant_messages == 0 then
        log:trace("No relevant messages found in chat, skipping title generation")
        return callback(nil)
    end

    -- Resolve the adapter that will be used so we can bail before showing feedback
    local gen_opts = self.opts.title_generation_opts or {}
    local resolved_adapter = chat.adapter and vim.deepcopy(chat.adapter)
    if gen_opts.adapter then
        resolved_adapter = require("codecompanion.adapters").resolve(gen_opts.adapter)
    end
    if resolved_adapter and resolved_adapter.type == "acp" then
        if gen_opts.adapter then
            -- User explicitly pointed title_generation_opts.adapter at an ACP adapter
            return callback(
                nil,
                "ACP adapters are not supported for title generation. Configure `title_generation_opts.adapter` to use an HTTP-based adapter."
            )
        end
        log:info(
            "Title generation skipped: chat is using an ACP adapter. Set `title_generation_opts.adapter` to an HTTP-based adapter to enable it."
        )
        return callback(nil)
    end

    -- Show appropriate feedback only after validation
    if is_refresh then
        callback("Refreshing title...")
    else
        callback("Deciding title...")
    end

    -- Extract conversation content based on whether this is a refresh or initial generation
    local conversation_context = ""

    if is_refresh then
        -- For refreshes, use recent conversation (last 6 messages or all if fewer)
        local recent_count = math.min(6, #relevant_messages)
        local start_index = math.max(1, #relevant_messages - recent_count + 1)
        local recent_messages = {}

        for i = start_index, #relevant_messages do
            local msg = relevant_messages[i]
            local role_prefix = msg.role == config.constants.USER_ROLE and "User" or "Assistant"
            local content = vim.trim(utils.message_text(msg.content))

            -- Truncate individual message if too long
            if #content > 1000 then
                content = content:sub(1, 1000) .. " [truncated]"
            end

            table.insert(recent_messages, role_prefix .. ": " .. content)
        end

        conversation_context = table.concat(recent_messages, "\n")
    else
        -- For initial generation, use the first user message
        local first_user_msg = nil
        for _, msg in ipairs(relevant_messages) do
            if msg.role == config.constants.USER_ROLE then
                first_user_msg = msg
                break
            end
        end

        if not first_user_msg then
            log:trace("No user message found in chat, skipping title generation")
            return callback(nil)
        end

        local content = vim.trim(utils.message_text(first_user_msg.content))

        -- Truncate individual message if too long
        if #content > 1000 then
            content = content:sub(1, 1000) .. " [truncated]"
        end

        conversation_context = "User: " .. content
    end

    -- Truncate total content if too long
    if #conversation_context > 10000 then
        conversation_context = conversation_context:sub(1, 10000) .. "\n[conversation truncated]"
    end

    log:trace(
        "Generating title for chat with save_id: %s (refresh: %s)",
        chat.opts.save_id or "N/A",
        tostring(is_refresh)
    )

    -- Create prompt for title generation
    local prompt
    if is_refresh then
        local original_title = chat.opts.title or "Unknown"
        prompt = string.format(
            [[The conversation has evolved since the original title was generated. Based on the recent conversation below, generate a new concise title (max 5 words) that better reflects the current topic.

Original title: "%s"

Recent conversation:
%s

Generate a new title that captures the main topic of the recent conversation. Do not include any special characters or quotes. Your response should contain only the new title.

New Title:]],
            original_title,
            conversation_context
        )
    else
        prompt = string.format(
            [[Generate a very short and concise title (max 5 words) for this chat based on the following conversation:
Do not include any special characters or quotes. Your response shouldn't contain any other text, just the title.

===
Examples:
1. User: What is the capital of France?
   Title: Capital of France
2. User: How do I create a new file in Vim?
   Title: Vim File Creation
===

Conversation:
%s
Title:]],
            conversation_context
        )
    end

    self:_make_adapter_request(chat, prompt, callback)
end

---@param chat CodeCompanion.History.Chat
---@param prompt string
---@param callback fun(title: string|nil, error_msg: string|nil)
function TitleGenerator:_make_adapter_request(chat, prompt, callback)
    log:trace("Making adapter request for title generation")
    local opts = self.opts.title_generation_opts or {}
    local adapter = vim.deepcopy(chat.adapter) --[[@as CodeCompanion.HTTPAdapter | CodeCompanion.ACPAdapter]]
    local settings = vim.deepcopy(chat.settings)
    local adapters = require("codecompanion.adapters")
    if opts.adapter then
        adapter = adapters.resolve(opts.adapter)
    end
    if opts.model then
        settings = schema.get_default(adapter, { model = opts.model })
    end
    settings = vim.deepcopy(adapter:map_schema_to_params(settings))
    settings.opts.stream = false
    local payload = {
        messages = adapter:map_roles({
            { role = "user", content = prompt },
        }),
    }
    --INFO: On HTTP errors the client invokes this callback twice: once with the error body as
    -- `data` and once with `err` set. Guard so the caller only ever sees one terminal result.
    local has_finished = false
    ---@param title string|nil
    ---@param error_msg string|nil
    local function finish(title, error_msg)
        if has_finished then
            return
        end
        has_finished = true
        return callback(title, error_msg)
    end

    client.new({ adapter = settings }):request(payload, {
        callback = function(err, data, _adapter)
            local err_msg = utils.format_adapter_error(err)
            if err_msg then
                log:error("Title generation error: %s", err_msg)
                vim.notify("Error while generating title: " .. err_msg, vim.log.levels.WARN)
                return finish(nil)
            end
            if data then
                local result = nil
                if _adapter.handlers.chat_output then
                    result = _adapter.handlers.chat_output(_adapter, data)
                else
                    result = adapters.call_handler(_adapter, "parse_chat", data)
                end
                if result and result.status then
                    if result.status == CONSTANTS.STATUS_SUCCESS then
                        local title = vim.trim(utils.message_text(result.output and result.output.content))
                        log:trace("Successfully generated title: %s", title)
                        return finish(title)
                    elseif result.status == CONSTANTS.STATUS_ERROR then
                        local output = utils.message_text(result.output, vim.inspect(result.output))
                        log:error("Title generation error: %s", output)
                        vim.notify("Error while generating title: " .. output, vim.log.levels.WARN)
                        return finish(nil)
                    end
                end
            end
            -- No usable response: revert to the base title rather than leaving the
            -- buffer stuck on the "Deciding title..." feedback.
            log:debug("Title generation produced no usable response")
            finish(nil)
        end,
    }, {
        silent = true,
    })
end

return TitleGenerator
