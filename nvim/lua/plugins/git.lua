-- Git: visual diffs, file history, conflict resolution (CLion's GUI equivalent)
return {
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
      { "<leader>gvd", "<cmd>DiffviewOpen<cr>", desc = "Diffview: working changes" },
      { "<leader>gvf", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: file history" },
      { "<leader>gvr", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: repo history" },
      { "<leader>gvc", "<cmd>DiffviewClose<cr>", desc = "Diffview: close" },
    },
    opts = {},
  },
}
