local Buffer = require("chatter.buffer")

---@class (exact) chatter.UI
local UI = {}

local function new()
  -- Create output window (top)
  local output_buf = Buffer.new()

  -- Create input window (bottom)
  local input_buf = vim.api.nvim_create_buf(false, true)
  local width, input_height = vim.o.columns, 5
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = width,
    height = input_height,
    row = vim.o.lines - input_height,
    col = 0,
    style = "minimal",
    border = "none",
    anchor = "SW",
  })
  local opts = { scope = "local", buf = input_buf }
  vim.api.nvim_set_option_value("buftype", "nofile", opts)
  vim.api.nvim_set_option_value("filetype", "chatter_input", opts)
  vim.api.nvim_set_option_value("modifiable", true, opts)
  vim.api.nvim_set_option_value("swapfile", false, opts)

  opts = { scope = "local", win = input_win }
  vim.api.nvim_set_option_value("number", false, opts)
  vim.api.nvim_set_option_value("relativenumber", false, opts)

  return {
    output = output_buf,
    input_buf = input_buf,
    input_win = input_win,
  }
end

return {
  new = new,
}
