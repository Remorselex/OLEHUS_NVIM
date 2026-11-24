-- A float with a list for the branch and push dialogs. The caller builds the lines; a line may
-- carry an item, and keys act on the item under the cursor. Like the `?` menu it closes on q or
-- Esc, or when focus leaves it, and gives focus back to the window it was opened from.
local M = {}

local namespace = vim.api.nvim_create_namespace("vcs_float")

local function window_valid(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

--- spec = {
---   title = " Branches ",
---   build = function() return lines, marks, items end,  -- marks: { row, start_col, end_col, group }; items[line] = item
---   keys = { { "<CR>", function(item, view) end, "description" }, ... },
---   first_line = function(items) return line end,      -- where the cursor starts (optional)
---   item_navigation = true,                             -- j / k step over lines without an item
---   on_close = function() end,
--- }
--- Returns a view: view.refresh(options), view.close(), view.item(), view.ask(fn) — see below.
--- view.refresh({ reset_cursor = true }) puts the cursor back on first_line (after filtering).
function M.open(spec)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.b[buffer].snacks_scroll = false
  local opened_from = vim.api.nvim_get_current_win()
  local view = { buffer = buffer, items = {} }
  local closed = false
  -- while a question of an action is on screen (a name, a confirmation) the float stays
  local asking = false

  local function place(lines)
    local width = spec.min_width or 50
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line) + 1)
    end
    width = math.min(width, vim.o.columns - 8)
    local height = math.max(math.min(#lines, vim.o.lines - 6), 1)
    return {
      relative = "editor",
      width = width,
      height = height,
      row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
      col = math.floor((vim.o.columns - width) / 2),
    }
  end

  function view.refresh(options)
    if closed then
      return
    end
    local lines, marks, items = spec.build()
    view.items = items or {}
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
    for _, mark in ipairs(marks or {}) do
      vim.api.nvim_buf_set_extmark(buffer, namespace, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
    end
    local config = place(lines)
    if window_valid(view.window) then
      vim.api.nvim_win_set_config(view.window, config)
      local first = options and options.reset_cursor and spec.first_line and spec.first_line(view.items)
      local line = first or math.min(vim.api.nvim_win_get_cursor(view.window)[1], #lines)
      vim.api.nvim_win_set_cursor(view.window, { math.max(line, 1), 0 })
      return
    end
    view.window = vim.api.nvim_open_win(buffer, true, vim.tbl_extend("force", config, {
      border = "rounded",
      title = spec.title,
      title_pos = "center",
      style = "minimal",
    }))
    vim.wo[view.window].cursorline = true
    vim.wo[view.window].wrap = false
    local first = spec.first_line and spec.first_line(view.items)
    if first then
      vim.api.nvim_win_set_cursor(view.window, { first, 0 })
    end
  end

  function view.item()
    if not window_valid(view.window) then
      return nil
    end
    return view.items[vim.api.nvim_win_get_cursor(view.window)[1]]
  end

  function view.close()
    if closed then
      return
    end
    closed = true
    if window_valid(view.window) then
      pcall(vim.api.nvim_win_close, view.window, true)
    end
    if window_valid(opened_from) then
      vim.api.nvim_set_current_win(opened_from)
    end
    if spec.on_close then
      spec.on_close()
    end
  end

  --- Run a question (vim.ui.input / select) without the float closing under it;
  --- question(done) must call done() when the answer is in, whatever it is.
  function view.ask(question)
    asking = true
    question(function()
      asking = false
      if not closed and window_valid(view.window) then
        vim.api.nvim_set_current_win(view.window)
      end
    end)
  end

  view.refresh()
  local function map(lhs, action, description)
    vim.keymap.set("n", lhs, action, { buffer = buffer, nowait = true, desc = description })
  end
  for _, key in ipairs(spec.keys or {}) do
    map(key[1], function()
      key[2](view.item(), view)
    end, key[3])
  end
  if spec.item_navigation then
    local function step(direction)
      return function()
        local line = vim.api.nvim_win_get_cursor(view.window)[1]
        local last = vim.api.nvim_buf_line_count(buffer)
        for _ = 1, vim.v.count1 do
          local next_line = line + direction
          while next_line >= 1 and next_line <= last and not view.items[next_line] do
            next_line = next_line + direction
          end
          if next_line < 1 or next_line > last then
            break
          end
          line = next_line
        end
        vim.api.nvim_win_set_cursor(view.window, { line, 0 })
      end
    end
    for lhs, direction in pairs({ j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1 }) do
      map(lhs, step(direction), direction > 0 and "Next item" or "Previous item")
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    if not vim.tbl_contains(vim.tbl_map(function(key)
      return key[1]
    end, spec.keys or {}), lhs) then
      map(lhs, view.close, "Close")
    end
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buffer,
    callback = function()
      -- closed: the float's own closing fires this too
      if closed or asking then
        return
      end
      -- the float is left for another window: it goes away, focus stays where the user went
      opened_from = nil
      vim.schedule(view.close)
      return true
    end,
  })
  return view
end

return M
