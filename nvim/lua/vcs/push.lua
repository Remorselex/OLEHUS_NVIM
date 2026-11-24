-- The push dialog, as in IntelliJ: which commits are about to leave and where they go.
-- Enter pushes, F pushes with --force-with-lease (after asking), t adds annotated tags.
--
-- A context is whatever shows the repository: { root, tab, refresh(), set_busy(text) };
-- the VCS state is one.
local git = require("vcs.git")
local output = require("vcs.output")
local float = require("vcs.float")
local when = require("vcs.when")
local ask = require("vcs.ask")

local M = {}

local OUTGOING_LIMIT = 100
local SUBJECT_WIDTH_MAX = 60

local function config_value(root, key)
  local ok, value = git.run_sync(root, { "config", "--get", key })
  return ok and vim.trim(value) or nil
end

--- Where `branch` goes: its upstream, or a new branch of the same name on the default remote.
local function plan_for(root, branch)
  local remote = config_value(root, "branch." .. branch .. ".remote")
  local merge = config_value(root, "branch." .. branch .. ".merge")
  if remote and remote ~= "." and merge then
    return { branch = branch, remote = remote, remote_branch = merge:gsub("^refs/heads/", ""), new = false }
  end
  remote = git.default_remote(root)
  if not remote then
    return nil
  end
  return { branch = branch, remote = remote, remote_branch = branch, new = true }
end

local function remote_messages(text)
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    local message = line:match("^remote:%s*(%S.*)$")
    if message then
      lines[#lines + 1] = message
    end
  end
  return lines
end

local function set_busy(context, text)
  if context.set_busy then
    context.set_busy(text)
  end
end

function M.run(context, plan, options)
  options = options or {}
  local args = { "push" }
  if options.force then
    args[#args + 1] = "--force-with-lease"
  end
  if options.tags then
    args[#args + 1] = "--follow-tags"
  end
  if plan.new then
    args[#args + 1] = "--set-upstream"
  end
  vim.list_extend(args, { plan.remote, plan.branch .. ":" .. plan.remote_branch })
  local target = plan.remote .. "/" .. plan.remote_branch
  set_busy(context, "pushing")
  -- not queued: push doesn't touch the index and must not hold up the checkboxes
  git.run(context.root, args, function(ok, stdout, stderr)
    set_busy(context, nil)
    local text = output.strip_terminal_colors(stdout .. "\n" .. stderr)
    if not ok then
      output.show(context.tab, "Push failed", text)
    else
      -- GitLab and GitHub send the merge request link in "remote:" lines
      local remote_lines = remote_messages(text)
      local details = #remote_lines > 0 and ("\n" .. table.concat(remote_lines, "\n")) or ""
      vim.notify(("Pushed %s → %s%s"):format(plan.branch, target, details), vim.log.levels.INFO, { title = "Git" })
    end
    context.refresh()
  end)
end

local function parse_commits(stdout)
  local commits = {}
  for line in stdout:gmatch("[^\n]+") do
    local short, subject, author, time = unpack(vim.split(line, "\31", { plain = true }))
    commits[#commits + 1] = { short = short, subject = subject or "", author = author or "", time = tonumber(time) or 0 }
  end
  return commits
end

local function build(plan, data, options)
  local lines, marks, items = {}, {}, {}
  local function add(text, group)
    lines[#lines + 1] = text
    if group then
      marks[#marks + 1] = { #lines - 1, 0, #text, group }
    end
  end
  local target = plan.remote .. "/" .. plan.remote_branch
  add((" %s → %s%s"):format(plan.branch, target, plan.new and "  (new branch)" or ""), "VcsBranch")
  add("")
  if #data.commits == 0 then
    add(plan.new and "  No commits of its own: the branch will be created at the same commit" or ("  Nothing to push: " .. target .. " already has everything"), "VcsHint")
  else
    local count = #data.commits >= OUTGOING_LIMIT and (OUTGOING_LIMIT .. "+") or tostring(#data.commits)
    add((" %s commit%s to push"):format(count, #data.commits == 1 and "" or "s"), "VcsGroup")
    local subject_width = 0
    for _, commit in ipairs(data.commits) do
      subject_width = math.max(subject_width, vim.fn.strdisplaywidth(commit.subject))
    end
    subject_width = math.min(subject_width, SUBJECT_WIDTH_MAX)
    for _, commit in ipairs(data.commits) do
      local meta = commit.author .. " · " .. when.short(commit.time)
      local subject = vim.fn.strdisplaywidth(commit.subject) > subject_width and (vim.fn.strcharpart(commit.subject, 0, subject_width - 1) .. "…") or commit.subject
      local text = ("   %s  %s"):format(commit.short, subject .. string.rep(" ", subject_width - vim.fn.strdisplaywidth(subject)))
      lines[#lines + 1] = text .. "   " .. meta
      marks[#marks + 1] = { #lines - 1, 3, 3 + #commit.short, "VcsLogHash" }
      marks[#marks + 1] = { #lines - 1, #text + 3, #lines[#lines], "VcsCount" }
    end
  end
  if data.behind > 0 then
    add("")
    add((" ↓ %d new commit%s on %s: the push will be rejected — update first (U)"):format(data.behind, data.behind == 1 and "" or "s", target), "VcsLogWarning")
  end
  add("")
  local hint = (" Enter push · F force with lease · t tags: %s · q cancel"):format(options.tags and "on" or "off")
  add(hint, "VcsHint")
  return lines, marks, items
end

--- Open the dialog for `branch` (a local branch name), or for the current branch.
function M.open(context, branch)
  git.branch_info(context.root, function(current)
    local name = branch or current.head
    if not branch and current.head == "(detached)" then
      vim.notify("HEAD is detached: there is no branch to push", vim.log.levels.WARN, { title = "Git" })
      return
    end
    if current.unborn then
      vim.notify("Nothing to push: there are no commits yet", vim.log.levels.WARN, { title = "Git" })
      return
    end
    local plan = plan_for(context.root, name)
    if not plan then
      vim.notify("No remote to push to", vim.log.levels.WARN, { title = "Git" })
      return
    end
    local log_args = { "log", "-n", tostring(OUTGOING_LIMIT), "--format=%h%x1f%s%x1f%an%x1f%at" }
    if plan.new then
      vim.list_extend(log_args, { name, "--not", "--remotes" })
    else
      local target = plan.remote .. "/" .. plan.remote_branch
      vim.list_extend(log_args, { target .. ".." .. name })
    end
    git.run(context.root, log_args, function(_, stdout)
      local data = { commits = parse_commits(stdout), behind = 0 }
      if not plan.new then
        local _, behind = git.run_sync(context.root, { "rev-list", "--count", name .. ".." .. plan.remote .. "/" .. plan.remote_branch })
        data.behind = tonumber(vim.trim(behind)) or 0
      end
      local options = { tags = false }
      local view
      view = float.open({
        title = " Push ",
        min_width = 60,
        build = function()
          return build(plan, data, options)
        end,
        keys = {
          { "<CR>", function()
            view.close()
            if #data.commits == 0 and not plan.new then
              return
            end
            M.run(context, plan, options)
          end, "Push" },
          { "F", function()
            view.ask(function(done)
              ask(("Force-push %s over %s/%s? Commits only on the remote are lost, unless someone pushed after your last fetch"):format(plan.branch, plan.remote, plan.remote_branch), "Force push", function()
                done()
                view.close()
                M.run(context, plan, vim.tbl_extend("force", options, { force = true }))
              end, done)
            end)
          end, "Force push (with lease)" },
          { "t", function()
            options.tags = not options.tags
            view.refresh()
          end, "Also push tags" },
        },
      })
    end)
  end)
end

return M
