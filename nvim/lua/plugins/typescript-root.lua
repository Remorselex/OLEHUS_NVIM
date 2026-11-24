-- By default vtsls finds the root by lock files and .git, so in a monorepo it
-- settles at the very top and loads a project spanning all 756 tsconfigs. Loading
-- takes about a minute, and until it finishes tsserver runs in partial semantic
-- mode: "go to definition" answers with the import line in the same file.
--
-- As the root we take the nearest package directory — the one holding both package.json
-- and tsconfig.json. Module resolution doesn't suffer: tsserver pulls into the
-- program everything it reaches through imports, sibling packages included.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        vtsls = {
          root_dir = function(bufnr, on_dir)
            local start = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
            if start == nil or start == "" then
              return on_dir(vim.uv.cwd())
            end

            for dir in vim.fs.parents(start .. "/x") do
              local has_package = vim.uv.fs_stat(dir .. "/package.json") ~= nil
              local has_tsconfig = vim.uv.fs_stat(dir .. "/tsconfig.json") ~= nil
                or vim.uv.fs_stat(dir .. "/jsconfig.json") ~= nil
              if has_package and has_tsconfig then
                return on_dir(dir)
              end
            end

            -- no package with a config further up the tree — fall back to the nearest package.json,
            -- and if there is none either, the behaviour stays as before
            local package_json = vim.fs.find("package.json", { upward = true, path = start })[1]
            return on_dir(package_json and vim.fs.dirname(package_json) or vim.uv.cwd())
          end,
        },
      },
    },
  },
}
