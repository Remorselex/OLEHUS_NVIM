-- Fancy comments: a box around the text, a heading line and a divider.
-- The box or line style can be switched by its number in the catalog: :CBcatalog, then e.g. :CBlabox3.
return {
  {
    "LudoPinelli/comment-box.nvim",
    cmd = { "CBcatalog", "CBlabox", "CBllline", "CBline", "CBd", "CBy" },
    keys = {
      { "<leader>cb", "<Cmd>CBlabox<CR>", mode = { "n", "v" }, desc = "Boxed comment" },
      { "<leader>ct", "<Cmd>CBllline<CR>", mode = { "n", "v" }, desc = "Heading comment ── text ──" },
      { "<leader>cB", "<Cmd>CBline<CR>", desc = "Divider line" },
      { "<leader>cX", "<Cmd>CBd<CR>", mode = { "n", "v" }, desc = "Remove the box, keep the text" },
    },
    opts = {},
  },
}
