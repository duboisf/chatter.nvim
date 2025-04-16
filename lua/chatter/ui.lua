local Buffer = require("chatter.buffer")

local initialized = false

---@class (exact) chatter.UI
---@field private chat_client chatter.ChatClient
---@field private completion_req chatter.CompletionRequest
---@field private history chatter.Buffer
---@field private prompt chatter.Buffer
local UI = {}

function UI:submit_prompt()
  local input_lines = vim.api.nvim_buf_get_lines(self.prompt:get_buf(), 0, -1, false)

  self.history:append("\n# User\n\n")
  for _, line in ipairs(input_lines) do
    self.history:append(line)
  end
  self.history:append("\n\n")

  vim.cmd.stopinsert()
  self.prompt:clear()

  local input_text = table.concat(input_lines, "\n")
  table.insert(self.completion_req.messages, { role = "user", content = input_text })

  self.history:append("# Assistant\n\n")
  self.history:start_spinner("Waiting for assistant...")

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
  history:set_win_option("winbar", "%#QuickFixLine# Chat history")

  -- Close original buffer
  vim.cmd.bunload({ args = { original_buf }, bang = true })

  -- Create input window (bottom)
  local prompt = Buffer.new("chatter://prompt", { split = "below", height = 7 })
  history:set_buf_option("filetype", "chatter")
  prompt:modifiable(true)
  prompt:set_win_option("winbar", "%#QuickFixLine# Prompt")

  ---@type chatter.UI
  local self = setmetatable({
    chat_client = chat_client,
    completion_req = completion_req,
    history = history,
    prompt = prompt,
  }, { __index = UI })

  self:setup_keymaps()

  initialized = true
end

return {
  init = init,
}
