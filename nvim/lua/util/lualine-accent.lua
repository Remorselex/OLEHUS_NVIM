-- A red accent laid over lualine's `auto` theme.
-- The red is not a constant but comes from the theme itself (DiagnosticError's fg),
-- so the accent stays native to whichever colorscheme a project selects.
local M = {}

local ACCENTED_SECTIONS = { "a", "x", "y", "z" }

local function highlight_color(group, attribute)
  local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok or highlight == nil or highlight[attribute] == nil then
    return nil
  end
  return string.format("#%06x", highlight[attribute])
end

function M.build()
  package.loaded["lualine.themes.auto"] = nil
  local theme = require("lualine.themes.auto")
  local accent = highlight_color("DiagnosticError", "fg") or "#fc5d7c"
  local on_accent = highlight_color("Normal", "bg") or "#181819"

  for mode_name, mode in pairs(theme) do
    if type(mode) == "table" then
      for _, section_name in ipairs(ACCENTED_SECTIONS) do
        local section = mode[section_name]
        if type(section) == "table" then
          -- the mode block is a filled swatch: recolour NORMAL only, since for the other
          -- modes the colour carries meaning (insert/visual) and must stay put
          if section.bg ~= nil and section_name == "a" and mode_name == "normal" then
            section.bg = accent
            section.fg = on_accent
          elseif section.bg == nil or section_name ~= "a" then
            section.fg = accent
          end
        end
      end
    end
  end

  return theme
end

-- lualine builds its theme once at setup, so rebuild it after a colorscheme change.
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    vim.schedule(function()
      local ok, lualine = pcall(require, "lualine")
      if ok then
        lualine.setup({ options = { theme = M.build() } })
      end
    end)
  end,
})

return M
