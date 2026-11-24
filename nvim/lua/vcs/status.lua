-- Parsing of `git status --porcelain=v2 --branch -z`: the format meant for programs, stable
-- across git versions and independent of the interface language.
local M = {}

M.COMMAND = { "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal" }

local function add_tracked(status, xy, submodule, path, original_path, conflicted)
  table.insert(status.entries, {
    path = path,
    original_path = original_path,
    staged = xy:sub(1, 1),
    unstaged = xy:sub(2, 2),
    submodule = submodule ~= "N...",
    group = conflicted and "conflicts" or "changes",
  })
end

function M.parse(output)
  local records = vim.split(output, "\0", { plain = true })
  local status = { branch = {}, entries = {} }
  local position = 1
  while position <= #records do
    local record = records[position]
    position = position + 1
    local kind = record:sub(1, 1)
    if kind == "#" then
      local key, value = record:match("^# branch%.(%S+) (.*)$")
      if key == "ab" then
        local ahead, behind = value:match("^%+(%d+) %-(%d+)$")
        status.branch.ahead, status.branch.behind = tonumber(ahead), tonumber(behind)
      elseif key then
        status.branch[key] = value
      end
    elseif kind == "1" then
      local xy, submodule, path = record:match("^1 (%S%S) (%S+) %S+ %S+ %S+ %S+ %S+ (.*)$")
      add_tracked(status, xy, submodule, path, nil, false)
    elseif kind == "2" then
      local xy, submodule, path = record:match("^2 (%S%S) (%S+) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
      -- a rename carries its original path in the next record
      local original_path = records[position]
      position = position + 1
      add_tracked(status, xy, submodule, path, original_path, false)
    elseif kind == "u" then
      local xy, submodule, path = record:match("^u (%S%S) (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
      add_tracked(status, xy, submodule, path, nil, true)
    elseif kind == "?" then
      table.insert(status.entries, { path = record:sub(3), group = "unversioned", staged = ".", unstaged = "?" })
    end
  end
  status.unborn = status.branch.oid == "(initial)"
  return status
end

--- What happened to the file relative to HEAD — one letter, as in IntelliJ.
function M.change_letter(entry)
  if entry.group == "unversioned" then
    return "?"
  end
  if entry.group == "conflicts" then
    return "!"
  end
  if entry.staged == "A" then
    return "A"
  end
  if entry.staged == "R" or entry.staged == "C" then
    return "R"
  end
  if entry.staged == "D" or entry.unstaged == "D" then
    return "D"
  end
  return "M"
end

--- The checkbox is the index: "full" — staged in full, "partial" — some changes are not staged yet.
function M.check_state(entry)
  if entry.group ~= "changes" or entry.staged == "." then
    return "none"
  end
  return entry.unstaged == "." and "full" or "partial"
end

--- Paths to hand to git so an action covers the whole entry: for a rename that is both
--- the new and the old name.
function M.paths_of(entries)
  local paths, seen = {}, {}
  for _, entry in ipairs(entries) do
    for _, path in ipairs({ entry.path, entry.original_path }) do
      if path and not seen[path] then
        seen[path] = true
        paths[#paths + 1] = path
      end
    end
  end
  return paths
end

return M
