-- Nesting by colour: indent guides get a colour per level; brackets are painted to match by
-- util/rainbow-scopes.lua, which also holds the palette and the switch (`Space u o`).
return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      local rainbow = require("util.rainbow-scopes")
      opts.indent = vim.tbl_deep_extend("force", opts.indent or {}, {
        indent = { hl = rainbow.guide_groups },
        scope = { hl = rainbow.scope_groups },
      })
    end,
  },
}
