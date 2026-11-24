-- Running git for the VCS window. Everything is asynchronous: in a big repository status takes
-- a noticeable while, and typing must not wait for it.
local M = {}

local ENVIRONMENT = {
  -- there is nowhere to ask for a password: better fail than hang
  GIT_TERMINAL_PROMPT = "0",
  GIT_EDITOR = "true",
  -- status doesn't take index.lock and doesn't disturb a git running next to it
  GIT_OPTIONAL_LOCKS = "0",
}

local function command(root, args)
  -- --literal-pathspecs: a file name with an asterisk or brackets is a name, not a pattern
  local prefix = { "git", "--literal-pathspecs", "-C", root, "-c", "core.quotepath=false", "-c", "color.ui=never" }
  return vim.list_extend(prefix, args)
end

--- on_done(ok, stdout, stderr) runs on the main loop.
--- options.stdin — a string fed to the process.
function M.run(root, args, on_done, options)
  options = options or {}
  vim.system(command(root, args), { text = true, env = ENVIRONMENT, stdin = options.stdin }, function(result)
    vim.schedule(function()
      on_done(result.code == 0, result.stdout or "", result.stderr or "")
    end)
  end)
end

function M.run_sync(root, args)
  local result = vim.system(command(root, args), { text = true, env = ENVIRONMENT }):wait()
  return result.code == 0, result.stdout or "", result.stderr or ""
end

-- Commands that change the index or history run one at a time per repository:
-- two git add from quick key presses would otherwise fight over index.lock.
local queues = {}

local function run_next(root)
  local queue = queues[root]
  local item = table.remove(queue.items, 1)
  queue.running = item ~= nil
  if not item then
    return
  end
  M.run(root, item.args, function(...)
    item.on_done(...)
    run_next(root)
  end, item.options)
end

function M.queue(root, args, on_done, options)
  queues[root] = queues[root] or { items = {} }
  table.insert(queues[root].items, { args = args, on_done = on_done, options = options })
  if not queues[root].running then
    run_next(root)
  end
end

--- Paths go through stdin, NUL-separated: no command-line length limit and no trouble
--- with spaces or newlines in names.
function M.run_with_paths(root, args, paths, on_done)
  local full_args = vim.list_extend(vim.deepcopy(args), { "--pathspec-from-file=-", "--pathspec-file-nul" })
  M.queue(root, full_args, on_done, { stdin = table.concat(paths, "\0") })
end

function M.root_of(path)
  local directory = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  if vim.fn.isdirectory(directory) == 0 then
    return nil
  end
  local result = vim.system({ "git", "-C", directory, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if result.code ~= 0 then
    return nil
  end
  return vim.trim(result.stdout)
end

--- The .git directory; in a worktree it is not a folder in the root but the path the .git file points to.
function M.git_dir(root)
  local ok, output = M.run_sync(root, { "rev-parse", "--absolute-git-dir" })
  return ok and vim.trim(output) or nil
end

--- The directory name of a linked worktree, nil for the main working tree.
function M.linked_worktree_name(root)
  local ok, dirs = M.run_sync(root, { "rev-parse", "--path-format=absolute", "--absolute-git-dir", "--git-common-dir" })
  if not ok then
    return nil
  end
  local git_dir, common_dir = unpack(vim.split(vim.trim(dirs), "\n", { plain = true }))
  if not common_dir or git_dir == common_dir then
    return nil
  end
  return vim.fs.basename(root)
end

--- `%(upstream:track,nobracket)` → { ahead, behind, gone }: "ahead 1, behind 2", "behind 3", "gone", "".
function M.parse_track(track)
  return {
    ahead = tonumber(track:match("ahead (%d+)")) or 0,
    behind = tonumber(track:match("behind (%d+)")) or 0,
    gone = track == "gone",
  }
end

--- The current branch against its upstream, shaped like status.branch:
--- { head = "main" | "(detached)", oid, upstream, ahead, behind, unborn }.
--- Reads refs only, so it is instant even where `git status` takes a while.
function M.branch_info(root, on_done)
  local format = "--format=%(HEAD)%1f%(refname:short)%1f%(objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)"
  M.run(root, { "for-each-ref", format, "refs/heads" }, function(_, stdout)
    for line in stdout:gmatch("[^\n]+") do
      local marker, name, oid, upstream, track = unpack(vim.split(line, "\31", { plain = true }))
      if marker == "*" then
        local counts = M.parse_track(track or "")
        return on_done({
          head = name,
          oid = oid,
          upstream = upstream ~= "" and not counts.gone and upstream or nil,
          ahead = counts.ahead,
          behind = counts.behind,
        })
      end
    end
    -- no branch is checked out: HEAD is detached, or the repository has no commits yet
    M.run(root, { "rev-parse", "--verify", "-q", "HEAD" }, function(has_head, head_oid)
      if has_head then
        return on_done({ head = "(detached)", oid = vim.trim(head_oid) })
      end
      local _, symbolic = M.run_sync(root, { "symbolic-ref", "--short", "-q", "HEAD" })
      on_done({ head = vim.trim(symbolic), unborn = true })
    end)
  end)
end

function M.remotes(root)
  local ok, stdout = M.run_sync(root, { "remote" })
  return ok and vim.split(vim.trim(stdout), "\n", { trimempty = true }) or {}
end

--- origin when there is one, otherwise the only (or first) remote.
function M.default_remote(root)
  local remotes = M.remotes(root)
  return vim.tbl_contains(remotes, "origin") and "origin" or remotes[1]
end

return M
