-- Neogit, a Magit port: one status buffer that everything is driven from,
-- editing a file in place included. Diffs and merges are handed to diffview.
return {
  {
    "NeogitOrg/neogit",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "sindrets/diffview.nvim",
      "folke/snacks.nvim",
    },
    cmd = "Neogit",
    opts = {
      graph_style = "unicode",
      process_spinner = false,
      -- diffs and merge conflicts open in diffview rather than the built-in viewer
      integrations = { diffview = true, snacks = true },
      commit_editor = { kind = "split" },
      popup = { kind = "split" },
    },
    keys = {
      { "<leader>gn", "<cmd>Neogit<cr>", desc = "Neogit (статус)" },
      { "<leader>gN", "<cmd>Neogit log<cr>", desc = "Neogit: история коммитов" },
    },
  },
}
