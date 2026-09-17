-- Pick a theme with `Space u C` (live preview); the choice is remembered FOR THIS
-- PROJECT, see lua/util/theme.lua. `Space u B` toggles the transparent background.
return {
  -- === Startup theme: whatever was saved for this project, else sonokai ===
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = { style = "moon" },
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = function()
        require("util.theme").load()
      end,
    },
  },

  -- === Calm, for long sessions ===
  -- the de facto choice in C/C++ land: warm, low contrast, no neon
  {
    "sainnhe/gruvbox-material",
    lazy = true,
    init = function()
      vim.g.gruvbox_material_background = "medium"
      vim.g.gruvbox_material_foreground = "material" -- the softest of its three foreground sets
      vim.g.gruvbox_material_better_performance = 1
      vim.g.gruvbox_material_enable_italic = 1
    end,
  },
  -- same author, colder and higher contrast than gruvbox-material
  {
    "sainnhe/sonokai",
    lazy = true,
    init = function()
      vim.g.sonokai_style = "shusia"
      vim.g.sonokai_better_performance = 1
    end,
  },
  { "rebelot/kanagawa.nvim", lazy = true },
  { "neanias/everforest-nvim", lazy = true, opts = { background = "medium" } },
  { "savq/melange-nvim", lazy = true },
  { "EdenEast/nightfox.nvim", lazy = true },
  { "rose-pine/neovim", name = "rose-pine", lazy = true },

  -- === Born in the JS/TS ecosystem ===
  -- Night Owl: written by Sarah Drasner for night-time JS/JSX work
  { "oxfist/night-owl.nvim", lazy = true },
  -- poimandres: out of the three.js/react world, muted blue-green
  { "olivercederborg/poimandres.nvim", lazy = true },
  -- a VS Code Dark+ port, for eyes trained on VS Code
  { "Mofiqul/vscode.nvim", lazy = true },

  -- === Neon: kept for the mood, no longer used at startup ===
  { "scottmckendry/cyberdream.nvim", lazy = true, opts = { italic_comments = true } },
  { "eldritch-theme/eldritch.nvim", name = "eldritch", lazy = true },
  { "artanikin/vim-synthwave84", lazy = true },
  { "thedenisnikulin/vim-cyberpunk", lazy = true },
}
