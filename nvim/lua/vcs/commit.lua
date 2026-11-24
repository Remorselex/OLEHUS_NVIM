-- The commit message under the panel — IntelliJ's Commit Message field.
-- Ctrl-K commits, Ctrl-P / Ctrl-N walk your earlier messages; the draft survives a restart
-- (it lives in .git/VCS_COMMIT_DRAFT and never reaches the repository).
local git = require("vcs.git")
local ask = require("vcs.ask")
local output = require("vcs.output")
local push = require("vcs.push")

local M = {}

local placeholder_namespace = vim.api.nvim_create_namespace("vcs_message_placeholder")

local function message_text(state)
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.message.buffer, 0, -1, false), "\n"))
end

local function set_message(state, text)
  vim.api.nvim_buf_set_lines(state.message.buffer, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

local function draft_path(state)
  return vim.fs.joinpath(state.git_dir, "VCS_COMMIT_DRAFT")
end

function M.save_draft(state)
  if not (state.message and vim.api.nvim_buf_is_valid(state.message.buffer)) then
    return
  end
  local text = message_text(state)
  if text == "" or text == state.amend_message then
    os.remove(draft_path(state))
    return
  end
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), draft_path(state))
end

-- during a merge, a cherry-pick or a revert git has a message ready
local function prepared_message(state)
  local path = vim.fs.joinpath(state.git_dir, "MERGE_MSG")
  if not vim.uv.fs_stat(path) then
    return nil
  end
  local lines = vim.tbl_filter(function(line)
    return not vim.startswith(line, "#")
  end, vim.fn.readfile(path))
  return vim.trim(table.concat(lines, "\n"))
end

local function initial_message(state)
  if vim.uv.fs_stat(draft_path(state)) then
    return table.concat(vim.fn.readfile(draft_path(state)), "\n")
  end
  state.merge_message = prepared_message(state)
  return state.merge_message or ""
end

--- After each refresh: an operation that just stopped on conflicts brings its message into the
--- empty field; once git committed it itself (M → Continue), the message leaves the field again.
function M.sync_prepared_message(state)
  local prepared = prepared_message(state)
  local text = message_text(state)
  if prepared and prepared ~= "" and text == "" then
    set_message(state, prepared)
    state.merge_message = prepared
    return
  end
  if prepared or not state.merge_message then
    return
  end
  if text == state.merge_message then
    set_message(state, "")
    os.remove(draft_path(state))
  end
  state.merge_message = nil
end

local function update_placeholder(state)
  local buffer = state.message.buffer
  vim.api.nvim_buf_clear_namespace(buffer, placeholder_namespace, 0, -1)
  if vim.api.nvim_buf_line_count(buffer) > 1 or vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1] ~= "" then
    return
  end
  vim.api.nvim_buf_set_extmark(buffer, placeholder_namespace, 0, 0, {
    virt_text = { { "Commit message…", "VcsHint" } },
    virt_text_pos = "overlay",
  })
end

function M.update_winbar(state)
  local window = state.message and state.message.window
  if not (window and vim.api.nvim_win_is_valid(window)) then
    return
  end
  local parts = { "%#VcsBranch# Commit%*" }
  if state.amend then
    parts[#parts + 1] = "%#VcsAmend# amend %*"
  end
  parts[#parts + 1] = "%=%#VcsHint#C-k commit  C-p/C-n history %*"
  vim.wo[window].winbar = table.concat(parts, " ")
end

local function load_history(state, on_loaded)
  if state.history then
    return on_loaded()
  end
  local _, email = git.run_sync(state.root, { "config", "user.email" })
  local args = { "log", "-n", "200", "--format=%B%x00" }
  if vim.trim(email) ~= "" then
    args[#args + 1] = "--author=" .. vim.trim(email)
  end
  git.run(state.root, args, function(ok, stdout)
    state.history, state.history_position = {}, 0
    local seen = {}
    for _, message in ipairs(ok and vim.split(stdout, "\0", { plain = true }) or {}) do
      message = vim.trim(message)
      if message ~= "" and not seen[message] then
        seen[message] = true
        state.history[#state.history + 1] = message
      end
    end
    on_loaded()
  end)
end

--- direction 1 — an older message, -1 — a newer one; position 0 brings back what was typed.
function M.history_step(state, direction)
  load_history(state, function()
    local position = state.history_position + direction
    if position < 0 or position > #state.history then
      return
    end
    if state.history_position == 0 then
      state.history_draft = message_text(state)
    end
    state.history_position = position
    set_message(state, position == 0 and state.history_draft or state.history[position])
  end)
end

function M.toggle_amend(state)
  if state.status.unborn then
    vim.notify("Nothing to amend: there are no commits yet", vim.log.levels.WARN, { title = "Git" })
    return
  end
  state.amend = not state.amend
  if state.amend then
    local ok, head_message = git.run_sync(state.root, { "log", "-1", "--format=%B" })
    state.amend_message = ok and vim.trim(head_message) or ""
    if message_text(state) == "" then
      set_message(state, state.amend_message)
    end
  elseif message_text(state) == state.amend_message then
    set_message(state, "")
  end
  M.update_winbar(state)
end

function M.run_commit(state, args, message, push_after)
  state.busy = "committing"
  state.render()
  git.queue(state.root, args, function(ok, stdout, stderr)
    state.busy = nil
    if not ok then
      output.show(state.tab, "Commit failed", stdout .. "\n" .. stderr)
      state.refresh()
      return
    end
    local hash = stdout:match("%[[^%]]- (%x+)%]") or ""
    vim.notify(("Committed %s: %s"):format(hash, message:match("^[^\n]*")), vim.log.levels.INFO, { title = "Git" })
    set_message(state, "")
    state.amend, state.amend_message, state.history = false, nil, nil
    os.remove(draft_path(state))
    M.update_winbar(state)
    state.refresh()
    if push_after then
      -- like Commit and Push in IntelliJ: the push dialog shows what is about to leave
      push.open(state)
    end
  end, { stdin = message .. "\n" })
end

function M.commit(state, push_after)
  local message = message_text(state)
  if message == "" then
    vim.notify("Write a commit message first", vim.log.levels.WARN, { title = "Git" })
    if state.message.window and vim.api.nvim_win_is_valid(state.message.window) then
      vim.api.nvim_set_current_win(state.message.window)
    end
    return
  end
  local has_conflicts, has_staged, has_changes = false, false, false
  for _, entry in ipairs(state.status.entries) do
    has_conflicts = has_conflicts or entry.group == "conflicts"
    has_staged = has_staged or (entry.group == "changes" and entry.staged ~= ".")
    has_changes = has_changes or entry.group == "changes"
  end
  if has_conflicts then
    vim.notify("Resolve the merge conflicts first", vim.log.levels.WARN, { title = "Git" })
    return
  end
  local merging = vim.uv.fs_stat(vim.fs.joinpath(state.git_dir, "MERGE_HEAD")) ~= nil
  local args = { "commit", "--file=-" }
  if state.amend then
    args[#args + 1] = "--amend"
  end
  if has_staged or state.amend or merging then
    return M.run_commit(state, args, message, push_after)
  end
  if not has_changes then
    vim.notify("Nothing to commit: check files with x", vim.log.levels.WARN, { title = "Git" })
    return
  end
  ask("Nothing is checked. Commit all changes to tracked files?", "Commit all", function()
    M.run_commit(state, vim.list_extend(args, { "--all" }), message, push_after)
  end)
end

--- The message buffer lives as long as the VCS tab; its window comes and goes with the panel.
function M.create(state)
  local buffer = vim.api.nvim_create_buf(false, true)
  state.message = { buffer = buffer }
  pcall(vim.api.nvim_buf_set_name, buffer, "vcs://" .. vim.fs.basename(state.root) .. "/message")
  -- :w and Ctrl-S out of habit must not throw errors: they just save the draft
  vim.bo[buffer].buftype = "acwrite"
  vim.bo[buffer].swapfile = false
  vim.b[buffer].completion = false
  vim.b[buffer].snacks_scroll = false
  set_message(state, initial_message(state))
  vim.bo[buffer].modified = false

  local group = vim.api.nvim_create_augroup("vcs_message_" .. buffer, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buffer,
    callback = function()
      update_placeholder(state)
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    buffer = buffer,
    callback = function()
      M.save_draft(state)
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buffer,
    callback = function()
      M.save_draft(state)
      vim.bo[buffer].modified = false
    end,
  })

  local function map(modes, lhs, action, description)
    vim.keymap.set(modes, lhs, action, { buffer = buffer, nowait = true, desc = description })
  end
  map({ "n", "i" }, "<C-k>", function()
    vim.cmd.stopinsert()
    M.commit(state, false)
  end, "Commit")
  map({ "n", "i" }, "<C-p>", function()
    M.history_step(state, 1)
  end, "Older message")
  map({ "n", "i" }, "<C-n>", function()
    M.history_step(state, -1)
  end, "Newer message")
  map("n", "q", function()
    state.close()
  end, "Close the VCS tab")
  map("n", "?", function()
    state.open_menu("panel")
  end, "Keys and view options")
end

function M.show_in(state, window)
  local buffer = state.message.buffer
  state.message.window = window
  vim.api.nvim_win_set_buf(window, buffer)
  if vim.bo[buffer].filetype ~= "gitcommit" then
    vim.api.nvim_win_call(window, function()
      vim.bo[buffer].filetype = "gitcommit"
    end)
  end
  local options = {
    -- LazyVim turns spelling on for gitcommit, and messages are not always English
    spell = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    statuscolumn = "",
    foldcolumn = "0",
    cursorline = false,
    winfixheight = true,
    winfixwidth = true,
  }
  for name, value in pairs(options) do
    vim.wo[window][name] = value
  end
  update_placeholder(state)
  M.update_winbar(state)
end

return M
