-- Copied from CopilotChat.nvim, modified heavily

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
---@field index number
---@field on_spin fun(spinner: string)
---@field on_stop fun()
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
function M:start()
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
    function()
      local frame = spinner_frames[state.index % #spinner_frames + 1]

      state.on_spin(frame)

      state.index = state.index % #spinner_frames + 1
    end
  )
end

function M:stop()
  local state = internal_state(self)

  if not state.timer then
    return
  end

  state.on_stop()
  state.timer:stop()
  state.timer:close()

  state.timer = nil
end

---Create a new spinner
---@param on_spin fun(spinner: string) The callback with the spinner string on each tick
---@param on_stop fun() The callback when the spinner stops
---@return chatter.Spinner # A new spinner instance
local function new(on_spin, on_stop)
  ---@type chatter.Spinner
  local self = setmetatable({}, { __index = M })

  ---@type chatter.SpinnerState
  local state = {
    on_spin = on_spin,
    on_stop = on_stop,
    index = 1,
    timer = nil,
  }

  _internal_state[self] = state

  return self
end

return {
  new = new,
}
