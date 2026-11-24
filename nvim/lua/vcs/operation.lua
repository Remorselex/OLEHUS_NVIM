-- An operation git left half-done: a rebase or merge stopped on conflicts, a cherry-pick or a
-- revert waiting to be finished. The panel names it in its bar; M offers continue / skip / abort.
local git = require("vcs.git")
local output = require("vcs.output")
local ask = require("vcs.ask")

local M = {}

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function read_number(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local number = tonumber(file:read("*l") or "")
  file:close()
  return number
end

--- { kind = "rebase" | "merge" | "cherry-pick" | "revert", label = "rebasing 2/5", can_skip, branch } or nil;
--- branch — for a rebase, the branch being rebuilt.
function M.detect(git_dir)
  if not git_dir then
    return nil
  end
  -- rebase-merge: the default backend; rebase-apply: the old one, `git am` too
  for _, layout in ipairs({ { "rebase-merge", "msgnum", "end" }, { "rebase-apply", "next", "last" } }) do
    local directory = vim.fs.joinpath(git_dir, layout[1])
    if exists(directory) then
      local done = read_number(vim.fs.joinpath(directory, layout[2]))
      local total = read_number(vim.fs.joinpath(directory, layout[3]))
      local label = (done and total) and ("rebasing %d/%d"):format(done, total) or "rebasing"
      -- HEAD is detached while git replays the commits; head-name says which branch it rebuilds
      local head_name = io.open(vim.fs.joinpath(directory, "head-name"), "r")
      local branch = head_name and vim.trim(head_name:read("*a")):gsub("^refs/heads/", "") or nil
      if head_name then
        head_name:close()
      end
      return { kind = "rebase", label = label, can_skip = true, branch = branch }
    end
  end
  if exists(vim.fs.joinpath(git_dir, "MERGE_HEAD")) then
    return { kind = "merge", label = "merging" }
  end
  if exists(vim.fs.joinpath(git_dir, "CHERRY_PICK_HEAD")) then
    return { kind = "cherry-pick", label = "cherry-picking", can_skip = true }
  end
  if exists(vim.fs.joinpath(git_dir, "REVERT_HEAD")) then
    return { kind = "revert", label = "reverting", can_skip = true }
  end
  return nil
end

local function run(context, operation, flag)
  git.queue(context.root, { operation.kind, flag }, function(ok, stdout, stderr)
    if not ok then
      output.show(context.tab, ("git %s %s did not finish"):format(operation.kind, flag), stdout .. "\n" .. stderr)
    elseif flag == "--abort" then
      vim.notify(("The %s is aborted: everything is as before it"):format(operation.kind), vim.log.levels.INFO, { title = "Git" })
    elseif not M.detect(context.git_dir) then
      vim.notify(("The %s is finished"):format(operation.kind), vim.log.levels.INFO, { title = "Git" })
    end
    context.refresh()
  end)
end

--- M in the panel: what to do with the operation in progress.
function M.menu(context)
  local operation = M.detect(context.git_dir)
  if not operation then
    vim.notify("No rebase, merge, cherry-pick or revert is in progress", vim.log.levels.INFO, { title = "Git" })
    return
  end
  local choices = { "Continue — the conflicts are resolved and checked" }
  if operation.can_skip then
    choices[#choices + 1] = "Skip — drop the commit that stopped"
  end
  choices[#choices + 1] = "Abort — go back to how it was before"
  vim.ui.select(choices, { prompt = "Git is " .. operation.label }, function(choice)
    if not choice then
      return
    end
    if vim.startswith(choice, "Continue") then
      return run(context, operation, "--continue")
    end
    if vim.startswith(choice, "Skip") then
      return run(context, operation, "--skip")
    end
    ask(("Abort the %s? Conflicts resolved so far are lost"):format(operation.kind), "Abort", function()
      run(context, operation, "--abort")
    end)
  end)
end

return M
