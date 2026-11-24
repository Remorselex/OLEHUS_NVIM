-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- VCS: our own IntelliJ-style git window (lua/vcs), lazygit as the fallback
vim.keymap.set("n", "<leader>gg", function() require("vcs").toggle() end, { desc = "Git: VCS window (IntelliJ-style)" })
vim.keymap.set("n", "<leader>gG", function() Snacks.lazygit({ cwd = LazyVim.root.git() }) end, { desc = "Lazygit (fallback)" })
-- the Log, branches and Update Project of the same window; they replace LazyVim's pickers on these keys
vim.keymap.set("n", "<leader>gl", function() require("vcs").log() end, { desc = "Git: Log (IntelliJ-style)" })
vim.keymap.set("n", "<leader>gf", function() require("vcs").file_history() end, { desc = "Git: history of this file" })
vim.keymap.set("x", "<leader>gf", function() require("vcs").line_history() end, { desc = "Git: history of the selected lines" })
vim.keymap.set("n", "<leader>gc", function() require("vcs").branches() end, { desc = "Git: branches" })
vim.keymap.set("n", "<leader>gu", function() require("vcs").update() end, { desc = "Git: Update Project (fetch + merge/rebase)" })
vim.keymap.set("n", "<leader>gw", function() require("vcs").worktrees() end, { desc = "Git: worktrees" })

-- ALIGN: `gl ip :` lines fields up on `:` for Ctrl-V column edits; saving formats them back.
-- Not `ga`: LazyVim's LSP keys gai/gao (incoming/outgoing calls) would swallow `ga` + `ip`.
vim.keymap.set("n", "gl", function() return require("util.align").operator() end, { expr = true, desc = "Align on a separator (motion, then the character)" })
vim.keymap.set("x", "gl", function() require("util.align").visual() end, { desc = "Align the selection on a separator (then the character)" })

-- KEYBOARD-ONLY: clicks, drags and the trackpad do nothing (util/keyboard-only.lua)
require("util.keyboard-only").set(true)
Snacks.toggle({
  name = "Mouse",
  get = function() return not require("util.keyboard-only").enabled() end,
  set = function(enabled) require("util.keyboard-only").set(not enabled) end,
}):map("<leader>uM")

-- MACROS: recording is off for now. q closes panels and floats everywhere else (their own
-- buffer-local q still does), and in a plain buffer a stray q plus any letter silently started
-- a recording — which also hides which-key, so Space looked dead. Q replayed the last macro.
vim.keymap.set("n", "q", "<Nop>", { desc = "Nothing (macro recording is off)" })
vim.keymap.set("n", "Q", "<Nop>", { desc = "Nothing (macro recording is off)" })

-- GITSIGNS-VIEW: look at the file itself with changes highlighted, not at a diff
vim.keymap.set("n", "<leader>gvh", "<cmd>Gitsigns toggle_linehl<cr>", { desc = "Highlight changed lines" })
vim.keymap.set("n", "<leader>gvw", "<cmd>Gitsigns toggle_word_diff<cr>", { desc = "Word-level change highlighting" })
vim.keymap.set("n", "<leader>gvx", "<cmd>Gitsigns toggle_deleted<cr>", { desc = "Show deleted lines" })

-- RUN-SCRIPTS: run npm/yarn/pnpm scripts (the IDE's play button).
-- In a monorepo take the package.json nearest the open file, not the root one.
local function nearest_package_dir()
  local start = vim.fn.expand("%:p:h")
  if start == "" then
    start = vim.fn.getcwd()
  end
  local package_json = vim.fs.find("package.json", { path = start, upward = true })[1]
  return package_json and vim.fs.dirname(package_json) or vim.fn.getcwd()
end

local function run_in_terminal(cmd)
  local dir = nearest_package_dir()
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.terminal then
    snacks.terminal(cmd, { cwd = dir })
  else
    vim.cmd("split | lcd " .. vim.fn.fnameescape(dir) .. " | terminal " .. cmd)
  end
end

vim.keymap.set("n", "<leader>rr", function() run_in_terminal("nr") end, { desc = "Scripts of the package under the cursor (nr)" })
vim.keymap.set("n", "<leader>rl", function() run_in_terminal("nr -") end, { desc = "Rerun the last script" })

-- INLINE-BLAME: a standing annotation at the end of every line (IDEA's Annotate)
vim.keymap.set("n", "<leader>gvb", "<cmd>Gitsigns toggle_current_line_blame<cr>", { desc = "Inline blame (on/off)" })

-- BLAME-PANEL: blame for the whole file, a commit per line
vim.keymap.set("n", "<leader>gva", "<cmd>Gitsigns blame<cr>", { desc = "Blame the whole file" })

-- RANGE-HISTORY: commits touching the selected lines (IDEA's "Show history for selection")
vim.keymap.set("v", "<leader>gvf", ":DiffviewFileHistory<cr>", { desc = "History of the selection" })

-- THEME: toggle the transparent background; the theme itself is remembered per project
vim.keymap.set("n", "<leader>uB", "<cmd>TransparencyToggle<cr>", { desc = "Transparent background on/off" })
vim.keymap.set("n", "<leader>uS", "<cmd>SyntaxContrastToggle<cr>", { desc = "Tell syntax apart by font style" })
Snacks.toggle({
  name = "Rider-style doc comments",
  get = function() return vim.g.doc_render end,
  set = function(enabled) require("util.doc-render").set_enabled(enabled) end,
}):map("<leader>uR")
Snacks.toggle({
  name = "Nesting colours (brackets + guides)",
  get = function() return vim.g.rainbow_scopes end,
  set = function(enabled)
    vim.g.rainbow_scopes = enabled
    require("util.rainbow-scopes").apply()
  end,
}):map("<leader>uo")

-- PATCH: patches as files, since format-patch/am were never ported to Neogit
vim.keymap.set("n", "<leader>gmw", function() require("util.git-patch").working_tree() end, { desc = "Patch: all uncommitted changes" })
vim.keymap.set("n", "<leader>gms", function() require("util.git-patch").staged() end, { desc = "Patch: staged changes" })
vim.keymap.set("n", "<leader>gmf", function() require("util.git-patch").current_file() end, { desc = "Patch: current file" })
vim.keymap.set("n", "<leader>gmc", function() require("util.git-patch").from_commit() end, { desc = "Patch: format-patch from a commit" })
vim.keymap.set("n", "<leader>gma", function() require("util.git-patch").apply() end, { desc = "Patch: apply a file" })

-- CMAKE: build/run the target that owns the current file (CLion's play button)
-- RUN: build and run by file type — Rust through cargo (util/cargo.lua), everything else through CMake
local function runner()
  return vim.bo.filetype == "rust" and require("util.cargo") or require("util.cmake")
end
vim.keymap.set("n", "<leader>rc", function() runner().run() end, { desc = "Build and run (C++ / Rust)" })
vim.keymap.set("n", "<leader>rb", function() runner().build() end, { desc = "Build only (C++ / Rust)" })
vim.keymap.set("n", "<leader>rt", function() require("util.cargo").test() end, { desc = "Rust: package tests (or this file's, from tests/)" })
vim.keymap.set("n", "<leader>ro", function() require("util.run-terminal").toggle_last() end, { desc = "Output of the last run (show/hide)" })
vim.keymap.set("n", "<leader>rC", function() require("util.cmake").configure() end, { desc = "C++: cmake configure" })
vim.keymap.set("n", "<leader>ra", function() require("util.cmake").add_target() end, { desc = "C++: add the file to CMake" })

-- COPY-PATH: IDEA's Copy Path/Reference. Ghostty leaves super+shift+c unbound,
-- so the real Cmd+Shift+C reaches nvim over the kitty keyboard protocol.
vim.keymap.set("n", "<D-C>", function() require("util.copy-path").absolute() end, { desc = "Copy the file path to the clipboard" })
vim.keymap.set("n", "<leader>cp", function() require("util.copy-path").pick() end, { desc = "Copy path: pick a form" })
vim.keymap.set("n", "<leader>cP", function() require("util.copy-path").absolute() end, { desc = "Copy the absolute path" })
