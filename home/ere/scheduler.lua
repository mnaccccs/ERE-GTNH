-- scheduler.lua —— ERE 智能分配器
-- 核心：score = weight × 缺口%（linear）或 weight × 缺口%（quad 时缺口取平方/100）
-- 多机分配：按 score 降序依次认领；单元素独占保护（soloGuard）——同一元素最多
--   ceil(机器数×配置上限) 台在产；默认除非只剩一个可产目标，禁止全部机器同产一元素。
-- UUM 保口粮：stats.warn 时不再发起新分配，在产任务自然收尾；恢复后自动重启。
-- 时间片：timeSlice 到期强制重新评估（防长任务霸占）。
-- 固定模式：机器.pin 锁电路，自动调度对该机让位（不写电路）。
-- 切槽写电路前先读后写（驱动 setInventorySlotContents 直接写槽，同值重写浪费同步）。

local util = require("util")

local scheduler = {}
scheduler.__index = scheduler

function scheduler.new(cfg, mdl, log)
  local self = setmetatable({}, scheduler)
  self.cfg = cfg
  self.model = mdl
  self.log = log
  self.discovery = nil   -- main 注入
  self.compat = nil
  self.allocatorRuns = 0
  return self
end

-- ==================== 评分 ====================

--- 元素唯一键：GT 粉类全是 gregtech:gt.metaitem.01（仅 damage 不同）、
--- 液滴全是 ae2fc:fluid_drop（仅 fluid.name 不同），独占保护计数必须按
--- 元素区分，不能按注册名——否则一台机上粉后所有粉都被误判"满员"
local function elemKey(s)
  if s.isFluid and s.fluid and s.fluid.name then return "F:" .. s.fluid.name end
  return "I:" .. tostring(s.name) .. ":" .. tostring(s.damage or 0)
end

--- 单槽得分。达标（含磁滞）返回 0
function scheduler:score(slot)
  local hyst = self.cfg.switchHysteresis or 0.90
  if slot.disabled then return 0 end
  if slot.cur == nil then return 0 end   -- 查询失败不参与分配
  if slot.quantity <= 0 then return 0 end
  -- 磁滞达标：现量 ≥ 目标×hyst 视为达标（比目标略低就停，防抖动）
  if slot.cur >= slot.quantity * hyst then return 0 end
  local gap = util.gapPct(slot.cur, slot.quantity)
  if gap <= 0 then return 0 end
  local g
  if self.cfg.policy.weighting == "quad" then
    g = (gap * gap) / 100
  else
    g = gap
  end
  return (slot.weight or 3) * g
end

-- ==================== 分配主循环 ====================

--- 每拍调用：评估 + 下发电路。nowUptime = computer.uptime()
--- 返回事件列表（供日志）
function scheduler:tick(nowUptime, uumStats, me)
  local events = {}
  local machines = self.model:machineList()
  if #machines == 0 then return events end

  -- 1. 收集可分配槽：score>0 且非停用
  local cands = {}
  for _, slot in pairs(self.model.slots) do
    local sc = self:score(slot)
    if sc > 0 then
      cands[#cands + 1] = { slot = slot, score = sc }
    end
  end
  table.sort(cands, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.slot.id < b.slot.id
  end)

  -- 2. UUM 保口粮判定
  local uumHold = false
  if self.cfg.policy.uumRation and uumStats and uumStats.warn then
    uumHold = true
  end

  -- 3. 逐台机器决策
  local assigned = {}   -- elemKey -> count（独占保护计数，按元素不按注册名）
  -- 先统计既有在产（固定模式不算）
  for _, m in ipairs(machines) do
    if m.mode ~= "pinned" and m.targetSlot then
      local s = self.model.slots[m.targetSlot]
      if s then assigned[elemKey(s)] = (assigned[elemKey(s)] or 0) + 1 end
    end
  end

  for i, m in ipairs(machines) do
    -- 固定模式：不参与自动调度，只确保电路=pin 值
    if m.mode == "pinned" then
      local cur = self:_readCircuit(m)
      if cur ~= m.pin then
        local ok, err = self:_writeCircuit(m, m.pin)
        if ok then
          events[#events + 1] = string.format("[固定] %s 电路→%d", m.addr:sub(1, 4), m.pin)
        else
          self:_machErr(m, err)
        end
      end
      goto continue
    end

    -- 当前任务仍有效？
    local keep = false
    if m.targetSlot then
      local s = self.model.slots[m.targetSlot]
      if s then
        local sc = self:score(s)
        local elapsed = nowUptime - (m.since or 0)
        -- 继续条件：仍缺货 且 未到时间片 且 仍是同元素第一优先（或其 score 仍显著）
        if sc > 0 and elapsed < (self.cfg.timeSlice or 300) then
          -- 时间片内允许继续（防饿死由时间片兜底）
          keep = true
          s.supplier = m.addr
        elseif sc <= 0 then
          events[#events + 1] = string.format("[分配] %s 完成 %s 收尾", m.addr:sub(1, 4), util.truncate(s.label or s.name, 12))
        else
          events[#events + 1] = string.format("[分配] %s 时间片到期，重新评估", m.addr:sub(1, 4))
        end
      end
    end

    if not keep then
      -- 清旧
      if m.targetSlot then
        local old = self.model.slots[m.targetSlot]
        if old and old.supplier == m.addr then old.supplier = nil end
        m.targetSlot = nil
      end
      -- UUM 保口粮：不再发起新分配（在产任务已自然收尾清掉）
      if uumHold then
        events[#events + 1] = string.format("[UUM ] %s 暂停新分配（UUM<阈值）", m.addr:sub(1, 4))
        local cur = self:_readCircuit(m)
        if cur ~= self.cfg.idleCircuit and cur ~= nil then
          self:_writeCircuit(m, self.cfg.idleCircuit)
        end
        m.mode = "auto"
        goto continue
      end
      -- 认领新目标
      -- 球仓能力表（有扫描数据时）：只能认领本机可产的元素
      local caps = self.model.caps and self.model.caps[m.addr]
      local capsActive = caps and next(caps) ~= nil
      local picked = nil
      for _, c in ipairs(cands) do
        local s = c.slot
        if not (capsActive and caps[s.id] == nil) then
          local cnt = assigned[elemKey(s)] or 0
          -- 独占保护：可产目标≥2 时，同元素占用机器数不得超过半数（向上取整）
          local limit = self:_soloLimit(#machines, #cands)
          if cnt < limit then
            picked = s
            break
          end
        end
      end
      if picked then
        assigned[elemKey(picked)] = (assigned[elemKey(picked)] or 0) + 1
        m.targetSlot = picked.id
        m.since = nowUptime
        picked.supplier = m.addr
        -- 电路号：优先取该元素在本机球仓的实际槽位（扫描数据）；
        -- 无扫描数据回落约定（请求器槽 N ↔ 电路 N）
        local circuit = (capsActive and caps[picked.id]) or picked.slot
        if circuit >= self.cfg.circuitMin and circuit <= self.cfg.circuitMax then
          local cur = self:_readCircuit(m)
          if cur ~= circuit then
            local ok, err = self:_writeCircuit(m, circuit)
            if ok then
              events[#events + 1] = string.format(
                "[分配] %s → 电路%02d %s (w%d·缺%d%%)",
                m.addr:sub(1, 4), circuit, util.truncate(picked.label or picked.name, 10),
                picked.weight or 3, util.gapPct(picked.cur, picked.quantity))
            else
              self:_machErr(m, err)
            end
          end
        else
          events[#events + 1] = string.format("[分配] %s 槽%d电路号越界(%d-%d)", m.addr:sub(1, 4), picked.slot, self.cfg.circuitMin, self.cfg.circuitMax)
        end
      else
        -- 无可认领：待机
        local cur = self:_readCircuit(m)
        if cur ~= self.cfg.idleCircuit and cur ~= nil then
          self:_writeCircuit(m, self.cfg.idleCircuit)
          events[#events + 1] = string.format("[分配] %s 无可产目标 → 电路-1", m.addr:sub(1, 4))
        end
      end
    end

    ::continue::
  end

  self.allocatorRuns = self.allocatorRuns + 1
  return events
end

--- 独占上限：可产目标只有 1 个 → 全部机器允许（别闲置）；
--- 否则同元素最多 ceil(机器数/2) 台（≥2 机器时禁止全员同产一元素）
function scheduler:_soloLimit(nMach, nCands)
  if not self.cfg.policy.soloGuard then return math.huge end
  if nCands <= 1 then return math.huge end
  if nMach <= 1 then return 1 end
  return math.ceil(nMach / 2)
end

-- ==================== 电路读写（带离线容错）====================

function scheduler:_readCircuit(m)
  if not self.discovery or not m.proxy then return nil end
  local v, err = self.discovery.readCircuit(m.proxy)
  if v == nil then
    self:_machErr(m, err)
    return nil
  end
  m.curcircuit = v
  return v
end

function scheduler:_writeCircuit(m, circuit)
  if not self.discovery or not m.proxy then return nil, "球仓未连接" end
  local ok, err = self.discovery.writeCircuit(m.proxy, circuit)
  if not ok then
    self:_machErr(m, err)
    return nil, err
  end
  m.curcircuit = circuit
  return true
end

function scheduler:_machErr(m, err)
  local msg = string.format("[错误] %s: %s", m.addr:sub(1, 4), tostring(err))
  if m.lastErr ~= msg then
    self.log:add(msg)
    m.lastErr = msg
  end
end

return scheduler
