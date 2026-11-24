-- Rider-style documentation comments: the skeleton is generated from the signature,
-- and the tags inside the comment are highlighted by a separate parser.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      -- doxygen marks up @brief/@param/@return inside /** */ in C and C++,
      -- comment handles TODO/NOTE/HACK and other markers in comments of any language.
      -- jsdoc for TS is already installed, hence the difference in looks between C++ and TS.
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "doxygen", "comment" })
      return opts
    end,
  },
  {
    "danymat/neogen",
    cmd = "Neogen",
    keys = {
      { "<leader>cg", function() require("neogen").generate() end, desc = "Generate a doc comment" },
    },
    opts = {
      -- LazyVim moved to blink.cmp long ago, there is no LuaSnip here; "nvim" is the built-in
      -- vim.snippet, and it is what places the tabstops at the spots that need filling in
      snippet_engine = "nvim",
      languages = {
        cpp = { template = { annotation_convention = "doxygen" } },
        c = { template = { annotation_convention = "doxygen" } },
        typescript = { template = { annotation_convention = "tsdoc" } },
        typescriptreact = { template = { annotation_convention = "tsdoc" } },
        javascript = { template = { annotation_convention = "jsdoc" } },
        lua = { template = { annotation_convention = "ldoc" } },
      },
    },
  },
}
