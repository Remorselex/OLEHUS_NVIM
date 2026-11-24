-- Worktrees, as in IntelliJ's Git → Worktrees and the zsh wt / wt-add / wt-rm: a branch lives in
-- its own directory next to the main tree (monoNew-master), and you go there instead of switching.
-- In nvim "going there" is a tab with a tab-local directory (:tcd): pickers, the file explorer and
-- the VCS window of that tab belong to the worktree, the other tabs stay where they were.
local git = require("vcs.git")
local output = require("vcs.output")
local float = require("vcs.float")
local ask = require("vcs.ask")

local M = {}

local function same_path(left, right)
  return (vim.uv.fs_realpath(left) or left) == (vim.uv.fs_realpath(right) or right)
end

local function home_relative(path)
  return vim.fn.fnamemodify(path, ":~")
end

--- `git worktree list --porcelain -z` → { path, head, branch, detached, bare, locked, prunable, main }.
function M.parse(stdout)
  local worktrees, current = {}, nil
  for field in vim.gsplit(stdout, "\0", { plain = true }) do
    if field == "" then
      if current then
        worktrees[#worktrees + 1] = current
        current = nil
      end
    else
      local key, value = field:match("^(%S+) ?(.*)$")
      if key == "worktree" then
        current = { path = value }
      elseif current and key == "HEAD" then
        current.head = value
      elseif current and key == "branch" then
        current.branch = (value:gsub("^refs/heads/", ""))
      elseif current and key == "detached" then
        current.detached = true
      elseif current and key == "bare" then
        current.bare = true
      elseif current and key == "locked" then
        current.locked = value ~= "" and value or true
      elseif current and key == "prunable" then
        current.prunable = value ~= "" and value or true
      end
    end
  end
  if current then
    worktrees[#worktrees + 1] = current
  end
  if worktrees[1] then
    -- git lists the main working tree first
    worktrees[1].main = true
  end
  return worktrees
end

function M.list(root)
  local ok, stdout = git.run_sync(root, { "worktree", "list", "--porcelain", "-z" })
  return ok and M.parse(stdout) or {}
end

--- The worktree (other than `root` itself) where `branch` is checked out, if any.
function M.holding(root, branch, worktrees)
  for _, worktree in ipairs(worktrees or M.list(root)) do
    if worktree.branch == branch and not same_path(worktree.path, root) then
      return worktree
    end
  end
end

--- Like wt-add: next to the main tree, named after the branch — monoNew-feature-login.
function M.default_path(root, branch)
  local ok, common = git.run_sync(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  local main_root = ok and vim.fs.dirname(vim.trim(common)) or root
  return main_root .. "-" .. branch:gsub("[/%s]", "-")
end

--- The tab of the worktree: the one whose tab-local directory it already is, or a new one.
function M.go_to(worktree)
  local path = worktree.path
  if vim.fn.isdirectory(path) == 0 then
    vim.notify("The directory of this worktree is gone: " .. home_relative(path) .. " — p prunes it", vim.log.levels.WARN, { title = "Git" })
    return
  end
  -- a tab made for this worktree first; then any editor tab already working in it — the first tab
  -- of a session started in the main tree is one, though its directory is the global one
  local fallback
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local number = vim.api.nvim_tabpage_get_number(tab)
    if same_path(vim.fn.getcwd(-1, number), path) then
      if vim.fn.haslocaldir(-1, number) == 1 then
        vim.api.nvim_set_current_tabpage(tab)
        return
      end
      local buffer = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab))
      if not fallback and not vim.startswith(vim.api.nvim_buf_get_name(buffer), "vcs://") then
        fallback = tab
      end
    end
  end
  if fallback then
    vim.api.nvim_set_current_tabpage(fallback)
    return
  end
  vim.cmd("tabnew")
  vim.bo.bufhidden = "wipe"
  vim.cmd.tcd(vim.fn.fnameescape(path))
  local label = worktree.branch and ("[" .. worktree.branch .. "]") or ("detached " .. (worktree.head or ""):sub(1, 8))
  vim.notify(("Worktree %s %s — this tab works in %s"):format(vim.fs.basename(path), label, home_relative(path)), vim.log.levels.INFO, { title = "Git" })
  -- a worktree is entered to work on its files: start from them
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    snacks.picker.files({ cwd = path })
  end
end

-- tabs and buffers of a removed worktree point at files that are gone: close what holds no edits
local function forget(path)
  local real = vim.uv.fs_realpath(path) or path
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local number = vim.api.nvim_tabpage_get_number(tab)
    if #vim.api.nvim_list_tabpages() > 1 and vim.fn.haslocaldir(-1, number) == 1 and same_path(vim.fn.getcwd(-1, number), real) then
      pcall(vim.cmd, number .. "tabclose")
    end
  end
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if name ~= "" and vim.startswith(name, path .. "/") and not vim.bo[buffer].modified then
      pcall(vim.api.nvim_buf_delete, buffer, {})
    end
  end
end

-- ---------------------------------------------------------------- the popup

local function track_counts(root)
  local ok, stdout = git.run_sync(root, { "for-each-ref", "--format=%(refname:short)%1f%(upstream:track,nobracket)", "refs/heads" })
  local counts = {}
  for line in (ok and stdout or ""):gmatch("[^\n]+") do
    local name, track = unpack(vim.split(line, "\31", { plain = true }))
    counts[name] = git.parse_track(track or "")
  end
  return counts
end

local function pad(text, width)
  return text .. string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0))
end

local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, width - 1) .. "…"
end

local function load(state)
  state.worktrees = M.list(state.context.root)
  state.counts = track_counts(state.context.root)
  state.generation = (state.generation or 0) + 1
  local generation = state.generation
  -- uncommitted changes per worktree: a status each, so it arrives a moment later
  for _, worktree in ipairs(state.worktrees) do
    if not worktree.bare and vim.fn.isdirectory(worktree.path) == 1 then
      git.run(worktree.path, { "status", "--porcelain", "--untracked-files=no" }, function(ok, stdout)
        if generation ~= state.generation then
          return
        end
        local count = 0
        for _ in stdout:gmatch("[^\n]+") do
          count = count + 1
        end
        worktree.changes = ok and count or nil
        if state.view then
          state.view.refresh()
        end
      end)
    end
  end
end

local function build(state)
  local lines, marks, items = {}, {}, {}
  local function add(text, group)
    lines[#lines + 1] = text
    if group then
      marks[#marks + 1] = { #lines - 1, 0, #text, group }
    end
  end
  add(" " .. #state.worktrees .. " worktree" .. (#state.worktrees == 1 and "" or "s") .. " of " .. vim.fs.basename(state.worktrees[1] and state.worktrees[1].path or state.context.root), "VcsBranch")
  add("")

  local name_width, branch_width = 8, 8
  for _, worktree in ipairs(state.worktrees) do
    name_width = math.max(name_width, vim.fn.strdisplaywidth(vim.fs.basename(worktree.path)))
    branch_width = math.max(branch_width, vim.fn.strdisplaywidth(worktree.branch or "detached 12345678") + 2)
  end
  name_width, branch_width = math.min(name_width, 36), math.min(branch_width, 44)

  local any_prunable = false
  for _, worktree in ipairs(state.worktrees) do
    local here = same_path(worktree.path, state.context.root)
    local marker = here and "● " or "  "
    local branch = worktree.branch and ("[" .. worktree.branch .. "]") or (worktree.bare and "bare" or ("detached " .. (worktree.head or ""):sub(1, 8)))
    local counts = worktree.branch and state.counts[worktree.branch]
    local track = ""
    if counts and counts.gone then
      track = "gone"
    elseif counts then
      track = vim.trim((counts.ahead > 0 and ("↑" .. counts.ahead .. " ") or "") .. (counts.behind > 0 and ("↓" .. counts.behind) or ""))
    end
    local changes = worktree.prunable and "missing" or (worktree.changes == nil and "…" or (worktree.changes == 0 and "clean" or (worktree.changes .. " changed")))
    local flags = {}
    if worktree.main then
      flags[#flags + 1] = "main"
    end
    if worktree.locked then
      flags[#flags + 1] = "locked"
    end
    local name = truncate(vim.fs.basename(worktree.path), name_width)
    local prefix = "  " .. marker
    local text = prefix .. pad(name, name_width) .. "  "
    local branch_start = #text
    text = text .. pad(truncate(branch, branch_width), branch_width) .. "  "
    local branch_end = branch_start + #truncate(branch, branch_width)
    text = text .. pad(track, 7) .. "  "
    local changes_start = #text
    text = text .. pad(changes, 10) .. "  "
    local path_start = #text
    text = text .. home_relative(worktree.path) .. (#flags > 0 and ("  (" .. table.concat(flags, ", ") .. ")") or "")
    lines[#lines + 1] = text
    items[#lines] = worktree
    local row = #lines - 1
    if here then
      marks[#marks + 1] = { row, 2, #prefix + #name, "VcsBranchCurrent" }
    end
    marks[#marks + 1] = { row, branch_start, branch_end, worktree.branch and "VcsLogBranch" or "VcsCount" }
    if worktree.prunable or (worktree.changes or 0) > 0 then
      marks[#marks + 1] = { row, changes_start, changes_start + #changes, "VcsLogWarning" }
    end
    marks[#marks + 1] = { row, path_start, #text, "VcsCount" }
    any_prunable = any_prunable or worktree.prunable ~= nil
  end
  add("")
  add(" Enter go to (its own tab) · n new · d remove · g VCS window · l log · y copy path", "VcsHint")
  add(" L lock / unlock · p prune" .. (any_prunable and " (a directory is missing)" or "") .. " · R refresh · q close", "VcsHint")
  return lines, marks, items
end

local function current_line(items)
  local lines = vim.tbl_keys(items)
  table.sort(lines)
  return lines[1]
end

local function refresh_all(state)
  load(state)
  state.view.refresh()
  state.context.refresh()
end

local function run(state, args, success, failure_title, on_failure)
  git.queue(state.context.root, args, function(ok, stdout, stderr)
    if ok then
      if success then
        success(stdout)
      end
    elseif not (on_failure and on_failure(stdout, stderr)) then
      output.show(state.context.tab, failure_title, stdout .. "\n" .. stderr)
    end
    if state.view then
      refresh_all(state)
    end
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

--- Create a worktree for `branch`. kind: "local" — an existing branch; "remote" — a remote branch
--- that gets a local tracking branch; "new" — a new branch from `start`.
function M.create(context, kind, branch, start, after)
  local root = context.root
  local local_name = kind == "remote" and branch:gsub("^[^/]+/", "") or branch
  vim.ui.input({ prompt = "Directory for the worktree: ", default = M.default_path(root, local_name), completion = "dir" }, function(path)
    path = path and vim.trim(path)
    if not path or path == "" then
      return after and after(false)
    end
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", "")
    local args
    if kind == "new" then
      args = { "worktree", "add", "-b", branch, path, start or "HEAD" }
    elseif kind == "remote" then
      args = { "worktree", "add", "--track", "-b", local_name, path, branch }
    else
      args = { "worktree", "add", path, branch }
    end
    git.queue(root, args, function(ok, stdout, stderr)
      if not ok then
        output.show(context.tab, "Could not create the worktree", stdout .. "\n" .. stderr)
        return after and after(false)
      end
      vim.notify(("Created the worktree %s for %s"):format(vim.fs.basename(path), local_name), vim.log.levels.INFO, { title = "Git" })
      context.refresh()
      if after then
        after(true)
      end
      M.go_to({ path = path, branch = local_name })
    end)
  end)
end

local function create_flow(state)
  local root = state.context.root
  local worktrees = state.worktrees
  local busy = {}
  for _, worktree in ipairs(worktrees) do
    if worktree.branch then
      busy[worktree.branch] = true
    end
  end
  local ok, stdout = git.run_sync(root, { "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes" })
  local choices, kinds = { "New branch from the current one…" }, { "new" }
  local locals = {}
  for refname in (ok and stdout or ""):gmatch("[^\n]+") do
    local name = refname:match("^refs/heads/(.+)$")
    if name then
      locals[name] = true
      if not busy[name] then
        choices[#choices + 1], kinds[#kinds + 1] = name, "local"
      end
    end
  end
  for refname in (ok and stdout or ""):gmatch("[^\n]+") do
    local name = refname:match("^refs/remotes/(.+)$")
    -- a remote branch is offered when no local branch of that name exists yet
    if name and not name:match("/HEAD$") and not locals[name:gsub("^[^/]+/", "")] then
      choices[#choices + 1], kinds[#kinds + 1] = name, "remote"
    end
  end
  state.view.ask(function(done)
    vim.ui.select(choices, { prompt = "Worktree for (branches not checked out anywhere)" }, function(choice, index)
      if not choice then
        return done()
      end
      local kind = kinds[index]
      if kind ~= "new" then
        state.view.close()
        return M.create(state.context, kind, choice)
      end
      vim.ui.input({ prompt = "New branch: " }, function(name)
        name = name and vim.trim(name)
        if not name or name == "" then
          return done()
        end
        state.view.close()
        M.create(state.context, "new", name, "HEAD")
      end)
    end)
  end)
end

local function remove(state, worktree)
  if worktree.main then
    vim.notify("The main worktree holds the repository itself: it can't be removed", vim.log.levels.WARN, { title = "Git" })
    return
  end
  if same_path(worktree.path, state.context.root) then
    vim.notify("You are in this worktree: go to another one first (Enter on it)", vim.log.levels.WARN, { title = "Git" })
    return
  end
  local name = vim.fs.basename(worktree.path)
  local keeps = worktree.branch and (", the branch " .. worktree.branch .. " stays") or ""
  confirm(state, ("Remove the worktree %s? Its directory is deleted%s"):format(name, keeps), "Remove", function()
    run(state, { "worktree", "remove", worktree.path }, function()
      forget(worktree.path)
      vim.notify("Removed the worktree " .. name, vim.log.levels.INFO, { title = "Git" })
    end, "Could not remove " .. name, function(_, stderr)
      if not stderr:match("modified or untracked files") then
        return false
      end
      vim.schedule(function()
        confirm(state, ("%s has uncommitted changes. Remove it anyway? The changes are lost"):format(name), "Remove anyway", function()
          run(state, { "worktree", "remove", "--force", worktree.path }, function()
            forget(worktree.path)
            vim.notify("Removed the worktree " .. name, vim.log.levels.INFO, { title = "Git" })
          end, "Could not remove " .. name)
        end)
      end)
      return true
    end)
  end)
end

--- context: { root, tab, refresh(), set_busy(text) } — see push.lua.
function M.open(context)
  local state = { context = context }
  load(state)
  local function on_worktree(action)
    return function(worktree)
      if worktree then
        action(worktree)
      end
    end
  end
  state.view = float.open({
    title = " Worktrees ",
    min_width = 80,
    build = function()
      return build(state)
    end,
    first_line = current_line,
    item_navigation = true,
    on_close = function()
      state.generation = (state.generation or 0) + 1
      state.view = nil
    end,
    keys = {
      { "<CR>", on_worktree(function(worktree)
        if same_path(worktree.path, context.root) then
          vim.notify("You are in this worktree", vim.log.levels.INFO, { title = "Git" })
          return
        end
        state.view.close()
        M.go_to(worktree)
      end), "Go to the worktree (its own tab)" },
      { "n", function()
        create_flow(state)
      end, "New worktree" },
      { "d", on_worktree(function(worktree)
        remove(state, worktree)
      end), "Remove" },
      { "g", on_worktree(function(worktree)
        state.view.close()
        require("vcs").open_root(worktree.path)
      end), "VCS window of the worktree" },
      { "l", on_worktree(function(worktree)
        state.view.close()
        require("vcs.log").open(worktree.path)
      end), "Log of the worktree" },
      { "y", on_worktree(function(worktree)
        vim.fn.setreg('"', worktree.path)
        pcall(vim.fn.setreg, "+", worktree.path)
        vim.notify("Copied " .. worktree.path, vim.log.levels.INFO, { title = "Git" })
      end), "Copy the path" },
      { "L", on_worktree(function(worktree)
        if worktree.main then
          vim.notify("The main worktree can't be locked", vim.log.levels.WARN, { title = "Git" })
          return
        end
        local verb = worktree.locked and "unlock" or "lock"
        run(state, { "worktree", verb, worktree.path }, function()
          vim.notify(("%sed %s"):format(verb:sub(1, 1):upper() .. verb:sub(2), vim.fs.basename(worktree.path)), vim.log.levels.INFO, { title = "Git" })
        end, "Could not " .. verb .. " the worktree")
      end), "Lock / unlock (prune leaves a locked one alone)" },
      { "p", function()
        run(state, { "worktree", "prune", "--verbose" }, function(stdout)
          local pruned = vim.trim(stdout)
          vim.notify(pruned ~= "" and pruned or "Nothing to prune: every worktree directory is in place", vim.log.levels.INFO, { title = "Git" })
        end, "Prune failed")
      end, "Prune worktrees whose directory is gone" },
      { "R", function()
        load(state)
        state.view.refresh()
      end, "Refresh" },
    },
  })
end

return M
