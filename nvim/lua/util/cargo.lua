-- Building, running and testing Rust from the editor — the counterpart of util/cmake.lua. The package comes
-- from the nearest Cargo.toml with [package], and the command runs from the workspace root with -p <package>,
-- so that exactly what belongs to the open file gets built.
local M = {}

local function buffer_dir()
  local dir = vim.fn.expand("%:p:h")
  return dir ~= "" and dir or vim.uv.cwd()
end

local function read(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

-- { name, dir } of the nearest package up from the file.
local function package_for_file()
  for dir in vim.fs.parents(buffer_dir() .. "/x") do
    local manifest = read(dir .. "/Cargo.toml")
    local package_section = manifest and manifest:match("%[package%](.-)\n%[") or (manifest and manifest:match("%[package%](.*)$"))
    local name = package_section and package_section:match('\nname%s*=%s*"([^"]+)"')
    if name then
      return { name = name, dir = dir }
    end
  end
end

-- The workspace root is the topmost Cargo.toml with [workspace]; without one, the package itself.
local function workspace_root(package_dir)
  local root = package_dir
  for dir in vim.fs.parents(package_dir .. "/x") do
    local manifest = read(dir .. "/Cargo.toml")
    if manifest and manifest:find("%[workspace%]") then
      root = dir
    end
  end
  return root
end

-- Which target to run or test: src/bin/<name>.rs, examples/<name>.rs, tests/<name>.rs.
local function target_arguments(package_dir, for_tests)
  local relative = vim.fn.expand("%:p"):sub(#package_dir + 2)
  local name = vim.fn.expand("%:t:r")
  if relative:match("^src/bin/") then
    return " --bin " .. name
  end
  if relative:match("^examples/") then
    return " --example " .. name
  end
  if for_tests and relative:match("^tests/") then
    return " --test " .. name
  end
  return ""
end

local function save_modified_buffers()
  pcall(vim.cmd, "silent! wall")
end

local function cargo(subcommand, for_tests)
  save_modified_buffers()
  local package = package_for_file()
  if not package then
    return vim.notify("No Cargo.toml with [package] found up the tree", vim.log.levels.ERROR)
  end
  local command = ("cargo %s -p %s%s"):format(subcommand, package.name, target_arguments(package.dir, for_tests))
  require("util.run-terminal").open(command, workspace_root(package.dir), true)
end

function M.run()
  cargo("run", false)
end

function M.build()
  cargo("build", false)
end

function M.test()
  cargo("test", true)
end

return M
