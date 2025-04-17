local Buffer = require("chatter.buffer")

local history_winbar_prefix = "%#QuickFixLine# Chat history"
local initialized = false
local virtual_text_ns = vim.api.nvim_create_namespace("chatter")

---@class (exact) chatter.UI
---@field private chat_client chatter.ChatClient
---@field private completion_req chatter.CompletionRequest
---@field private history chatter.Buffer
---@field private prompt chatter.Buffer
---@field private spinner chatter.Spinner
local UI = {}

function UI:submit_prompt()
  local input_lines = vim.api.nvim_buf_get_lines(self.prompt:get_buf(), 0, -1, false)

  self.history:append("\n# User\n")
  self.history:append_lines(input_lines)
  self.history:append("\n\n")

  vim.cmd.stopinsert()
  self.prompt:clear()

  local input_text = table.concat(input_lines, "\n")
  table.insert(self.completion_req.messages, { role = "user", content = input_text })

  self.history:append("# Assistant\n\n")

  self.spinner:start()

  local thread = coroutine.create(function()
    local stream_id, err = self.chat_client:request_completion(self.completion_req)
    if err then
      self.history:append("\n\nChat completion request error: " .. err)
      return
    elseif not stream_id then
      self.history:append("\n\nChat completion request failed, did not receive stream id")
      return
    end

    while true do
      local ok, result
      ok, result, err = self.chat_client:stream_chat(stream_id)

      if not ok then
        self.history:append_error("💥 error from server: " .. err)
        return
      elseif not result then
        self.history:append_error("🤐 error from server: empty response")
        return
      end

      if result.done then
        table.insert(self.completion_req.messages, { role = "assistant", content = result.response })
        break
      end

      self.history:append(result.response)
    end

    self.history:append("\n")

    self:reset_spinner()
  end)

  coroutine.resume(thread)
end

function UI:setup_keymaps()
  vim.keymap.set({ 'i', 'n' }, '<C-CR>',
    function() self:submit_prompt() end,
    {
      buffer = self.prompt:get_buf(),
      noremap = true,
      silent = true,
    }
  )
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
---@param chat_client chatter.ChatClient
---@param completion_req chatter.CompletionRequest
local function init(chat_client, completion_req)
  if initialized then
    return
  end

  local original_buf = vim.api.nvim_get_current_buf()

  vim.treesitter.language.register("markdown", "chatter")

  -- Create output window (top)
  local history = Buffer.new("chatter://history", { split = "right" })
  history:modifiable(false)
  history:set_buf_option("filetype", "chatter")
  history:set_win_option("winbar", history_winbar_prefix)

  -- Close original buffer
  vim.cmd.bunload({ args = { original_buf }, bang = true })

  -- Create input window (bottom)
  local prompt = Buffer.new("chatter://prompt", { split = "below", height = 7 })
  history:set_buf_option("filetype", "chatter")
  prompt:modifiable(true)
  prompt:set_win_option("winbar", "%#QuickFixLine# Prompt")

  local spinner = require("chatter.spinner").new(
    vim.schedule_wrap(function(spinner) on_spin(history, spinner) end),
    vim.schedule_wrap(function() on_stop(history) end)
  )

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
end

return {
  init = init,
}
