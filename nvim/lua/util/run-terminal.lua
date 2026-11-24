-- The Run button's window (Space r c / r b / r t, cargo and CMake alike). In terminal mode the first key
-- pressed after the process ends deletes the buffer together with its output, so trying to scroll it
-- threw it away. Here a finished run drops to normal mode: j/k, Ctrl-u/d, gg, / and y work as in any
-- buffer, q hides the window and Space r o brings it back.
local M = {}

-- 10 000 by default: a pretty-printed {:#?} dump of a whole API response runs past that
local SCROLLBACK_LINES = 100000

local last_run ---@type snacks.win?

local function still_running(terminal)
  local job = vim.bo[terminal.buf].channel
  return job > 0 and vim.fn.jobwait({ job }, 0)[1] == -1
end

---@param command string
---@param cwd string
---@param keep_open boolean? false: the window closes by itself when the command succeeds
function M.open(command, cwd, keep_open)
  -- snacks keeps one terminal per command: without this a second run would only show the
  -- previous, already finished one with its old output instead of building again
  local previous = Snacks.terminal.get(command, { cwd = cwd, create = false })
  if previous then
    previous:close()
  end
  local terminal = Snacks.terminal.open(command, { cwd = cwd, auto_close = not keep_open, auto_insert = false })
  vim.bo[terminal.buf].scrollback = SCROLLBACK_LINES
  terminal:on("TermClose", function()
    if vim.api.nvim_get_current_buf() == terminal.buf then
      vim.cmd.stopinsert()
    end
  end, { buf = true })
  last_run = terminal
end

function M.toggle_last()
  if last_run == nil or not last_run:buf_valid() then
    return vim.notify("Nothing has been run yet", vim.log.levels.INFO)
  end
  last_run:toggle()
  -- showing the window starts terminal mode again, where a finished run would die on the next key
  if last_run:win_valid() and not still_running(last_run) then
    vim.cmd.stopinsert()
  end
end

return M
