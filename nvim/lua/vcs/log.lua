-- The Log tab, IntelliJ's Git Log: commits with the branch graph on top; bottom-left the files
-- of the selected commit and its message; bottom-right the diff of the file under the cursor.
-- Filters narrow the list: text (/), author (a), branch (b), path (f), date (d); F clears them.
-- History of a file or of selected lines is the same Log with a path or line filter.
--
-- The graph is git's own (`log --graph`) drawn with box characters. Meaning never rides on
-- colour alone: a branch label is [name], a remote one (origin/name), a tag <name>, the checked-out
-- branch is reversed, a merge commit is ◆ and an ordinary one ●.
local git = require("vcs.git")
local diff = require("vcs.diff")
local menu = require("vcs.menu")
local output = require("vcs.output")
local when = require("vcs.when")
local ask = require("vcs.ask")
local highlights = require("vcs.highlights")

local M = {}

-- one state per Log tab: [tabpage] = state
local states = {}

local PAGE = 300
-- more commits are fetched when the cursor gets this close to the end of the list
local PAGE_AHEAD = 25
local AUTHOR_WIDTH = 16
local DATE_WIDTH = 10
local LIST_SHARE = 0.42

local namespace = vim.api.nvim_create_namespace("vcs_log")
local details_namespace = vim.api.nvim_create_namespace("vcs_log_details")

local FIELD = "\31"
-- the leading separator splits the graph from the fields
local FORMAT = "--format=" .. table.concat({ "", "%H", "%h", "%P", "%an", "%ae", "%at", "%D", "%s" }, "%x1f")

local GRAPH_GLYPHS = { ["*"] = "●", ["|"] = "│", ["/"] = "╱", ["\\"] = "╲", ["-"] = "─", ["_"] = "_", ["."] = "·" }

local REF_STYLE = {
  head = { "[", "]", "VcsLogHead" },
  detached = { "[", "]", "VcsLogHead" },
  branch = { "[", "]", "VcsLogBranch" },
  remote = { "(", ")", "VcsLogRemote" },
  tag = { "<", ">", "VcsLogTag" },
}

local function window_valid(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:stop()
    handle:close()
  end
end

local function escape_statusline(text)
  return (text:gsub("%%", "%%%%"))
end

local function truncate(text, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(width - 1, 0)) .. "…"
end

local function pad(text, width)
  return text .. string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0))
end

-- ---------------------------------------------------------------- parsing

local function parse_refs(decorations)
  local refs = {}
  for part in vim.gsplit(decorations, ", ", { plain = true }) do
    local head_branch = part:match("^HEAD %-> refs/heads/(.+)$")
    if head_branch then
      refs[#refs + 1] = { kind = "head", name = head_branch }
    elseif part == "HEAD" then
      refs[#refs + 1] = { kind = "detached", name = "HEAD" }
    elseif part:match("^tag: refs/tags/") then
      refs[#refs + 1] = { kind = "tag", name = part:sub(#"tag: refs/tags/" + 1) }
    elseif part:match("^refs/heads/") then
      refs[#refs + 1] = { kind = "branch", name = part:sub(#"refs/heads/" + 1) }
    elseif part:match("^refs/remotes/") and not part:match("/HEAD$") then
      refs[#refs + 1] = { kind = "remote", name = part:sub(#"refs/remotes/" + 1) }
    end
    -- refs/stash and the like are not branches
  end
  -- as in IntelliJ: the checked-out branch, local branches, remote ones, tags
  local order = { head = 1, detached = 1, branch = 2, remote = 3, tag = 4 }
  table.sort(refs, function(left, right)
    if order[left.kind] ~= order[right.kind] then
      return order[left.kind] < order[right.kind]
    end
    return left.name < right.name
  end)
  -- origin/main next to main says only "the remote has it too": the remote name is enough
  local local_names = {}
  for _, ref in ipairs(refs) do
    if ref.kind == "head" or ref.kind == "branch" then
      local_names[ref.name] = true
    end
  end
  for _, ref in ipairs(refs) do
    local remote, branch = ref.name:match("^([^/]+)/(.+)$")
    if ref.kind == "remote" and branch and local_names[branch] then
      ref.name = remote
    end
  end
  return refs
end

--- Lines of `git log --graph` → rows: { graph, commit } for a commit, { graph } for a line of the
--- graph alone (where branches fork or join).
function M.parse(stdout)
  local rows, count = {}, 0
  for line in vim.gsplit(stdout, "\n", { plain = true }) do
    if line ~= "" then
      local graph, rest = line:match("^(.-)\31(.*)$")
      if graph then
        local hash, short, parents, author, email, time, decorations, subject = unpack(vim.split(rest, FIELD, { plain = true }))
        count = count + 1
        rows[#rows + 1] = {
          -- leading spaces are the lanes to the left: only the trailing ones go
          graph = (graph:gsub("%s+$", "")),
          commit = {
            hash = hash,
            short = short,
            parents = vim.split(parents or "", " ", { trimempty = true }),
            author = author or "",
            email = email or "",
            time = tonumber(time) or 0,
            refs = parse_refs(decorations or ""),
            subject = subject or "",
          },
        }
      elseif not line:match("^[%s%.]+$") then
        -- a line of dots marks history left out by --follow: nothing to read in it
        rows[#rows + 1] = { graph = (line:gsub("%s+$", "")) }
      end
    end
  end
  return rows, count
end

--- `git diff-tree --name-status -z` → { letter, path, old_path } sorted by path.
function M.parse_name_status(stdout)
  local tokens = vim.split(stdout, "\0", { plain = true })
  local files, index = {}, 1
  while index <= #tokens and tokens[index] ~= "" do
    local letter = tokens[index]:sub(1, 1)
    if letter == "R" or letter == "C" then
      files[#files + 1] = { letter = letter, old_path = tokens[index + 1], path = tokens[index + 2] }
      index = index + 3
    else
      files[#files + 1] = { letter = letter, path = tokens[index + 1] }
      index = index + 2
    end
  end
  table.sort(files, function(left, right)
    return left.path < right.path
  end)
  return files
end

local function draw_graph(graph, is_merge)
  return (graph:gsub("[%*|/\\%-_%.]", function(character)
    if character == "*" and is_merge then
      return "◆"
    end
    return GRAPH_GLYPHS[character]
  end))
end

-- ---------------------------------------------------------------- filters

local function scope_label(state)
  local filters = state.filters
  if filters.title then
    return filters.title
  end
  if filters.scope == "--all" then
    return "all branches"
  end
  return filters.scope or state.head_name or "HEAD"
end

local function filter_labels(state)
  local filters, labels = state.filters, {}
  if filters.text then
    labels[#labels + 1] = ("text “%s”"):format(filters.text)
  end
  if filters.author then
    labels[#labels + 1] = "author " .. (filters.author_label or filters.author)
  end
  if filters.lines then
    labels[#labels + 1] = ("lines %d–%d of %s"):format(filters.lines.first, filters.lines.last, filters.lines.path)
  elseif filters.path then
    labels[#labels + 1] = "path " .. filters.path
  end
  if filters.since then
    labels[#labels + 1] = "since " .. (filters.since_label or filters.since)
  end
  return labels
end

local function log_args(state)
  local filters = state.filters
  local args = { "log", "--graph", "--date-order", "--decorate=full", "-n", tostring(state.limit), FORMAT }
  if filters.author then
    args[#args + 1] = "--author=" .. filters.author
  end
  if filters.text then
    vim.list_extend(args, { "--grep=" .. filters.text, "--regexp-ignore-case", "--fixed-strings" })
  end
  if filters.since then
    args[#args + 1] = "--since=" .. filters.since
  end
  if filters.lines then
    -- -s: commits only; without it every commit carries its patch
    vim.list_extend(args, { ("-L%d,%d:%s"):format(filters.lines.first, filters.lines.last, filters.lines.path), "-s" })
  end
  if filters.scope == "--all" then
    args[#args + 1] = "--all"
  elseif filters.scope then
    args[#args + 1] = filters.scope
  end
  if filters.path and not filters.lines then
    -- --follow keeps the history of a file across renames; it works for one file only
    if filters.follow then
      args[#args + 1] = "--follow"
    end
    vim.list_extend(args, { "--", filters.path })
  end
  return args
end

-- ---------------------------------------------------------------- rendering the list

local function commit_line(state, row, width)
  local commit = row.commit
  local graph = draw_graph(row.graph, #commit.parents > 1)
  local text, marks = " " .. graph .. " ", {}
  marks[#marks + 1] = { 1, 1 + #graph, "VcsLogGraph" }
  -- plain find: a pattern class would match the first byte of any box character
  local node = graph:find("●", 1, true) or graph:find("◆", 1, true)
  if node then
    marks[#marks + 1] = { node, node + 3, "VcsLogNode" }
  end
  for _, ref in ipairs(commit.refs) do
    local style = REF_STYLE[ref.kind]
    local label = style[1] .. ref.name .. style[2]
    marks[#marks + 1] = { #text, #text + #label, style[3] }
    text = text .. label .. " "
  end
  local meta = pad(truncate(commit.author, AUTHOR_WIDTH), AUTHOR_WIDTH) .. "  " .. pad(when.short(commit.time), DATE_WIDTH)
  local room = width - vim.fn.strdisplaywidth(text) - vim.fn.strdisplaywidth(meta) - 2
  local subject = truncate(commit.subject, room)
  local subject_start = #text
  text = text .. subject
  if commit.hash == state.head_oid then
    marks[#marks + 1] = { subject_start, #text, "VcsLogHeadSubject" }
  end
  local gap = math.max(width - vim.fn.strdisplaywidth(text) - vim.fn.strdisplaywidth(meta) - 1, 1)
  text = text .. string.rep(" ", gap)
  marks[#marks + 1] = { #text, #text + #meta, "VcsCount" }
  return text .. meta, marks
end

local function set_list_winbar(state)
  if not window_valid(state.list.window) then
    return
  end
  local parts = { "%#VcsBranch# 󰜘 Log · " .. escape_statusline(scope_label(state)) .. "%*" }
  for _, label in ipairs(filter_labels(state)) do
    parts[#parts + 1] = "%#VcsLogFilter#" .. escape_statusline(label) .. "%*"
  end
  local tail
  if state.loading then
    tail = "loading…"
  else
    tail = ("%d%s commit%s"):format(state.commit_count, state.has_more and "+" or "", state.commit_count == 1 and "" or "s")
  end
  vim.wo[state.list.window].winbar = table.concat(parts, "  ") .. "%=%#VcsHint#" .. tail .. " · ? keys %*"
end

local function render_list(state)
  local buffer = state.list.buffer
  if not vim.api.nvim_buf_is_valid(buffer) or not window_valid(state.list.window) then
    return
  end
  local width = vim.api.nvim_win_get_width(state.list.window)
  local lines, all_marks = {}, {}
  for index, row in ipairs(state.rows) do
    if row.commit then
      local text, marks = commit_line(state, row, width)
      lines[index] = text
      for _, mark in ipairs(marks) do
        all_marks[#all_marks + 1] = { index - 1, mark[1], mark[2], mark[3] }
      end
    else
      local graph = draw_graph(row.graph, false)
      lines[index] = " " .. graph
      all_marks[#all_marks + 1] = { index - 1, 1, 1 + #graph, "VcsLogGraph" }
    end
  end
  if #lines == 0 then
    local message = state.loading and "  Reading the history…" or "  No commits match — F clears the filters"
    lines = { "", message }
    all_marks = { { 1, 0, #message, "VcsHint" } }
  end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  for _, mark in ipairs(all_marks) do
    vim.api.nvim_buf_set_extmark(buffer, namespace, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  set_list_winbar(state)
end

-- ---------------------------------------------------------------- selection

local function cursor_line(state)
  return window_valid(state.list.window) and vim.api.nvim_win_get_cursor(state.list.window)[1] or 1
end

--- The commit on the cursor line, or the nearest one above a line of the graph alone.
local function commit_at(state, line)
  for index = line, 1, -1 do
    local row = state.rows[index]
    if row and row.commit then
      return row.commit, index
    end
  end
  for index = line + 1, #state.rows do
    if state.rows[index].commit then
      return state.rows[index].commit, index
    end
  end
end

--- Commits under the visual selection (oldest first: the order to replay them), or the one at the cursor.
local function selected_commits(state)
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    local commit = commit_at(state, cursor_line(state))
    return commit and { commit } or {}
  end
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then
    first, last = last, first
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  local commits = {}
  for index = last, first, -1 do
    local row = state.rows[index]
    if row and row.commit then
      commits[#commits + 1] = row.commit
    end
  end
  return commits
end

local function line_of_hash(state, hash)
  for index, row in ipairs(state.rows) do
    if row.commit and row.commit.hash == hash then
      return index
    end
  end
end

-- ---------------------------------------------------------------- details: files and message

local LETTER_SUFFIX = { M = "M", A = "A", D = "D", R = "R", C = "R", T = "M", U = "Conflict" }

local function file_spec(commit, file)
  local parent = commit.parents[1]
  return {
    id = commit.hash .. ":" .. file.path,
    path = file.path,
    old_path = file.old_path or file.path,
    old_revision = (file.letter ~= "A" and parent) or nil,
    new_revision = file.letter ~= "D" and commit.hash or nil,
    old_label = parent and parent:sub(1, 8) or "empty",
    new_label = commit.short,
  }
end

local function file_at_cursor(state)
  if not window_valid(state.details.window) then
    return nil
  end
  return state.details.rows[vim.api.nvim_win_get_cursor(state.details.window)[1]]
end

local function show_file_diff(state, file, focus)
  local commit = state.details.commit
  if not (commit and file) then
    return
  end
  diff.show_revisions(state, file_spec(commit, file), { focus = focus })
end

local function render_details(state, commit, files, info)
  local buffer = state.details.buffer
  if not vim.api.nvim_buf_is_valid(buffer) then
    return
  end
  local lines, marks, rows = {}, {}, {}
  local function add(text, group)
    lines[#lines + 1] = text
    if group then
      marks[#marks + 1] = { #lines - 1, 0, #text, group }
    end
  end
  for _, file in ipairs(files) do
    local name, directory = vim.fs.basename(file.path), vim.fs.dirname(file.path)
    local text = (" %s  %s"):format(file.letter, name)
    local name_end = #text
    if directory ~= "." then
      text = text .. "  " .. directory
    end
    if file.old_path then
      local same_directory = vim.fs.dirname(file.old_path) == directory
      text = text .. "  ← " .. (same_directory and vim.fs.basename(file.old_path) or file.old_path)
    end
    lines[#lines + 1] = text
    rows[#lines] = file
    local suffix = LETTER_SUFFIX[file.letter] or highlights.SUFFIX[file.letter] or "M"
    marks[#marks + 1] = { #lines - 1, 1, 2, "VcsLetter" .. suffix }
    if file.letter == "D" then
      marks[#marks + 1] = { #lines - 1, 4, name_end, "VcsNameD" }
    end
    marks[#marks + 1] = { #lines - 1, name_end, #text, "VcsCount" }
  end
  if #files == 0 then
    add(" No file changes (an empty commit or a merge without conflicts)", "VcsHint")
  end
  add("")
  add(" " .. string.rep("─", 40), "VcsHint")
  -- short lines: the pane is narrow
  add((" %s  %s"):format(commit.short, commit.author))
  marks[#marks + 1] = { #lines - 1, 1, 1 + #commit.short, "VcsLogHash" }
  add((" %s · %s"):format(when.full(commit.time), commit.email), "VcsCount")
  if info.committer and (info.committer ~= commit.author or math.abs((info.commit_time or 0) - commit.time) > 60) then
    add((" committed by %s · %s"):format(info.committer, when.full(info.commit_time or commit.time)), "VcsCount")
  end
  if #commit.parents > 1 then
    local parents = vim.tbl_map(function(parent)
      return parent:sub(1, 8)
    end, commit.parents)
    add(" merge of " .. table.concat(parents, " + "), "VcsCount")
    add(" files: against the first parent", "VcsCount")
  end
  if #commit.refs > 0 then
    local text, ref_marks = " ", {}
    for _, ref in ipairs(commit.refs) do
      local style = REF_STYLE[ref.kind]
      local label = style[1] .. ref.name .. style[2]
      ref_marks[#ref_marks + 1] = { #text, #text + #label, style[3] }
      text = text .. label .. " "
    end
    add(text)
    for _, mark in ipairs(ref_marks) do
      marks[#marks + 1] = { #lines - 1, mark[1], mark[2], mark[3] }
    end
  end
  add("")
  local message = vim.split(vim.trim(info.message or commit.subject), "\n", { plain = true })
  for index, line in ipairs(message) do
    add(" " .. line, index == 1 and "VcsGroup" or nil)
  end

  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.api.nvim_buf_clear_namespace(buffer, details_namespace, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buffer, details_namespace, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  state.details.rows, state.details.commit = rows, commit
  if window_valid(state.details.window) then
    local count = #files
    vim.wo[state.details.window].winbar = ("%%#VcsBranch# %s%%*  %%#VcsHint#%d file%s%%*"):format(commit.short, count, count == 1 and "" or "s")
    vim.api.nvim_win_set_cursor(state.details.window, { 1, 0 })
  end
end

-- the diff shown as soon as a commit is selected: in a file's history that file,
-- otherwise the first file of the commit
local function file_of_interest(state, files)
  local wanted = state.filters.lines and state.filters.lines.path or (state.filters.follow and state.filters.path)
  for _, file in ipairs(wanted and files or {}) do
    if file.path == wanted or file.old_path == wanted then
      return file
    end
  end
  -- --follow walked past a rename: the file has another name in this commit
  return files[1]
end

local function load_details(state, commit)
  if state.details.requested == commit.hash then
    return
  end
  state.details.requested = commit.hash
  local parent = commit.parents[1]
  local files_args = parent and { "diff-tree", "-r", "-M", "--name-status", "-z", parent, commit.hash }
    or { "diff-tree", "-r", "-M", "--name-status", "-z", "--root", "--no-commit-id", commit.hash }
  local result = {}
  local pending = 2
  local function finished()
    pending = pending - 1
    if pending > 0 or state.closed or state.details.requested ~= commit.hash then
      return
    end
    local files = M.parse_name_status(result.files or "")
    render_details(state, commit, files, result.info)
    local file = file_of_interest(state, files)
    if not file then
      return diff.show_placeholder(state, { "", "  The commit changes no files", "", "  ? — keys and view options" })
    end
    for line, row in pairs(state.details.rows) do
      if row == file then
        vim.api.nvim_win_set_cursor(state.details.window, { line, 0 })
      end
    end
    show_file_diff(state, file, false)
  end
  git.run(state.root, files_args, function(_, stdout)
    result.files = stdout
    finished()
  end)
  git.run(state.root, { "show", "-s", "--format=%B%x1f%cn%x1f%ct", commit.hash }, function(_, stdout)
    local message, committer, commit_time = unpack(vim.split(stdout, FIELD, { plain = true }))
    result.info = { message = message, committer = committer and vim.trim(committer), commit_time = tonumber(commit_time and vim.trim(commit_time)) }
    finished()
  end)
end

-- ---------------------------------------------------------------- loading

local function load(state, options)
  options = options or {}
  state.generation = (state.generation or 0) + 1
  local generation = state.generation
  state.loading = true
  set_list_winbar(state)
  git.branch_info(state.root, function(branch)
    state.head_name = branch.head ~= "(detached)" and branch.head or nil
    state.head_oid = branch.oid
    git.run(state.root, log_args(state), function(ok, stdout, stderr)
      if state.closed or generation ~= state.generation then
        return
      end
      state.loading = false
      if not ok then
        state.rows, state.commit_count, state.has_more = {}, 0, false
        render_list(state)
        output.show(state.tab, "git log", stderr)
        return
      end
      local keep = options.keep_hash or state.selected
      state.rows, state.commit_count = M.parse(stdout)
      state.has_more = state.commit_count >= state.limit
      render_list(state)
      local line = (keep and line_of_hash(state, keep)) or select(2, commit_at(state, 1)) or 1
      if window_valid(state.list.window) then
        vim.api.nvim_win_set_cursor(state.list.window, { math.min(line, math.max(#state.rows, 1)), 0 })
      end
      local commit = commit_at(state, line)
      if commit then
        state.details.requested = nil
        state.selected = commit.hash
        load_details(state, commit)
      end
    end)
  end)
end

local function select_at_cursor(state)
  local line = cursor_line(state)
  local commit = commit_at(state, line)
  if commit and commit.hash ~= state.selected then
    state.selected = commit.hash
    load_details(state, commit)
  end
  if state.has_more and not state.loading and line > #state.rows - PAGE_AHEAD then
    state.limit = state.limit + PAGE
    load(state, { keep_hash = state.selected })
  end
end

-- ---------------------------------------------------------------- actions

local function context_refresh(state)
  -- the VCS window of the same repository follows too
  require("vcs").refresh_repository(state.root)
end

local function after_git(state, failure_title, success_message)
  return function(ok, stdout, stderr)
    if not ok then
      output.show(state.tab, failure_title, stdout .. "\n" .. stderr)
    elseif success_message then
      vim.notify(success_message, vim.log.levels.INFO, { title = "Git" })
    end
    context_refresh(state)
  end
end

local function copy_hash(state)
  local commit = commit_at(state, cursor_line(state))
  if not commit then
    return
  end
  vim.fn.setreg('"', commit.hash)
  pcall(vim.fn.setreg, "+", commit.hash)
  vim.notify("Copied " .. commit.hash, vim.log.levels.INFO, { title = "Git" })
end

local function cherry_pick(state)
  local commits = selected_commits(state)
  if #commits == 0 then
    return
  end
  local merges = vim.tbl_filter(function(commit)
    return #commit.parents > 1
  end, commits)
  if #merges > 0 and #commits > 1 then
    vim.notify("A merge commit can only be cherry-picked on its own", vim.log.levels.WARN, { title = "Git" })
    return
  end
  local hashes = vim.tbl_map(function(commit)
    return commit.hash
  end, commits)
  local what = #commits == 1 and (commits[1].short .. " " .. truncate(commits[1].subject, 50)) or (#commits .. " commits")
  ask(("Cherry-pick %s onto %s?"):format(what, state.head_name or "HEAD"), "Cherry-pick", function()
    local args = { "cherry-pick" }
    if #merges > 0 then
      -- a merge is replayed against its first parent: the changes the merge brought in
      vim.list_extend(args, { "-m", "1" })
    end
    git.queue(state.root, vim.list_extend(args, hashes), after_git(state, "Cherry-pick stopped on a conflict — resolve it in the VCS window (Space g g), then M → Continue", "Cherry-picked " .. what))
  end)
end

local function revert(state)
  local commit = commit_at(state, cursor_line(state))
  if not commit then
    return
  end
  ask(("Revert %s %s? A new commit undoes its changes"):format(commit.short, truncate(commit.subject, 50)), "Revert", function()
    local args = { "revert", "--no-edit" }
    if #commit.parents > 1 then
      vim.list_extend(args, { "-m", "1" })
    end
    args[#args + 1] = commit.hash
    git.queue(state.root, args, after_git(state, "Revert stopped on a conflict — resolve it in the VCS window, then M → Continue", "Reverted " .. commit.short))
  end)
end

local function new_branch(state)
  local commit = commit_at(state, cursor_line(state))
  if not commit then
    return
  end
  vim.ui.input({ prompt = ("New branch at %s: "):format(commit.short) }, function(name)
    name = name and vim.trim(name)
    if not name or name == "" then
      return
    end
    git.queue(state.root, { "switch", "-c", name, commit.hash }, after_git(state, "Could not create " .. name, ("Created %s at %s and switched to it"):format(name, commit.short)))
  end)
end

local function new_tag(state)
  local commit = commit_at(state, cursor_line(state))
  if not commit then
    return
  end
  vim.ui.input({ prompt = ("Tag %s as: "):format(commit.short) }, function(name)
    name = name and vim.trim(name)
    if not name or name == "" then
      return
    end
    git.queue(state.root, { "tag", name, commit.hash }, after_git(state, "Could not tag " .. commit.short, ("Tagged %s as %s"):format(commit.short, name)))
  end)
end

local RESET_MODES = {
  { label = "Soft — keep the changes of the dropped commits checked (staged)", flag = "--soft" },
  { label = "Mixed — keep them as unchecked changes", flag = "--mixed" },
  { label = "Hard — throw them away, and local changes too", flag = "--hard" },
}

local function reset_to(state)
  local commit = commit_at(state, cursor_line(state))
  if not commit then
    return
  end
  local branch = state.head_name or "HEAD"
  vim.ui.select(vim.tbl_map(function(mode)
    return mode.label
  end, RESET_MODES), { prompt = ("Reset %s to %s"):format(branch, commit.short) }, function(_, index)
    if not index then
      return
    end
    local mode = RESET_MODES[index]
    local function run()
      git.queue(state.root, { "reset", mode.flag, commit.hash }, after_git(state, "Reset failed", ("%s is now at %s (%s)"):format(branch, commit.short, mode.flag:sub(3))))
    end
    if mode.flag ~= "--hard" then
      return run()
    end
    ask(("Hard reset %s to %s? Uncommitted changes are lost for good"):format(branch, commit.short), "Hard reset", run)
  end)
end

local function checkout_commit(state)
  local commit = commit_at(state, cursor_line(state))
  if not commit then
    return
  end
  ask(("Check out %s? HEAD becomes detached: new commits belong to no branch until you create one"):format(commit.short), "Check out", function()
    git.queue(state.root, { "switch", "--detach", commit.hash }, after_git(state, "Checkout failed", "HEAD is at " .. commit.short))
  end)
end

-- ---------------------------------------------------------------- filter prompts

local function apply_filters(state, changes)
  for key, value in pairs(changes) do
    state.filters[key] = value or nil
  end
  state.limit = PAGE
  load(state)
end

local function filter_text(state)
  vim.ui.input({ prompt = "Commit message contains: ", default = state.filters.text }, function(text)
    if text == nil then
      return
    end
    text = vim.trim(text)
    apply_filters(state, { text = text ~= "" and text or false })
  end)
end

local function filter_author(state)
  local _, email = git.run_sync(state.root, { "config", "user.email" })
  email = vim.trim(email)
  local choices = { "Anyone" }
  if email ~= "" then
    table.insert(choices, 1, "Me (" .. email .. ")")
  end
  choices[#choices + 1] = "Type a name or an email…"
  vim.ui.select(choices, { prompt = "Commits by" }, function(choice)
    if not choice then
      return
    end
    if choice == "Anyone" then
      return apply_filters(state, { author = false, author_label = false })
    end
    if vim.startswith(choice, "Me") then
      return apply_filters(state, { author = email, author_label = "me" })
    end
    vim.ui.input({ prompt = "Author (part of a name or an email): " }, function(author)
      author = author and vim.trim(author)
      if author and author ~= "" then
        apply_filters(state, { author = author, author_label = false })
      end
    end)
  end)
end

local function filter_branch(state)
  local ok, stdout = git.run_sync(state.root, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" })
  local choices = { "Current branch (HEAD)", "All branches" }
  for name in (ok and stdout or ""):gmatch("[^\n]+") do
    if not name:match("/HEAD$") and name ~= "origin" then
      choices[#choices + 1] = name
    end
  end
  vim.ui.select(choices, { prompt = "Show the history of" }, function(choice, index)
    if not choice then
      return
    end
    local scope = index == 1 and false or (index == 2 and "--all" or choice)
    apply_filters(state, { scope = scope, title = false })
  end)
end

local function filter_path(state)
  vim.ui.input({ prompt = "File or folder (relative to the repository): ", default = state.filters.path, completion = "file" }, function(path)
    if path == nil then
      return
    end
    path = vim.trim(path):gsub("/$", "")
    if path == "" then
      return apply_filters(state, { path = false, follow = false, lines = false })
    end
    local is_file = vim.fn.filereadable(vim.fs.joinpath(state.root, path)) == 1
    apply_filters(state, { path = path, follow = is_file, lines = false })
  end)
end

local SINCE = {
  { "Last 24 hours", "24 hours ago" },
  { "Last week", "1 week ago" },
  { "Last month", "1 month ago" },
  { "Last 3 months", "3 months ago" },
  { "Last year", "1 year ago" },
  { "Any time", false },
}

local function filter_date(state)
  local choices = vim.tbl_map(function(item)
    return item[1]
  end, SINCE)
  choices[#choices + 1] = "Type a date (2026-10-01, 2 weeks ago)…"
  vim.ui.select(choices, { prompt = "Commits since" }, function(choice, index)
    if not choice then
      return
    end
    local preset = SINCE[index]
    if preset then
      return apply_filters(state, { since = preset[2], since_label = preset[2] and preset[1]:lower() or false })
    end
    vim.ui.input({ prompt = "Since: " }, function(since)
      since = since and vim.trim(since)
      if since and since ~= "" then
        apply_filters(state, { since = since, since_label = false })
      end
    end)
  end)
end

local function clear_filters(state)
  state.filters = {}
  state.limit = PAGE
  load(state)
end

-- ---------------------------------------------------------------- the tab

local function list_window_options(window, fixed)
  local options = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    statuscolumn = "",
    foldcolumn = "0",
    wrap = false,
    spell = false,
    list = false,
    cursorline = true,
    diff = false,
    scrollbind = false,
    cursorbind = false,
    foldenable = false,
    winhighlight = "",
  }
  options[fixed] = true
  if fixed == "winfixwidth" then
    -- the details pane is narrow: a long message wraps at word boundaries instead of running off
    options.wrap, options.linebreak, options.breakindent = true, true, true
  end
  for name, value in pairs(options) do
    vim.wo[window][name] = value
  end
end

local function scratch(name, filetype)
  local buffer = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buffer, name)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = filetype
  vim.b[buffer].snacks_indent = false
  -- smooth scrolling rewinds the cursor while it animates (see init.lua)
  vim.b[buffer].snacks_scroll = false
  return buffer
end

local function teardown(state)
  if state.closed then
    return
  end
  state.closed = true
  diff.restore_diffopt(state)
  close_handle(state.watcher)
  for _, timer in ipairs({ state.select_timer, state.preview_timer, state.reload_timer, state.decorate_timer }) do
    close_handle(timer)
  end
  diff.release_real_buffer(state)
  pcall(vim.api.nvim_del_augroup_by_id, state.diff.live_group)
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
  for _, buffer in ipairs({ state.list.buffer, state.details.buffer }) do
    if vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
  states[state.tab] = nil
end

local function close(state)
  if state.closed or not vim.api.nvim_tabpage_is_valid(state.tab) then
    return teardown(state)
  end
  if #vim.api.nvim_list_tabpages() == 1 then
    vim.cmd("tabnew")
  end
  vim.cmd(vim.api.nvim_tabpage_get_number(state.tab) .. "tabclose")
end

-- branch moves (a commit elsewhere, a fetch, a checkout) show up in the Log by themselves
local function watch(state)
  local handle = vim.uv.new_fs_event()
  if not (handle and state.git_dir) then
    return
  end
  state.watcher = handle
  handle:start(state.git_dir, { recursive = false }, function(error, filename)
    if error or not filename then
      return
    end
    if filename == "HEAD" or filename == "packed-refs" or filename == "FETCH_HEAD" or filename:match("^refs") then
      vim.schedule(function()
        if state.closed then
          return
        end
        if vim.api.nvim_get_current_tabpage() ~= state.tab then
          state.stale = true
          return
        end
        state.reload_timer:stop()
        state.reload_timer:start(300, 0, vim.schedule_wrap(function()
          if not state.closed then
            load(state)
          end
        end))
      end)
    end
  end)
end

local function focus(window)
  if window_valid(window) then
    vim.api.nvim_set_current_win(window)
  end
end

local function attach_list_keys(state)
  local buffer = state.list.buffer
  local function map(modes, lhs, action, description)
    vim.keymap.set(modes, lhs, action, { buffer = buffer, nowait = true, desc = description })
  end
  local function step(direction)
    return function()
      local line = cursor_line(state)
      for _ = 1, vim.v.count1 do
        local next_line = line
        repeat
          next_line = next_line + direction
        until next_line < 1 or next_line > #state.rows or state.rows[next_line].commit
        if next_line < 1 or next_line > #state.rows then
          break
        end
        line = next_line
      end
      vim.api.nvim_win_set_cursor(state.list.window, { line, 0 })
    end
  end
  map("n", "j", step(1), "Next commit")
  map("n", "k", step(-1), "Previous commit")
  map("n", "<Down>", step(1), "Next commit")
  map("n", "<Up>", step(-1), "Previous commit")
  local function to_files()
    focus(state.details.window)
    if state.details.rows[1] then
      vim.api.nvim_win_set_cursor(state.details.window, { 1, 0 })
    end
  end
  map("n", "<CR>", to_files, "To the files of the commit")
  map("n", "l", to_files, "To the files of the commit")
  map("n", "<Tab>", to_files, "To the files of the commit")
  map("n", "y", function()
    copy_hash(state)
  end, "Copy the hash")
  map({ "n", "x" }, "c", function()
    cherry_pick(state)
  end, "Cherry-pick (visual: several)")
  map("n", "v", function()
    revert(state)
  end, "Revert")
  map("n", "n", function()
    new_branch(state)
  end, "New branch here")
  map("n", "t", function()
    new_tag(state)
  end, "New tag here")
  map("n", "X", function()
    reset_to(state)
  end, "Reset the current branch to here")
  map("n", "o", function()
    checkout_commit(state)
  end, "Check out this commit (detached)")
  map("n", "/", function()
    filter_text(state)
  end, "Filter: message text")
  map("n", "a", function()
    filter_author(state)
  end, "Filter: author")
  map("n", "b", function()
    filter_branch(state)
  end, "Filter: branch")
  map("n", "f", function()
    filter_path(state)
  end, "Filter: path")
  map("n", "d", function()
    filter_date(state)
  end, "Filter: date")
  map("n", "F", function()
    clear_filters(state)
  end, "Clear the filters")
  map("n", "R", function()
    load(state)
  end, "Reload")
  map("n", "B", function()
    require("vcs.branches").open(state)
  end, "Branches")
  map("n", "U", function()
    require("vcs.update").run(state)
  end, "Update Project")
  map("n", "p", function()
    require("vcs.push").open(state)
  end, "Push")
  map("n", "M", function()
    require("vcs.operation").menu(state)
  end, "Continue / abort a rebase or merge")
  map("n", "W", function()
    require("vcs.worktree").open(state)
  end, "Worktrees")
  map("n", "q", function()
    close(state)
  end, "Close the Log")
  map("n", "?", function()
    menu.open(state, "log")
  end, "Keys and view options")
end

local function attach_details_keys(state)
  local buffer = state.details.buffer
  local function map(lhs, action, description)
    vim.keymap.set("n", lhs, action, { buffer = buffer, nowait = true, desc = description })
  end
  local function open_diff()
    local file = file_at_cursor(state)
    if file then
      show_file_diff(state, file, true)
    end
  end
  map("<CR>", open_diff, "Diff of the file")
  map("l", open_diff, "Diff of the file")
  map("<Tab>", function()
    focus(state.diff.left and window_valid(state.diff.left) and state.diff.left or state.diff.right)
  end, "To the diff")
  for _, lhs in ipairs({ "h", "<BS>", "<S-Tab>" }) do
    map(lhs, function()
      focus(state.list.window)
    end, "Back to the commits")
  end
  map("e", function()
    local file = file_at_cursor(state)
    if not file then
      return
    end
    local path = vim.fs.joinpath(state.root, file.path)
    if vim.fn.filereadable(path) == 0 then
      vim.notify("Not in the working copy any more: " .. file.path, vim.log.levels.WARN, { title = "Git" })
      return
    end
    local target = state.origin_tab
    if target and vim.api.nvim_tabpage_is_valid(target) and target ~= state.tab then
      vim.api.nvim_set_current_tabpage(target)
    else
      vim.cmd("tabnew")
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
  end, "Open the file in an editor tab")
  map("q", function()
    close(state)
  end, "Close the Log")
  map("?", function()
    menu.open(state, "log")
  end, "Keys and view options")
end

local function create(root, filters, origin_tab)
  local state = {
    kind = "log",
    root = root,
    git_dir = git.git_dir(root),
    origin_tab = origin_tab,
    filters = filters,
    limit = PAGE,
    rows = {},
    commit_count = 0,
    select_timer = vim.uv.new_timer(),
    preview_timer = vim.uv.new_timer(),
    reload_timer = vim.uv.new_timer(),
    decorate_timer = vim.uv.new_timer(),
  }
  state.close = function()
    close(state)
  end
  state.refresh = function()
    context_refresh(state)
  end
  state.set_busy = function(text)
    state.busy = text
    if text then
      vim.notify(text:sub(1, 1):upper() .. text:sub(2) .. "…", vim.log.levels.INFO, { title = "Git" })
    end
  end
  state.open_menu = function(origin)
    menu.open(state, origin == "diff" and "revision" or origin)
  end
  state.on_view_changed = function()
    diff.apply_diffopt(state)
    diff.apply_view(state)
  end
  -- keys of the diff buffers: back to the files and the commits
  state.map_extra_keys = function(buffer)
    vim.keymap.set("n", "<Tab>", function()
      focus(state.list.window)
    end, { buffer = buffer, nowait = true, desc = "VCS: to the commits" })
    vim.keymap.set("n", "<S-Tab>", function()
      focus(state.details.window)
    end, { buffer = buffer, nowait = true, desc = "VCS: to the files" })
  end

  vim.cmd("tabnew")
  state.tab = vim.api.nvim_get_current_tabpage()
  states[state.tab] = state
  vim.bo.bufhidden = "wipe"
  local list_window = vim.api.nvim_get_current_win()
  vim.cmd("belowright split")
  local bottom_window = vim.api.nvim_get_current_win()
  diff.create_area(state, bottom_window)
  local details_window
  vim.api.nvim_win_call(bottom_window, function()
    vim.cmd("leftabove vsplit")
    details_window = vim.api.nvim_get_current_win()
  end)

  local name = vim.fs.basename(root)
  state.list = { buffer = scratch("vcs://" .. name .. "/log", "vcs_log"), window = list_window }
  state.details = { buffer = scratch("vcs://" .. name .. "/commit", "vcs_commit"), window = details_window, rows = {} }
  vim.api.nvim_win_set_buf(list_window, state.list.buffer)
  vim.api.nvim_win_set_buf(details_window, state.details.buffer)
  list_window_options(list_window, "winfixheight")
  list_window_options(details_window, "winfixwidth")
  vim.api.nvim_win_set_height(list_window, math.max(8, math.floor(vim.o.lines * LIST_SHARE)))
  vim.api.nvim_win_set_width(details_window, math.min(64, math.max(36, math.floor(vim.o.columns * 0.3))))
  vim.wo[details_window].winbar = "%#VcsHint# Commit%*"

  attach_list_keys(state)
  attach_details_keys(state)
  state.group = vim.api.nvim_create_augroup("vcs_log_" .. state.list.buffer, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.group,
    buffer = state.list.buffer,
    callback = function()
      -- while the cursor runs down the list the details are not reloaded for every line
      state.select_timer:stop()
      state.select_timer:start(80, 0, vim.schedule_wrap(function()
        if not state.closed then
          select_at_cursor(state)
        end
      end))
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.group,
    buffer = state.details.buffer,
    callback = function()
      state.preview_timer:stop()
      state.preview_timer:start(80, 0, vim.schedule_wrap(function()
        if not state.closed and vim.api.nvim_get_current_win() == state.details.window then
          show_file_diff(state, file_at_cursor(state), false)
        end
      end))
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = state.group,
    callback = function()
      if not state.closed and vim.tbl_contains(vim.v.event.windows or {}, state.list.window) then
        render_list(state)
      end
    end,
  })

  diff.apply_diffopt(state)
  watch(state)
  focus(list_window)
  load(state)
  return state
end

local setup_done = false
local function setup()
  if setup_done then
    return
  end
  setup_done = true
  local group = vim.api.nvim_create_augroup("vcs_log", { clear = true })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      for _, state in pairs(states) do
        if not vim.api.nvim_tabpage_is_valid(state.tab) then
          teardown(state)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      local state = states[vim.api.nvim_get_current_tabpage()]
      if not state then
        return
      end
      diff.apply_diffopt(state)
      if state.stale then
        state.stale = false
        load(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabLeave", {
    group = group,
    callback = function()
      local state = states[vim.api.nvim_get_current_tabpage()]
      if state then
        diff.restore_diffopt(state)
      end
    end,
  })
end

--- Reload every Log of the repository (after a commit or a checkout made elsewhere).
function M.reload(root)
  for _, state in pairs(states) do
    if state.root == root and not state.closed then
      if vim.api.nvim_get_current_tabpage() == state.tab then
        load(state)
      else
        state.stale = true
      end
    end
  end
end

--- Open the Log of `root`. options (all optional):
---   scope  — "--all", a branch or a range "main..feature"; nil — the current branch
---   title  — what to call the scope in the bar ("in feature, not in main")
---   path   — a file or folder; follow — keep a file's history across renames
---   lines  — { path, first, last }: history of these lines
--- A Log of the same repository that is already open is reused with the new filters.
function M.open(root, options)
  setup()
  options = options or {}
  local filters = {
    scope = options.scope,
    title = options.title,
    path = options.path,
    follow = options.follow,
    lines = options.lines,
  }
  local origin_tab = vim.api.nvim_get_current_tabpage()
  for tab, state in pairs(states) do
    if state.root == root and not state.closed and vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      state.origin_tab = origin_tab ~= tab and origin_tab or state.origin_tab
      state.filters, state.limit, state.selected = filters, PAGE, nil
      focus(state.list.window)
      load(state)
      return state
    end
  end
  return create(root, filters, origin_tab)
end

return M
