-- The changes tree: group → folders → files. A chain of folders that each hold exactly one
-- subfolder and no files is glued into one row (src/app/deep), as in IntelliJ.
local status = require("vcs.status")

local M = {}

M.GROUPS = {
  { id = "conflicts", title = "Merge Conflicts" },
  { id = "changes", title = "Changes" },
  { id = "unversioned", title = "Unversioned Files" },
}

local function new_directory(group, name, path)
  return { kind = "directory", group = group, name = name, path = path, id = group .. ":" .. path, directories = {}, files = {}, entries = {} }
end

local function insert(directory, entry, parts, depth)
  table.insert(directory.entries, entry)
  local name = parts[depth]
  if depth == #parts then
    table.insert(directory.files, { kind = "file", group = entry.group, name = name, path = entry.path, id = entry.group .. ":" .. entry.path, entry = entry, entries = { entry } })
    return
  end
  local child = directory.directories[name]
  if not child then
    child = new_directory(entry.group, name, directory.path == "" and name or (directory.path .. "/" .. name))
    directory.directories[name] = child
  end
  insert(child, entry, parts, depth + 1)
end

local function by_name(left, right)
  return left.name:lower() < right.name:lower()
end

local function sorted_directories(directory)
  local list = vim.tbl_values(directory.directories)
  table.sort(list, by_name)
  return list
end

local function compact(directory)
  local only_child = sorted_directories(directory)[1]
  while #directory.files == 0 and vim.tbl_count(directory.directories) == 1 and directory.path ~= "" do
    directory.name = directory.name .. "/" .. only_child.name
    directory.path, directory.id = only_child.path, only_child.id
    directory.directories, directory.files = only_child.directories, only_child.files
    only_child = sorted_directories(directory)[1]
  end
  for _, child in pairs(directory.directories) do
    compact(child)
  end
end

local function split_path(path)
  -- an unversioned folder comes as "tmp-dir/": it is one node, not a folder holding an empty name
  local is_directory = path:sub(-1) == "/"
  local parts = vim.split(path:gsub("/$", ""), "/", { plain = true })
  if is_directory then
    parts[#parts] = parts[#parts] .. "/"
  end
  return parts
end

--- The checkbox of a folder or group, from all the files inside.
function M.aggregate_check(entries)
  local full, any = true, false
  for _, entry in ipairs(entries) do
    local state = status.check_state(entry)
    full = full and state == "full"
    any = any or state ~= "none"
  end
  if #entries > 0 and full then
    return "full"
  end
  return any and "partial" or "none"
end

--- A flat list of rows to draw: { node, depth }. Collapsed nodes are not expanded.
function M.rows(parsed_status, options)
  local rows = {}
  for _, group in ipairs(M.GROUPS) do
    local root = new_directory(group.id, "", "")
    root.kind, root.id, root.name = "group", group.id .. ":", group.title
    for _, entry in ipairs(parsed_status.entries) do
      if entry.group == group.id then
        insert(root, entry, options.flat and { entry.path } or split_path(entry.path), 1)
      end
    end
    if #root.entries > 0 then
      compact(root)
      local function walk(directory, depth)
        rows[#rows + 1] = { node = directory, depth = depth }
        if options.collapsed[directory.id] then
          return
        end
        for _, child in ipairs(sorted_directories(directory)) do
          walk(child, depth + 1)
        end
        table.sort(directory.files, by_name)
        for _, file in ipairs(directory.files) do
          rows[#rows + 1] = { node = file, depth = depth + 1 }
        end
      end
      walk(root, 0)
    end
  end
  return rows
end

return M
