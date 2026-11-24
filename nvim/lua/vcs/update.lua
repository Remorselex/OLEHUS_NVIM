-- Update Project, Ctrl+T in IntelliJ: fetch every remote, then bring the current branch up to
-- its upstream by merge or by rebase. Local changes are put aside and brought back (--autostash).
local git = require("vcs.git")
local output = require("vcs.output")
local settings = require("vcs.settings")

local M = {}

--- "merge" or "rebase": the choice from the `?` menu, otherwise what `git pull` would do.
function M.method(root)
  local chosen = settings.get("update_method")
  if chosen then
    return chosen
  end
  local ok, value = git.run_sync(root, { "config", "--get", "pull.rebase" })
  return (ok and vim.trim(value) ~= "" and vim.trim(value) ~= "false") and "rebase" or "merge"
end

local function plural(count, word)
  return ("%d %s%s"):format(count, word, count == 1 and "" or "s")
end

local function set_busy(context, text)
  if context.set_busy then
    context.set_busy(text)
  end
end

function M.run(context)
  local root = context.root
  set_busy(context, "fetching")
  git.run(root, { "fetch", "--all", "--prune" }, function(fetched, fetch_stdout, fetch_stderr)
    if not fetched then
      set_busy(context, nil)
      output.show(context.tab, "Fetch failed", fetch_stdout .. "\n" .. fetch_stderr)
      return
    end
    git.branch_info(root, function(branch)
      local function finish(message)
        set_busy(context, nil)
        vim.notify(message, vim.log.levels.INFO, { title = "Git" })
        context.refresh()
      end
      if branch.head == "(detached)" or branch.unborn then
        return finish("Fetched. HEAD is not on a branch: nothing to update")
      end
      if not branch.upstream then
        return finish(("Fetched. %s has no upstream to update from"):format(branch.head))
      end
      if branch.behind == 0 then
        local to_push = branch.ahead > 0 and (" · ↑%d to push"):format(branch.ahead) or ""
        return finish(("%s is up to date with %s%s"):format(branch.head, branch.upstream, to_push))
      end
      local method = M.method(root)
      set_busy(context, method == "rebase" and "rebasing" or "merging")
      git.queue(root, { method, "--autostash", "@{upstream}" }, function(updated, stdout, stderr)
        local text = stdout .. "\n" .. stderr
        if not updated then
          set_busy(context, nil)
          output.show(context.tab, ("Update stopped in the %s: resolve the conflicts, check the files, then M → Continue (or Abort)"):format(method), text)
          context.refresh()
          return
        end
        -- the update went through, but the stashed local changes did not apply cleanly
        if text:lower():match("autostash") and text:lower():match("conflict") then
          output.show(context.tab, "Updated, but your local changes came back with conflicts — the stash is kept (git stash list)", text, vim.log.levels.WARN)
        end
        git.run(root, { "diff", "--shortstat", branch.oid, "HEAD" }, function(_, shortstat)
          local summary = vim.trim(shortstat) ~= "" and (" · " .. vim.trim(shortstat)) or ""
          finish(("Updated %s from %s by %s: %s%s"):format(branch.head, branch.upstream, method, plural(branch.behind, "commit"), summary))
        end)
      end)
    end)
  end)
end

return M
