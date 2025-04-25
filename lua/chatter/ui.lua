local Buffer = require("chatter.buffer")
local utils = require("chatter.utils")

local history_winbar_prefix = "%#QuickFixLine# Chat history"
local initialized = false
local virtual_text_ns = vim.api.nvim_create_namespace("chatter")

---@class (exact) chatter.UI
---@field private chat_client chatter.ChatClient
---@field private completion_req chatter.CompletionRequest
---@field private displayed_assistant_header boolean
---@field private history chatter.Buffer
---@field private prompt chatter.Buffer
---@field private spinner chatter.Spinner
local UI = {}

---@param tool_call chatter.ToolCall
---@return string
local function format_tool_call(tool_call)
  local func = tool_call["function"]
  local args = vim.json.decode(func.arguments)
  local formatted_args = {}
  for name, value in pairs(args) do
    if type(value) == "string" then
      -- trim the string to 50 characters
      if #value > 20 then
        value = value:sub(1, 20) .. "..."
      end
      table.insert(formatted_args, string.format("%s: %q", name, value))
    else
      table.insert(formatted_args, string.format("%s: %s", name, vim.inspect(value)))
    end
  end
  return string.format("🛠️ %s(%s)", func.name, table.concat(formatted_args, ", "))
end

---Call tools
---@param tool_calls chatter.ToolCall[]
function UI:call_tools(tool_calls)
  if #tool_calls == 0 then
    return
  end

  self.history:append("\n\n_⚡ Calling tools_\n")

  for _, tool_call in ipairs(tool_calls) do
    ---@type chatter.ChatCompletionMessage
    local msg = { role = "tool", tool_call_id = tool_call.id, content = "n/a" }

    self.history:append("\n  " .. format_tool_call(tool_call))

    local ok, result, err = self.chat_client.tool_call(tool_call)
    if ok and result then
      for _, content in ipairs(result.content) do
        if content.type == "text" then
          msg.content = content.text
          table.insert(self.completion_req.messages, msg)
        else
          self.history:append_error("💥 error: unknown content type: " .. content.type)
        end
      end
    end
    if err then
      self.history:append_error("💥 error calling tool: " .. err)
      msg.content = "💥 error calling tool: " .. err
      table.insert(self.completion_req.messages, msg)
    end
  end
end

---@param header string
---@param tool_calls chatter.ToolCall[]
function UI:display_tool_calls(header, tool_calls)
  if #tool_calls > 0 then
    self.history:append(string.format("\n\n%s\n", header))
    for _, tool in ipairs(tool_calls) do
      local tool_desc = format_tool_call(tool)
      self.history:append("\n  " .. tool_desc)
    end
  end
end

---@param tool_calls chatter.ToolCall[]
function UI:handle_tool_calls(tool_calls)
  if #tool_calls == 0 then
    return
  end

  local safe_tools = {}
  local unsafe_tools = {}
  for _, tool in ipairs(tool_calls) do
    if self.chat_client.tool_safe(tool["function"].name) then
      table.insert(safe_tools, tool)
    else
      table.insert(unsafe_tools, tool)
    end
  end

  if #unsafe_tools == 0 then
    self:call_tools(tool_calls)
    return
  end

  self:display_tool_calls("✅ Safe tools", safe_tools)
  self:display_tool_calls("⚠️ Unsafe tools", unsafe_tools)

  self:reset_spinner()

  vim.cmd("redraw!")

  print("⚠️ Unsafe tools detected. Please confirm before calling them.")
  local choice = vim.fn.confirm("Do you wish to run the listed tools?", "&Yes\n&No")

  self.spinner:start()

  if choice == 1 then
    self:call_tools(tool_calls)
  else
    self.history:append("\n\n❌ User refused to call the tools")
    for _, tool_call in ipairs(tool_calls) do
      table.insert(self.completion_req.messages,
        {
          role = "tool",
          tool_call_id = tool_call.id,
          content = "❌ User refused to call the tool " .. tool_call["function"].name,
        }
      )
    end
  end
end

---@param content string
function UI:append_assistant_content(content)
  if not self.displayed_assistant_header then
    self.history:append("\n\n# _Assistant_\n\n")
    self.displayed_assistant_header = true
  end
  self.history:append(content)
end

--- Handles the user prompt.
--- This function is called when the user submits a prompt.
--- It appends the user input to the history buffer and clears the prompt buffer.
function UI:handle_user_prompt()
  self.displayed_assistant_header = false
  self.history:append("\n# _User_")

  local input_lines = vim.api.nvim_buf_get_lines(self.prompt:get_buf(), 0, -1, false)
  utils.remove_trailing_empty_lines(input_lines)
  self.history:append_lines(input_lines)

  self.prompt:clear()
  self.prompt:append("\n", true)

  local input_text = table.concat(input_lines, "\n")
  table.insert(self.completion_req.messages, { role = "user", content = input_text })
end

--- Stream the chat response from the server.
--- This function is called when the user submits a prompt.
--- It initializes a stream and continues to receive messages from the server until the response is complete.
--- It handles tool calls if present in the response, asking the user for confirmation if necessary,
--- calling the tools if the user agrees and appending the tool call results to the history.
function UI:chat_stream_loop()
  local stream_id, err = self.chat_client.chat_stream_init(self.completion_req)
  if err then
    self.history:append_error("💥 " .. err)
    return
  end
  assert(stream_id, "error: empty stream id from server")

  while true do
    local result
    result, err = self.chat_client.chat_stream_continue(stream_id)
    if err then
      self.history:append_error("💥 " .. err)
      return
    end

    assert(result, "error: empty result from server")

    if result.done then
      table.insert(self.completion_req.messages, result.message)

      if result.message.tool_calls then
        self:handle_tool_calls(result.message.tool_calls)
      end

      return
    end

    self:append_assistant_content(result.message.content)
  end
end

function UI:submit_prompt()
  coroutine.wrap(function()
    self:handle_user_prompt()

    while true do
      self.spinner:start()
      self:chat_stream_loop()
      self.history:append("\n")
      self:reset_spinner()
      -- if the last message is a tool response, continue looping to send back the tool calls.
      -- Otherwise, break the loop.
      local nb_msgs = #self.completion_req.messages
      if nb_msgs > 0 and self.completion_req.messages[nb_msgs].role == "tool" then
        self.history:append("\n📤 _Sending too call results..._")
      else
        return
      end
    end
  end)()
end

function UI:setup_keymaps()
  for _, keys in ipairs({ "<C-CR>", "<C-s>" }) do
    vim.keymap.set({ 'i', 'n' }, keys,
      function() self:submit_prompt() end,
      {
        buffer = self.prompt:get_buf(),
        noremap = true,
        silent = true,
      }
    )
  end
end

function UI:reset_spinner()
  self.spinner:stop()
  self.history:set_win_option("winbar", history_winbar_prefix)
  vim.api.nvim_buf_clear_namespace(self.history:get_buf(), virtual_text_ns, 0, 0)
end

--- Start the spinner and set the virtual text
---@param history chatter.Buffer
---@param spinner string
local function on_spin(history, spinner)
  local winbar = history_winbar_prefix .. " 〣 Assitant is thinking 🤔 " .. spinner
  history:set_win_option("winbar", winbar)

  -- Set the virtual text on the first line (line 0, since it's 0-indexed)
  vim.api.nvim_buf_set_extmark(
    history:get_buf(),
    virtual_text_ns,
    math.max(0, vim.api.nvim_buf_line_count(history:get_buf()) - 1), 0,
    {
      id = 1,
      hl_mode = 'combine',
      priority = 100,
      virt_text = {
        { spinner, 'Comment' },
      },
    })
end

---Stop the spinner and clear the virtual text
---@param history chatter.Buffer
local function on_stop(history)
  history:set_win_option("winbar", history_winbar_prefix)
  vim.api.nvim_buf_clear_namespace(history:get_buf(), virtual_text_ns, 0, -1)
end

--- Create a new UI instance
---@param config chatter.Config
---@param completion_req chatter.CompletionRequest
---@return boolean success
local function init(config, completion_req)
  if initialized then
    return true
  end

  local original_buf = vim.api.nvim_get_current_buf()

  -- Create output window (top)
  local history = Buffer.new("chatter://history", { split = "below" })
  history:modifiable(false)
  history:set_buf_option("filetype", "markdown")
  history:set_win_option("winbar", history_winbar_prefix)

  -- Unload original buffer, as this init function is triggered by a BufNew event,
  -- see plugin/chatter.lua.
  do
    local filename = vim.api.nvim_buf_get_name(original_buf)
    if filename == "chatter://prompt" then
      vim.cmd.bunload({ args = { original_buf }, bang = true })
    end
  end

  local mcp = Buffer.new("chatter://mcp", { split = "above", height = 7 })
  mcp:modifiable(false)
  mcp:set_win_option("winbar", "%#QuickFixLine# MCP messages")
  vim.cmd("match Property /./")

  -- Set the current window back to the history window to create the prompt window
  vim.api.nvim_set_current_win(history:get_winid())

  -- Create input window (bottom)
  local prompt = Buffer.new("chatter://prompt", { split = "below", height = 7 })
  prompt:set_buf_option("filetype", "markdown")
  prompt:modifiable(true)
  prompt:append("\n")
  prompt:set_win_option("winbar", "%#QuickFixLine# Prompt")

  local spinner = require("chatter.spinner").new(
    vim.schedule_wrap(function(spinner) on_spin(history, spinner) end),
    vim.schedule_wrap(function() on_stop(history) end)
  )

  local chat_client = require("chatter.chat_client")

  local ok, err = chat_client.start({
    command = config.command,
    on_exit = function(_, code)
      if code ~= 0 then
        prompt:append_error(string.format(
          "💥 chat server exited with exit code %d.\nSee above MCP messages window for details.", code))
        prompt:modifiable(false)
        vim.cmd.stopinsert()
      end
    end,
    on_stderr = function(_, data)
      if data then
        utils.remove_trailing_empty_lines(data)
        mcp:append_lines(data)
      end
    end
  })

  if not ok then
    prompt:append_error("💥 error starting chat client: " .. err)
    return false
  end

  ---@type chatter.UI
  local self = setmetatable({
    chat_client = chat_client,
    completion_req = completion_req,
    history = history,
    prompt = prompt,
    spinner = spinner,
  }, { __index = UI })

  self:setup_keymaps()

  initialized = true

  return true
end

return {
  init = init,
}
