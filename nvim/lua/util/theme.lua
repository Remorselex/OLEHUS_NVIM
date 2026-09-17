-- The colorscheme is remembered per project: pick one with `Space u C` and the next
-- time this repository is opened it comes back, with no config edits in between.
local M = {}

local STORE_PATH = vim.fn.stdpath("data") .. "/theme-by-project.json"
local FALLBACK_THEME = "sonokai"

-- ColorScheme also fires while the startup theme is being applied, so saving stays
-- off until that has happened; otherwise the default would overwrite the user's pick.
local saving_enabled = false

local function project_key()
  local current_dir = vim.uv.cwd() or "."
  local git_dir = vim.fs.find(".git", { upward = true, path = current_dir })[1]
  return git_dir and vim.fs.dirname(git_dir) or current_dir
end

local function read_store()
  local file = io.open(STORE_PATH, "r")
  if not file then
    return {}
  end
  local raw = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  return (ok and type(decoded) == "table") and decoded or {}
end

local function write_store(store)
  local file = io.open(STORE_PATH, "w")
  if not file then
    return
  end
  file:write(vim.json.encode(store))
  file:close()
end

function M.remember(theme_name)
  if not saving_enabled or theme_name == nil or theme_name == "" then
    return
  end
  local store = read_store()
  store[project_key()] = theme_name
  write_store(store)
end

function M.load()
  local wanted = read_store()[project_key()] or FALLBACK_THEME
  if not pcall(vim.cmd.colorscheme, wanted) then
    vim.cmd.colorscheme(FALLBACK_THEME)
  end
  saving_enabled = true
end

function M.current_project()
  return project_key()
end

vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function(event)
    M.remember(event.match)
  end,
})

return M
