-- Trigram-indexed search for large repositories.
--
-- Pickers shell out to ripgrep, which rescans every file on every keystroke: on
-- a 400k-file monorepo that is ~8 s per query. tgrep answers from a prebuilt
-- index in ~0.2 s. The shim in bin/nvim-search/rg routes ripgrep calls to it and
-- falls back to the real ripgrep wherever no index exists.
--
-- The index only tracks edits while `tgrep serve` runs, so without the server a
-- search silently misses the file you just wrote. That is why the server is
-- started here rather than left to the user.
local M = {}

local function project_root()
  local git_entry = vim.fs.find(".git", { upward = true, path = vim.uv.cwd() })[1]
  return git_entry and vim.fs.dirname(git_entry) or vim.uv.cwd()
end

local function has_index(root)
  return vim.uv.fs_stat(root .. "/.tgrep") ~= nil
end

local function server_running(root)
  return vim.system({ "tgrep", "status" }, { cwd = root, text = true }):wait().code == 0
end

function M.ensure_server()
  if vim.fn.executable("tgrep") == 0 then
    return
  end
  local root = project_root()
  if not has_index(root) or server_running(root) then
    return
  end
  vim.system({ "tgrep", "serve", root }, { cwd = root, detach = true })
end

function M.build_index()
  if vim.fn.executable("tgrep") == 0 then
    vim.notify("tgrep is not installed: brew install tgrep", vim.log.levels.ERROR)
    return
  end
  local root = project_root()
  vim.notify("tgrep: building the index for " .. root)
  vim.system({ "tgrep", "index", root }, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify("tgrep index: " .. (result.stderr or "error"), vim.log.levels.ERROR)
        return
      end
      vim.notify("tgrep: index ready, starting the server")
      M.ensure_server()
    end)
  end)
end

function M.status()
  local root = project_root()
  local result = vim.system({ "tgrep", "status" }, { cwd = root, text = true }):wait()
  vim.notify(result.code == 0 and (result.stdout or "") or ("no index or server for " .. root))
end

-- `tgrep status` only answers for one directory, and the process list shows the
-- server as "tgrep serve ." regardless of where it runs, so the root has to come
-- from each process's working directory.
local function running_servers()
  local pids = vim.system({ "pgrep", "-x", "tgrep" }, { text = true }):wait()
  local servers = {}
  for pid in (pids.stdout or ""):gmatch("%d+") do
    local cwd = vim.system({ "lsof", "-a", "-p", pid, "-d", "cwd", "-Fn" }, { text = true }):wait()
    local root = (cwd.stdout or ""):match("\nn(/[^\n]*)")
    if root then
      local status = vim.system({ "tgrep", "status" }, { cwd = root, text = true }):wait()
      servers[#servers + 1] = {
        pid = pid,
        root = root,
        port = (status.stdout or ""):match("Port:%s*(%d+)"),
        files = (status.stdout or ""):match("Files:%s*(%d+)"),
      }
    end
  end
  return servers
end

function M.servers()
  local servers = running_servers()
  if #servers == 0 then
    vim.notify("tgrep: no servers running")
    return
  end
  local lines = { ("tgrep: servers running: %d"):format(#servers) }
  for _, server in ipairs(servers) do
    lines[#lines + 1] = ("  pid %-7s port %-6s files %-8s %s")
      :format(server.pid, server.port or "?", server.files or "?", vim.fn.fnamemodify(server.root, ":~"))
  end
  vim.notify(table.concat(lines, "\n"))
end

function M.report()
  local root = project_root()
  if not has_index(root) then
    return
  end
  local status = vim.system({ "tgrep", "status" }, { cwd = root, text = true }):wait()
  local files = (status.stdout or ""):match("Files:%s*(%d+)")
  local pid = (status.stdout or ""):match("PID:%s*(%d+)")
  vim.notify(pid and ("tgrep: server pid %s, files %s"):format(pid, files or "?")
    or "tgrep: index exists, but the server didn't start — :TgrepStatus")
end

vim.api.nvim_create_user_command("TgrepServers", M.servers, { desc = "All running tgrep servers" })
vim.api.nvim_create_user_command("TgrepIndex", M.build_index, { desc = "Build a trigram index for the project" })
vim.api.nvim_create_user_command("TgrepStatus", M.status, { desc = "tgrep index and server status" })

return M
