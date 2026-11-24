-- View preferences of the VCS window, kept across restarts in stdpath("state")/vcs.json.
local M = {}

local PATH = vim.fs.joinpath(vim.fn.stdpath("state"), "vcs.json")

local DEFAULTS = {
  -- "split": HEAD and working copy side by side; "unified": one pane, old lines above new ones
  view = "split",
  -- "full": changed lines get a background; "bar": only a marker in the gutter
  highlight = "full",
  ignore_whitespace = false,
  panel_width = nil,
}

local values

local function load()
  values = vim.deepcopy(DEFAULTS)
  local ok, lines = pcall(vim.fn.readfile, PATH)
  if not ok then
    return
  end
  local decoded_ok, saved = pcall(vim.json.decode, table.concat(lines, "\n"))
  if decoded_ok and type(saved) == "table" then
    values = vim.tbl_extend("force", values, saved)
  end
end

function M.get(name)
  if not values then
    load()
  end
  return values[name]
end

function M.set(name, value)
  if not values then
    load()
  end
  values[name] = value
  pcall(vim.fn.writefile, { vim.json.encode(values) }, PATH)
end

return M
