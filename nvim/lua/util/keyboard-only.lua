-- Keyboard only: clicks, drags and the trackpad or wheel do nothing inside nvim.
-- 'mouse' stays on on purpose: with it off the terminal turns the wheel into arrow keys
-- (alternate scroll mode) and the trackpad would still move the cursor. So nvim keeps the
-- mouse and every mouse key maps to nothing. Space u M brings the mouse back for a while.
local M = {}

local MODES = { "n", "x", "s", "o", "i", "c", "t" }

local function mouse_keys()
  local keys = {}
  for _, modifier in ipairs({ "", "S-", "C-", "M-" }) do
    for _, button in ipairs({ "Left", "Right", "Middle", "X1", "X2" }) do
      for _, event in ipairs({ "Mouse", "Drag", "Release" }) do
        keys[#keys + 1] = ("<%s%s%s>"):format(modifier, button, event)
      end
      for _, clicks in ipairs({ "2-", "3-", "4-" }) do
        keys[#keys + 1] = ("<%s%s%sMouse>"):format(modifier, clicks, button)
      end
    end
    for _, direction in ipairs({ "Up", "Down", "Left", "Right" }) do
      keys[#keys + 1] = ("<%sScrollWheel%s>"):format(modifier, direction)
    end
  end
  return keys
end

function M.enabled()
  return vim.g.keyboard_only == true
end

function M.set(enabled)
  vim.g.keyboard_only = enabled
  for _, key in ipairs(mouse_keys()) do
    for _, mode in ipairs(MODES) do
      if enabled then
        vim.keymap.set(mode, key, "<Nop>", { desc = "Keyboard only" })
      else
        pcall(vim.keymap.del, mode, key)
      end
    end
  end
end

return M
