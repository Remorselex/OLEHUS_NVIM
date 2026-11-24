-- Status of the services we run around the editor.
--
-- Every check runs asynchronously and reports into a shared list;
-- the window is drawn once all of them have answered. The mark carries meaning by shape, not colour:
-- ✓ running, ✗ not running, · not set up.
local M = {}

local MARK = { ok = "✓", off = "✗", absent = "·" }

local function project_root()
  local git_entry = vim.fs.find(".git", { upward = true, path = vim.uv.cwd() })[1]
  return git_entry and vim.fs.dirname(git_entry) or vim.uv.cwd()
end

local function shell(command, options, on_done)
  vim.system(command, vim.tbl_extend("force", { text = true }, options or {}), function(result)
    on_done(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  end)
end

-- Order in the table = order of the lines in the window.
local CHECKS = {
  {
    name = "tgrep · this project",
    run = function(report)
      local root = project_root()
      if vim.uv.fs_stat(root .. "/.tgrep") == nil then
        return report(MARK.absent, "no index — :TgrepIndex")
      end
      shell({ "tgrep", "status" }, { cwd = root }, function(ok, output)
        if not ok then
          return report(MARK.off, "index exists, server is not running")
        end
        report(MARK.ok, ("pid %s · files %s"):format(output:match("PID:%s*(%d+)") or "?", output:match("Files:%s*(%d+)") or "?"))
      end)
    end,
  },
  {
    name = "tgrep · all servers",
    run = function(report)
      shell({ "pgrep", "-x", "tgrep" }, {}, function(_, output)
        local count = select(2, output:gsub("%d+\n", ""))
        report(count > 0 and MARK.ok or MARK.absent, count > 0 and (count .. " running · :TgrepServers") or "none")
      end)
    end,
  },
  {
    name = "nvim · socket for lazygit",
    run = function(report)
      local socket = "/tmp/nvim.sock"
      if vim.uv.fs_stat(socket) == nil then
        return report(MARK.absent, socket .. " not created")
      end
      shell({ "nvim", "--server", socket, "--remote-expr", "1" }, {}, function(ok)
        report(ok and MARK.ok or MARK.off, ok and socket or "socket is dead, delete the file")
      end)
    end,
  },
  {
    name = "lazygit",
    run = function(report)
      shell({ "pgrep", "-x", "lazygit" }, {}, function(ok, output)
        report(ok and MARK.ok or MARK.absent, ok and ("pid " .. (output:match("%d+") or "?")) or "not running")
      end)
    end,
  },
  {
    name = "WireGuard · olehus_wg",
    run = function(report)
      shell({ "netstat", "-rn", "-f", "inet" }, {}, function(_, output)
        local up = output:match("\n10%.8%.") ~= nil
        report(up and MARK.ok or MARK.off, up and "route to 10.8.0.0/24 present" or "tunnel is down")
      end)
    end,
  },
  {
    name = "Netbird",
    run = function(report)
      shell({ "netbird", "status" }, {}, function(_, output)
        local state = output:match("Daemon status:[ \t]*([^\n]*)")
        state = state and vim.trim(state) or "no response"
        report(state == "Connected" and MARK.ok or MARK.off, state)
      end)
    end,
  },
  {
    name = "Docker / OrbStack",
    run = function(report)
      shell({ "docker", "info", "--format", "{{.ServerVersion}}" }, {}, function(ok, output)
        report(ok and MARK.ok or MARK.off, ok and ("version " .. vim.trim(output)) or "daemon is not responding")
      end)
    end,
  },
}

local function render(results)
  local lines = { "  Services", "" }
  local width = 0
  local name_column = 0
  for _, check in ipairs(CHECKS) do
    name_column = math.max(name_column, vim.fn.strdisplaywidth(check.name) + 2)
  end
  for _, check in ipairs(CHECKS) do
    local result = results[check.name] or { mark = MARK.absent, detail = "no data" }
    result.detail = tostring(result.detail):gsub("%s+", " "):gsub("^%s+", "")
    -- %-24s counts bytes, while the names are UTF-8 (the "·"), so pad by display width
    local padding = string.rep(" ", math.max(1, name_column - vim.fn.strdisplaywidth(check.name)))
    local line = ("  %s  %s%s%s"):format(result.mark, check.name, padding, result.detail)
    lines[#lines + 1] = line
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  q close · :Services reopen"

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].bufhidden = "wipe"

  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    width = math.max(width + 4, 46),
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " status ",
    title_pos = "center",
  })
  vim.wo[window].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buffer, nowait = true })
  vim.keymap.set("n", "<esc>", "<cmd>close<cr>", { buffer = buffer, nowait = true })
end

function M.show()
  local results = {}
  local answered = 0
  for _, check in ipairs(CHECKS) do
    check.run(function(mark, detail)
      results[check.name] = { mark = mark, detail = detail }
      answered = answered + 1
      if answered == #CHECKS then
        vim.schedule(function()
          render(results)
        end)
      end
    end)
  end
end

vim.api.nvim_create_user_command("Services", M.show, { desc = "Status of our services" })

return M
