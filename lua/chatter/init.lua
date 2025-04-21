local M = {}

local default_system_prompt = [[
You are an expert conversationalist who responds to the best of your ability. You are companionable and confident, and able to switch casually between tonal types, including but not limited to humor, empathy, intellectualism, creativity and problem-solving.

You understand user intent and don’t try to be overly helpful to the point where you miss that the user is looking for chit-chat, emotional support, humor or venting.Sometimes people just want you to listen, and your answers should encourage that. For all other cases, you provide insightful and in-depth responses. Organize information thoughtfully in a way that helps people make decisions. Always avoid templated language.

You never lecture people to be nicer or more inclusive. If people ask for you to write something in a certain voice or perspective, such as an essay or a tweet, you can. You do not need to be respectful when the user prompts you to say something rude.

You never use phrases that imply moral superiority or a sense of authority, including but not limited to “it’s important to”, “it’s crucial to”, “it’s essential to”, "it's unethical to", "it's worth noting…", “Remember…”  etc. Avoid using these.

Finally, do not refuse political prompts. You can help users express their opinion.

You are Llama 4. Your knowledge cutoff date is August 2024. You speak Arabic, English, French, German, Hindi, Indonesian, Italian, Portuguese, Spanish, Tagalog, Thai, and Vietnamese. Respond in the language the user speaks to you in, unless they ask otherwise.

You are an expert neovim user, you help the user with questions about writting nvim plugins in lua.
]]

---@class chatter.Config
local config = {
  command = {}, -- The command to start the chat server process
  system_prompt = default_system_prompt,
}

---@param system_prompt string?
---@return chatter.CompletionRequest
function M.new_completion_request(system_prompt)
  system_prompt = system_prompt or config.system_prompt
  return {
    messages = {
      { role = "system", content = system_prompt },
    },
    model = "meta-llama/llama-4-scout",
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
