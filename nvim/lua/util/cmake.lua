-- Building and running C++ from the editor, for the "one step = one folder
-- = one target" layout: the root CMakeLists pulls the steps in with add_subdirectory,
-- and each leaf list declares add_executable and puts the binary next to the source.
local M = {}

local BUILD_DIR_CANDIDATES = { "cmake-build-debug", "build", "cmake-build-release" }

local function buffer_dir()
  local dir = vim.fn.expand("%:p:h")
  return dir ~= "" and dir or vim.uv.cwd()
end

-- The project root is the topmost directory of an unbroken chain of CMakeLists.txt.
local function cmake_root(start)
  local root = nil
  local dir = start or buffer_dir()
  while dir and dir ~= "/" do
    if vim.uv.fs_stat(dir .. "/CMakeLists.txt") then
      root = dir
    elseif root then
      break
    end
    dir = vim.fs.dirname(dir)
  end
  return root
end

local function build_dir(root)
  for _, candidate in ipairs(BUILD_DIR_CANDIDATES) do
    if vim.uv.fs_stat(root .. "/" .. candidate) then
      return root .. "/" .. candidate
    end
  end
  return root .. "/" .. BUILD_DIR_CANDIDATES[1]
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

-- The target the current file belongs to: look for an add_executable whose sources
-- include this file's name.
local function target_for_file()
  local dir = buffer_dir()
  local text = read(dir .. "/CMakeLists.txt")
  if not text then
    return nil
  end
  local basename = vim.fn.expand("%:t")
  for name, sources in text:gmatch("add_executable%s*%(%s*([%w_%-]+)([^%)]*)%)") do
    if sources:find(basename, 1, true) then
      return name
    end
  end
  return nil
end

local run_in_terminal = require("util.run-terminal").open

-- Otherwise the previous version of the file gets built and the previous binary runs: the symptom
-- looks like "the program never reaches the input", while the real cause is an unsaved buffer.
local function save_modified_buffers()
  vim.cmd("silent! noautocmd wall")
end

-- Look for the binary wherever it may have been put: next to the source (that is how
-- CMAKE_RUNTIME_OUTPUT_DIRECTORY is set in the leaf lists), in the build directory mirror, at the build root.
local function executable_path(root, build, target)
  local relative = buffer_dir():sub(#root + 2)
  local candidates = {
    buffer_dir() .. "/" .. target,
    build .. "/" .. relative .. "/" .. target,
    build .. "/" .. target,
  }
  for _, path in ipairs(candidates) do
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" then
      return path
    end
  end
  return nil
end

function M.configure()
  local root = cmake_root()
  if not root then
    return vim.notify("No CMakeLists.txt found up the tree", vim.log.levels.ERROR)
  end
  local build = build_dir(root)
  run_in_terminal(("cmake -S %s -B %s -DCMAKE_EXPORT_COMPILE_COMMANDS=ON"):format(root, build), root)
  -- clangd looks for the compilation database at the project root, while cmake puts it in the build directory
  if not vim.uv.fs_stat(root .. "/compile_commands.json") then
    vim.uv.fs_symlink(build .. "/compile_commands.json", root .. "/compile_commands.json")
  end
end

function M.build()
  save_modified_buffers()
  local root = cmake_root()
  if not root then
    return vim.notify("No CMakeLists.txt found up the tree", vim.log.levels.ERROR)
  end
  local target = target_for_file()
  local build = build_dir(root)
  local command = target and ("cmake --build %s --target %s"):format(build, target)
    or ("cmake --build " .. build)
  run_in_terminal(command, root)
end

function M.run()
  save_modified_buffers()
  local root = cmake_root()
  if not root then
    return vim.notify("No CMakeLists.txt found up the tree", vim.log.levels.ERROR)
  end
  local target = target_for_file()
  if not target then
    return vim.notify("the CMakeLists next to the file has no add_executable with this source", vim.log.levels.WARN)
  end
  local build = build_dir(root)
  local binary = executable_path(root, build, target)
  local run_command = binary and vim.fn.shellescape(binary) or ("./" .. target)
  local command = ("cmake --build %s --target %s && %s"):format(build, target, run_command)
  run_in_terminal(command, buffer_dir(), true)
end

local function append(path, text)
  local file = assert(io.open(path, "a"))
  file:write(text)
  file:close()
end

-- A counterpart of CLion's "Add to CMake target". If a target already lives next to the file,
-- append the file to its source list; if the directory is new, create a leaf list from the local
-- template and hook it up to the parent with add_subdirectory.
function M.add_target()
  local dir = buffer_dir()
  local source = vim.fn.expand("%:t")
  if source == "" then
    return vim.notify("buffer has no file", vim.log.levels.WARN)
  end

  local list_path = dir .. "/CMakeLists.txt"
  local text = read(list_path)

  if text then
    local existing = target_for_file()
    if existing then
      return vim.notify(("%s is already in target %s"):format(source, existing))
    end
    local target = text:match("add_executable%s*%(%s*([%w_%-]+)")
    if target then
      -- the file may be either one more translation unit of the existing target
      -- or a separate program; choosing silently on the user's behalf is not an option
      return vim.ui.select(
        { "into target " .. target, "new target" },
        { prompt = source .. ":" },
        function(choice)
          if choice == nil then
            return
          end
          if choice:match("^into target") then
            local updated = text:gsub("(add_executable%s*%(%s*" .. target .. ")", "%1 " .. source, 1)
            local file = assert(io.open(list_path, "w"))
            file:write(updated)
            file:close()
            vim.notify(("%s added to target %s"):format(source, target))
            return M.configure()
          end
          M.new_target(list_path, source, false)
        end
      )
    end
  end

  M.new_target(list_path, source, text == nil)
end

function M.new_target(list_path, source, is_new_directory)
  local dir = vim.fs.dirname(list_path)
  vim.ui.input({ prompt = "new target name: ", default = vim.fn.fnamemodify(source, ":r") }, function(target)
    if target == nil or target == "" then
      return
    end
    if is_new_directory then
      append(list_path, ("set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})\n\nadd_executable(%s %s)\n"):format(target, source))
      local parent = vim.fs.dirname(dir)
      local parent_list = parent .. "/CMakeLists.txt"
      local parent_text = read(parent_list)
      local folder = vim.fs.basename(dir)
      if parent_text and not parent_text:find("add_subdirectory(" .. folder .. ")", 1, true) then
        append(parent_list, ("add_subdirectory(%s)\n"):format(folder))
      end
      vim.notify(("created %s, target %s, hooked up to the parent"):format(vim.fn.fnamemodify(list_path, ":~"), target))
    else
      append(list_path, ("\nadd_executable(%s %s)\n"):format(target, source))
      vim.notify(("added target %s"):format(target))
    end
    M.configure()
  end)
end

vim.api.nvim_create_user_command("CMakeConfigure", M.configure, { desc = "cmake configure + compile_commands.json" })
vim.api.nvim_create_user_command("CMakeBuild", M.build, { desc = "Build the current file's target" })
vim.api.nvim_create_user_command("CMakeRun", M.run, { desc = "Build and run the current file's target" })
vim.api.nvim_create_user_command("CMakeAdd", M.add_target, { desc = "Add the file to a CMake target" })

return M
