-- With noice the command line takes no rows (cmdheight=0). Making the only window in a
-- column shorter (LazyVim's Ctrl+Down, Ctrl-W -, :resize) hands the freed rows to the
-- command line instead; with the transparent background that looks like nvim filling only
-- the top of the terminal. Give the rows back and name the keys that did it.
local M = {}

local KEYS_REMEMBERED = 24
local QUIET_MS = 400

local recent_keys = {}
local keys_before_last_grow = {}
local rows_taken = 0
local report_timer = vim.uv.new_timer()

local function remember(_, typed)
  if typed == nil or typed == "" then
    return
  end
  recent_keys[#recent_keys + 1] = vim.fn.keytrans(typed)
  if #recent_keys > KEYS_REMEMBERED then
    table.remove(recent_keys, 1)
  end
end

local LONGEST_REPEATED_GROUP = 3

local function repeats_at(keys, start, length)
  local count = 1
  while true do
    for offset = 0, length - 1 do
      if keys[start + count * length + offset] ~= keys[start + offset] then
        return count
      end
    end
    count = count + 1
  end
end

-- "<C-Down> <C-Down> <C-Down>" -> "<C-Down>×3", "<C-W> - <C-W> -" -> "(<C-W> -)×2"
local function describe(keys)
  local words = {}
  local position = 1
  while position <= #keys do
    local best_length, best_count = 1, 1
    for length = 1, LONGEST_REPEATED_GROUP do
      local count = repeats_at(keys, position, length)
      if count > 1 and count * length > best_count * best_length then
        best_length, best_count = length, count
      end
    end
    local group = table.concat(vim.list_slice(keys, position, position + best_length - 1), " ")
    if best_count == 1 then
      words[#words + 1] = group
    else
      words[#words + 1] = (best_length > 1 and ("(" .. group .. ")") or group) .. "×" .. best_count
    end
    position = position + best_length * best_count
  end
  return table.concat(words, " ")
end

local function report()
  vim.notify(
    ("The command line took %d rows from the windows; gave them back.\nKeys before it: %s"):format(
      rows_taken,
      describe(keys_before_last_grow)
    ),
    vim.log.levels.WARN
  )
  rows_taken = 0
end

local function noice_running()
  local loaded, config = pcall(require, "noice.config")
  return loaded and config.is_running()
end

local function give_rows_back()
  local height = vim.o.cmdheight
  if height == 0 or not noice_running() then
    return
  end
  vim.o.cmdheight = 0
  rows_taken = rows_taken + height
  keys_before_last_grow = vim.list_slice(recent_keys)
  -- one report per burst: holding Ctrl+Down resizes on every key repeat
  report_timer:stop()
  report_timer:start(QUIET_MS, 0, vim.schedule_wrap(report))
end

function M.setup()
  vim.on_key(remember, vim.api.nvim_create_namespace("cmdline_height"))
  vim.api.nvim_create_autocmd("WinResized", {
    group = vim.api.nvim_create_augroup("cmdline_height", { clear = true }),
    callback = give_rows_back,
  })
end

return M
