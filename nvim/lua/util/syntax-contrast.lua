-- Telling syntax apart WITHOUT relying on colour.
--
-- With dichromacy one of the three cone types is missing, so some colour pairs
-- collapse into a single shade no matter which theme is loaded. The dependable fix
-- is a second axis that owes nothing to hue: font style. Its four states
-- (regular / bold / italic / bold italic) survive even full greyscale.
--
--   regular      values and calls: @variable, @function, @string, @number
--   bold         declarations and structure: @keyword, @type, @constructor
--   italic       belonging and context: parameters, members, modules, comments
--   bold italic  compile-time constants: @constant and macros
local M = {}

local BOLD = { bold = true, italic = false }
local ITALIC = { bold = false, italic = true }
local BOLD_ITALIC = { bold = true, italic = true }

local STYLE_BY_GROUP = {
  ["@keyword"] = BOLD,
  ["@keyword.function"] = BOLD,
  ["@keyword.return"] = BOLD,
  ["@keyword.conditional"] = BOLD,
  ["@keyword.repeat"] = BOLD,
  ["@keyword.exception"] = BOLD,
  ["@keyword.import"] = BOLD,
  ["@keyword.operator"] = BOLD,
  ["@keyword.type"] = BOLD,
  ["@type"] = BOLD,
  ["@type.builtin"] = BOLD,
  ["@type.definition"] = BOLD,
  ["@constructor"] = BOLD,

  ["@variable.parameter"] = ITALIC,
  ["@variable.member"] = ITALIC,
  ["@property"] = ITALIC,
  ["@module"] = ITALIC,
  ["@attribute"] = ITALIC,
  ["@tag.attribute"] = ITALIC,
  ["@comment"] = ITALIC,
  ["@label"] = ITALIC,

  ["@constant"] = BOLD_ITALIC,
  ["@constant.builtin"] = BOLD_ITALIC,
  ["@constant.macro"] = BOLD_ITALIC,
}

function M.apply()
  if not vim.g.syntax_contrast then
    return
  end
  for group, style in pairs(STYLE_BY_GROUP) do
    local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and highlight ~= nil then
      -- link=false already resolved the attributes, and reassigning breaks the link,
      -- so the theme's colour has to be carried over by hand
      highlight.bold = style.bold
      highlight.italic = style.italic
      highlight.link = nil
      pcall(vim.api.nvim_set_hl, 0, group, highlight)
    end
  end
end

vim.api.nvim_create_user_command("SyntaxContrastToggle", function()
  vim.g.syntax_contrast = not vim.g.syntax_contrast
  vim.cmd.colorscheme(vim.g.colors_name)
  vim.notify("Syntax by font style: " .. (vim.g.syntax_contrast and "on" or "off"))
end, { desc = "Bold/italic for syntax groups on/off" })

return M
