-- `Space s k`: search hotkeys in the live keymaps and in CHEATSHEET.md at once
-- (util/hotkey-search.lua). Replaces LazyVim's keymaps-only picker on the same key.
return {
  {
    "folke/snacks.nvim",
    keys = {
      { "<leader>sk", function() require("util.hotkey-search").open() end, desc = "Hotkeys (keymaps + cheatsheet)" },
    },
  },
}
