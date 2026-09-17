-- Patches as files: format-patch and am were never ported to Neogit, so this does it.
-- Patches land outside any repository, to keep working trees clean.
local M = {}

local PATCH_DIR = vim.fn.expand("~/patches")

local function repository_root()
  local git_entry = vim.fs.find(".git", { upward = true, path = vim.uv.cwd() })[1]
  if git_entry == nil then
    vim.notify("не git-репозиторий", vim.log.levels.ERROR)
    return nil
  end
  return vim.fs.dirname(git_entry)
end

local function run_git(root, args)
  local result = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
  if result.code ~= 0 then
    vim.notify("git " .. table.concat(args, " ") .. "\n" .. (result.stderr or ""), vim.log.levels.ERROR)
    return nil
  end
  return result.stdout or ""
end

local function patch_path(root, suffix)
  vim.fn.mkdir(PATCH_DIR, "p")
  local repository_name = vim.fs.basename(root)
  return ("%s/%s-%s-%s.patch"):format(PATCH_DIR, repository_name, suffix, os.date("%Y%m%d-%H%M%S"))
end

local function save(root, git_args, suffix)
  local diff = run_git(root, git_args)
  if diff == nil then
    return
  end
  if diff == "" then
    vim.notify("нечего класть в патч", vim.log.levels.WARN)
    return
  end
  local path = patch_path(root, suffix)
  local file = assert(io.open(path, "w"))
  file:write(diff)
  file:close()
  vim.fn.setreg("+", path)
  vim.notify(("патч: %s\n(%d строк, путь в буфере обмена)"):format(path, select(2, diff:gsub("\n", "\n"))))
end

function M.working_tree()
  local root = repository_root()
  if root then
    save(root, { "diff", "HEAD" }, "worktree")
  end
end

function M.staged()
  local root = repository_root()
  if root then
    save(root, { "diff", "--cached" }, "staged")
  end
end

function M.current_file()
  local root = repository_root()
  if root == nil then
    return
  end
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("буфер без файла", vim.log.levels.WARN)
    return
  end
  save(root, { "diff", "HEAD", "--", file }, vim.fn.fnamemodify(file, ":t:r"))
end

-- format-patch writes one file per commit, which is what `git am` consumes
function M.from_commit()
  local root = repository_root()
  if root == nil then
    return
  end
  local log = run_git(root, { "log", "--oneline", "-50", "--no-decorate" })
  if log == nil or log == "" then
    return
  end
  local commits = vim.split(vim.trim(log), "\n")
  vim.ui.select(commits, { prompt = "format-patch для коммита:" }, function(choice)
    if choice == nil then
      return
    end
    local sha = choice:match("^(%S+)")
    vim.fn.mkdir(PATCH_DIR, "p")
    local written = run_git(root, { "format-patch", "-1", sha, "-o", PATCH_DIR })
    if written ~= nil then
      vim.fn.setreg("+", vim.trim(written))
      vim.notify("патч: " .. vim.trim(written))
    end
  end)
end

function M.apply()
  local root = repository_root()
  if root == nil then
    return
  end
  local files = vim.fn.glob(PATCH_DIR .. "/*.patch", false, true)
  if #files == 0 then
    vim.notify("в " .. PATCH_DIR .. " нет патчей", vim.log.levels.WARN)
    return
  end
  table.sort(files, function(a, b) return a > b end)
  vim.ui.select(files, {
    prompt = "применить патч:",
    format_item = function(item) return vim.fs.basename(item) end,
  }, function(choice)
    if choice == nil then
      return
    end
    -- dry run first: git apply --check leaves the tree alone when the patch won't fit
    local checked = run_git(root, { "apply", "--check", choice })
    if checked == nil then
      return
    end
    if run_git(root, { "apply", choice }) ~= nil then
      vim.notify("применён: " .. vim.fs.basename(choice))
      vim.cmd.checktime()
    end
  end)
end

return M
