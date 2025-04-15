-- Copied from CopilotChat.nvim, modified heavily

local ns = vim.api.nvim_create_namespace('chatter.spinner')

local spinner_frames = {
  '⠋',
  '⠙',
  '⠹',
  '⠸',
  '⠼',
  '⠴',
  '⠦',
  '⠧',
  '⠇',
  '⠏',
}

---@class (exact) chatter.SpinnerState
---@field bufnr number
---@field index number
---@field timer uv.uv_timer_t?

---@class chatter.SpinneStateDict : { [chatter.Spinner]: chatter.SpinnerState? }
local _internal_state = setmetatable({}, {
  __mode = "k"
})

--- Return the state of the spinner
---@param self chatter.Spinner
---@return chatter.SpinnerState
local function internal_state(self)
  return assert(_internal_state[self], "Spinner state not initialized (should not happen)")
end

---@class (exact) chatter.Spinner
local M = {}

--- Start the spinner
--- @param self chatter.Spinner
--- @param status? string Optional status to display
function M:start(status)
  local state = internal_state(self)
  -- If the spinner is already running, it's a no-op
  if state.timer then
    return
  end

  local timer = assert(vim.uv.new_timer())

  state.timer = timer

  timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      local frame = spinner_frames[state.index % #spinner_frames + 1]

      if status then
        frame = status .. ' ' .. frame
      end

      vim.api.nvim_buf_set_extmark(state.bufnr, ns, math.max(0, vim.api.nvim_buf_line_count(state.bufnr) - 1), 0,
        {
          id = 1,
          hl_mode = 'combine',
          priority = 100,
          virt_text = {
            { frame, 'Comment' },
          },
        })

      state.index = state.index % #spinner_frames + 1
    end)
  )
end

function M:stop()
  local state = internal_state(self)

  if not state.timer then
    return
  end

  state.timer:stop()
  state.timer:close()

  state.timer = nil

  vim.api.nvim_buf_del_extmark(state.bufnr, ns, 1)
end

---Create a new spinner
---@param bufnr number The buffer number to attach the spinner to
---@return chatter.Spinner # A new spinner instance
local function new(bufnr)
  ---@type chatter.Spinner
  local self = setmetatable({}, { __index = M })

  ---@type chatter.SpinnerState
  local state = {
    bufnr = bufnr,
    index = 1,
    timer = nil,
  }

  _internal_state[self] = state

  return self
end

return {
  new = new,
}
