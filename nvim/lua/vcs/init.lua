-- A VCS window in the spirit of IntelliJ: its own tab, the changes with checkboxes and the commit
-- message on the left, the diff of the selected file on the right. Space g g opens and closes it.
local git = require("vcs.git")
local status = require("vcs.status")
local panel = require("vcs.panel")
local diff = require("vcs.diff")
local commit = require("vcs.commit")
local menu = require("vcs.menu")
local settings = require("vcs.settings")
local highlights = require("vcs.highlights")
local push = require("vcs.push")
local operation = require("vcs.operation")
local update = require("vcs.update")
local branches = require("vcs.branches")
local worktree = require("vcs.worktree")

local M = {}

-- one state per VCS tab: [tabpage] = state
local states = {}

local MESSAGE_HEIGHT = 9

local function is_open(state)
  return not state.closed and vim.api.nvim_tabpage_is_valid(state.tab)
end

local function window_valid(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:stop()
    handle:close()
  end
end

local function teardown(state)
  if state.closed then
    return
  end
  state.closed = true
  diff.restore_diffopt(state)
  commit.save_draft(state)
  close_handle(state.watcher)
  close_handle(state.refresh_timer)
  close_handle(state.preview_timer)
  close_handle(state.decorate_timer)
  diff.release_real_buffer(state)
  pcall(vim.api.nvim_del_augroup_by_id, state.diff.live_group)
  for _, buffer in ipairs({ state.panel.buffer, state.message and state.message.buffer }) do
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
  states[state.tab] = nil
end

function M.refresh(state)
  if state.refreshing then
    state.refresh_pending = true
    return
  end
  state.refreshing, state.stale = true, false
  state.busy = state.busy or "refreshing"
  panel.render(state)
  git.run(state.root, status.COMMAND, function(ok, stdout, stderr)
    state.refreshing = false
    if state.busy == "refreshing" then
      state.busy = nil
    end
    if not is_open(state) then
      return
    end
    if not ok then
      vim.notify("git status:\n" .. stderr, vim.log.levels.ERROR, { title = "Git" })
      return
    end
    local previous_head = state.status.branch.oid
    state.status, state.loaded = status.parse(stdout), true
    state.operation = operation.detect(state.git_dir)
    commit.sync_prepared_message(state)
    panel.render(state)
    commit.update_winbar(state)
    -- the shown file left the list (committed, rolled back): drop its diff, unless it is being edited
    local shown_id, shown_entry = state.diff.shown_id, nil
    for _, entry in ipairs(state.status.entries) do
      if (entry.group .. ":" .. entry.path) == shown_id then
        shown_entry = entry
      end
    end
    if shown_id and not shown_entry and vim.api.nvim_get_current_win() ~= state.diff.right then
      diff.show_placeholder(state)
    elseif shown_entry and previous_head ~= state.status.branch.oid then
      -- HEAD moved (commit, amend, checkout): the HEAD side of the diff is stale
      diff.show(state, { kind = "file", id = shown_id, path = shown_entry.path, entry = shown_entry }, { reload = true })
    end
    if state.refresh_pending then
      state.refresh_pending = false
      M.refresh(state)
    end
  end)
end

local function schedule_refresh(state)
  if state.closed then
    return
  end
  -- status takes a while in a big repository; while the tab is not visible it is not run,
  -- the tab refreshes when entered instead
  if vim.api.nvim_get_current_tabpage() ~= state.tab then
    state.stale = true
    return
  end
  state.refresh_timer:stop()
  state.refresh_timer:start(150, 0, vim.schedule_wrap(function()
    if is_open(state) then
      M.refresh(state)
    end
  end))
end

-- the index changes under any git: a terminal, gitsigns, another editor — so watch it
local function watch_git_dir(state)
  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  state.watcher = handle
  handle:start(state.git_dir, {}, function(error, filename)
    if error or not filename then
      return
    end
    if filename == "index" or filename == "HEAD" or filename == "MERGE_HEAD" or filename:match("^refs") then
      vim.schedule(function()
        schedule_refresh(state)
      end)
    end
  end)
end

function M.close(state)
  if not is_open(state) then
    return teardown(state)
  end
  if #vim.api.nvim_list_tabpages() == 1 then
    vim.cmd("tabnew")
  end
  vim.cmd(vim.api.nvim_tabpage_get_number(state.tab) .. "tabclose")
end

local function default_panel_width()
  return math.min(56, math.max(32, math.floor(vim.o.columns * 0.25)))
end

local function panel_window_options(window)
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
    winfixwidth = true,
    -- a split copies the options of the window it came from, diff mode included
    diff = false,
    scrollbind = false,
    cursorbind = false,
    foldenable = false,
    winhighlight = "",
  }
  for name, value in pairs(options) do
    vim.wo[window][name] = value
  end
end

-- the panel and the message field form the left column; it can be hidden to give the diff room
local function open_side(state)
  local anchor = window_valid(state.diff.left) and state.diff.left or state.diff.right
  vim.api.nvim_win_call(anchor, function()
    vim.cmd("topleft vsplit")
    state.panel.window = vim.api.nvim_get_current_win()
  end)
  vim.api.nvim_win_set_buf(state.panel.window, state.panel.buffer)
  vim.api.nvim_win_set_width(state.panel.window, settings.get("panel_width") or default_panel_width())
  panel_window_options(state.panel.window)
  vim.api.nvim_win_call(state.panel.window, function()
    vim.cmd("belowright " .. MESSAGE_HEIGHT .. "split")
    state.message.window = vim.api.nvim_get_current_win()
  end)
  commit.show_in(state, state.message.window)
  state.panel_hidden = false
end

local function hide_side(state)
  state.panel_hidden = true
  for _, window in ipairs({ state.message.window, state.panel.window }) do
    if window_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
  end
  vim.api.nvim_win_call(state.diff.right, function()
    vim.cmd("wincmd =")
  end)
end

local function attach_panel_keymaps(state)
  local function map(modes, lhs, action, description)
    vim.keymap.set(modes, lhs, action, { buffer = state.panel.buffer, nowait = true, desc = description })
  end
  local function node()
    return panel.node_at_cursor(state)
  end
  local function open_node()
    local current = node()
    if not current then
      return
    end
    if current.kind ~= "file" then
      return panel.toggle_fold(state, current)
    end
    if current.group == "conflicts" then
      -- diffview already does the three-way merge well
      return vim.cmd("DiffviewOpen")
    end
    diff.show(state, current, { focus = true })
  end

  map({ "n", "x" }, "x", function()
    panel.toggle(state, panel.selected_nodes(state))
  end, "Check / uncheck")
  map("n", "X", function()
    panel.toggle_all(state)
  end, "Check / uncheck all")
  map("n", "<CR>", open_node, "Edit in the diff / fold")
  map("n", "o", open_node, "Edit in the diff / fold")
  map("n", "<2-LeftMouse>", open_node, "Edit in the diff / fold")
  map("n", "e", function()
    panel.open_in_editor(state, node())
  end, "Open in an editor tab")
  map("n", "l", function()
    panel.toggle_fold(state, node(), false)
  end, "Expand")
  map("n", "h", function()
    panel.collapse_or_parent(state)
  end, "Collapse / go to folder")
  map("n", "<Tab>", function()
    panel.toggle_fold(state, node())
  end, "Fold / unfold")
  map({ "n", "x" }, "u", function()
    panel.rollback(state, panel.selected_nodes(state))
  end, "Roll back")
  map("n", "c", function()
    vim.api.nvim_set_current_win(state.message.window)
    vim.cmd("startinsert!")
  end, "Write the commit message")
  map("n", "C", function()
    commit.commit(state, false)
  end, "Commit")
  map("n", "P", function()
    commit.commit(state, true)
  end, "Commit and push")
  map("n", "p", function()
    push.open(state)
  end, "Push dialog")
  map("n", "A", function()
    commit.toggle_amend(state)
  end, "Amend")
  map("n", "L", function()
    require("vcs.log").open(state.root)
  end, "Log")
  map("n", "B", function()
    branches.open(state)
  end, "Branches")
  map("n", "U", function()
    update.run(state)
  end, "Update Project")
  map("n", "M", function()
    operation.menu(state)
  end, "Continue / skip / abort a rebase or merge")
  map("n", "W", function()
    worktree.open(state)
  end, "Worktrees")
  map("n", "t", function()
    state.flat = not state.flat
    panel.render(state)
  end, "Tree / flat list")
  map("n", "<", function()
    state.resize_panel(-5)
  end, "Panel narrower")
  map("n", ">", function()
    state.resize_panel(5)
  end, "Panel wider")
  map("n", "R", function()
    M.refresh(state)
  end, "Refresh")
  map("n", "q", function()
    M.close(state)
  end, "Close")
  map("n", "?", function()
    menu.open(state, "panel")
  end, "Keys and view options")
end

local function create(root, origin_tab)
  local state = {
    root = root,
    git_dir = git.git_dir(root),
    -- a linked worktree is named in the bar, like wt:<name> in the shell prompt
    worktree_name = git.linked_worktree_name(root),
    origin_tab = origin_tab,
    collapsed = {},
    flat = false,
    amend = false,
    status = { branch = {}, entries = {} },
    refresh_timer = vim.uv.new_timer(),
    preview_timer = vim.uv.new_timer(),
    decorate_timer = vim.uv.new_timer(),
  }
  state.refresh = function()
    M.refresh(state)
    require("vcs.log").reload(state.root)
  end
  state.render = function()
    panel.render(state)
  end
  -- push, update and the branch popup report progress through the panel's bar
  state.set_busy = function(text)
    state.busy = text
    panel.render(state)
  end
  state.close = function()
    M.close(state)
  end
  state.open_menu = function(origin)
    menu.open(state, origin)
  end
  state.on_view_changed = function()
    diff.apply_diffopt(state)
    diff.apply_view(state)
  end
  state.panel_width = function()
    return window_valid(state.panel.window) and vim.api.nvim_win_get_width(state.panel.window) or (settings.get("panel_width") or default_panel_width())
  end
  state.resize_panel = function(delta)
    local width = math.max(20, math.min(state.panel_width() + delta, vim.o.columns - 40))
    settings.set("panel_width", width)
    if window_valid(state.panel.window) then
      vim.api.nvim_win_set_width(state.panel.window, width)
      panel.render(state)
    end
  end
  state.toggle_panel = function()
    if state.panel_hidden then
      open_side(state)
      panel.render(state)
    else
      hide_side(state)
    end
  end

  vim.cmd("tabnew")
  state.tab = vim.api.nvim_get_current_tabpage()
  states[state.tab] = state
  -- the empty buffer tabnew makes must not stay behind
  vim.bo.bufhidden = "wipe"
  diff.create_area(state, vim.api.nvim_get_current_win())

  local panel_buffer = vim.api.nvim_create_buf(false, true)
  state.panel = { buffer = panel_buffer }
  pcall(vim.api.nvim_buf_set_name, panel_buffer, "vcs://" .. vim.fs.basename(root) .. "/changes")
  vim.bo[panel_buffer].modifiable = false
  vim.bo[panel_buffer].filetype = "vcs_changes"
  -- indent guides over the tree only get in the way
  vim.b[panel_buffer].snacks_indent = false
  -- smooth scrolling rewinds the cursor while it animates: a key typed right after a jump that
  -- scrolled the list (11G<CR>) would land on the old line
  vim.b[panel_buffer].snacks_scroll = false
  commit.create(state)
  open_side(state)
  attach_panel_keymaps(state)

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup("vcs_panel_" .. panel_buffer, { clear = true }),
    buffer = panel_buffer,
    callback = function()
      -- while the cursor runs down the list the diff is not rebuilt for every line
      state.preview_timer:stop()
      state.preview_timer:start(90, 0, vim.schedule_wrap(function()
        if is_open(state) and vim.api.nvim_get_current_win() == state.panel.window then
          diff.show(state, panel.node_at_cursor(state))
        end
      end))
    end,
  })

  diff.apply_diffopt(state)
  watch_git_dir(state)
  vim.api.nvim_set_current_win(state.panel.window)
  M.refresh(state)
  return state
end

local function current_root()
  local name = vim.api.nvim_buf_get_name(0)
  local root = (name ~= "" and vim.bo.buftype == "") and git.root_of(name) or nil
  return root or git.root_of(vim.uv.cwd())
end

local function state_of_current_tab()
  return states[vim.api.nvim_get_current_tabpage()]
end

local setup_done = false
local function setup()
  if setup_done then
    return
  end
  setup_done = true
  highlights.setup()
  local group = vim.api.nvim_create_augroup("vcs", { clear = true })
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
  vim.api.nvim_create_autocmd({ "FocusGained", "TabEnter" }, {
    group = group,
    callback = function()
      local state = state_of_current_tab()
      if state then
        diff.apply_diffopt(state)
        schedule_refresh(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabLeave", {
    group = group,
    callback = function()
      local state = state_of_current_tab()
      if state then
        diff.restore_diffopt(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local state = state_of_current_tab()
      if state then
        diff.on_window_enter(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      local state = state_of_current_tab()
      if state then
        diff.on_window_leave(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      local closed = tonumber(event.match)
      for _, state in pairs(states) do
        -- the panel closed by hand (:q): treat it as hidden and take the message field along
        if closed == state.panel.window and not state.panel_hidden then
          state.panel_hidden = true
          vim.schedule(function()
            if is_open(state) and window_valid(state.message.window) then
              pcall(vim.api.nvim_win_close, state.message.window, true)
            end
          end)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      for _, state in pairs(states) do
        if vim.startswith(event.match, state.root .. "/") then
          schedule_refresh(state)
        end
      end
    end,
  })
end

--- Re-read everything that shows `root`: its VCS tabs and its Logs.
function M.refresh_repository(root)
  for _, state in pairs(states) do
    if state.root == root and is_open(state) then
      schedule_refresh(state)
    end
  end
  require("vcs.log").reload(root)
end

-- What push, update and the branch popup work with when called from an ordinary tab:
-- the VCS state of the repository when its tab is open, otherwise a stand-in.
local function context_for(root)
  for _, state in pairs(states) do
    if state.root == root and is_open(state) then
      return state
    end
  end
  return {
    root = root,
    git_dir = git.git_dir(root),
    tab = vim.api.nvim_get_current_tabpage(),
    refresh = function()
      M.refresh_repository(root)
    end,
    set_busy = function(text)
      if text then
        vim.notify(text:sub(1, 1):upper() .. text:sub(2) .. "…", vim.log.levels.INFO, { title = "Git" })
      end
    end,
  }
end

local function with_root(action)
  setup()
  local root = current_root()
  if not root then
    vim.notify("Not inside a git repository", vim.log.levels.WARN, { title = "Git" })
    return
  end
  return action(root)
end

-- the path of the current file inside its repository, or nil for a buffer that is no file
local function file_in_repository(root)
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    return nil
  end
  local real_root, real_name = vim.uv.fs_realpath(root), vim.uv.fs_realpath(name)
  if not (real_root and real_name and vim.startswith(real_name, real_root .. "/")) then
    return nil
  end
  return real_name:sub(#real_root + 2)
end

--- Space g l: the Log of the current branch.
function M.log(options)
  with_root(function(root)
    require("vcs.log").open(root, options)
  end)
end

--- Space g f: the history of the current file, across renames.
function M.file_history()
  with_root(function(root)
    local path = file_in_repository(root)
    if not path then
      vim.notify("This buffer is not a file of the repository", vim.log.levels.WARN, { title = "Git" })
      return
    end
    require("vcs.log").open(root, { path = path, follow = true })
  end)
end

--- Space g f in visual mode: the history of the selected lines.
function M.line_history()
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then
    first, last = last, first
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  with_root(function(root)
    local path = file_in_repository(root)
    if not path then
      vim.notify("This buffer is not a file of the repository", vim.log.levels.WARN, { title = "Git" })
      return
    end
    require("vcs.log").open(root, { lines = { path = path, first = first, last = last } })
  end)
end

--- Space g c: the branches popup.
function M.branches()
  with_root(function(root)
    branches.open(context_for(root))
  end)
end

--- Space g u: Update Project.
function M.update()
  with_root(function(root)
    update.run(context_for(root))
  end)
end

--- Space g w: the worktrees of the repository.
function M.worktrees()
  with_root(function(root)
    worktree.open(context_for(root))
  end)
end

--- The push dialog for the current branch.
function M.push()
  with_root(function(root)
    push.open(context_for(root))
  end)
end

--- Space g g: open the VCS window for the repository of the current file; inside it, close it.
function M.toggle()
  setup()
  local current_tab = vim.api.nvim_get_current_tabpage()
  if states[current_tab] then
    return M.close(states[current_tab])
  end
  local root = current_root()
  if not root then
    vim.notify("Not inside a git repository", vim.log.levels.WARN, { title = "Git" })
    return
  end
  M.open_root(root)
end

--- The VCS window of `root` (a worktree from the worktree popup, say): its open tab or a new one.
function M.open_root(root)
  setup()
  local current_tab = vim.api.nvim_get_current_tabpage()
  for tab, state in pairs(states) do
    if state.root == root and is_open(state) then
      state.origin_tab = current_tab
      vim.api.nvim_set_current_tabpage(tab)
      if window_valid(state.panel.window) then
        vim.api.nvim_set_current_win(state.panel.window)
      end
      return M.refresh(state)
    end
  end
  create(root, current_tab)
end

return M
