-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- === Highlights: registered BEFORE any colorscheme is applied ===
-- options.lua loads ahead of plugins and of the colorscheme, so a ColorScheme hook
-- here also fires for the startup theme. In autocmds.lua it was too late: that file
-- loads on VeryLazy, by which point the theme is already in place.

-- Pickers spawn "rg" by name, so a shim earlier on PATH reroutes them to the
-- trigram-indexed tgrep. Scoped to vim.env so the interactive shell keeps the
-- real ripgrep. See util/tgrep.lua and bin/nvim-search/rg.
vim.env.PATH = vim.fn.expand("~/dotfiles/bin/nvim-search") .. ":" .. vim.env.PATH

-- Root is the repository, not the LSP workspace. vtsls is rooted at the nearest package
-- (plugins/typescript-root.lua), and LazyVim asks LSP first and prefers the deepest root,
-- so opening one file in monoNew narrowed every search to that package.
vim.g.root_spec = { { ".git", "lua" }, "lsp", "cwd" }

-- A closed fold shows its first line highlighted plus how much is hidden; doc comments
-- show their first sentence. See util/foldtext.lua.
vim.opt.foldtext = "v:lua.require'util.foldtext'.render()"

vim.opt.cursorlineopt = "both"

-- Transparent editor background. Toggled live with `Space u B`.
vim.g.transparent_background = true

-- Tell syntax groups apart by font weight, not by hue alone. `Space u S`.
vim.g.syntax_contrast = true

-- A block's brackets and indent guide share a colour per indent level. `Space u o`.
vim.g.rainbow_scopes = true

local TRANSPARENT_GROUPS = {
  "Normal", "NormalNC", "NormalFloat", "FloatBorder", "SignColumn",
  "EndOfBuffer", "LineNr", "FoldColumn",
  "StatusLine", "StatusLineNC", "TabLine", "TabLineFill", "WinBar", "WinBarNC",
  "NeoTreeNormal", "NeoTreeNormalNC", "NeoTreeEndOfBuffer",
  "NormalSB", "MsgArea", "NonText",
}

local function highlight_bg(group)
  local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  return (ok and highlight) and highlight.bg or nil
end

-- Mix in sRGB: 0.0 is all background, 1.0 is all foreground.
local function blend(foreground, background, ratio)
  local mixed = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local foreground_channel = math.floor(foreground / 2 ^ shift) % 256
    local background_channel = math.floor(background / 2 ^ shift) % 256
    local channel = math.floor(background_channel + (foreground_channel - background_channel) * ratio + 0.5)
    mixed = mixed + math.min(255, math.max(0, channel)) * 2 ^ shift
  end
  return math.floor(mixed)
end

-- The theme decides what a selection looks like; the cursor line is derived from it
-- and dimmed, otherwise it drowns the syntax highlighting on the current line.
-- Computed from whichever theme is active, so it holds for all of them.
local function tone_down_cursorline()
  local visual_bg = highlight_bg("Visual")
  if visual_bg == nil then
    return
  end
  -- with a transparent background Normal has no bg, so black is the base and this
  -- simply darkens the selection; the result reads over the terminal's dark ground
  local editor_bg = highlight_bg("Normal") or 0x000000
  pcall(vim.api.nvim_set_hl, 0, "CursorLine", { bg = string.format("#%06x", blend(visual_bg, editor_bg, 0.55)) })
end

local function apply_highlight_tweaks()
  tone_down_cursorline()
  require("util.syntax-contrast").apply()
  require("util.rainbow-scopes").apply()
  pcall(vim.api.nvim_set_hl, 0, "CursorLineNr", { bold = true })
  if not vim.g.transparent_background then
    return
  end
  for _, group in ipairs(TRANSPARENT_GROUPS) do
    pcall(vim.api.nvim_set_hl, 0, group, { bg = "none" })
  end
end

vim.api.nvim_create_autocmd("ColorScheme", { callback = apply_highlight_tweaks })
vim.schedule(apply_highlight_tweaks)

-- Repaint the highlights after vim.g.transparent_background changes.
vim.api.nvim_create_user_command("TransparencyToggle", function()
  vim.g.transparent_background = not vim.g.transparent_background
  vim.cmd.colorscheme(vim.g.colors_name)
  vim.notify("Transparent background: " .. (vim.g.transparent_background and "on" or "off"))
end, { desc = "Editor transparent background on/off" })
