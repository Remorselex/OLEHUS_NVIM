-- Documentation comments rendered in place, like Rider's reader mode: the comment markers
-- disappear, tags turn into words, and the block reads as prose behind a bar on the left.
-- The block under the cursor is always shown raw, so editing never fights the rendering.
--
-- Covers /** … */ and /*! … */ blocks plus ///, //! and Lua's --- line comments. Comments
-- are found with treesitter, so a "/**" inside a string is never mistaken for one.
local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("doc_render")
local PRIORITY = 250 -- above treesitter's 100, so names and labels keep their own style

local FILETYPES = {
  c = true, cpp = true, cuda = true, objc = true, cs = true, java = true, kotlin = true, swift = true,
  javascript = true, javascriptreact = true, typescript = true, typescriptreact = true,
  lua = true, rust = true,
}

-- What a tag turns into. Parameter-like tags become a bullet with the name in bold.
local PARAMETER_TAGS = { param = true, tparam = true, arg = true, argument = true, prop = true, property = true, field = true }
local HIDDEN_TAGS = { brief = true, details = true, summary = true, description = true, desc = true }
local LABEL_BY_TAG = {
  ["return"] = "Returns", returns = "Returns", retval = "Returns",
  throws = "Throws", throw = "Throws", exception = "Throws",
  note = "Note", warning = "Warning", attention = "Warning",
  see = "See", sa = "See", since = "Since", deprecated = "Deprecated",
  example = "Example", pre = "Precondition", post = "Postcondition",
}
-- Labels followed by a name worth the same emphasis as a parameter's: "Throws: std::out_of_range".
local NAMED_LABEL_TAGS = { throws = true, throw = true, exception = true }

local LINE_MARKERS_BY_LANGUAGE = {
  default = { "///", "//!" },
  lua = { "---" },
}

local query_by_language = {}
local blocks_by_buffer = {} -- buffer -> { tick, blocks }
local raw_block_by_buffer = {} -- buffer -> index of the block left raw under the cursor
local folds_by_buffer = {} -- buffer -> which blocks were inside a closed fold at the last render
local pending_render = {}

local function comment_query(language)
  if query_by_language[language] ~= nil then
    return query_by_language[language]
  end
  local ok, info = pcall(vim.treesitter.language.inspect, language)
  local node_types = {}
  if ok then
    for name, is_named in pairs(info.symbols) do
      if is_named and name:match("comment$") then
        node_types[#node_types + 1] = ("(%s)"):format(name)
      end
    end
  end
  local query = false
  if #node_types > 0 then
    local parsed, result = pcall(vim.treesitter.query.parse, language, ("[%s] @comment"):format(table.concat(node_types, " ")))
    query = parsed and result or false
  end
  query_by_language[language] = query
  return query
end

local function line_marker(text, language)
  for _, marker in ipairs(LINE_MARKERS_BY_LANGUAGE[language] or LINE_MARKERS_BY_LANGUAGE.default) do
    if vim.startswith(text, marker) then
      return marker
    end
  end
end

-- Doc blocks as { kind = "block" | "lines", first_row, last_row }, consecutive line comments merged.
local function find_blocks(buffer)
  local cached = blocks_by_buffer[buffer]
  local tick = vim.api.nvim_buf_get_changedtick(buffer)
  if cached and cached.tick == tick then
    return cached.blocks
  end

  local blocks = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buffer)
  if not ok or not parser then
    blocks_by_buffer[buffer] = { tick = tick, blocks = blocks }
    return blocks
  end
  local language = parser:lang()
  local query = comment_query(language)
  local tree = parser:parse()[1]
  if not query or not tree then
    blocks_by_buffer[buffer] = { tick = tick, blocks = blocks }
    return blocks
  end

  for _, node in query:iter_captures(tree:root(), buffer) do
    local first_row, first_column, last_row = node:range()
    local text = vim.treesitter.get_node_text(node, buffer)
    local line_before = vim.api.nvim_buf_get_lines(buffer, first_row, first_row + 1, false)[1]:sub(1, first_column)
    -- a trailing comment after code ("int x; /**< … */") stays as it is
    local starts_line = line_before:match("^%s*$") ~= nil
    local previous = blocks[#blocks]

    if starts_line and (vim.startswith(text, "/**") or vim.startswith(text, "/*!")) and not vim.startswith(text, "/**/") then
      blocks[#blocks + 1] = { kind = "block", first_row = first_row, last_row = last_row }
    elseif starts_line and line_marker(text, language) then
      if previous and previous.kind == "lines" and previous.last_row + 1 == first_row then
        previous.last_row = first_row
      else
        blocks[#blocks + 1] = { kind = "lines", first_row = first_row, last_row = first_row, language = language }
      end
    end
  end

  blocks_by_buffer[buffer] = { tick = tick, blocks = blocks }
  return blocks
end

local function mark(buffer, row, column, options)
  options.priority = options.priority or PRIORITY
  pcall(vim.api.nvim_buf_set_extmark, buffer, NAMESPACE, row, column, options)
end

local function conceal(buffer, row, start_column, end_column)
  if end_column > start_column then
    mark(buffer, row, start_column, { end_col = end_column, conceal = "" })
  end
end

local function inline(buffer, row, column, text, group)
  mark(buffer, row, column, { virt_text = { { text, group } }, virt_text_pos = "inline" })
end

local function highlight(buffer, row, start_column, end_column, group)
  if end_column > start_column then
    mark(buffer, row, start_column, { end_col = end_column, hl_group = group })
  end
end

-- `code` spans: the backticks go, the inside reads as code.
local function render_code_spans(buffer, row, line, from_column, to_column)
  local search_from = from_column + 1
  while true do
    local open, close = line:find("`[^`]+`", search_from)
    if not open or close > to_column then
      return
    end
    conceal(buffer, row, open - 1, open)
    highlight(buffer, row, open, close - 1, "DocRenderCode")
    conceal(buffer, row, close - 1, close)
    search_from = close + 1
  end
end

-- Text of one line from content_column (0-based) to content_end; tags become words.
local function render_content(buffer, row, line, content_column, content_end)
  local content = line:sub(content_column + 1, content_end)
  local leading_space, tag_mark, tag = content:match("^(%s*)([@\\])(%a+)")
  if not tag then
    render_code_spans(buffer, row, line, content_column, content_end)
    return
  end

  local tag_column = content_column + #leading_space
  local after_tag = tag_column + #tag_mark + #tag
  -- Doxygen direction, "@param[in] limit", is shown as nothing: the name says enough
  local direction = line:match("^%[[%a,]+%]", after_tag + 1)
  after_tag = after_tag + #(direction or "")
  if line:sub(after_tag + 1, after_tag + 1) == " " then
    after_tag = after_tag + 1
  end

  if HIDDEN_TAGS[tag] then
    conceal(buffer, row, tag_column, after_tag)
  elseif PARAMETER_TAGS[tag] then
    conceal(buffer, row, tag_column, after_tag)
    inline(buffer, row, tag_column, "• ", "DocRenderLabel")
    local name_column = after_tag
    -- JSDoc puts the type first: "@param {string} name"
    local type_text = line:match("^{[^}]*}%s*", name_column + 1)
    if type_text then
      local braces_end = name_column + #(type_text:match("^{[^}]*}"))
      conceal(buffer, row, name_column, name_column + 1)
      highlight(buffer, row, name_column + 1, braces_end - 1, "DocRenderType")
      conceal(buffer, row, braces_end - 1, braces_end)
      name_column = name_column + #type_text
    end
    local name = line:match("^[%w_%.%[%]%?]+", name_column + 1)
    if name then
      highlight(buffer, row, name_column, name_column + #name, "DocRenderName")
      local after_name = name_column + #name
      if line:match("^ %S", after_name + 1) then
        conceal(buffer, row, after_name, after_name + 1)
        inline(buffer, row, after_name, " — ", "DocRenderBar")
      end
    end
  elseif LABEL_BY_TAG[tag] then
    conceal(buffer, row, tag_column, after_tag)
    inline(buffer, row, tag_column, LABEL_BY_TAG[tag] .. ": ", "DocRenderLabel")
    if NAMED_LABEL_TAGS[tag] then
      local name = line:match("^[%w_:%.<>]+", after_tag + 1)
      if name then
        highlight(buffer, row, after_tag, after_tag + #name, "DocRenderName")
      end
    end
  end
  render_code_spans(buffer, row, line, after_tag, content_end)
end

local function render_block(buffer, block, lines)
  for row = block.first_row, block.last_row do
    local line = lines[row - block.first_row + 1]
    local indent = #line:match("^%s*")

    if block.kind == "lines" then
      local marker = line_marker(line:sub(indent + 1), block.language)
      if marker then
        local content_column = indent + #marker + (line:sub(indent + #marker + 1, indent + #marker + 1) == " " and 1 or 0)
        conceal(buffer, row, indent, content_column)
        inline(buffer, row, indent, "▎ ", "DocRenderBar")
        render_content(buffer, row, line, content_column, #line)
      end
    else
      local content_column, content_end = indent, #line
      local closer = line:find("%s*%*/%s*$")
      if closer then
        content_end = closer - 1
      end

      local opener = row == block.first_row and line:match("^/%*[%*!] ?", indent + 1)
      local star = not opener and line:match("^%* ?", indent + 1)
      local prefix = opener or star or ""
      local is_empty_edge = (row == block.first_row or row == block.last_row)
        and block.first_row ~= block.last_row
        and line:sub(indent + #prefix + 1, content_end):match("^%s*$")

      if is_empty_edge then
        mark(buffer, row, 0, { end_row = row, conceal_lines = "" })
      else
        content_column = indent + #prefix
        conceal(buffer, row, indent, content_column)
        inline(buffer, row, indent, "▎ ", "DocRenderBar")
        if closer then
          conceal(buffer, row, content_end, #line)
        end
        render_content(buffer, row, line, content_column, content_end)
      end
    end
  end
end

local function cursor_block_index(buffer, blocks)
  if vim.api.nvim_get_current_buf() ~= buffer then
    return nil
  end
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for index, block in ipairs(blocks) do
    if cursor_row >= block.first_row and cursor_row <= block.last_row then
      return index
    end
  end
end

-- A closed fold is drawn from its first line, and a doc block hides its "/**" line, so a block
-- inside a closed fold is left raw: otherwise the fold, summary and all, would vanish.
local function closed_folds_signature(buffer, blocks)
  if vim.api.nvim_get_current_buf() ~= buffer then
    return ""
  end
  local flags = {}
  for index, block in ipairs(blocks) do
    flags[index] = vim.fn.foldclosed(block.first_row + 1) ~= -1 and "1" or "0"
  end
  return table.concat(flags)
end

-- LSP fold ranges stop a line short, so a folded "/** … */" leaves its "*/" dangling below the fold.
local function hide_closer_left_by_fold(buffer, block)
  if block.kind ~= "block" or block.first_row == block.last_row then
    return
  end
  local last_line = vim.api.nvim_buf_get_lines(buffer, block.last_row, block.last_row + 1, false)[1]
  if last_line:match("^%s*%*/%s*$") and vim.fn.foldclosed(block.last_row + 1) == -1 then
    mark(buffer, block.last_row, 0, { end_row = block.last_row, conceal_lines = "" })
  end
end

function M.clear(buffer)
  if vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_clear_namespace(buffer, NAMESPACE, 0, -1)
  end
  raw_block_by_buffer[buffer] = nil
  folds_by_buffer[buffer] = nil
end

function M.render(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buffer) then
    return
  end
  M.clear(buffer)
  if not vim.g.doc_render or not FILETYPES[vim.bo[buffer].filetype] then
    return
  end

  local blocks = find_blocks(buffer)
  local raw_index = cursor_block_index(buffer, blocks)
  local folds = closed_folds_signature(buffer, blocks)
  raw_block_by_buffer[buffer] = raw_index or 0
  folds_by_buffer[buffer] = folds
  for index, block in ipairs(blocks) do
    if folds:sub(index, index) == "1" then
      hide_closer_left_by_fold(buffer, block)
    elseif index ~= raw_index then
      render_block(buffer, block, vim.api.nvim_buf_get_lines(buffer, block.first_row, block.last_row + 1, false))
    end
  end
end

local function render_soon(buffer)
  if pending_render[buffer] then
    return
  end
  pending_render[buffer] = true
  vim.defer_fn(function()
    pending_render[buffer] = nil
    M.render(buffer)
  end, 80)
end

-- Runs after every command, so it only compares: redraw when the cursor crossed into or out of
-- a doc block, or a fold over one opened or closed (zc, zo, zM, zR move no text).
local function refresh_if_stale(buffer)
  if not vim.g.doc_render or not FILETYPES[vim.bo[buffer].filetype] then
    return
  end
  local cached = blocks_by_buffer[buffer]
  if not cached then
    return render_soon(buffer)
  end
  local cursor_moved_across = (cursor_block_index(buffer, cached.blocks) or 0) ~= raw_block_by_buffer[buffer]
  local folds_changed = closed_folds_signature(buffer, cached.blocks) ~= folds_by_buffer[buffer]
  if cursor_moved_across or folds_changed then
    M.render(buffer)
  end
end

function M.apply_highlights()
  local function attributes(group)
    local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    return ok and value or {}
  end
  local comment = attributes("Comment")
  local parameter = attributes("@variable.parameter")
  local type_style = attributes("@type")
  local code = attributes("@markup.raw")
  -- Style carries the meaning, colour only helps: bold labels and names, italic types.
  vim.api.nvim_set_hl(0, "DocRenderBar", { fg = comment.fg })
  vim.api.nvim_set_hl(0, "DocRenderLabel", { fg = comment.fg, bold = true })
  vim.api.nvim_set_hl(0, "DocRenderName", { fg = parameter.fg or comment.fg, bold = true })
  vim.api.nvim_set_hl(0, "DocRenderType", { fg = type_style.fg or comment.fg, italic = true })
  vim.api.nvim_set_hl(0, "DocRenderCode", { fg = code.fg or attributes("String").fg or comment.fg })
end

function M.set_enabled(enabled)
  vim.g.doc_render = enabled
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then
      M.render(buffer)
    end
  end
end

function M.setup()
  -- Off until asked for with Space u R: a comment that turns into prose right after a save
  -- looks as if the editor folded it.
  if vim.g.doc_render == nil then
    vim.g.doc_render = false
  end
  M.apply_highlights()
  local group = vim.api.nvim_create_augroup("doc_render", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.apply_highlights })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType", "TextChanged", "InsertLeave" }, {
    group = group,
    callback = function(event)
      render_soon(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "SafeState", "CursorMovedI" }, {
    group = group,
    callback = function()
      refresh_if_stale(vim.api.nvim_get_current_buf())
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      blocks_by_buffer[event.buf] = nil
      raw_block_by_buffer[event.buf] = nil
      folds_by_buffer[event.buf] = nil
    end,
  })
  render_soon(vim.api.nvim_get_current_buf())
end

return M
