-- `gl{motion}{char}` / visual `gl{char}` (the whole file: `gl ig :`): line the text up on a separator
-- so the column after it can be edited at once with Ctrl-V (struct field types, JSON values).
-- Formatting on save puts the code back to the project's style, so this never leaks into commits.
--
--   gl ip :      appid: u32,            appid:   u32,
--                name: String,     ->   name:    String,
--                release: Option<..>    release: Option<..>
--
-- `:` stays glued to the left side (`key:   value`), any other separator gets padded before it
-- (`left    = right`). Each nesting level lines up on its own: a JSON object's keys align with
-- each other, not with the keys of the objects inside it; `"key": {` lines are left alone.
local M = {}

local COMPOUND_NEIGHBOURS = {
  [":"] = { [":"] = true },
  ["="] = { ["="] = true, [">"] = true, ["!"] = true, ["<"] = true, ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true },
}

-- byte index of the first separator outside "strings" that isn't part of `::`, `==`, `=>`, …
local function find_separator(line, separator)
  local neighbours = COMPOUND_NEIGHBOURS[separator] or {}
  local in_string = false
  local index = 1
  while index <= #line do
    local char = line:sub(index, index)
    if in_string then
      if char == "\\" then
        index = index + 1
      elseif char == '"' then
        in_string = false
      end
    elseif char == '"' then
      in_string = true
    elseif char == separator then
      local before, after = line:sub(index - 1, index - 1), line:sub(index + 1, index + 1)
      if not neighbours[before] and not neighbours[after] then
        return index
      end
      index = index + 1
    end
    index = index + 1
  end
end

-- `"assets": {` holds no value to edit, and padding it would only push its neighbours apart
local OPENS_A_BLOCK = { ["{"] = true, ["["] = true, ["("] = true }

local function indent_of(line)
  return #line:match("^%s*")
end

-- "same nesting level" = same indent and no shallower line between them
local function group_of_each_line(lines)
  local groups = {}
  local open_levels = {} -- indent -> group of that level, while no shallower line has closed it
  local group_count = 0

  local function place(number, line)
    if line:match("^%s*$") then
      return
    end
    local indent = indent_of(line)
    for level in pairs(open_levels) do
      if level > indent then
        open_levels[level] = nil
      end
    end
    if open_levels[indent] == nil then
      group_count = group_count + 1
      open_levels[indent] = group_count
    end
    groups[number] = open_levels[indent]
  end

  for number, line in ipairs(lines) do
    place(number, line)
  end
  return groups
end

---@param lines string[]
---@param separator string
---@return string[]
function M.align_lines(lines, separator)
  local glued = separator == ":"
  local split = {} ---@type table<integer, {left: string, right: string}>
  for number, line in ipairs(lines) do
    local position = find_separator(line, separator)
    if position then
      local left = glued and line:sub(1, position) or line:sub(1, position - 1):gsub("%s+$", "")
      local right = line:sub(position + 1):gsub("^%s+", "")
      if not OPENS_A_BLOCK[right] then
        split[number] = { left = left, right = right }
      end
    end
  end

  local groups = group_of_each_line(lines)
  local widest = {} ---@type table<integer, integer>
  for number, parts in pairs(split) do
    local group = groups[number]
    widest[group] = math.max(widest[group] or 0, vim.fn.strdisplaywidth(parts.left))
  end

  local result = {}
  for number, line in ipairs(lines) do
    local parts = split[number]
    if parts == nil then
      result[number] = line
    else
      local padding = string.rep(" ", widest[groups[number]] - vim.fn.strdisplaywidth(parts.left))
      if glued then
        result[number] = parts.left .. padding .. (parts.right == "" and "" or " " .. parts.right)
      else
        result[number] = parts.left .. padding .. " " .. separator .. (parts.right == "" and "" or " " .. parts.right)
      end
    end
  end
  return result
end

local function align_range(first_line, last_line)
  local separator = vim.fn.getcharstr()
  if separator == "\27" or separator == "" then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(0, first_line - 1, last_line, false)
  local aligned = M.align_lines(lines, separator)
  if not vim.deep_equal(lines, aligned) then
    vim.api.nvim_buf_set_lines(0, first_line - 1, last_line, false, aligned)
  end
end

-- an operator leaves the cursor at the start of the range: after `gl ig :` it would sit on line 1
local view_before_operator

function M.operator(motion_type)
  if motion_type == nil then
    view_before_operator = vim.fn.winsaveview()
    vim.o.operatorfunc = "v:lua.require'util.align'.operator"
    return "g@"
  end
  align_range(vim.fn.line("'["), vim.fn.line("']"))
  -- `.` repeats the operator without the mapping, so there is no fresh view to go back to
  if view_before_operator ~= nil then
    vim.fn.winrestview(view_before_operator)
    view_before_operator = nil
  end
end

function M.visual()
  local first_line, last_line = vim.fn.line("v"), vim.fn.line(".")
  if first_line > last_line then
    first_line, last_line = last_line, first_line
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  align_range(first_line, last_line)
end

return M
