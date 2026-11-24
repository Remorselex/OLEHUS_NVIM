-- IDEA's navigation bar: breadcrumbs with a type-to-filter menu
return {
  {
    "Bekaboo/dropbar.nvim",
    lazy = false, -- needed immediately: the winbar is attached as a window opens
    dependencies = {
      -- fzf-lib: without it the type-to-filter input (`i`) inside the menu is dead
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
    keys = {
      { "<leader>;", function() require("dropbar.api").pick() end, desc = "Navigation bar (breadcrumbs)" },
    },
    opts = {},
  },
}
