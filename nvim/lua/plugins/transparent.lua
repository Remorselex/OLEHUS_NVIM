-- Transparency inside the themes themselves; the shared hook over highlight groups
-- lives in config/options.lua. Reads vim.g.transparent_background so that
-- `Space u B` genuinely turns the background back on.
return {
  {
    "folke/tokyonight.nvim",
    opts = function(_, opts)
      opts.transparent = vim.g.transparent_background
      opts.styles = vim.tbl_extend("force", opts.styles or {}, {
        sidebars = vim.g.transparent_background and "transparent" or "dark",
        floats = vim.g.transparent_background and "transparent" or "dark",
      })
      return opts
    end,
  },
  {
    "catppuccin/nvim",
    opts = function(_, opts)
      opts.transparent_background = vim.g.transparent_background
      return opts
    end,
  },
}
