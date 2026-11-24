-- Kotlin is read-only here: we need highlighting, not a language server. The LazyVim
-- lang.kotlin extra is left out on purpose — it pulls in the outdated kotlin-language-server,
-- and any LSP in monoNew would have to import a Gradle build of 4107 projects.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "kotlin" } },
  },
}
