-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- shrinking the only window hands its rows to the hidden command line: give them back
require("util.cmdline-height").setup()

-- TGREP: the index only stays live while the server runs, otherwise search misses fresh edits
vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  callback = function()
    require("util.tgrep").ensure_server()
    -- doc comments as prose, like Rider's reader mode: toggled with Space u R
    require("util.doc-render").setup()
    -- always load the module: it registers :Services. Show it only when started
    -- without a file and unless vim.g.services_dashboard_on_start turns it off.
    local services = require("util.services")
    if vim.g.services_dashboard_on_start ~= false and vim.fn.argc() == 0 then
      vim.defer_fn(services.show, 400)
    end
  end,
})
