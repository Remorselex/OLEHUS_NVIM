-- The branches popup, IntelliJ's Git Branches: recent, local and remote branches; how each
-- stands against its upstream; and what to do with the one under the cursor.
-- The current branch is marked with ● and bold, a gone upstream says "gone": shape, not colour.
local git = require("vcs.git")
local output = require("vcs.output")
local float = require("vcs.float")
local when = require("vcs.when")
local ask = require("vcs.ask")
local worktree = require("vcs.worktree")

local M = {}

local RECENT_COUNT = 5
-- a remote with more branches than this starts folded
local FOLD_REMOTE_OVER = 15
local NAME_WIDTH_MAX = 40
local UPSTREAM_WIDTH_MAX = 32

-- folded remotes per repository, kept while nvim runs
local folded_by_root = {}

local FORMAT = "--format=%(refname)%1f%(objectname:short)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(committerdate:unix)%1f%(HEAD)%1f%(subject)"

local function shorten_middle(text, width)
  local length = vim.fn.strchars(text)
  if length <= width then
    return text
  end
  local head = math.ceil((width - 1) / 2)
  return vim.fn.strcharpart(text, 0, head) .. "…" .. vim.fn.strcharpart(text, length - (width - 1 - head))
end

local function pad(text, width)
  return text .. string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0))
end

local function remote_of(refname, remotes)
  local rest = refname:gsub("^refs/remotes/", "")
  local best
  for _, remote in ipairs(remotes) do
    if vim.startswith(rest, remote .. "/") and (not best or #remote > #best) then
      best = remote
    end
  end
  if not best then
    return nil
  end
  return best, rest:sub(#best + 2)
end

local function load(root)
  local remotes = git.remotes(root)
  local ok, stdout = git.run_sync(root, { "for-each-ref", FORMAT, "refs/heads", "refs/remotes" })
  local data = { locals = {}, remotes = {}, remote_names = remotes, current = nil }
  for line in (ok and stdout or ""):gmatch("[^\n]+") do
    local refname, short, upstream, track, time, head, subject = unpack(vim.split(line, "\31", { plain = true }))
    local item = { short = short, time = tonumber(time) or 0, subject = subject or "" }
    if vim.startswith(refname, "refs/heads/") then
      item.kind, item.name = "local", refname:sub(#"refs/heads/" + 1)
      item.track = git.parse_track(track or "")
      item.upstream = upstream ~= "" and upstream or nil
      item.current = head == "*"
      data.locals[#data.locals + 1] = item
      if item.current then
        data.current = item
      end
    else
      local remote, branch = remote_of(refname, remotes)
      -- origin/HEAD only says which branch is the default one
      if remote and branch ~= "HEAD" then
        item.kind, item.remote, item.branch, item.name = "remote", remote, branch, remote .. "/" .. branch
        data.remotes[remote] = data.remotes[remote] or {}
        table.insert(data.remotes[remote], item)
      end
    end
  end
  local by_name = {}
  for _, item in ipairs(data.locals) do
    by_name[item.name] = item
  end
  -- a branch checked out in another worktree can't be switched to here: it is gone to instead
  for _, tree in ipairs(worktree.list(root)) do
    local item = tree.branch and by_name[tree.branch]
    if item and not item.current then
      item.worktree = tree
    end
  end
  -- recent: where `git checkout` / `git switch` went, newest first
  local _, reflog = git.run_sync(root, { "reflog", "-n", "300", "--format=%gs" })
  data.recent, data.by_name = {}, by_name
  local seen = {}
  for target in reflog:gmatch("checkout: moving from %S+ to (%S+)") do
    local item = by_name[target]
    if item and not item.current and not seen[target] then
      seen[target] = true
      data.recent[#data.recent + 1] = item
      if #data.recent == RECENT_COUNT then
        break
      end
    end
  end
  table.sort(data.locals, function(left, right)
    return left.name:lower() < right.name:lower()
  end)
  for _, list in pairs(data.remotes) do
    table.sort(list, function(left, right)
      return left.name:lower() < right.name:lower()
    end)
  end
  return data
end

local function track_text(item)
  if not item.upstream then
    return ""
  end
  if item.track.gone then
    return "gone"
  end
  local parts = {}
  if item.track.ahead > 0 then
    parts[#parts + 1] = "↑" .. item.track.ahead
  end
  if item.track.behind > 0 then
    parts[#parts + 1] = "↓" .. item.track.behind
  end
  return table.concat(parts, " ")
end

local function matches(item, filter)
  return filter == "" or item.name:lower():find(filter:lower(), 1, true) ~= nil
end

local function build(state)
  local data, filter = state.data, state.filter
  local lines, marks, items = {}, {}, {}
  local function add(text, group, item)
    lines[#lines + 1] = text
    if group then
      marks[#marks + 1] = { #lines - 1, 0, #text, group }
    end
    items[#lines] = item
  end

  local name_width = 10
  for _, item in ipairs(data.locals) do
    name_width = math.max(name_width, vim.fn.strdisplaywidth(item.name))
  end
  for _, list in pairs(data.remotes) do
    for _, item in ipairs(list) do
      name_width = math.max(name_width, vim.fn.strdisplaywidth(item.name))
    end
  end
  name_width = math.min(name_width, NAME_WIDTH_MAX)
  local upstream_width = 0
  for _, item in ipairs(data.locals) do
    upstream_width = math.max(upstream_width, vim.fn.strdisplaywidth(item.upstream or ""))
  end
  upstream_width = math.min(upstream_width, UPSTREAM_WIDTH_MAX)
  local worktree_width = 0
  for _, item in ipairs(data.locals) do
    if item.worktree then
      worktree_width = math.max(worktree_width, vim.fn.strdisplaywidth("  wt:" .. vim.fs.basename(item.worktree.path)))
    end
  end

  local function branch_row(item)
    local marker = item.current and "● " or "  "
    local name = pad(shorten_middle(item.name, name_width), name_width)
    local columns = "  " .. marker .. name
    local name_end = #columns
    if item.kind == "local" then
      columns = columns .. "  " .. pad(track_text(item), 8) .. "  " .. pad(shorten_middle(item.upstream or "", upstream_width), upstream_width)
    end
    local worktree_label = item.worktree and ("  wt:" .. vim.fs.basename(item.worktree.path)) or ""
    local worktree_start = #columns
    if item.kind == "local" then
      columns = columns .. pad(worktree_label, worktree_width)
    end
    local date_start = #columns + 2
    local text = columns .. "  " .. when.relative(item.time)
    lines[#lines + 1] = text
    items[#lines] = item
    local row = #lines - 1
    if item.worktree then
      marks[#marks + 1] = { row, worktree_start + 2, worktree_start + #worktree_label, "VcsLogFilter" }
    end
    local name_group = item.current and "VcsBranchCurrent" or (item.kind == "remote" and "VcsLogRemote" or nil)
    if name_group then
      marks[#marks + 1] = { row, 2 + #marker, name_end, name_group }
    end
    if item.current then
      marks[#marks + 1] = { row, 2, 2 + #marker, "VcsBranchCurrent" }
    end
    if item.kind == "local" and item.track and item.track.gone then
      marks[#marks + 1] = { row, name_end + 2, name_end + 6, "VcsLogWarning" }
    end
    marks[#marks + 1] = { row, date_start, #text, "VcsCount" }
  end

  local current = data.current
  local head_text = current and ("on " .. current.name .. (track_text(current) ~= "" and ("  " .. track_text(current)) or "")) or "HEAD is detached"
  add(" " .. head_text, "VcsBranch")
  if filter ~= "" then
    add((" filter: %s   / change · Backspace clear"):format(filter), "VcsHint")
  end
  add("")

  local recent = vim.tbl_filter(function(item)
    return matches(item, filter)
  end, data.recent)
  if #recent > 0 then
    add(" Recent", "VcsGroup")
    for _, item in ipairs(recent) do
      branch_row(item)
    end
  end
  local locals = vim.tbl_filter(function(item)
    return matches(item, filter)
  end, data.locals)
  add((" Local · %d"):format(#locals), "VcsGroup")
  for _, item in ipairs(locals) do
    branch_row(item)
  end
  local remote_names = vim.tbl_keys(data.remotes)
  table.sort(remote_names)
  for _, remote in ipairs(remote_names) do
    local list = vim.tbl_filter(function(item)
      return matches(item, filter)
    end, data.remotes[remote])
    local folded = filter == "" and state.folded[remote]
    if folded == nil then
      folded = #list > FOLD_REMOTE_OVER
    end
    add((" %s Remote · %s · %d"):format(folded and "▸" or "▾", remote, #list), "VcsGroup", { kind = "section", remote = remote, folded = folded })
    if not folded then
      for _, item in ipairs(list) do
        branch_row(item)
      end
    end
  end
  add("")
  add(" Enter checkout · n new branch from · m merge into current · r rebase current onto · R rename", "VcsHint")
  add(" d delete · c / C compare · l log · p push · u update · w worktree · f fetch · / filter · q close", "VcsHint")
  return lines, marks, items
end

-- the cursor starts on the current branch, or on the first branch when HEAD is detached
local function first_branch_line(items)
  local lines = vim.tbl_keys(items)
  table.sort(lines)
  local fallback
  for _, line in ipairs(lines) do
    local item = items[line]
    if item.current then
      return line
    end
    if item.kind ~= "section" then
      fallback = fallback or line
    end
  end
  return fallback
end

local function after_change(state)
  return function()
    state.data = load(state.context.root)
    state.view.refresh()
    state.context.refresh()
  end
end

local function run(state, args, success_message, failure_title, on_failure)
  git.queue(state.context.root, args, function(ok, stdout, stderr)
    if ok then
      if success_message then
        vim.notify(success_message, vim.log.levels.INFO, { title = "Git" })
      end
    elseif not (on_failure and on_failure(stdout, stderr)) then
      output.show(state.context.tab, failure_title, stdout .. "\n" .. stderr)
    end
    after_change(state)()
  end)
end

local function input(state, prompt, default, on_answer)
  state.view.ask(function(done)
    vim.ui.input({ prompt = prompt, default = default }, function(answer)
      done()
      answer = answer and vim.trim(answer)
      if answer and answer ~= "" then
        on_answer(answer)
      end
    end)
  end)
end

local function confirm(state, question, label, on_confirmed)
  state.view.ask(function(done)
    ask(question, label, function()
      done()
      on_confirmed()
    end, done)
  end)
end

-- each step only after the previous one worked: a pop after a failed stash would bring back
-- somebody's older stash instead
local function stash_and_switch(state, args, label)
  local root, tab = state.context.root, state.context.tab
  local stash_args = { "stash", "push", "--include-untracked", "-m", "vcs: switching to " .. label }
  git.queue(root, stash_args, function(stashed, stash_stdout, stash_stderr)
    if not stashed then
      output.show(tab, "Could not stash the changes", stash_stdout .. "\n" .. stash_stderr)
      return after_change(state)()
    end
    local nothing_stashed = stash_stdout:match("No local changes to save") ~= nil
    git.queue(root, args, function(switched, switch_stdout, switch_stderr)
      if not switched then
        output.show(tab, "Checkout failed — your changes are in the stash (git stash list)", switch_stdout .. "\n" .. switch_stderr)
        return after_change(state)()
      end
      if nothing_stashed then
        vim.notify("Switched to " .. label, vim.log.levels.INFO, { title = "Git" })
        return after_change(state)()
      end
      git.queue(root, { "stash", "pop" }, function(popped, pop_stdout, pop_stderr)
        if popped then
          vim.notify("Switched to " .. label .. ", local changes are back", vim.log.levels.INFO, { title = "Git" })
        else
          output.show(tab, "Switched, but the changes came back with conflicts — resolve them; the stash is kept (git stash list)", pop_stdout .. "\n" .. pop_stderr, vim.log.levels.WARN)
        end
        after_change(state)()
      end)
    end)
  end)
end

-- checkout that keeps local changes out of the way when they collide with the target branch,
-- like IntelliJ's smart checkout: stash, switch, bring the changes back
local function switch(state, args, label)
  run(state, args, "Switched to " .. label, "Checkout failed", function(_, stderr)
    if not (stderr:match("would be overwritten") or stderr:match("commit your changes or stash them")) then
      return false
    end
    vim.schedule(function()
      confirm(state, ("Local changes collide with %s. Stash them, switch, and bring them back?"):format(label), "Stash and switch", function()
        stash_and_switch(state, args, label)
      end)
    end)
    return true
  end)
end

-- git refuses to check out a branch that another worktree holds: offer to go there instead
local function offer_worktree(state, item)
  local tree = item.worktree
  confirm(state, ("%s is checked out in the worktree %s. Go there?"):format(item.name, vim.fs.basename(tree.path)), "Go to the worktree", function()
    state.view.close()
    worktree.go_to(tree)
  end)
end

local function checkout(state, item)
  if item.kind == "local" then
    if item.current then
      vim.notify("Already on " .. item.name, vim.log.levels.INFO, { title = "Git" })
      return
    end
    if item.worktree then
      return offer_worktree(state, item)
    end
    return switch(state, { "switch", item.name }, item.name)
  end
  local existing = state.data.by_name[item.branch]
  if existing and existing.worktree then
    return offer_worktree(state, existing)
  end
  if existing then
    -- the local branch of that name is the one to work on; it may lag behind the remote one
    local note = existing.upstream == item.name and "" or (" (it tracks " .. (existing.upstream or "nothing") .. ")")
    if existing.current then
      vim.notify("Already on " .. existing.name .. note, vim.log.levels.INFO, { title = "Git" })
      return
    end
    return switch(state, { "switch", existing.name }, existing.name .. note)
  end
  switch(state, { "switch", "--track", item.name }, item.branch .. " (new, tracks " .. item.name .. ")")
end

local function current_name(state)
  return state.data.current and state.data.current.name or "HEAD"
end

local function delete(state, item)
  if item.kind == "local" then
    if item.current then
      vim.notify("Can't delete the branch you are on", vim.log.levels.WARN, { title = "Git" })
      return
    end
    return confirm(state, ("Delete the local branch %s?"):format(item.name), "Delete", function()
      run(state, { "branch", "-d", item.name }, "Deleted " .. item.name, "Could not delete " .. item.name, function(_, stderr)
        if not stderr:match("not fully merged") then
          return false
        end
        vim.schedule(function()
          confirm(state, ("%s has commits that are in no other branch. Delete it anyway? They stay reachable only through the reflog"):format(item.name), "Delete anyway", function()
            run(state, { "branch", "-D", item.name }, "Deleted " .. item.name, "Could not delete " .. item.name)
          end)
        end)
        return true
      end)
    end)
  end
  confirm(state, ("Delete %s on the remote %s? Everyone loses it"):format(item.branch, item.remote), "Delete on remote", function()
    run(state, { "push", item.remote, "--delete", item.branch }, ("Deleted %s on %s"):format(item.branch, item.remote), "Could not delete the remote branch")
  end)
end

local function update_branch(state, item)
  if item.kind ~= "local" then
    vim.notify("Update a local branch, or fetch (f) to refresh the remote ones", vim.log.levels.INFO, { title = "Git" })
    return
  end
  if item.current then
    state.view.close()
    return require("vcs.update").run(state.context)
  end
  if not item.upstream then
    vim.notify(item.name .. " has no upstream to update from", vim.log.levels.WARN, { title = "Git" })
    return
  end
  -- a branch that is not checked out can be moved by fetch itself, fast-forward only
  local remote, remote_branch = remote_of("refs/remotes/" .. item.upstream, state.data.remote_names)
  run(state, { "fetch", remote, remote_branch .. ":" .. item.name }, ("Updated %s from %s"):format(item.name, item.upstream), "Could not update " .. item.name .. " (only a fast-forward is possible without checking it out)")
end

local function open_log(state, options)
  state.view.close()
  require("vcs.log").open(state.context.root, options)
end

--- context: { root, tab, refresh(), set_busy(text) } — see push.lua.
function M.open(context)
  local state = { context = context, filter = "" }
  folded_by_root[context.root] = folded_by_root[context.root] or {}
  state.folded = folded_by_root[context.root]
  state.data = load(context.root)
  local function on_branch(action)
    return function(item)
      if item and item.kind ~= "section" then
        action(item)
      end
    end
  end
  state.view = float.open({
    title = " Branches ",
    min_width = 70,
    build = function()
      return build(state)
    end,
    first_line = first_branch_line,
    item_navigation = true,
    keys = {
      { "<CR>", function(item)
        if not item then
          return
        end
        if item.kind == "section" then
          state.folded[item.remote] = not item.folded
          return state.view.refresh()
        end
        checkout(state, item)
      end, "Checkout / fold" },
      { "l", function(item)
        if item and item.kind == "section" then
          state.folded[item.remote] = false
          return state.view.refresh()
        end
        if item then
          open_log(state, { scope = item.name })
        end
      end, "Show in the Log / unfold" },
      { "h", function(item)
        if item and item.kind == "section" then
          state.folded[item.remote] = true
          state.view.refresh()
        end
      end, "Fold" },
      { "n", function(item)
        local start = item and item.kind ~= "section" and item.name or current_name(state)
        local default = item and item.kind == "remote" and item.branch or ""
        input(state, ("New branch from %s: "):format(start), default, function(name)
          switch(state, { "switch", "-c", name, start }, name)
        end)
      end, "New branch from this one" },
      { "m", on_branch(function(item)
        confirm(state, ("Merge %s into %s?"):format(item.name, current_name(state)), "Merge", function()
          run(state, { "merge", item.name }, ("Merged %s into %s"):format(item.name, current_name(state)), "Merge stopped — resolve the conflicts, then M → Continue in the VCS window")
        end)
      end), "Merge into the current branch" },
      { "r", on_branch(function(item)
        confirm(state, ("Rebase %s onto %s?"):format(current_name(state), item.name), "Rebase", function()
          run(state, { "rebase", "--autostash", item.name }, ("Rebased %s onto %s"):format(current_name(state), item.name), "Rebase stopped — resolve the conflicts, then M → Continue in the VCS window")
        end)
      end), "Rebase the current branch onto this one" },
      { "R", on_branch(function(item)
        if item.kind ~= "local" then
          vim.notify("Only a local branch can be renamed", vim.log.levels.WARN, { title = "Git" })
          return
        end
        input(state, ("Rename %s to: "):format(item.name), item.name, function(name)
          run(state, { "branch", "-m", item.name, name }, ("Renamed %s → %s"):format(item.name, name), "Could not rename " .. item.name)
        end)
      end), "Rename" },
      { "d", on_branch(function(item)
        delete(state, item)
      end), "Delete" },
      { "c", on_branch(function(item)
        open_log(state, { scope = current_name(state) .. ".." .. item.name, title = ("in %s, not in %s"):format(item.name, current_name(state)) })
      end), "Commits it has that the current branch doesn't" },
      { "C", on_branch(function(item)
        open_log(state, { scope = item.name .. ".." .. current_name(state), title = ("in %s, not in %s"):format(current_name(state), item.name) })
      end), "Commits the current branch has that it doesn't" },
      { "p", on_branch(function(item)
        if item.kind ~= "local" then
          vim.notify("Push a local branch", vim.log.levels.WARN, { title = "Git" })
          return
        end
        state.view.close()
        require("vcs.push").open(context, item.name)
      end), "Push" },
      { "u", on_branch(function(item)
        update_branch(state, item)
      end), "Update from its upstream" },
      { "w", on_branch(function(item)
        local target = item.kind == "remote" and (state.data.by_name[item.branch] or item) or item
        if target.current then
          vim.notify(target.name .. " is checked out right here", vim.log.levels.INFO, { title = "Git" })
          return
        end
        state.view.close()
        if target.worktree then
          return worktree.go_to(target.worktree)
        end
        worktree.create(context, target.kind, target.name)
      end), "Open in a worktree: go to its one, or create one" },
      { "f", function()
        vim.notify("Fetching all remotes…", vim.log.levels.INFO, { title = "Git" })
        run(state, { "fetch", "--all", "--prune" }, "Fetched", "Fetch failed")
      end, "Fetch all remotes" },
      { "/", function()
        input(state, "Filter branches: ", state.filter, function(text)
          state.filter = text
          state.view.refresh({ reset_cursor = true })
        end)
      end, "Filter" },
      { "<BS>", function()
        state.filter = ""
        state.view.refresh({ reset_cursor = true })
      end, "Clear the filter" },
    },
  })
end

return M
