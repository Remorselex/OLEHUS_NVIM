-- Text of a closed fold: the first line with its syntax highlighting, then how much is hidden.
-- A documentation comment shows its first sentence instead of a bare "/**", as Rider does.
local M = {}

local function lines_word(count)
  return count == 1 and "line" or "lines"
end

local function highlighted_chunks(buffer, row, text)
  local chunks = {}
  local pending_text, pending_group = "", nil
  for column = 0, #text - 1 do
    local captures = vim.treesitter.get_captures_at_pos(buffer, row, column)
    local top = captures[#captures]
    local group = top and ("@%s.%s"):format(top.capture, top.lang) or nil
    if group ~= pending_group and pending_text ~= "" then
      chunks[#chunks + 1] = { pending_text, pending_group }
      pending_text = ""
    end
    pending_group = group
    pending_text = pending_text .. text:sub(column + 1, column + 1)
  end
  if pending_text ~= "" then
    chunks[#chunks + 1] = { pending_text, pending_group }
  end
  return chunks
end

-- "/**" alone says nothing; the first line with words in it does.
local function doc_summary_chunks(indent, first_row, last_row)
  for row = first_row + 1, last_row do
    local text = vim.fn.getline(row):gsub("^%s*%*?%s*", ""):gsub("^[@\\]brief%s*", ""):gsub("%s*%*/%s*$", "")
    if text ~= "" then
      return { { indent .. "/** " .. text .. " */", "@comment" } }
    end
  end
  return { { indent .. "/** */", "@comment" } }
end

function M.render()
  local buffer = vim.api.nvim_get_current_buf()
  local first_row, last_row = vim.v.foldstart, vim.v.foldend
  local text = vim.fn.getline(first_row)

  local chunks
  if text:match("^%s*/%*[%*!]%s*$") then
    chunks = doc_summary_chunks(text:match("^%s*"), first_row, last_row)
  else
    chunks = highlighted_chunks(buffer, first_row - 1, text)
  end

  local tab = string.rep(" ", vim.bo[buffer].tabstop)
  for _, chunk in ipairs(chunks) do
    chunk[1] = chunk[1]:gsub("\t", tab)
  end
  local hidden = last_row - first_row + 1
  chunks[#chunks + 1] = { ("  ⋯ %d %s"):format(hidden, lines_word(hidden)), "Comment" }
  return chunks
end

return M
