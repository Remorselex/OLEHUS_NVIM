-- The Changes panel on the left: a file tree with checkboxes. A checkbox is the git index:
-- [x] the file is staged in full, [~] partly (some hunks), [ ] not staged.
local git = require("vcs.git")
local status = require("vcs.status")
local tree = require("vcs.tree")
local highlights = require("vcs.highlights")
local ask = require("vcs.ask")

local M = {}

local namespace = vim.api.nvim_create_namespace("vcs_panel")

local CHECKBOX = { full = { "[x]", "VcsCheckFull" }, partial = { "[~]", "VcsCheckPartial" }, none = { "[ ]", "VcsCheckNone" } }
local NAME_GROUP = { D = "VcsNameD", ["?"] = "VcsNameUntracked", ["!"] = "VcsNameConflict" }

local function icon_of(kind, name)
  local ok, icons = pcall(require, "mini.icons")
  if not ok then
    return kind == "directory" and "" or "", "VcsDirectory"
  end
  return icons.get(kind, name)
end

local function count_label(count)
  return ("%d %s"):format(count, count == 1 and "file" or "files")
end

-- a row as a list of { text, highlight group } chunks
local function chunks_for(row, state)
  local node, chunks = row.node, {}
  local function add(text, group)
    chunks[#chunks + 1] = { text, group }
  end
  add(string.rep("  ", row.depth))
  if node.kind ~= "file" then
    add(state.collapsed[node.id] and "▸ " or "▾ ", "VcsCount")
  else
    add("  ")
  end
  if node.group ~= "conflicts" then
    local check = node.kind == "file" and status.check_state(node.entry) or tree.aggregate_check(node.entries)
    add(CHECKBOX[check][1], CHECKBOX[check][2])
    add(" ")
  end
  if node.kind == "group" then
    add(node.name, "VcsGroup")
    add("  " .. count_label(#node.entries), "VcsCount")
    return chunks
  end
  if node.kind == "directory" then
    local icon, icon_group = icon_of("directory", node.name)
    add(icon .. " ", icon_group)
    add(node.name, "VcsDirectory")
    add("  " .. #node.entries, "VcsCount")
    return chunks
  end
  local letter = status.change_letter(node.entry)
  add(letter .. " ", "VcsLetter" .. highlights.SUFFIX[letter])
  local is_directory = node.path:sub(-1) == "/"
  local bare_path = node.path:gsub("/$", "")
  local icon, icon_group = icon_of(is_directory and "directory" or "file", vim.fs.basename(bare_path))
  add(icon .. " ", icon_group)
  add(state.flat and vim.fs.basename(bare_path) .. (is_directory and "/" or "") or node.name, NAME_GROUP[letter])
  local directory = vim.fs.dirname(bare_path)
  if state.flat and directory ~= "." then
    add("  " .. directory, "VcsCount")
  end
  local original_path = node.entry.original_path
  if original_path then
    -- from the same folder the old name alone is enough
    local same_directory = vim.fs.dirname(original_path) == vim.fs.dirname(node.path)
    add("  ← " .. (same_directory and vim.fs.basename(original_path) or original_path), "VcsCount")
  end
  return chunks
end

local function escape_statusline(text)
  return (text:gsub("%%", "%%%%"))
end

-- a long branch name is cut in the middle: both the start (the ticket) and the end (the gist) matter
local function shorten_middle(text, width)
  local length = vim.fn.strchars(text)
  if length <= width then
    return text
  end
  local head = math.ceil((width - 1) / 2)
  return vim.fn.strcharpart(text, 0, head) .. "…" .. vim.fn.strcharpart(text, length - (width - 1 - head))
end

local function branch_winbar(state)
  local branch = state.status and state.status.branch or {}
  local name = branch.head == "(detached)" and ("detached " .. (branch.oid or ""):sub(1, 8)) or (branch.head or "?")
  if state.operation and state.operation.branch then
    name = state.operation.branch
  end
  local tail = {}
  if branch.upstream then
    tail[#tail + 1] = ("↑%d ↓%d"):format(branch.ahead or 0, branch.behind or 0)
  elseif branch.head and branch.head ~= "(detached)" then
    tail[#tail + 1] = "no upstream"
  end
  if state.busy then
    tail[#tail + 1] = state.busy .. "…"
  end
  local tail_text = table.concat(tail, "  ")
  -- a rebase or merge stopped half-way is the first thing to see: reversed, with the key to go on
  local operation_text = state.operation and (" " .. state.operation.label:upper() .. " · M ") or ""
  local width = vim.api.nvim_win_get_width(state.panel.window) - vim.fn.strdisplaywidth(tail_text .. operation_text) - 6
  local operation_part = operation_text ~= "" and ("%#VcsAmend#" .. escape_statusline(operation_text) .. "%* ") or ""
  local worktree_part = state.worktree_name and ("%#VcsHint# wt:" .. escape_statusline(state.worktree_name) .. "%*") or ""
  if state.worktree_name then
    width = width - vim.fn.strdisplaywidth(" wt:" .. state.worktree_name)
  end
  return ("%s%%#VcsBranch# 󰘬 %s%%*  %s%%#VcsHint#%s%%*"):format(worktree_part, escape_statusline(shorten_middle(name, math.max(width, 12))), operation_part, escape_statusline(tail_text))
end

function M.node_at_cursor(state)
  if not (state.rows and state.panel.window and vim.api.nvim_win_is_valid(state.panel.window)) then
    return nil
  end
  local row = state.rows[vim.api.nvim_win_get_cursor(state.panel.window)[1]]
  return row and row.node
end

function M.render(state)
  local buffer = state.panel.buffer
  if not vim.api.nvim_buf_is_valid(buffer) then
    return
  end
  local cursor_node = M.node_at_cursor(state)
  state.rows = tree.rows(state.status, { flat = state.flat, collapsed = state.collapsed })

  local lines, marks = {}, {}
  for index, row in ipairs(state.rows) do
    local text, column = "", 0
    for _, chunk in ipairs(chunks_for(row, state)) do
      if chunk[2] then
        marks[#marks + 1] = { index - 1, column, column + #chunk[1], chunk[2] }
      end
      text = text .. chunk[1]
      column = column + #chunk[1]
    end
    lines[index] = text
  end
  if #lines == 0 then
    lines = { "", state.loaded and "  No changes — the working copy is clean" or "  Reading git status…" }
    marks = { { 1, 0, #lines[2], "VcsHint" } }
  end

  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buffer, namespace, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end

  local window = state.panel.window
  if not (window and vim.api.nvim_win_is_valid(window)) then
    return
  end
  vim.wo[window].winbar = branch_winbar(state)
  for index, row in ipairs(state.rows) do
    if cursor_node and row.node.id == cursor_node.id then
      vim.api.nvim_win_set_cursor(window, { index, 0 })
      return
    end
  end
  local line = math.min(vim.api.nvim_win_get_cursor(window)[1], #lines)
  vim.api.nvim_win_set_cursor(window, { math.max(line, 1), 0 })
end

--- Nodes in the visual selection, or the one under the cursor.
function M.selected_nodes(state)
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return { M.node_at_cursor(state) }
  end
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then
    first, last = last, first
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  local nodes = {}
  for line = first, last do
    if state.rows[line] then
      nodes[#nodes + 1] = state.rows[line].node
    end
  end
  return nodes
end

local function entries_of(nodes)
  local entries, seen = {}, {}
  for _, node in ipairs(nodes) do
    for _, entry in ipairs(node.entries) do
      if not seen[entry] then
        seen[entry] = true
        entries[#entries + 1] = entry
      end
    end
  end
  return entries
end

local function report_failure(action)
  return function(ok, _, stderr)
    if not ok then
      vim.notify(action .. ":\n" .. stderr, vim.log.levels.ERROR, { title = "Git" })
    end
  end
end

local function after(state, on_done)
  return function(ok, stdout, stderr)
    on_done(ok, stdout, stderr)
    state.refresh()
  end
end

function M.toggle(state, nodes)
  local entries = vim.tbl_filter(function(entry)
    return entry.group ~= "conflicts"
  end, entries_of(nodes))
  if #entries == 0 then
    return
  end
  local paths = status.paths_of(entries)
  if tree.aggregate_check(entries) ~= "full" then
    -- -A: deletions get into the index too
    git.run_with_paths(state.root, { "add", "-A" }, paths, after(state, report_failure("Could not stage")))
    return
  end
  -- in a repository without commits there is nothing for restore --staged to go back to
  local args = state.status.unborn and { "rm", "--cached", "-r", "-q" } or { "restore", "--staged" }
  git.run_with_paths(state.root, args, paths, after(state, report_failure("Could not unstage")))
end

--- Check everything under Changes, or uncheck it when all of it is checked already.
function M.toggle_all(state)
  local entries = vim.tbl_filter(function(entry)
    return entry.group == "changes"
  end, state.status.entries)
  M.toggle(state, { { entries = entries } })
end

function M.rollback(state, nodes)
  local entries = vim.tbl_filter(function(entry)
    return entry.group == "changes"
  end, entries_of(nodes))
  if #entries == 0 then
    vim.notify("Only tracked files can be rolled back", vim.log.levels.WARN, { title = "Git" })
    return
  end
  local question = #entries == 1 and ("Roll back %s to HEAD? The changes will be lost"):format(entries[1].path)
    or ("Roll back %s to HEAD? The changes will be lost"):format(count_label(#entries))
  ask(question, "Roll back", function()
    M.rollback_entries(state, entries)
  end)
end

function M.rollback_entries(state, entries)
  -- new files (and the new name of a rename) are untracked but stay on disk;
  -- everything that exists in HEAD is taken from there
  local added, existing = {}, {}
  for _, entry in ipairs(entries) do
    if entry.staged == "A" or entry.original_path then
      added[#added + 1] = entry.path
    end
    if entry.original_path or entry.staged ~= "A" then
      existing[#existing + 1] = entry.original_path or entry.path
    end
  end
  if #added > 0 then
    git.run_with_paths(state.root, { "rm", "--cached", "-q", "-r" }, added, report_failure("Could not untrack"))
  end
  if #existing > 0 and not state.status.unborn then
    -- queued after the rm: two git commands at once would fight over index.lock
    git.run_with_paths(state.root, { "restore", "--source=HEAD", "--staged", "--worktree" }, existing, after(state, report_failure("Could not roll back")))
    return
  end
  state.refresh()
end

function M.toggle_fold(state, node, collapse)
  if not node or node.kind == "file" then
    return
  end
  if collapse == nil then
    collapse = not state.collapsed[node.id]
  end
  state.collapsed[node.id] = collapse or nil
  M.render(state)
end

--- h works like the left arrow in IntelliJ: collapse an open folder, otherwise go to the parent.
function M.collapse_or_parent(state)
  local line = vim.api.nvim_win_get_cursor(state.panel.window)[1]
  local row = state.rows[line]
  if not row then
    return
  end
  if row.node.kind ~= "file" and not state.collapsed[row.node.id] then
    return M.toggle_fold(state, row.node, true)
  end
  for parent_line = line - 1, 1, -1 do
    if state.rows[parent_line].depth < row.depth then
      vim.api.nvim_win_set_cursor(state.panel.window, { parent_line, 0 })
      return
    end
  end
end

--- Open the file in an ordinary editor tab, like F4 in IntelliJ.
function M.open_in_editor(state, node)
  if not node or node.kind ~= "file" then
    return
  end
  local path = vim.fs.joinpath(state.root, node.path)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("The file is not on disk: " .. node.path, vim.log.levels.WARN, { title = "Git" })
    return
  end
  local target = state.origin_tab
  if not (target and vim.api.nvim_tabpage_is_valid(target)) or target == state.tab then
    vim.cmd("tabnew")
  else
    vim.api.nvim_set_current_tabpage(target)
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

return M
