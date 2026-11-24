-- Rider-style folding: an arrow in the left column next to every foldable block, clickable
-- with the mouse. Blocks come from the LSP (clangd, vtsls…), or treesitter without one; the folded block's text
-- comes from util/foldtext.lua.
return {
  {
    "folke/snacks.nvim",
    opts = {
      statuscolumn = { folds = { open = true } },
    },
  },
}
