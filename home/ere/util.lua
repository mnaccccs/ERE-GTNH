-- util.lua —— ERE 通用工具：格式化、中文宽度、日志缓冲、时间
-- 骨架沿用 FPB/SEUI 惯例；所有函数不依赖组件，可独立测试。

local util = {}

-- ==================== 数值格式化 ====================

--- 紧凑数值：4.5P / 1.2T / 50.0M / 3.5K / 512（Lua number double，2^53 内精确）
function util.fmtNum(n)
  if n == nil then return "-" end
  local neg = n < 0 and "-" or ""
  n = math.abs(n)
  local s
  if n >= 1e15 then s = string.format("%.1fP", n / 1e15)
  elseif n >= 1e12 then s = string.format("%.1fT", n / 1e12)
  elseif n >= 1e9 then s = string.format("%.1fG", n / 1e9)
  elseif n >= 1e6 then s = string.format("%.1fM", n / 1e6)
  elseif n >= 1e3 then s = string.format("%.1fK", n / 1e3)
  else s = string.format("%d", math.floor(n + 0.5)) end
  return neg .. s
end

--- 带符号紧凑数值：+118K / -2.1K / +980
function util.fmtDelta(n)
  if n == nil then return "-" end
  return (n >= 0 and "+" or "") .. util.fmtNum(n)
end

--- 速率（每小时）：+8.9K/h；nil 或非有限 → "-"
function util.fmtRate(perHour)
  if perHour == nil or perHour ~= perHour then return "-" end
  return util.fmtDelta(perHour) .. "/h"
end

--- 秒 → 紧凑时长：86400→"24h" 3725→"1h02m" 125→"2m05s" 8.4→"8.4s"
function util.fmtDur(sec)
  if sec == nil then return "-" end
  if sec < 0 then sec = 0 end
  if sec >= 86400 then return string.format("%dd", math.floor(sec / 86400)) end
  if sec >= 3600 then return string.format("%dh%02dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60)) end
  if sec >= 60 then return string.format("%dm%02ds", math.floor(sec / 60), math.floor(sec % 60)) end
  return string.format("%.1fs", sec)
end

--- 缺口百分比：现量相对目标的不足程度（0-100 整数；目标≤0 → 0）
function util.gapPct(cur, target)
  if not target or target <= 0 then return 0 end
  local cur = cur or 0
  local gap = (target - cur) / target * 100
  if gap < 0 then gap = 0 end
  if gap > 100 then gap = 100 end
  return math.floor(gap + 0.5)
end

-- ==================== 中文宽度（沿用 FPB 实现）====================

-- 宽字符码点判定（CJK/全角，终端占 2 格）
local function isWide(cp)
  if cp < 0x1100 then return false end
  return cp <= 0x115F
      or (cp >= 0x2E80 and cp <= 0x9FFF)
      or (cp >= 0xA000 and cp <= 0xA4CF)
      or (cp >= 0xAC00 and cp <= 0xD7A3)
      or (cp >= 0xF900 and cp <= 0xFAFF)
      or (cp >= 0xFE30 and cp <= 0xFE6F)
      or (cp >= 0xFF00 and cp <= 0xFF60)
      or (cp >= 0xFFE0 and cp <= 0xFFE6)
end

--- 显示宽度（中文按 2 格），按 UTF-8 字节流逐字累计
function util.wlen(s)
  s = tostring(s)
  local w = 0
  for c in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
    local cp = string.byte(c)
    if cp < 128 then w = w + 1
    elseif isWide(util.codepoint(c)) then w = w + 2
    else w = w + 1 end
  end
  return w
end

--- UTF-8 首字节序列 → 码点（避免依赖 5.2/5.3 差异的 string.unpack）
function util.codepoint(seq)
  local b = { seq:byte(1, -1) }
  if #b == 1 then return b[1] end
  local cp = b[1] % (2 ^ (8 - #b))
  for i = 2, #b do cp = cp * 64 + (b[i] % 64) end
  return cp
end

--- 右对齐裁剪补空：返回恰好 w 显示宽的字符串（超长截断加…，不足左补 pad）
function util.padLeft(s, w, pad)
  s = tostring(s)
  local pad = pad or " "
  if util.wlen(s) > w then s = util.truncate(s, w - 1) .. "…" end
  local n = w - util.wlen(s)
  if n <= 0 then return s end
  return string.rep(pad, math.ceil(n / util.wlen(pad))) .. s
end

--- 左对齐：超长截断加…，不足右补空
function util.padRight(s, w, pad)
  s = tostring(s)
  local pad = pad or " "
  if util.wlen(s) > w then s = util.truncate(s, w - 1) .. "…" end
  local n = w - util.wlen(s)
  if n <= 0 then return s end
  return s .. string.rep(pad, math.ceil(n / util.wlen(pad)))
end

--- 按显示宽度截断（不切断多字节字符）
function util.truncate(s, w)
  s = tostring(s)
  local acc, cw = 0, 0
  for c in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
    local cwid = (util.codepoint(c) < 128) and 1 or (isWide(util.codepoint(c)) and 2 or 1)
    if acc + cwid > w then break end
    acc = acc + cwid
    cw = cw + #c
  end
  return s:sub(1, cw)
end

-- ==================== 日志缓冲（沿用 FPB）====================

local Log = {}
Log.__index = Log

function util.newLog(cap)
  return setmetatable({ buf = {}, cap = cap or 200, head = 0, count = 0 }, Log)
end

function Log:add(msg)
  self.head = (self.head % self.cap) + 1
  self.buf[self.head] = msg
  if self.count < self.cap then self.count = self.count + 1 end
end

--- 按时间正序返回最近 n 条（默认全部）
function Log:tail(n)
  local n = math.min(n or self.count, self.count)
  local out = {}
  for i = n - 1, 0, -1 do
    local idx = ((self.head - i - 1) % self.cap) + 1
    out[#out + 1] = self.buf[idx]
  end
  return out
end

-- ==================== 时间 ====================

--- 世界时钟字符串 HH:MM:SS（游戏内时间，仅展示用；真实排序一律用 computer.uptime）
function util.gameClock(osTime)
  -- Minecraft 一天 24000 ticks，os.time() 返回 0-23.999…（0=06:00）
  local t = (osTime or 0) % 24
  local h = math.floor(t)
  local m = math.floor((t - h) * 60)
  local s = math.floor((((t - h) * 60) - m) * 60)
  return string.format("%02d:%02d:%02d", h, m, s)
end

return util
