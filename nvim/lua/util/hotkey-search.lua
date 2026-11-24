-- One picker over every hotkey: the live keymaps (English descriptions, Enter runs the key)
-- and every line of CHEATSHEET.md that names a key (Russian, so "свернуть" finds `za`;
-- Enter opens the cheatsheet on that line). The cheatsheet also covers built-in Vim keys
-- that no keymap lists, such as motions and `%`.
local M = {}

local CHEATSHEET = vim.fn.stdpath("config") .. "/CHEATSHEET.md"

-- "| `za` / клик | свернуть |" -> "`za` / клик — свернуть"; bullets and bold markers dropped
local function readable(line)
  if line:match("^%s*|") then
    local cells = {}
    for cell in line:gmatch("[^|]+") do
      local trimmed = vim.trim(cell)
      if trimmed ~= "" then
        cells[#cells + 1] = trimmed
      end
    end
    line = table.concat(cells, " — ")
  end
  return vim.trim(line:gsub("^%s*[-*]%s+", ""):gsub("^%s*%d+%.%s+", ""):gsub("%*%*", ""))
end

local function cheatsheet_items()
  local items = {}
  local section = ""
  local in_code_block = false
  for line_number, line in ipairs(vim.fn.readfile(CHEATSHEET)) do
    local heading = line:match("^#+%s+(.+)")
    if line:match("^```") then
      in_code_block = not in_code_block
    elseif heading and not in_code_block then
      section = heading:gsub("`", "")
    elseif not in_code_block and line:find("`") then
      local shown = readable(line)
      items[#items + 1] = {
        cheatsheet = true,
        shown = shown,
        section = section,
        text = shown:gsub("`", "") .. " " .. section,
        file = CHEATSHEET,
        pos = { line_number, 0 },
        preview = "file",
      }
    end
  end
  return items
end

-- Keys inside backticks are bold as well as coloured, so they don't rely on hue alone.
local function format_cheatsheet(item)
  local highlights = { { "   " }, { "?", "SnacksPickerKeymapMode" }, { " " } }
  local is_key = false
  for piece in (item.shown .. "`"):gmatch("([^`]*)`") do
    if piece ~= "" then
      highlights[#highlights + 1] = { piece, is_key and "HotkeySearchKey" or nil }
    end
    is_key = not is_key
  end
  highlights[#highlights + 1] = { "  " .. item.section, "Comment" }
  return highlights
end

---@param opts? snacks.picker.Config extra picker options, e.g. { pattern = "свернуть" }
function M.open(opts)
  local key_colour = vim.api.nvim_get_hl(0, { name = "SnacksPickerKeymapLhs", link = false })
  vim.api.nvim_set_hl(0, "HotkeySearchKey", { fg = key_colour.fg, bold = true })
  local keymaps_source = require("snacks.picker.config.sources").keymaps

  Snacks.picker(vim.tbl_extend("force", {
    title = "Hotkeys (keymaps + cheatsheet)",
    modes = keymaps_source.modes,
    global = true,
    ["local"] = true,
    plugs = false,
    finder = function(opts)
      local items = cheatsheet_items()
      vim.list_extend(items, require("snacks.picker.source.vim").keymaps(opts))
      return items
    end,
    format = function(item, picker)
      if item.cheatsheet then
        return format_cheatsheet(item)
      end
      return Snacks.picker.format.keymap(item, picker)
    end,
    preview = "preview",
    confirm = function(picker, item)
      if item and item.cheatsheet then
        return picker:action("jump")
      end
      return keymaps_source.confirm(picker, item)
    end,
  }, opts or {}))
end

return M
