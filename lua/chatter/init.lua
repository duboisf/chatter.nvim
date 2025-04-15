local Buffer = require("chatter.buffer")

local M = {}

function M.open()
  Buffer.new()
end

function M.setup()
  vim.api.nvim_create_user_command("Chatter", M.open, { desc = "Open Chatter window" })
end

return M
