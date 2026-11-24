-- One float for help and view options, opened with `?` in the panel or in the diff.
-- A key from the "View" section changes the setting at once and the float redraws in place,
-- so the effect is visible behind it.
local settings = require("vcs.settings")
local update = require("vcs.update")

local M = {}

local namespace = vim.api.nvim_create_namespace("vcs_menu")

local PANEL_KEYS = {
  { "x", "check / uncheck (visual mode: the selection)" },
  { "X", "check / uncheck all changes" },
  { "Enter", "edit the file in the diff · on a folder: fold" },
  { "e", "open the file in an editor tab" },
  { "l  h", "expand / collapse · h on a file: go to its folder" },
  { "u", "roll back to HEAD (asks first)" },
  { "c", "write the commit message" },
  { "C  P", "commit · commit and open the push dialog" },
  { "p", "push dialog: what leaves and where to" },
  { "A", "amend the last commit" },
  { "L  B", "Log · branches" },
  { "U", "Update Project: fetch, then merge or rebase" },
  { "M", "continue / skip / abort a rebase or merge in progress" },
  { "W", "worktrees: one branch per directory, each in its own tab" },
  { "t", "tree / flat list" },
  { "<  >", "panel narrower / wider" },
  { "R  q", "refresh · close the VCS tab" },
}

local LOG_KEYS = {
  { "j  k", "next / previous commit" },
  { "Enter  l", "to the files of the commit · Tab: files → diff → commits" },
  { "/  a  b", "filter: message text · author · branch" },
  { "f  d  F", "filter: path · date · clear all filters" },
  { "y", "copy the hash" },
  { "c", "cherry-pick (V: several commits)" },
  { "v", "revert: a new commit undoes this one" },
  { "n  t", "new branch here · new tag here" },
  { "X  o", "reset the current branch to here · check out (detached)" },
  { "B  U  p  W", "branches · Update Project · push dialog · worktrees" },
  { "M", "continue / abort a rebase or merge in progress" },
  { "R  q", "reload · close the Log" },
  { "", "in the files: Enter diff · e open in the editor · h back" },
}

local REVISION_KEYS = {
  { "]c  [c", "next / previous change" },
  { "Tab  S-Tab", "to the commits · to the files" },
  { "q", "close the Log" },
}

local KEYS = {
  panel = { "Changes panel", PANEL_KEYS },
  diff = { "Diff", DIFF_KEYS },
  log = { "Log", LOG_KEYS },
  revision = { "Diff of the commit", REVISION_KEYS },
}

local DIFF_KEYS = {
  { "]c  [c", "next / previous change" },
  { "i a o Enter", "edit the real file (the preview is read-only)" },
  { "Space g h s", "stage the hunk · r: reset it (gitsigns, real file)" },
  { "C-k", "commit, from the message field · C-p C-n: history" },
}

local function view_options(state)
  local view, highlight = settings.get("view"), settings.get("highlight")
  local options = {
    { key = "1", label = "one pane: old lines above new ones", on = view == "unified", apply = function()
      settings.set("view", "unified")
    end },
    { key = "2", label = "two panes: before | after", on = view == "split", apply = function()
      settings.set("view", "split")
    end },
    { key = "h", label = "highlight", value = highlight == "full" and "whole line" or "gutter bar only", apply = function()
      settings.set("highlight", highlight == "full" and "bar" or "full")
    end },
    { key = "w", label = "ignore whitespace", value = settings.get("ignore_whitespace") and "on" or "off", apply = function()
      settings.set("ignore_whitespace", not settings.get("ignore_whitespace"))
    end },
  }
  -- the Log has no changes tree
  if state.toggle_panel then
    options[#options + 1] = { key = "T", label = "tree panel", value = state.panel_hidden and "hidden" or "shown", apply = function()
      state.toggle_panel()
    end }
    options[#options + 1] = { key = "<  >", label = "tree width", value = state.panel_width() .. " columns" }
  end
  local method = update.method(state.root)
  options[#options + 1] = { key = "u", label = "Update Project by", value = method, apply = function()
    settings.set("update_method", method == "rebase" and "merge" or "rebase")
  end }
  return options
end

local function build(state, origin)
  local lines, marks = {}, {}
  local function heading(text)
    lines[#lines + 1] = " " .. text
    marks[#marks + 1] = { #lines - 1, 1, #lines[#lines], "VcsGroup" }
  end
  local function key_line(key, text)
    local padded = (" %-12s"):format(key)
    lines[#lines + 1] = padded .. text
    marks[#marks + 1] = { #lines - 1, 1, #padded, "VcsMenuKey" }
  end

  local keys = KEYS[origin] or KEYS.diff
  heading(keys[1])
  for _, item in ipairs(keys[2]) do
    key_line(item[1], item[2])
  end
  lines[#lines + 1] = ""
  heading("Options — press the key to change")
  for _, option in ipairs(view_options(state)) do
    local marker = option.on == nil and "  " or (option.on and "● " or "○ ")
    local padded = (" %-12s"):format(option.key)
    local text = padded .. marker .. option.label .. (option.value and ("  " .. option.value) or "")
    lines[#lines + 1] = text
    marks[#marks + 1] = { #lines - 1, 1, #padded, "VcsMenuKey" }
    if option.on then
      marks[#marks + 1] = { #lines - 1, #padded, #padded + #marker, "VcsMenuOn" }
    end
    if option.value then
      marks[#marks + 1] = { #lines - 1, #text - #option.value, #text, "VcsMenuOn" }
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " q / Esc / ?  close"
  marks[#marks + 1] = { #lines - 1, 0, #lines[#lines], "VcsHint" }
  return lines, marks
end

function M.open(state, origin)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  local window
  -- a view change rebuilds windows behind the float, and nvim's "previous window" moves with it;
  -- focus has to go back where `?` was pressed
  local opened_from = vim.api.nvim_get_current_win()

  local function render()
    local lines, marks = build(state, origin)
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
    for _, mark in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(buffer, namespace, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
    end
    local width = 0
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    local config = {
      relative = "editor",
      width = width + 1,
      height = #lines,
      row = math.max(math.floor((vim.o.lines - #lines) / 2) - 1, 0),
      col = math.floor((vim.o.columns - width) / 2),
    }
    if window and vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_set_config(window, config)
      return
    end
    window = vim.api.nvim_open_win(buffer, true, vim.tbl_extend("force", config, {
      border = "rounded",
      title = " VCS ",
      title_pos = "center",
      style = "minimal",
    }))
  end

  -- refocus only when closed with a key; leaving the float by other means keeps that choice
  local closed = false
  local function close(refocus)
    -- closing the float fires its own WinLeave, which lands here a second time
    if closed then
      return
    end
    closed = true
    if window and vim.api.nvim_win_is_valid(window) then
      pcall(vim.api.nvim_win_close, window, true)
    end
    if not refocus then
      return
    end
    for _, candidate in ipairs({ opened_from, state.panel and state.panel.window, state.diff.right }) do
      if candidate and vim.api.nvim_win_is_valid(candidate) then
        vim.api.nvim_set_current_win(candidate)
        return
      end
    end
  end

  local function act(apply)
    return function()
      apply()
      state.on_view_changed()
      render()
    end
  end

  render()
  for _, option in ipairs(view_options(state)) do
    if option.apply then
      vim.keymap.set("n", option.key, act(option.apply), { buffer = buffer, nowait = true })
    end
  end
  if state.resize_panel then
    vim.keymap.set("n", "<", act(function()
      state.resize_panel(-5)
    end), { buffer = buffer, nowait = true })
    vim.keymap.set("n", ">", act(function()
      state.resize_panel(5)
    end), { buffer = buffer, nowait = true })
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, function()
      close(true)
    end, { buffer = buffer, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buffer,
    once = true,
    callback = function()
      close(false)
    end,
  })
end

return M
