-- uum.lua —— ERE UUM 储量监控：环形缓冲采样 + 三窗口增量 + sparkline
-- 设计：每 sampleSec 秒采一点（默认 10 分钟），环形缓冲 144 点 = 24h。
--   Δ24h = 当前 - 最老有效点；Δ1h/Δ10m 按窗口长度取点。
--   采样不依赖真实墙钟——用 computer.uptime 单调时钟，断电重启缓冲清零
--   （OpenComputers 电脑断电内存不保，磁盘持久化不值得为此写文件）。
--   sparkline：把缓冲按时间均匀聚合为 24 格，用阶梯块字符表达相对高度。

local computer = require("computer")

local uum = {}
uum.__index = uum

function uum.new(cfg)
  local self = setmetatable({}, uum)
  self.cfg = cfg
  self.n = cfg.uum.sampleCount or 144
  self.buf = {}          -- { t = uptime, v = mB }，按时间正序逻辑环形
  self.head = 0
  self.count = 0
  self.lastV = nil       -- 上一拍现值（非采样拍用于即时 Δ10m 参考锚）
  self.lastT = nil
  return self
end

--- 采样（主循环每拍调用；内部按 sampleSec 间隔落点）
function uum:sample(nowUptime, valueMB)
  if valueMB == nil then return end
  self.lastV = valueMB
  self.lastT = nowUptime
  local interval = self.cfg.uum.sampleSec or 600
  local lastIdx = ((self.head - 1) % self.n) + 1
  local last = self.buf[lastIdx]
  if not last or (nowUptime - last.t) >= interval then
    self.head = (self.head % self.n) + 1
    self.buf[self.head] = { t = nowUptime, v = valueMB }
    if self.count < self.n then self.count = self.count + 1 end
  end
end

--- 取最老点（窗口 ≥ winSec 内的最老采样）
local function oldestIn(self, winSec, nowUptime)
  local best = nil
  for i = 0, self.count - 1 do
    local idx = ((self.head - i - 1) % self.n) + 1
    local p = self.buf[idx]
    if (nowUptime - p.t) <= winSec then
      best = p  -- 继续找更老的
    else
      break
    end
  end
  return best
end

--- 三窗口统计。返回 { now, d24h, d1h, d10m, ratePerHour, trend }
---   ratePerHour：由最老可用点（≤24h）到当前估算；无两点 → nil
---   trend："up"|"down"|"flat"|nil（按 Δ1h 符号，|Δ1h|<1% 现 → flat）
function uum:stats(nowUptime)
  local nowV = self.lastV
  if nowV == nil then return nil end

  local function delta(winSec)
    local p = oldestIn(self, winSec, nowUptime)
    if not p or p.t >= nowUptime then return nil end
    return nowV - p.v, nowUptime - p.t
  end

  local d24h = delta(24 * 3600)
  local d1h = delta(3600)
  local d10m = delta(600)

  -- 净速率：优先 1h 窗口（粒度合适），不足用 10m，再不足用 24h
  local rate = nil
  if d1h then
    rate = d1h / math.max(60, nowUptime - oldestIn(self, 3600, nowUptime).t) * 3600
  elseif d10m then
    rate = d10m / math.max(60, nowUptime - oldestIn(self, 600, nowUptime).t) * 3600
  elseif d24h then
    rate = d24h / math.max(60, nowUptime - oldestIn(self, 86400, nowUptime).t) * 3600
  end

  local trend = nil
  if d1h then
    if d1h > nowV * 0.01 then trend = "up"
    elseif d1h < -nowV * 0.01 then trend = "down"
    else trend = "flat" end
  end

  return {
    now = nowV,
    d24h = d24h, d1h = d1h, d10m = d10m,
    ratePerHour = rate,
    trend = trend,
    warn = nowV < (self.threshold or self.cfg.uum.warnThreshold or 0),  -- threshold 由 main 每拍注入（请求器 UU 物质槽数量优先）
  }
end

--- 24 格 sparkline：按时间窗聚合（每格≈1h），返回 { v=...,  } 数组的格子值与 min/max
--- 没有数据的格子为 nil；调用方（ui）自行画占位符
function uum:sparkline(bins)
  local bins = bins or self.cfg.uum.sparkBins or 24
  local span = (self.cfg.uum.sampleSec or 600) * self.n  -- 缓冲覆盖时长
  local newest = self.buf[self.head]
  if not newest then return {}, nil, nil end
  local tEnd = newest.t
  local tStart = math.max(tEnd - span, 0)
  -- 尚无 24h 数据时按已有长度缩放
  local oldestPt = nil
  for i = self.count, 1, -1 do
    local idx = ((self.head - i) % self.n) + 1
    oldestPt = self.buf[idx]
    if oldestPt then break end
  end
  if oldestPt and oldestPt.t > tStart then tStart = oldestPt.t end
  if tEnd <= tStart then return {}, nil, nil end

  local out = {}
  local vmin, vmax = nil, nil
  for i = 0, self.count - 1 do
    local idx = ((self.head - i - 1) % self.n) + 1
    local p = self.buf[idx]
    if p.t >= tStart then
      local frac = (p.t - tStart) / (tEnd - tStart)
      local b = math.floor(frac * bins) + 1
      if b > bins then b = bins end
      -- 同格多次采样取最新（后写覆盖）
      out[b] = p.v
      if vmin == nil or p.v < vmin then vmin = p.v end
      if vmax == nil or p.v > vmax then vmax = p.v end
    end
  end
  return out, vmin, vmax
end

return uum
