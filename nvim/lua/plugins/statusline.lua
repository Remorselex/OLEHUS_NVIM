-- Statusline: no branch, full path to the file, red accent
return {
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      -- drop section b (branch plus git diff) entirely
      opts.sections.lualine_b = {}

      -- the symbol under the cursor (f memo() callback) is worth keeping
      local symbols
      local ok, trouble = pcall(require, "trouble")
      if ok then
        local s = trouble.statusline({
          mode = "symbols",
          groups = {},
          title = false,
          filter = { range = true },
          format = "{kind_icon}{symbol.name:Normal}",
          hl_group = "lualine_c_normal",
        })
        symbols = { s.get, cond = s.has }
      end

      opts.sections.lualine_c = {
        { "diagnostics" },
        { "filetype", icon_only = true, separator = "", padding = { left = 1, right = 0 } },
        -- length = 0 gives the whole path, no ellipsis
        { LazyVim.lualine.pretty_path({ length = 0 }) },
      }
      if symbols then
        table.insert(opts.sections.lualine_c, symbols)
      end

      opts.options.theme = require("util.lualine-accent").build()
    end,
  },
}
