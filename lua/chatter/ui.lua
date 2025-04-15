local Buffer = require("chatter.buffer")

-- TODO refator to be singleton

---@class (exact) chatter.UI
local UI = {}

--- Create a new UI instance
---@param chat_client chatter.ChatClient
---@param completion_req chatter.CompletionRequest
local function new(chat_client, completion_req)
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

  local self = setmetatable({}, { __index = UI })

  vim.keymap.set('i', '<C-CR>',
    function()
      history:get_buf()
      prompt:get_buf()
      local input_lines = vim.api.nvim_buf_get_lines(prompt:get_buf(), 0, -1, false)

      history:append("\n# User\n\n")
      for _, line in ipairs(input_lines) do
        history:append(line)
      end
      history:append("\n\n")

      vim.cmd.stopinsert()
      prompt:clear()

      local input_text = table.concat(input_lines, "\n")
      table.insert(completion_req.messages, { role = "user", content = input_text })

      history:append("# Assistant\n\n")
      history:start_spinner("Waiting for assistant...")

      local thread = coroutine.create(function()
        local stream_id, err = chat_client:request_completion(completion_req)
        if err then
          history:append("\n\nChat completion request error: " .. err)
          return
        elseif not stream_id then
          history:append("\n\nChat completion request failed, did not receive stream id")
          return
        end

        while true do
          local ok, result
          ok, result, err = chat_client:stream_chat(stream_id)

          if not ok then
            history:append("\n\nReceived error: " .. err)
            return
          elseif not result then
            history:append("\n\nNo result from server")
            return
          end

          if result.done then
            table.insert(completion_req.messages, { role = "assistant", content = result.response })
            break
          end

          history:append(result.response)
        end

        history:append("\n")
      end)

      coroutine.resume(thread)
    end,
    {
      buffer = prompt:get_buf(),
      noremap = true,
      silent = true,
    }
  )

  return self
end

return {
  new = new,
}
