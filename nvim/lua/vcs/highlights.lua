-- Colours of the VCS window come from the theme, but meaning is carried by shape: [x] [~] [ ],
-- the status letter, a struck-through name for a deleted file, italics for an unversioned one,
-- bold for a conflict; gutter bars are solid (line only on this side) or dashed (line changed).
local M = {}

local function attribute_of(group, attribute)
  local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  return ok and highlight[attribute] or nil
end

-- a theme colour plus attributes; a plain link can't add attributes
local function derived(source, attributes)
  return vim.tbl_extend("force", { fg = attribute_of(source, "fg") }, attributes)
end

local function background_of(source, attributes)
  return vim.tbl_extend("force", { bg = attribute_of(source, "bg") }, attributes or {})
end

local function definitions()
  return {
    VcsGroup = derived("Title", { bold = true }),
    VcsDirectory = { link = "Directory" },
    VcsCount = { link = "Comment" },
    VcsHint = { link = "Comment" },
    VcsCheckFull = derived("DiagnosticOk", { bold = true }),
    VcsCheckPartial = derived("DiagnosticWarn", { bold = true }),
    VcsCheckNone = { link = "Comment" },
    VcsLetterM = derived("Changed", { bold = true }),
    VcsLetterA = derived("Added", { bold = true }),
    VcsLetterD = derived("Removed", { bold = true }),
    VcsLetterR = derived("Changed", { bold = true }),
    VcsLetterUntracked = derived("Comment", { bold = true }),
    VcsLetterConflict = derived("DiagnosticError", { bold = true }),
    VcsNameD = { strikethrough = true },
    VcsNameUntracked = { italic = true },
    VcsNameConflict = derived("DiagnosticError", { bold = true }),
    VcsBranch = derived("Title", { bold = true }),
    VcsAmend = derived("DiagnosticWarn", { bold = true, reverse = true }),
    VcsMenuKey = derived("Special", { bold = true }),
    VcsMenuOn = derived("DiagnosticOk", { bold = true }),

    -- the Log and the branch popup: labels differ by brackets and attributes, not by colour alone
    VcsLogGraph = { link = "Comment" },
    VcsLogNode = derived("Title", { bold = true }),
    VcsLogHash = derived("Constant", { bold = true }),
    VcsLogHead = derived("Title", { bold = true, reverse = true }),
    VcsLogBranch = derived("Title", { bold = true }),
    VcsLogRemote = derived("Directory", { italic = true }),
    VcsLogTag = derived("Constant", { bold = true, underline = true }),
    VcsLogHeadSubject = { bold = true },
    VcsLogFilter = derived("DiagnosticWarn", { bold = true }),
    VcsLogWarning = derived("DiagnosticWarn", { bold = true }),
    VcsBranchCurrent = derived("Title", { bold = true }),

    -- gutter markers of the diff
    VcsSignAdded = derived("Added", { bold = true }),
    VcsSignRemoved = derived("Removed", { bold = true }),
    VcsSignChanged = derived("Changed", { bold = true }),

    -- "gutter bar" highlighting: no backgrounds, changed words keep an underline
    VcsDiffPlain = {},
    VcsDiffTextBar = { underline = true },
    VcsDiffFillerBar = { link = "NonText" },

    -- unified view: backgrounds only, so syntax colours stay visible on top
    VcsUnifiedAdded = background_of("DiffAdd"),
    VcsUnifiedRemoved = background_of("DiffDelete"),
    VcsUnifiedRemovedBar = { italic = true },
    VcsWordAdded = background_of("DiffText", { underline = true }),
    VcsWordRemoved = background_of("DiffText", { strikethrough = true }),
    VcsWordAddedBar = { underline = true, bold = true },
    VcsWordRemovedBar = { strikethrough = true },
  }
end

-- status letter → group suffix: "?" and "!" are not allowed in group names
M.SUFFIX = { M = "M", A = "A", D = "D", R = "R", ["?"] = "Untracked", ["!"] = "Conflict" }

function M.apply()
  for name, definition in pairs(definitions()) do
    -- default: a theme may define its own Vcs* groups and they win
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", definition, { default = true }))
  end
end

function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("vcs_highlights", { clear = true }),
    callback = M.apply,
  })
end

return M
