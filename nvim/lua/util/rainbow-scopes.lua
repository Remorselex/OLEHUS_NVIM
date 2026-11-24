-- Nesting by colour: a block's brackets and its indent guide share one colour per indent level;
-- the guide of the block under the cursor is drawn at full strength, the rest dimmed.
--
-- Brackets take the indent level of their line, not their nesting depth: `.map(|x| {` opens two
-- brackets but one indent, so by depth every bracket below it would drift one colour away from
-- its guide. By indent level they always agree, since formatted code closes a block at the
-- indent it opened it.
--
-- The palette is Okabe–Ito, built for colour-blind readers, ordered by simulating protanopia,
-- deuteranopia and tritanopia (Machado 2009, OKLab): neighbouring levels stay at least 25 apart
-- for every kind of dichromacy, levels two apart at least 11 (8 is the usual floor). Lightness
-- alternates between levels as a second channel, and brackets are bold so their colour has
-- enough area to be read.
local M = {}

local PALETTE = { "#E69F00", "#3D8FD9", "#D55E00", "#F0E442", "#009E73", "#FFFFFF" }
local GUIDE_STRENGTH = 0.45
-- above treesitter (100), below the selection and search
local BRACKET_PRIORITY = 110

M.bracket_groups = {}
M.guide_groups = {}
M.scope_groups = {}
for level = 1, #PALETTE do
  M.bracket_groups[level] = "RainbowBracket" .. level
  M.guide_groups[level] = "RainbowGuide" .. level
  M.scope_groups[level] = "RainbowScope" .. level
end

-- Mix in sRGB: 0.0 is all background, 1.0 is all foreground.
local function blend(foreground, background, ratio)
  local mixed = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local foreground_channel = math.floor(foreground / 2 ^ shift) % 256
    local background_channel = math.floor(background / 2 ^ shift) % 256
    mixed = mixed + math.floor(background_channel + (foreground_channel - background_channel) * ratio + 0.5) * 2 ^ shift
  end
  return math.floor(mixed)
end

-- Switched off, the guides fall back to what snacks draws without us; brackets are simply not painted.
function M.apply()
  local enabled = vim.g.rainbow_scopes
  -- with a transparent background Normal has no bg; the terminal's ground is dark
  local editor_bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg or 0x000000
  for level, colour in ipairs(PALETTE) do
    local full = tonumber(colour:sub(2), 16)
    local guide = blend(full, editor_bg, GUIDE_STRENGTH)
    vim.api.nvim_set_hl(0, M.bracket_groups[level], { fg = full, bold = true })
    vim.api.nvim_set_hl(0, M.guide_groups[level], enabled and { fg = guide } or { link = "SnacksIndent" })
    vim.api.nvim_set_hl(0, M.scope_groups[level], enabled and { fg = full } or { link = "SnacksIndentScope" })
  end
end

-- Same level arithmetic as snacks.indent, so a bracket and the guide below it pick the same colour.
local function level_group(row)
  local shiftwidth = vim.fn.shiftwidth()
  local level = math.floor(vim.fn.indent(row + 1) / shiftwidth)
  return M.bracket_groups[level % #PALETTE + 1]
end

local function paint_brackets(buffer, top, bottom)
  local parser = vim.treesitter.get_parser(buffer, nil, { error = false })
  if parser == nil then
    return
  end
  local query = vim.treesitter.query.get(parser:lang(), "highlights")
  local tree = parser:parse()[1]
  if query == nil or tree == nil then
    return
  end
  for id, node in query:iter_captures(tree:root(), buffer, top, bottom + 1) do
    if query.captures[id] == "punctuation.bracket" then
      local start_row, start_column, end_row, end_column = node:range()
      vim.api.nvim_buf_set_extmark(buffer, M.namespace, start_row, start_column, {
        end_row = end_row,
        end_col = end_column,
        hl_group = level_group(start_row),
        priority = BRACKET_PRIORITY,
        ephemeral = true,
      })
    end
  end
end

M.namespace = vim.api.nvim_create_namespace("rainbow_scopes")
vim.api.nvim_set_decoration_provider(M.namespace, {
  on_win = function(_, _, buffer, top, bottom)
    if vim.g.rainbow_scopes then
      vim.api.nvim_buf_call(buffer, function()
        paint_brackets(buffer, top, bottom)
      end)
    end
    return false
  end,
})

return M
