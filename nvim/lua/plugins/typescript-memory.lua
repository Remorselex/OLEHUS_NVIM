-- tsserver gets a 3 GB heap by default. A monoNew package pulls in more than that through its
-- imports, so V8 aborts (SIGABRT) and vtsls restarts it in a loop every ~18 s — that is the
-- "JS/TS language service crashed 5 times in the last 5 minutes" prompt. The machine has 128 GB.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        vtsls = {
          settings = {
            typescript = { tsserver = { maxTsServerMemory = 16384 } },
          },
        },
      },
    },
  },
}
