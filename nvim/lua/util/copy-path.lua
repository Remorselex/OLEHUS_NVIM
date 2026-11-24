-- A counterpart of IDEA's "Copy Path/Reference…": put the current file's path on the
-- clipboard in one of several forms. There Cmd+Shift+C copies the absolute path and a separate
-- menu offers the other variants — same here.
local M = {}

local function project_root()
  local git_entry = vim.fs.find(".git", { upward = true, path = vim.fn.expand("%:p:h") })[1]
  return git_entry and vim.fs.dirname(git_entry) or vim.uv.cwd()
end

local function relative_to(path, root)
  if root and path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

-- Every form is computed lazily: for a file without a name some of them make no sense.
local function variants()
  local absolute = vim.fn.expand("%:p")
  if absolute == "" then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local root = project_root()

  return {
    { label = "absolute path", value = absolute },
    { label = "from the repository root", value = relative_to(absolute, root) },
    { label = "from the current directory", value = vim.fn.expand("%:.") },
    { label = "absolute path : line", value = absolute .. ":" .. line },
    { label = "from the repository root : line", value = relative_to(absolute, root) .. ":" .. line },
    { label = "file name", value = vim.fn.expand("%:t") },
    { label = "name without extension", value = vim.fn.expand("%:t:r") },
    { label = "file directory", value = vim.fn.expand("%:p:h") },
  }
end

local function put_in_clipboard(value)
  vim.fn.setreg("+", value)
  vim.fn.setreg('"', value)
  vim.notify(value)
end

-- The direct action, like Cmd+Shift+C in IDEA.
function M.absolute()
  local all = variants()
  if not all then
    return vim.notify("buffer has no file", vim.log.levels.WARN)
  end
  put_in_clipboard(all[1].value)
end

-- The menu of forms, like Cmd+Alt+Shift+C.
function M.pick()
  local all = variants()
  if not all then
    return vim.notify("buffer has no file", vim.log.levels.WARN)
  end
  vim.ui.select(all, {
    prompt = "Copy path:",
    format_item = function(item)
      -- %-30s counts bytes, not screen cells: pad by display width so any non-ASCII label still lines up
      local padding = string.rep(" ", math.max(1, 32 - vim.fn.strdisplaywidth(item.label)))
      return item.label .. padding .. item.value
    end,
  }, function(choice)
    if choice then
      put_in_clipboard(choice.value)
    end
  end)
end

vim.api.nvim_create_user_command("CopyPath", M.absolute, { desc = "Copy the file's absolute path to the clipboard" })
vim.api.nvim_create_user_command("CopyPathPick", M.pick, { desc = "Pick a path form and copy it" })

return M
