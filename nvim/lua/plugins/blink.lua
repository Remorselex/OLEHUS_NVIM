-- Completion (blink.cmp comes with LazyVim): the documentation window leaks treesitter parsers
-- and slows typing down over time — the patch lives in util/blink-docs-highlight.lua.
-- Own snippets live in snippets/<filetype>.json next to init.lua (blink reads that folder itself).
return {
  {
    "saghen/blink.cmp",
    -- opts is evaluated once, when blink loads — its modules can't be required any earlier
    opts = function(_, opts)
      require("util.blink-docs-highlight").apply()

      opts.sources = opts.sources or {}
      opts.sources.providers = opts.sources.providers or {}
      opts.sources.providers.snippets = vim.tbl_deep_extend("force", opts.sources.providers.snippets or {}, {
        should_show_items = function(context, items)
          -- after "." or "::" the list is about methods and paths: a snippet named "new"
          -- must not compete with Vec::new
          if context.trigger.initial_kind == "trigger_character" then
            return false
          end
          -- the fuzzy matcher forgives typos, so a fresh name like "History" matched
          -- "relm-async-factory", came preselected, and Enter pasted a whole Relm4 component:
          -- snippets show up only once the word starts like one of them
          local typed = context.get_keyword():lower()
          for _, item in ipairs(items) do
            if vim.startswith(item.label:lower(), typed) then
              return true
            end
          end
          return false
        end,
      })
    end,
  },
}
