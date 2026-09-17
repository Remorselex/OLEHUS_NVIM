-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- GITSIGNS-VIEW: look at the file itself with changes highlighted, not at a diff
vim.keymap.set("n", "<leader>gvh", "<cmd>Gitsigns toggle_linehl<cr>", { desc = "Подсветка изменённых строк" })
vim.keymap.set("n", "<leader>gvw", "<cmd>Gitsigns toggle_word_diff<cr>", { desc = "Пословная подсветка изменений" })
vim.keymap.set("n", "<leader>gvx", "<cmd>Gitsigns toggle_deleted<cr>", { desc = "Показать удалённые строки" })

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

vim.keymap.set("n", "<leader>rr", function() run_in_terminal("nr") end, { desc = "Скрипты пакета под курсором (nr)" })
vim.keymap.set("n", "<leader>rl", function() run_in_terminal("nr -") end, { desc = "Повторить последний скрипт" })

-- INLINE-BLAME: a standing annotation at the end of every line (IDEA's Annotate)
vim.keymap.set("n", "<leader>gvb", "<cmd>Gitsigns toggle_current_line_blame<cr>", { desc = "Inline blame (вкл/выкл)" })

-- BLAME-PANEL: blame for the whole file, a commit per line
vim.keymap.set("n", "<leader>gva", "<cmd>Gitsigns blame<cr>", { desc = "Blame всего файла" })

-- RANGE-HISTORY: commits touching the selected lines (IDEA's "Show history for selection")
vim.keymap.set("v", "<leader>gvf", ":DiffviewFileHistory<cr>", { desc = "История выделенного фрагмента" })

-- THEME: toggle the transparent background; the theme itself is remembered per project
vim.keymap.set("n", "<leader>uB", "<cmd>TransparencyToggle<cr>", { desc = "Прозрачный фон вкл/выкл" })
vim.keymap.set("n", "<leader>uS", "<cmd>SyntaxContrastToggle<cr>", { desc = "Различение синтаксиса начертанием" })

-- PATCH: patches as files, since format-patch/am were never ported to Neogit
vim.keymap.set("n", "<leader>gmw", function() require("util.git-patch").working_tree() end, { desc = "Патч: все незакоммиченные изменения" })
vim.keymap.set("n", "<leader>gms", function() require("util.git-patch").staged() end, { desc = "Патч: застейдженное" })
vim.keymap.set("n", "<leader>gmf", function() require("util.git-patch").current_file() end, { desc = "Патч: текущий файл" })
vim.keymap.set("n", "<leader>gmc", function() require("util.git-patch").from_commit() end, { desc = "Патч: format-patch по коммиту" })
vim.keymap.set("n", "<leader>gma", function() require("util.git-patch").apply() end, { desc = "Патч: применить файл" })
