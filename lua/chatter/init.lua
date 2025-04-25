local M = {}

---@class chatter.Config
---@field command string[] The command to start the chat server process
---@return boolean success
local config = {}

--- Open the Chatter windows
---@return boolean success
function M.open()
  local win = vim.api.nvim_get_current_win()
  local win_config = vim.api.nvim_win_get_config(win)
  if win_config.relative ~= "" then
    -- Don't open the window if the current window is a floating window
    vim.notify(
      "Chatter: current window is floating, refusing to open Chatter automatically.",
      vim.log.levels.INFO
    )
    return false
  end

  if not config.command or #config.command == 0 then
    vim.notify("Chatter: No chat server cli command specified. Please set the command in your configuration.",
      vim.log.levels.ERROR)
    return false
  end
  local completion_req = { messages = {} }
  return require("chatter.ui").init(config, completion_req)
end

--- Setup function
---@param opts? chatter.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  vim.api.nvim_create_user_command("Chatter", M.open, { desc = "Open Chatter window" })
end

return M
