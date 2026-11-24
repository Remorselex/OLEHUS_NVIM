-- Highlighting for the blink.cmp documentation window without leaking treesitter parsers.
--
-- blink keeps a single documentation window and highlights it with a parser bound to the buffer:
-- the signature in the open file's language, the description in markdown. On a language change
-- vim.treesitter.get_parser creates a new parser but never detaches the old one from the buffer.
-- Every item shown leaves two listeners behind for good, and after a few hours a single window
-- update edits hundreds of trees — typing with completion open stalls, and only a restart helps.
-- saghen/blink.cmp#2645, neovim/neovim#42122. Remove once blink fixes it upstream.
--
-- Same highlighting here, but from a string parser: it never hooks onto the buffer and gets garbage-collected.
local M = {}

local Range = require("vim.treesitter._range")

local function highlight_with_string_parser(buffer, filetype, start_line, end_line)
  local language = vim.treesitter.language.get_lang(filetype)
  if not language then
    return
  end
  -- treesitter sees a buffer with a trailing newline; without it a closing ``` on the last line
  -- doesn't count as the end of the code block
  local text = table.concat(vim.api.nvim_buf_get_lines(buffer, start_line, end_line, false), "\n") .. "\n"
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, language)
  if not ok or not parser then
    return
  end
  parser:parse(true)

  -- the same namespace blink clears before every show, otherwise highlights would pile up
  local namespace = require("blink.cmp.config").appearance.highlight_ns
  parser:for_each_tree(function(tree, language_tree)
    local query = vim.treesitter.query.get(language_tree:lang(), "highlights")
    if not query then
      return
    end
    for capture, node, metadata in query:iter_captures(tree:root(), text) do
      local name = query.captures[capture]
      local capture_metadata = metadata[capture] or {}
      if not vim.startswith(name, "_") then
        local start_row, start_col, end_row, end_col = Range.unpack4(vim.treesitter.get_range(node, text, capture_metadata))
        vim.api.nvim_buf_set_extmark(buffer, namespace, start_line + start_row, start_col, {
          end_line = start_line + end_row,
          end_col = end_col,
          hl_group = "@" .. name .. "." .. language_tree:lang(),
          priority = tonumber(metadata.priority or capture_metadata.priority) or vim.hl.priorities.treesitter,
          conceal = metadata.conceal or capture_metadata.conceal,
          strict = false,
        })
      end
    end
  end)
end

function M.apply()
  local ok, docs = pcall(require, "blink.cmp.lib.window.docs")
  if not ok or type(docs.highlight_with_treesitter) ~= "function" then
    -- blink rewrote the documentation window: check whether the leak is still alive, and remove this file
    vim.notify("blink-docs-highlight: docs.highlight_with_treesitter not found, patch not applied", vim.log.levels.WARN)
    return
  end
  docs.highlight_with_treesitter = highlight_with_string_parser
end

return M
