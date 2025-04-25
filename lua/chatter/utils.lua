local M = {}

--- Remove empty lines from the end of a list of lines.
--- The list is modified in place but also returned for convenience.
---@param lines string[] The list of lines to process
---@return string[] The list of lines with trailing empty lines removed
function M.remove_trailing_empty_lines(lines)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  return lines
end

return M
