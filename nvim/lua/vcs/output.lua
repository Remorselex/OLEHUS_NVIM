-- What git said when something failed: a short answer goes to a notification, a long one
-- (pre-commit hooks, a rejected push, a rebase stopped on conflicts) to a split at the bottom.
local M = {}

function M.strip_terminal_colors(text)
  return (text:gsub("\27%[[%d;]*[mK]", ""))
end

--- tab — show the split only while this tab is current; nil shows it wherever the user is.
function M.show(tab, title, text, level)
  level = level or vim.log.levels.ERROR
  local lines = vim.split(vim.trim(M.strip_terminal_colors(text)), "\n", { plain = true })
  if #lines <= 4 then
    vim.notify(title .. "\n" .. table.concat(lines, "\n"), level, { title = "Git" })
    return
  end
  vim.notify(title .. " — the full output is in the split below", level, { title = "Git" })
  if tab and vim.api.nvim_get_current_tabpage() ~= tab then
    return
  end
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].bufhidden = "wipe"
  vim.cmd("botright " .. math.min(#lines, 15) .. "split")
  vim.api.nvim_win_set_buf(0, buffer)
  vim.wo.winbar = " " .. title:gsub("%%", "%%%%") .. "%=%#VcsHint#q close %*"
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buffer, nowait = true })
end

--- An on_done for git.run that reports a failure and then calls after(ok).
function M.reporter(tab, action, after)
  return function(ok, stdout, stderr)
    if not ok then
      M.show(tab, action, stdout .. "\n" .. stderr)
    end
    if after then
      after(ok, stdout, stderr)
    end
  end
end

return M
