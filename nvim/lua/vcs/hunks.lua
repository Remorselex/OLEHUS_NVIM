-- Line hunks between HEAD and the working copy, the changed words inside paired lines, and
-- syntax highlighting for text that is not in any buffer (old lines drawn as virtual lines).
local M = {}

local function joined(lines)
  return #lines == 0 and "" or (table.concat(lines, "\n") .. "\n")
end

--- { old_start, old_count, new_start, new_count } per hunk, 1-based as vim.text.diff returns them.
--- A pure insertion has old_count 0 and old_start = the line it follows; a pure deletion the same
--- on the new side.
function M.compute(old_lines, new_lines, options)
  return vim.text.diff(joined(old_lines), joined(new_lines), {
    result_type = "indices",
    algorithm = "histogram",
    linematch = 60,
    ignore_whitespace = options and options.ignore_whitespace or false,
  })
end

local function tokens_of(line)
  local tokens = {}
  for word, rest in line:gmatch("([%w_]*)([^%w_]?)") do
    if word ~= "" then
      tokens[#tokens + 1] = word
    end
    if rest ~= "" then
      tokens[#tokens + 1] = rest
    end
  end
  return tokens
end

local function token_ranges(tokens, first, count)
  local column = 0
  for index = 1, first - 1 do
    column = column + #tokens[index]
  end
  local length = 0
  for index = first, first + count - 1 do
    length = length + #(tokens[index] or "")
  end
  return { column, column + length }
end

--- Byte ranges of the words that differ between two versions of one line:
--- { old = { {start, end}, ... }, new = { ... } }, or nil when the lines share almost nothing —
--- then marking words is noise and the whole line already says "changed".
function M.word_changes(old_line, new_line)
  local old_tokens, new_tokens = tokens_of(old_line), tokens_of(new_line)
  local token_hunks = vim.text.diff(joined(old_tokens), joined(new_tokens), { result_type = "indices", algorithm = "histogram" })
  local changes, changed_bytes = { old = {}, new = {} }, 0
  for _, hunk in ipairs(token_hunks) do
    local old_start, old_count, new_start, new_count = unpack(hunk)
    if old_count > 0 then
      local range = token_ranges(old_tokens, old_start, old_count)
      changes.old[#changes.old + 1] = range
      changed_bytes = changed_bytes + range[2] - range[1]
    end
    if new_count > 0 then
      local range = token_ranges(new_tokens, new_start, new_count)
      changes.new[#changes.new + 1] = range
      changed_bytes = changed_bytes + range[2] - range[1]
    end
  end
  if changed_bytes > 0.6 * (#old_line + #new_line) then
    return nil
  end
  return changes
end

--- Treesitter highlight groups for text that lives outside a buffer, only for the lines in
--- `wanted` (a set of 1-based line numbers): groups[line][column] = "@keyword.lua" with 0-based
--- columns. Later captures win, as in the buffer highlighter.
function M.syntax_groups(lines, path, wanted)
  local groups = {}
  local filetype = vim.filetype.match({ filename = path }) or ""
  local language = filetype ~= "" and vim.treesitter.language.get_lang(filetype) or nil
  if not language then
    return groups
  end
  local text = joined(lines)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, language)
  if not ok or not parser then
    return groups
  end
  parser:parse(true)
  parser:for_each_tree(function(tree, language_tree)
    local query = vim.treesitter.query.get(language_tree:lang(), "highlights")
    if not query then
      return
    end
    for capture, node, metadata in query:iter_captures(tree:root(), text) do
      local name = query.captures[capture]
      if not vim.startswith(name, "_") and name ~= "spell" and name ~= "nospell" then
        local group = "@" .. name .. "." .. language_tree:lang()
        local start_row, start_col, end_row, end_col = node:range()
        local capture_metadata = metadata[capture]
        if capture_metadata and capture_metadata.range then
          start_row, start_col, end_row, end_col = unpack(capture_metadata.range)
        end
        for row = start_row, end_row do
          local line = wanted[row + 1] and lines[row + 1]
          if line then
            groups[row + 1] = groups[row + 1] or {}
            local first = row == start_row and start_col or 0
            local last = row == end_row and end_col or #line
            for column = first, last - 1 do
              groups[row + 1][column] = group
            end
          end
        end
      end
    end
  end)
  return groups
end

return M
