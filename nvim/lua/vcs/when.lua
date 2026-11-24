-- Dates in the Log, the branch list and the push dialog, in English like the rest of the UI.
local M = {}

local MINUTE, HOUR, DAY = 60, 3600, 86400
-- not os.date("%b"): it follows the locale, and the UI is English
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- "just now", "5 min ago", "3 hours ago", "2 days ago", "4 months ago", "2 years ago".
function M.relative(unix_time)
  local age = os.time() - unix_time
  local function ago(count, unit)
    return ("%d %s%s ago"):format(count, unit, count == 1 and "" or "s")
  end
  if age < MINUTE then
    return "just now"
  end
  if age < HOUR then
    return ("%d min ago"):format(math.floor(age / MINUTE))
  end
  if age < DAY then
    return ago(math.floor(age / HOUR), "hour")
  end
  if age < 30 * DAY then
    return ago(math.floor(age / DAY), "day")
  end
  if age < 365 * DAY then
    return ago(math.floor(age / (30 * DAY)), "month")
  end
  return ago(math.floor(age / (365 * DAY)), "year")
end

--- A narrow column: "14:02" today, "Oct 16" this year, "2025-03-02" before.
function M.short(unix_time)
  local now = os.date("*t")
  local moment = os.date("*t", unix_time)
  if moment.year == now.year and moment.yday == now.yday then
    return os.date("%H:%M", unix_time)
  end
  if moment.year == now.year then
    return ("%s %02d"):format(MONTHS[moment.month], moment.day)
  end
  return os.date("%Y-%m-%d", unix_time)
end

--- "16 Oct 2026 14:02" — the commit details.
function M.full(unix_time)
  local date = os.date("*t", unix_time)
  return ("%d %s %d %02d:%02d"):format(date.day, MONTHS[date.month], date.year, date.hour, date.min)
end

return M
