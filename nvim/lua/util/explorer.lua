-- Snacks draws a new explorer one tick of the event loop later, and until then its own toggle
-- can't see it. Space e pressed again before that tick (typed fast, or queued while nvim was
-- busy) opened a second explorer beside the first; two sidebars on the left make snacks split
-- the height between them, which handed half the screen to the hidden command line.
-- Here an explorer that is still opening counts as open, so the repeated press does nothing.
local M = {}

-- an explorer that hasn't appeared by then failed to open: let the next press try again
local STILL_OPENING_MS = 1000

local asked_at = setmetatable({}, { __mode = "k" })

local function still_opening(picker)
  local asked = asked_at[picker]
  return asked ~= nil and not picker.layout:valid() and vim.uv.now() - asked < STILL_OPENING_MS
end

local function explorer_on_this_tab()
  for _, picker in ipairs(Snacks.picker.get({ source = "explorer", tab = false })) do
    if picker:on_current_tab() or still_opening(picker) then
      return picker
    end
  end
end

---@param opts? snacks.picker.explorer.Config
function M.toggle(opts)
  local picker = explorer_on_this_tab()
  if picker == nil then
    local opened = Snacks.explorer(opts)
    if opened then
      asked_at[opened] = vim.uv.now()
    end
    return
  end
  if still_opening(picker) then
    return
  end
  picker:close()
end

return M
