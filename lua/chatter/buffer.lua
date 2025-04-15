local Spinner = require("chatter.spinner")

local api = vim.api

local function set_buf_opt(buf, name, value)
  local opts = { buf = buf }
  api.nvim_set_option_value(name, value, opts)
end

local function set_local_opt(name, value)
  local opts = { scope = 'local' }
  api.nvim_set_option_value(name, value, opts)
end

local function set_options(buf)
  set_buf_opt(buf, 'bufhidden', 'wipe')
  set_buf_opt(buf, 'buftype', 'nofile')
  set_buf_opt(buf, 'filetype', 'markdown')
  set_buf_opt(buf, 'modified', false)
  set_buf_opt(buf, 'swapfile', false)

  api.nvim_buf_set_var(buf, 'disable_jump_to_last_position', true)

  set_local_opt('cmdheight', 0)
  set_local_opt('concealcursor', 'n')
  set_local_opt('fillchars', 'eob: ')
  set_local_opt('hidden', true)
  set_local_opt('number', false)
  set_local_opt('relativenumber', false)
  set_local_opt('showtabline', 0)
  set_local_opt('signcolumn', 'yes:1')
  set_local_opt('wrap', true)
  set_local_opt('laststatus', 0)
end

---@class (exact) chatter.BufferState
---@field buf number
---@field win number
---@field lines string[]
---@field spinner chatter.Spinner

---@class chatter.BufferStateDict : { [chatter.Buffer]: chatter.BufferState? }
local _internal_state = setmetatable({}, {
  __mode = "k"
})

--- Return the state of the Buffer
---@param self chatter.Buffer
---@return chatter.BufferState
local function internal_state(self)
  return assert(_internal_state[self], "Buffer state not initialized (should not happen)")
end

---@class (exact) chatter.Buffer
local M = {}

--- Set the buffer to be modifiable or not
---@param modifiable boolean Whether the buffer should be modifiable
function M:modifiable(modifiable)
  local state = internal_state(self)
  ---@type vim.api.keyset.option
  local opts = { buf = state.buf }
  api.nvim_set_option_value('modifiable', modifiable, opts)
  api.nvim_set_option_value('readonly', not modifiable, opts)
end

--- Get the end position of the buffer
--- @param self chatter.Buffer
--- @return number row
--- @return number col
local function get_end_pos(self)
  local state = internal_state(self)
  local buf = state.buf
  local last_line = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1]
  local row = vim.api.nvim_buf_line_count(buf) - 1 -- 0-based index for row
  local col = #last_line                           -- Length of the last line for column
  return row, col
end

--- Append text to the buffer
---@param text string The text to append
function M:append(text)
  local state = internal_state(self)

  self:modifiable(true)

  if state.spinner then
    state.spinner:stop()
  end

  local row, col = get_end_pos(self)
  local ok, err = pcall(vim.api.nvim_buf_set_text, state.buf, row, col, row, col, vim.split(text, "\n"))
  if not ok then
    error("Error appending text to buffer " .. state.buf .. ": " .. err)
  end

  -- Make the cursor follow the text
  local current_win = api.nvim_get_current_win()
  if current_win == state.win then
    row, col = get_end_pos(self)
    api.nvim_win_set_cursor(current_win, { row + 1, col + 1 })
  end

  self:modifiable(false)
end

--- Start the spinner with an optional status message
---@param text? string The status message to display
function M:start_spinner(text)
  local spinner = internal_state(self).spinner
  spinner:stop()
  spinner:start(text)
end

--- Stop the spinner
function M:stop_spinner()
  internal_state(self).spinner:stop()
end

--- Create a new chatter.Buffer instance
---@return chatter.Buffer
local function new()
  ---@type chatter.Buffer
  local self = setmetatable({}, { __index = M })

  local buf = api.nvim_create_buf(true, true)

  local width, height = vim.o.columns, vim.o.lines

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    hight = height,
    row = 0,
    col = 0,
    style = "minimal",
    border = "none",
  })

  ---@type chatter.BufferState
  local state = {
    buf = buf,
    win = win,
    lines = {},
    spinner = Spinner.new(buf)
  }

  _internal_state[self] = state

  set_options(buf)

  api.nvim_buf_set_lines(buf, 0, -1, false, {})
  api.nvim_win_set_cursor(win, { 1, 0 })

  self:modifiable(false)

  return self
end

return {
  new = new,
}
