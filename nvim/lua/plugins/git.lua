-- Git: visual diffs, file history, conflict resolution (CLion's GUI equivalent)
return {
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
      { "<leader>gvd", "<cmd>DiffviewOpen<cr>", desc = "Diffview: рабочие изменения" },
      { "<leader>gvf", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: история файла" },
      { "<leader>gvr", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: история репы" },
      { "<leader>gvc", "<cmd>DiffviewClose<cr>", desc = "Diffview: закрыть" },
    },
    opts = {},
  },
}
