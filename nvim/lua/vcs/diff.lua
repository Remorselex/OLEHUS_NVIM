-- Diff of the selected file, right of the panel. Two views:
--   split   — HEAD on the left, working copy on the right, nvim's own diff mode;
--   unified — one pane, old lines drawn as virtual lines above the new ones.
-- While the cursor walks the panel the working copy is a read-only copy: no LSP is started and
-- nothing lands in the buffer list. Enter, or starting to type in it, swaps in the real file,
-- which is then edited and saved right here.
-- The Log shows a file inside a commit the same way, with both sides read-only (show_revisions).
local git = require("vcs.git")
local hunks = require("vcs.hunks")
local settings = require("vcs.settings")

local M = {}

local PLACEHOLDER = { "", "  Select a file on the left to see its diff", "", "  ? — keys and view options" }

-- One namespace per diff window and scoped to it: the real file may be open in another tab,
-- and the diff markers must not leak there.
local NAMESPACE = {
  left = vim.api.nvim_create_namespace("vcs_diff_left"),
  right = vim.api.nvim_create_namespace("vcs_diff_right"),
}

-- solid: the line exists on this side only; dashed: the line is on both sides but differs
local SIGN = { only_here = "┃", changed = "┇", removed_below = "▁" }

local UNCHANGED_CONTEXT = 4

local function scratch_buffer(lines)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  -- a fresh buffer per file: the old one is wiped together with its treesitter parsers
  vim.bo[buffer].bufhidden = "wipe"
  -- smooth scrolling fights scrollbind between the two diff panes
  vim.b[buffer].snacks_scroll = false
  return buffer
end

-- syntax without a filetype: otherwise LSP and ftplugins would attach to a copy
local function highlight_syntax(buffer, path)
  local filetype = vim.filetype.match({ filename = path, buf = buffer }) or ""
  local language = filetype ~= "" and vim.treesitter.language.get_lang(filetype) or nil
  if language and pcall(vim.treesitter.start, buffer, language) then
    return
  end
  vim.bo[buffer].syntax = filetype
end

local function is_binary(text)
  return text:find("\0", 1, true) ~= nil
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function split_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  -- a file ending with a newline yields one empty string too many
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

local function escape_statusline(text)
  return (text:gsub("%%", "%%%%"))
end

local function set_winbar(window, text)
  vim.wo[window].winbar = " " .. escape_statusline(text)
end

-- "HEAD · Config.ts  javascript/packages/…": the file name always fits, the folder is cut instead
local function set_file_winbar(window, label, path, suffix)
  local directory = vim.fs.dirname(path)
  vim.wo[window].winbar = (" %s · %%#VcsBranch#%s%%*%s  %%<%%#VcsHint#%s%%*"):format(
    escape_statusline(label),
    escape_statusline(vim.fs.basename(path)),
    escape_statusline(suffix or ""),
    directory == "." and "" or escape_statusline(directory)
  )
end

local function window_valid(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

-- 'diffopt' is global: a VCS or Log tab sets its whitespace option while it is the current tab only
function M.apply_diffopt(state)
  state.saved_diffopt = state.saved_diffopt or vim.o.diffopt
  local options = vim.tbl_filter(function(option)
    return not option:match("^iwhite")
  end, vim.split(state.saved_diffopt, ",", { plain = true }))
  if settings.get("ignore_whitespace") then
    options[#options + 1] = "iwhiteall"
  end
  vim.o.diffopt = table.concat(options, ",")
end

function M.restore_diffopt(state)
  if state.saved_diffopt then
    vim.o.diffopt = state.saved_diffopt
    state.saved_diffopt = nil
  end
end

-- the native gutter respects window-scoped namespaces; snacks' statuscolumn would show the
-- markers in every window of the buffer
local function set_gutter(window, visible)
  local options = visible
      and { number = true, relativenumber = vim.go.relativenumber, signcolumn = "yes:1", statuscolumn = "", foldcolumn = "0" }
    or { number = false, relativenumber = false, signcolumn = "no", statuscolumn = "", foldcolumn = "0" }
  for name, value in pairs(options) do
    vim.wo[window][name] = value
  end
  vim.wo[window].wrap = false
end

function M.create_area(state, window)
  state.diff = { right = window, live_group = vim.api.nvim_create_augroup("vcs_diff_live_" .. window, { clear = true }) }
  set_winbar(window, "Diff")
  set_gutter(window, false)
  vim.api.nvim_win_set_buf(window, scratch_buffer(PLACEHOLDER))
end

local function diff_off(state)
  for _, window in ipairs({ state.diff.left, state.diff.right }) do
    if window_valid(window) and vim.wo[window].diff then
      vim.api.nvim_win_call(window, function()
        vim.cmd("diffoff")
      end)
    end
  end
end

local function close_left(state)
  if window_valid(state.diff.left) then
    vim.api.nvim_win_close(state.diff.left, true)
  end
  state.diff.left = nil
end

local function ensure_left(state)
  if window_valid(state.diff.left) then
    return
  end
  vim.api.nvim_win_call(state.diff.right, function()
    vim.cmd("leftabove vsplit")
    state.diff.left = vim.api.nvim_get_current_win()
  end)
  vim.cmd("wincmd =")
end

-- A real file opened only for the diff must not stay in the buffer list: it is unlisted and
-- unloaded once another file is shown. If it got edited, it stays.
local function release_real_buffer(state)
  local real = state.diff.real
  state.diff.real = nil
  if not (real and vim.api.nvim_buf_is_valid(real.buffer)) then
    return
  end
  pcall(vim.api.nvim_clear_autocmds, { group = state.diff.live_group, buffer = real.buffer })
  vim.api.nvim_buf_clear_namespace(real.buffer, NAMESPACE.right, 0, -1)
  if real.saved_keys then
    M.on_window_leave(state, real)
  end
  local edited = vim.bo[real.buffer].modified or vim.api.nvim_buf_get_changedtick(real.buffer) ~= real.changedtick
  if edited or real.was_listed then
    vim.bo[real.buffer].buflisted = true
    return
  end
  if #vim.fn.win_findbuf(real.buffer) == 0 then
    pcall(vim.api.nvim_buf_delete, real.buffer, {})
  end
end

M.release_real_buffer = release_real_buffer

function M.show_placeholder(state, lines)
  diff_off(state)
  close_left(state)
  set_winbar(state.diff.right, "Diff")
  set_gutter(state.diff.right, false)
  vim.wo[state.diff.right].winhighlight = ""
  vim.api.nvim_win_set_buf(state.diff.right, scratch_buffer(lines or PLACEHOLDER))
  release_real_buffer(state)
  state.diff.shown_id, state.diff.file = nil, nil
end

local function current_working_lines(state)
  return vim.api.nvim_buf_get_lines(state.diff.file.working_buffer, 0, -1, false)
end

local function sign_extmark(buffer, namespace, row, glyph, group)
  vim.api.nvim_buf_set_extmark(buffer, namespace, row, 0, { sign_text = glyph, sign_hl_group = group, priority = 20 })
end

-- markers on both sides for the split view
local function decorate_split(state, changes)
  local file = state.diff.file
  for _, hunk in ipairs(changes) do
    local old_start, old_count, new_start, new_count = unpack(hunk)
    local changed = old_count > 0 and new_count > 0
    for offset = 0, old_count - 1 do
      sign_extmark(file.head_buffer, NAMESPACE.left, old_start - 1 + offset, changed and SIGN.changed or SIGN.only_here, changed and "VcsSignChanged" or "VcsSignRemoved")
    end
    for offset = 0, new_count - 1 do
      sign_extmark(file.working_buffer, NAMESPACE.right, new_start - 1 + offset, changed and SIGN.changed or SIGN.only_here, changed and "VcsSignChanged" or "VcsSignAdded")
    end
    if new_count == 0 and new_start > 0 then
      sign_extmark(file.working_buffer, NAMESPACE.right, new_start - 1, SIGN.removed_below, "VcsSignRemoved")
    end
  end
end

-- chunks of one old line: syntax colours, the removed background, struck-through changed words
local function old_line_chunks(text, syntax, word_ranges, bar)
  local base = bar and "VcsUnifiedRemovedBar" or "VcsUnifiedRemoved"
  local word = bar and "VcsWordRemovedBar" or "VcsWordRemoved"
  local in_word = {}
  for _, range in ipairs(word_ranges or {}) do
    for column = range[1], range[2] - 1 do
      in_word[column] = true
    end
  end
  local function key_at(column)
    return (syntax and syntax[column] or "") .. (in_word[column] and "|word" or "")
  end
  local chunks, start = {}, 0
  for column = 1, #text do
    if column == #text or key_at(column) ~= key_at(start) then
      local groups = { base }
      if syntax and syntax[start] then
        groups[#groups + 1] = syntax[start]
      end
      if in_word[start] then
        groups[#groups + 1] = word
      end
      chunks[#chunks + 1] = { text:sub(start + 1, column), groups }
      start = column
    end
  end
  return chunks
end

-- a virtual line starts at the window edge, so it draws its own gutter: marker and old number
local function gutter_prefix(gutter_width, line_number)
  local number = tostring(line_number)
  local padding = math.max(gutter_width - 3 - #number, 0)
  return { { SIGN.only_here, "VcsSignRemoved" }, { " " .. string.rep(" ", padding) .. number .. " ", "LineNr" } }
end

local function fold_unchanged(window, changes, line_count)
  vim.api.nvim_win_call(window, function()
    vim.wo.foldmethod = "manual"
    vim.cmd("normal! zE")
    local next_unchanged = 1
    local function fold(first, last)
      if last - first >= 2 then
        vim.cmd(("%d,%dfold"):format(first, last))
      end
    end
    for _, hunk in ipairs(changes) do
      local new_start, new_count = hunk[3], hunk[4]
      local change_row = new_count > 0 and new_start or new_start + 1
      local first = next_unchanged == 1 and 1 or next_unchanged + UNCHANGED_CONTEXT
      fold(first, change_row - 1 - UNCHANGED_CONTEXT)
      next_unchanged = new_start + math.max(new_count, 1)
    end
    fold(next_unchanged + UNCHANGED_CONTEXT, line_count)
    vim.wo.foldlevel = 0
  end)
end

-- unified view: old lines as virtual lines, new lines marked in place
local function decorate_unified(state, changes, refold)
  local file, window = state.diff.file, state.diff.right
  local bar = settings.get("highlight") == "bar"
  local working_lines = current_working_lines(state)
  local wanted = {}
  for _, hunk in ipairs(changes) do
    for offset = 0, hunk[2] - 1 do
      wanted[hunk[1] + offset] = true
    end
  end
  local syntax = hunks.syntax_groups(file.head_lines, file.path, wanted)
  local window_width = vim.api.nvim_win_get_width(window)
  local gutter_width = vim.fn.getwininfo(window)[1].textoff

  for _, hunk in ipairs(changes) do
    local old_start, old_count, new_start, new_count = unpack(hunk)
    local changed = old_count > 0 and new_count > 0
    local virtual_lines = {}
    for offset = 0, old_count - 1 do
      local old_line = file.head_lines[old_start + offset] or ""
      local new_line = changed and offset < new_count and working_lines[new_start + offset] or nil
      local words = new_line and hunks.word_changes(old_line, new_line)
      local chunks = gutter_prefix(gutter_width, old_start + offset)
      vim.list_extend(chunks, old_line_chunks(old_line, syntax[old_start + offset], words and words.old, bar))
      if not bar then
        -- the background runs to the window edge, like on a real line
        local used = vim.fn.strdisplaywidth(old_line) + gutter_width
        chunks[#chunks + 1] = { string.rep(" ", math.max(window_width - used, 0)), "VcsUnifiedRemoved" }
      end
      virtual_lines[#virtual_lines + 1] = chunks
    end
    if #virtual_lines > 0 then
      -- above the replacing lines; for a pure deletion below the line it followed
      local above = new_count > 0 or new_start == 0
      local row = (new_count > 0 and new_start - 1) or math.max(new_start - 1, 0)
      vim.api.nvim_buf_set_extmark(file.working_buffer, NAMESPACE.right, row, 0, {
        virt_lines = virtual_lines,
        virt_lines_above = above,
        virt_lines_leftcol = true,
      })
    end
    for offset = 0, new_count - 1 do
      local row = new_start - 1 + offset
      vim.api.nvim_buf_set_extmark(file.working_buffer, NAMESPACE.right, row, 0, {
        sign_text = changed and SIGN.changed or SIGN.only_here,
        sign_hl_group = changed and "VcsSignChanged" or "VcsSignAdded",
        line_hl_group = not bar and "VcsUnifiedAdded" or nil,
        priority = 20,
      })
      local old_line = changed and offset < old_count and file.head_lines[old_start + offset] or nil
      local words = old_line and hunks.word_changes(old_line, working_lines[new_start + offset] or "")
      for _, range in ipairs(words and words.new or {}) do
        vim.api.nvim_buf_set_extmark(file.working_buffer, NAMESPACE.right, row, range[1], {
          end_col = range[2],
          hl_group = bar and "VcsWordAddedBar" or "VcsWordAdded",
          priority = 200,
        })
      end
    end
  end
  if refold then
    fold_unchanged(window, changes, #working_lines)
  end
end

--- Repaint the markers of the shown file in the current view. refold — rebuild folds over the
--- unchanged lines (not while the user types: it would close folds under the cursor).
function M.decorate(state, refold)
  local file = state.diff.file
  if not file or not vim.api.nvim_buf_is_valid(file.working_buffer) or not window_valid(state.diff.right) then
    return
  end
  local unified = settings.get("view") == "unified"
  for side, buffer in pairs({ left = file.head_buffer, right = file.working_buffer }) do
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_clear_namespace(buffer, NAMESPACE[side], 0, -1)
    end
  end
  vim.api.nvim__ns_set(NAMESPACE.right, { wins = { state.diff.right } })
  if window_valid(state.diff.left) then
    vim.api.nvim__ns_set(NAMESPACE.left, { wins = { state.diff.left } })
  end

  local bar = settings.get("highlight") == "bar"
  local bar_highlights = "DiffAdd:VcsDiffPlain,DiffChange:VcsDiffPlain,DiffText:VcsDiffTextBar,DiffDelete:VcsDiffFillerBar"
  for _, window in ipairs({ state.diff.left, state.diff.right }) do
    if window_valid(window) then
      vim.wo[window].winhighlight = (bar and not unified) and bar_highlights or ""
    end
  end

  local changes = hunks.compute(file.head_lines, current_working_lines(state), { ignore_whitespace = settings.get("ignore_whitespace") })
  state.diff.changes = changes
  if unified then
    decorate_unified(state, changes, refold)
  else
    decorate_split(state, changes)
  end
end

local function change_rows(state)
  local rows = {}
  for _, hunk in ipairs(state.diff.changes or {}) do
    rows[#rows + 1] = math.max(hunk[4] > 0 and hunk[3] or hunk[3] + 1, 1)
  end
  return rows
end

--- ]c / [c in the unified view, where nvim's diff mode is off.
function M.jump(state, direction)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rows = change_rows(state)
  if direction < 0 then
    rows = vim.fn.reverse(rows)
  end
  for _, target in ipairs(rows) do
    if (direction > 0 and target > row) or (direction < 0 and target < row) then
      vim.api.nvim_win_set_cursor(0, { math.min(target, vim.api.nvim_buf_line_count(0)), 0 })
      vim.cmd("normal! zvzz")
      return
    end
  end
end

-- `?` (and ]c [c in the unified view) inside the diff windows. On the real file they exist only
-- while the diff window has focus, so the same file in an editor tab keeps its own keys.
local DIFF_KEYS = { "?", "]c", "[c" }

local function map_diff_keys(state, buffer, remember_existing)
  local saved = {}
  local function map(lhs, action, description)
    if remember_existing then
      local existing = vim.fn.maparg(lhs, "n", false, true)
      saved[lhs] = existing.buffer == 1 and existing or false
    end
    vim.keymap.set("n", lhs, action, { buffer = buffer, nowait = true, desc = description })
  end
  map("?", function()
    state.open_menu("diff")
  end, "VCS: keys and view options")
  if settings.get("view") == "unified" then
    map("]c", function()
      M.jump(state, 1)
    end, "VCS: next change")
    map("[c", function()
      M.jump(state, -1)
    end, "VCS: previous change")
  end
  return saved
end

--- Called on WinEnter in the VCS tab: give the real file the diff keys while it has focus.
function M.on_window_enter(state)
  local real = state.diff.real
  if not real or real.saved_keys then
    return
  end
  if vim.api.nvim_get_current_win() == state.diff.right and vim.api.nvim_get_current_buf() == real.buffer then
    real.saved_keys = map_diff_keys(state, real.buffer, true)
  end
end

--- Called on WinLeave: take the keys back and restore what the buffer had before.
function M.on_window_leave(state, real)
  real = real or state.diff.real
  if not (real and real.saved_keys and vim.api.nvim_buf_is_valid(real.buffer)) then
    return
  end
  for _, lhs in ipairs(DIFF_KEYS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = real.buffer })
    if real.saved_keys[lhs] then
      vim.fn.mapset("n", false, real.saved_keys[lhs])
    end
  end
  real.saved_keys = nil
end

-- the preview copy turns into the real file as soon as the user tries to edit it
local function map_preview_keys(state, buffer)
  map_diff_keys(state, buffer, false)
  for _, key in ipairs({ "i", "a", "o", "O", "I", "A", "<CR>" }) do
    vim.keymap.set("n", key, function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      M.start_editing(state)
      pcall(vim.api.nvim_win_set_cursor, state.diff.right, cursor)
      if key ~= "<CR>" then
        vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
      end
    end, { buffer = buffer, nowait = true, desc = "VCS: edit the real file" })
  end
  vim.keymap.set("n", "q", function()
    state.close()
  end, { buffer = buffer, nowait = true, desc = "VCS: close" })
end

local function arrange(state, refold)
  local file = state.diff.file
  local unified = settings.get("view") == "unified"
  diff_off(state)
  if unified then
    close_left(state)
  else
    ensure_left(state)
    if not (file.head_buffer and vim.api.nvim_buf_is_valid(file.head_buffer)) then
      file.head_buffer = scratch_buffer(file.head_lines)
      pcall(vim.api.nvim_buf_set_name, file.head_buffer, "vcs://" .. (file.left_label or "HEAD") .. "/" .. file.head_path)
      highlight_syntax(file.head_buffer, file.path)
      map_diff_keys(state, file.head_buffer, false)
      vim.keymap.set("n", "q", function()
        state.close()
      end, { buffer = file.head_buffer, nowait = true, desc = "VCS: close" })
      if state.map_extra_keys then
        state.map_extra_keys(file.head_buffer)
      end
    end
    vim.api.nvim_win_set_buf(state.diff.left, file.head_buffer)
    set_gutter(state.diff.left, true)
    if file.in_head then
      set_file_winbar(state.diff.left, file.left_label or "HEAD", file.head_path)
    else
      set_winbar(state.diff.left, file.left_missing or "New file — not in HEAD")
    end
  end
  if vim.api.nvim_win_get_buf(state.diff.right) ~= file.working_buffer then
    vim.api.nvim_win_set_buf(state.diff.right, file.working_buffer)
  end
  set_gutter(state.diff.right, true)
  local label = file.right_label or (file.deleted and "Deleted" or (file.editing and "Working copy" or "Working copy · preview"))
  set_file_winbar(state.diff.right, label, file.path, file.editing and "  ✎" or "")
  if not unified then
    for _, window in ipairs({ state.diff.left, state.diff.right }) do
      vim.api.nvim_win_call(window, function()
        vim.cmd("diffthis")
      end)
      -- diffthis turns on a 2-wide fold column; the folds work without it
      vim.wo[window].foldcolumn = "0"
    end
  end
  M.decorate(state, refold)
end

--- Re-lay out the shown file after a view setting changed.
function M.apply_view(state)
  if not state.diff.file then
    return
  end
  M.on_window_leave(state)
  arrange(state, true)
  M.on_window_enter(state)
end

local function jump_to_first_change(state)
  local rows = change_rows(state)
  vim.api.nvim_win_call(state.diff.right, function()
    vim.api.nvim_win_set_cursor(0, { math.min(rows[1] or 1, vim.api.nvim_buf_line_count(0)), 0 })
    vim.cmd("normal! zvzz")
  end)
end

local function live_update(state, buffer)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.diff.live_group,
    buffer = buffer,
    callback = function()
      state.decorate_timer:stop()
      state.decorate_timer:start(150, 0, vim.schedule_wrap(function()
        if state.diff.real and state.diff.real.buffer == buffer then
          M.decorate(state, false)
        end
      end))
    end,
  })
end

--- Swap the read-only preview for the real file and focus it.
function M.start_editing(state)
  local file = state.diff.file
  if not file or file.deleted then
    return
  end
  if not file.editing then
    -- the real file opens where the preview cursor was, usually on the first change
    local cursor = vim.api.nvim_win_get_cursor(state.diff.right)
    local listed_before = {}
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      listed_before[buffer] = vim.bo[buffer].buflisted
    end
    vim.api.nvim_win_call(state.diff.right, function()
      vim.cmd.edit(vim.fn.fnameescape(file.absolute_path))
    end)
    local buffer = vim.api.nvim_win_get_buf(state.diff.right)
    release_real_buffer(state)
    if not listed_before[buffer] then
      vim.bo[buffer].buflisted = false
    end
    state.diff.real = { buffer = buffer, changedtick = vim.api.nvim_buf_get_changedtick(buffer), was_listed = listed_before[buffer] }
    file.working_buffer, file.editing = buffer, true
    live_update(state, buffer)
    arrange(state, true)
    pcall(vim.api.nvim_win_set_cursor, state.diff.right, cursor)
    vim.api.nvim_win_call(state.diff.right, function()
      vim.cmd("normal! zv")
    end)
  end
  vim.api.nvim_set_current_win(state.diff.right)
  M.on_window_enter(state)
end

-- a file open in the editor may hold unsaved edits: the preview shows what the user sees
local function loaded_buffer_lines(path)
  local real_path = vim.uv.fs_realpath(path)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if name ~= "" and vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].buftype == "" and vim.uv.fs_realpath(name) == real_path then
      return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    end
  end
end

local function open_file(state, node, head_lines, options)
  local entry = node.entry
  local absolute_path = vim.fs.joinpath(state.root, entry.path)
  local working_text = read_file(absolute_path)
  if working_text and is_binary(working_text) then
    return M.show_placeholder(state, { "", "  Binary file: " .. entry.path })
  end
  local working_lines = working_text and (loaded_buffer_lines(absolute_path) or split_lines(working_text)) or {}

  local previous = state.diff.file
  local file = {
    id = node.id,
    path = entry.path,
    head_path = entry.original_path or entry.path,
    absolute_path = absolute_path,
    head_lines = head_lines,
    in_head = #head_lines > 0 or not (entry.group == "unversioned" or entry.staged == "A"),
    deleted = working_text == nil,
  }
  local keep_real = previous and previous.id == node.id and previous.editing and state.diff.real and vim.api.nvim_buf_is_valid(state.diff.real.buffer)
  if keep_real then
    -- the real file stays open while its own diff is refreshed (after a commit, say)
    file.working_buffer, file.editing = state.diff.real.buffer, true
  else
    M.on_window_leave(state)
    file.working_buffer = scratch_buffer(working_lines)
    pcall(vim.api.nvim_buf_set_name, file.working_buffer, "vcs://working/" .. entry.path)
    highlight_syntax(file.working_buffer, entry.path)
    map_preview_keys(state, file.working_buffer)
    vim.api.nvim_win_set_buf(state.diff.right, file.working_buffer)
    release_real_buffer(state)
  end

  state.diff.file, state.diff.shown_id = file, node.id
  arrange(state, true)
  if not options.keep_position then
    jump_to_first_change(state)
  end
  if options.focus then
    M.start_editing(state)
  end
end

-- a file inside a commit: nothing to edit, so no preview keys — only the diff keys and q
local function open_revisions(state, spec, old_lines, new_lines, options)
  M.on_window_leave(state)
  local buffer = scratch_buffer(new_lines)
  pcall(vim.api.nvim_buf_set_name, buffer, ("vcs://%s/%s"):format(spec.new_label, spec.path))
  highlight_syntax(buffer, spec.path)
  map_diff_keys(state, buffer, false)
  vim.keymap.set("n", "q", function()
    state.close()
  end, { buffer = buffer, nowait = true, desc = "VCS: close" })
  if state.map_extra_keys then
    state.map_extra_keys(buffer)
  end
  vim.api.nvim_win_set_buf(state.diff.right, buffer)
  release_real_buffer(state)
  state.diff.file = {
    id = spec.id,
    path = spec.path,
    head_path = spec.old_path or spec.path,
    head_lines = old_lines,
    in_head = spec.old_revision ~= nil,
    deleted = spec.new_revision == nil,
    working_buffer = buffer,
    revision = true,
    left_label = spec.old_label,
    left_missing = "Added in " .. spec.new_label,
    right_label = spec.new_revision and spec.new_label or ("Deleted in " .. spec.new_label),
  }
  state.diff.shown_id = spec.id
  arrange(state, true)
  jump_to_first_change(state)
  if options.focus then
    vim.api.nvim_set_current_win(state.diff.right)
  end
end

--- The diff of a file inside a commit, for the Log: spec = { id, path, old_path, old_revision,
--- new_revision, old_label, new_label }. A revision is nil when the commit added or deleted the
--- file. options.focus — jump into the diff.
function M.show_revisions(state, spec, options)
  options = options or {}
  if spec.id == state.diff.shown_id and window_valid(state.diff.right) then
    if options.focus then
      vim.api.nvim_set_current_win(state.diff.right)
    end
    return
  end
  state.diff.requested_id = spec.id
  local sides, pending = {}, 2
  local function finished()
    pending = pending - 1
    if pending > 0 or state.diff.requested_id ~= spec.id or not window_valid(state.diff.right) then
      return
    end
    if sides.old.binary or sides.new.binary then
      return M.show_placeholder(state, { "", "  Binary file: " .. spec.path })
    end
    open_revisions(state, spec, sides.old.lines, sides.new.lines, options)
  end
  local function load(side, revision, path)
    if not revision then
      sides[side] = { lines = {} }
      return finished()
    end
    git.run(state.root, { "show", revision .. ":" .. path }, function(ok, stdout)
      sides[side] = { lines = ok and split_lines(stdout) or {}, binary = ok and is_binary(stdout) }
      finished()
    end)
  end
  load("old", spec.old_revision, spec.old_path or spec.path)
  load("new", spec.new_revision, spec.path)
end

--- Show the diff of a file. options.focus — open the real file and jump into it (Enter);
--- options.reload — re-read HEAD for the file already shown (after a commit), cursor stays.
function M.show(state, node, options)
  options = options or {}
  if not node or node.kind ~= "file" then
    return
  end
  if not options.reload and node.id == state.diff.shown_id and window_valid(state.diff.right) then
    if options.focus then
      M.start_editing(state)
    end
    return
  end
  -- while git answers about one file the cursor may already be on the next: show the latest only
  state.diff.requested_id = node.id
  local entry = node.entry
  if entry.path:sub(-1) == "/" then
    return M.show_placeholder(state, { "", "  Unversioned folder: " .. entry.path, "", "  x — add it as a whole" })
  end
  if entry.submodule then
    return M.show_placeholder(state, { "", "  Submodule: " .. entry.path })
  end
  local in_head = not (entry.group == "unversioned" or entry.staged == "A" or state.status.unborn)
  local open_options = { focus = options.focus, keep_position = options.reload }
  if not in_head then
    return open_file(state, node, {}, open_options)
  end
  local requested_id = node.id
  git.run(state.root, { "show", "HEAD:" .. (entry.original_path or entry.path) }, function(ok, stdout)
    if state.diff.requested_id ~= requested_id or not window_valid(state.diff.right) then
      return
    end
    if ok and is_binary(stdout) then
      return M.show_placeholder(state, { "", "  Binary file: " .. entry.path })
    end
    open_file(state, node, ok and split_lines(stdout) or {}, open_options)
  end)
end

return M
