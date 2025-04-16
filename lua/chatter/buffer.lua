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
  -- set_buf_opt(buf, 'bufhidden', 'wipe')
  set_buf_opt(buf, 'buflisted', true)
  set_buf_opt(buf, 'buftype', 'nofile')
  set_buf_opt(buf, 'modified', false)
  set_buf_opt(buf, 'swapfile', false)

  api.nvim_buf_set_var(buf, 'disable_jump_to_last_position', true)

  set_local_opt('cmdheight', 1)
  set_local_opt('concealcursor', 'n')
  set_local_opt('fillchars', 'eob: ')
  -- set_local_opt('hidden', true)
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

--- Append lines to the buffer
---@param lines string[] The lines to append
function M:append_lines(lines)
  local state = internal_state(self)

  self:modifiable(true)

  if state.spinner then
    state.spinner:stop()
  end

  vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, lines)

  self:modifiable(false)

  -- Make the cursor follow the text if the window is not focused
  if vim.api.nvim_get_current_win() ~= state.win then
    vim.api.nvim_buf_call(state.buf, function()
      vim.cmd [[normal! G]]
    end)
  end
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

  self:modifiable(false)

  -- Make the cursor follow the text if the window is not focused
  if vim.api.nvim_get_current_win() ~= state.win then
    vim.api.nvim_buf_call(state.buf, function()
      vim.cmd [[normal! G]]
    end)
  end
end

--- Append an error message to the buffer.
---@param text string The error message to append
function M:append_error(text)
  self:append("\n\n```\n" .. text .. "\n```")
end

function M:get_state()
  return _internal_state
end

function M:clear()
  local modifiable = vim.api.nvim_get_option_value('modifiable', { buf = self:get_buf() })
  self:modifiable(true)
  api.nvim_buf_set_lines(self:get_buf(), 0, -1, false, {})
  self:modifiable(modifiable)
end

--- Get the buffer associated with the Buffer
---@return number buf The buffer ID
function M:get_buf()
  return internal_state(self).buf
end

--- Get the window associated with the Buffer
---@return number win The window ID
function M:get_win()
  return internal_state(self).win
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

function M:set_buf_option(name, value)
  local state = internal_state(self)
  local opts = { buf = state.buf }
  api.nvim_set_option_value(name, value, opts)
end

function M:set_win_option(name, value)
  local state = internal_state(self)
  local opts = { win = state.win }
  api.nvim_set_option_value(name, value, opts)
end

--- Create a new chatter.Buffer instance
---@param name string The name of the buffer
---@param opts? vim.api.keyset.win_config Table defining the window configuration
---@return chatter.Buffer
local function new(name, opts)
  ---@type chatter.Buffer
  local self = setmetatable({}, { __index = M })

  -- local buf = api.nvim_get_current_buf()
  -- local win = api.nvim_get_current_win()
  local buf = api.nvim_create_buf(true, true)

  api.nvim_buf_set_name(buf, name)

  opts = vim.tbl_deep_extend("force", { win = 0 }, opts or {})

  local win = vim.api.nvim_open_win(buf, true, opts)

  ---@type chatter.BufferState
  local state = {
    buf = buf,
    win = win,
    lines = {},
    spinner = Spinner.new(buf)
  }

  _internal_state[self] = state

  api.nvim_buf_set_lines(buf, 0, -1, false, {})
  api.nvim_win_set_cursor(win, { 1, 0 })

  set_options(buf)

  return self
end

return {
  new = new,
}
