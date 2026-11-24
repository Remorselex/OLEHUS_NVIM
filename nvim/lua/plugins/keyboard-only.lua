-- No smooth scrolling: a jump is instant, and keys typed right after it land where the cursor
-- really is (while the animation runs, snacks rewinds the view and the cursor).
return {
  {
    "folke/snacks.nvim",
    opts = {
      scroll = { enabled = false },
    },
  },
}
