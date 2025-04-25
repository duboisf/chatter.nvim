local function set_window_to_prompt()
  local prompt_bufnr = vim.fn.bufnr("chatter://prompt")
  if prompt_bufnr == -1 then return end
  local prompt_winid = vim.fn.bufwinid(prompt_bufnr)
  if prompt_winid == -1 then return end
  vim.api.nvim_set_current_win(prompt_winid)
  vim.cmd.startinsert()
end

vim.api.nvim_create_autocmd({ "BufEnter" }, {
  pattern = "chatter://prompt",
  callback = function()
    local ok, chatter = pcall(require, "chatter")
    if not ok then
      return
    end
    chatter.open()
    set_window_to_prompt()
  end,
  once = true,
})

vim.api.nvim_create_autocmd({ "UIEnter" }, {
  callback = set_window_to_prompt,
  once = true,
})
