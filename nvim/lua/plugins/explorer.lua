-- Space e / Space E: LazyVim's explorer keys, but a press while the explorer is still opening
-- no longer opens a second one (util/explorer.lua). Space e and Space E remap to these.
return {
  {
    "folke/snacks.nvim",
    keys = {
      { "<leader>fe", function() require("util.explorer").toggle({ cwd = LazyVim.root() }) end, desc = "Explorer Snacks (root dir)" },
      { "<leader>fE", function() require("util.explorer").toggle() end, desc = "Explorer Snacks (cwd)" },
    },
  },
}
