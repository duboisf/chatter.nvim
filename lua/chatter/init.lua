local M = {}

---@class chatter.Config
local config = {
  command = {}, -- The command to start the chat server process
  system_prompt = "You are a helpful assistant.",
}

---@param system_prompt string?
---@return chatter.CompletionRequest
function M.new_completion_request(system_prompt)
  system_prompt = system_prompt or config.system_prompt
  return {
    messages = {
      { role = "system", content = system_prompt },
    },
    model = "meta-llama/llama-4-maverick:free",
  }
end

function M.open()
  local win = vim.api.nvim_get_current_win()
  local win_config = vim.api.nvim_win_get_config(win)
  if win_config.relative ~= "" then
    -- Don't open the window if the current window is a floating window
    vim.notify(
      "Chatter: current window is floating, refusing to open Chatter automatically.",
      vim.log.levels.INFO
    )
    return
  end

  if not config.command or #config.command == 0 then
    vim.notify("Chatter: No chat server cli command specified. Please set the command in your configuration.",
      vim.log.levels.ERROR)
    return
  end
  local ok, chat_client, err = require("chatter.chat_client").new(config.command)
  if not ok then
    vim.notify("Chatter: Failed to start chat client: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  assert(chat_client)
  local completion_req = M.new_completion_request()
  require("chatter.ui").init(chat_client, completion_req)
end

--- Setup function
---@param opts? chatter.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  vim.api.nvim_create_user_command("Chatter", M.open, { desc = "Open Chatter window" })
end

return M
