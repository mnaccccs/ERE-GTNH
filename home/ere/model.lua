-- model.lua —— ERE 数据模型：目标槽（来自全部请求器）+ 机器（球仓）+ 状态持久化
-- 目标槽 id 规则："请求器地址前8:槽号"，跨请求器全局唯一。
-- 权重/停用状态持久化到磁盘（ERE_STATE.lua），重启不丢。

local component = require("component")
local serialization = require("serialization")

local model = {}
model.__index = model

function model.new(cfg, log)
  local self = setmetatable({}, model)
  self.cfg = cfg
  self.log = log
  self.slots = {}      -- id -> { id, maintainerAddr, slot, name, damage, label,
                       --        quantity, batch, isFluid, fluid, isEnable, isDone,
                       --        weight=3, disabled=false,              （用户设定）
                       --        cur=0, gapPct=0, supplier=nil, state="..." } （运行时）
  self.machines = {}   -- orbAddr -> { addr, proxy, curcircuit, mode="auto"|"pinned",
                       --                  pin=号|nil, targetSlot=id|nil,
                       --                  since=uptime, lastErr=nil }
  self.statePath = "/home/ere/ERE_STATE.lua"
  return self
end

-- ==================== 请求器读取 ====================

--- 读取一台请求器全部槽。返回 { slotData... }（1 基槽号），离线返回 nil
local function readMaintainer(proxy, maxSlots)
  local out = {}
  for s = 1, (maxSlots or 5) do
    local ok, r = pcall(proxy.getSlot, s)
    if ok and type(r) == "table" then
      out[s] = r
    elseif ok and r == nil then
      out[s] = nil  -- 空槽
    else
      return nil, tostring(r)  -- 整台离线/异常
    end
  end
  return out
end

--- 全量刷新目标槽（每拍调用）。changed 返回是否结构变化（增删槽）
function model:refreshSlots(maxSlots)
  local changed = false
  local seen = {}
  local errs = {}
  local thFound = nil  -- UUM 阈值槽（UU物质液滴）的数量
  local uumFluidName = self.cfg.uum and self.cfg.uum.fluidName

  for _, m in ipairs(self.maintainers or {}) do
    local addr = m.address
    local data, err = readMaintainer(m, maxSlots)
    if data then
      for s = 1, #data do
        local d = data[s]
        -- UUM 阈值槽：数量即停配阈值，不作为生产目标（多槽时取先扫到的）
        if d and d.isFluid and d.fluid and d.fluid.name == uumFluidName and (d.quantity or 0) > 0 then
          if thFound == nil then thFound = d.quantity end
        elseif d and d.name and (d.quantity or 0) > 0 and d.isEnable ~= false then
          -- 简单去重：同请求器同物品只留第一槽（FPB 5aec7b4 教训）
          local id = addr:sub(1, 8) .. ":" .. s
          seen[id] = true
          local slot = self.slots[id]
          if not slot then
            slot = {
              id = id, maintainerAddr = addr, slot = s,
              weight = 3, disabled = false,
            }
            self.slots[id] = slot
            changed = true
          end
          slot.name = d.name
          slot.damage = d.damage or 0
          slot.label = d.label or d.name
          slot.quantity = d.quantity or 0
          slot.batch = d.batch or 0
          slot.isFluid = d.isFluid == true
          slot.fluid = d.fluid
          slot.isEnable = d.isEnable
          slot.isDone = d.isDone
        end
      end
    else
      errs[#errs + 1] = string.format("请求器 %s 读取失败: %s", (addr or "?"):sub(1, 4), err)
    end
  end

  -- 槽消失（请求器重配/拆除）→ 移除
  for id in pairs(self.slots) do
    if not seen[id] then
      self.slots[id] = nil
      changed = true
    end
  end

  self.uumThreshold = thFound
  self.maintainerErrors = errs
  return changed, errs
end

-- ==================== 库存刷新 ====================

--- 刷新每个槽的现量与缺口（compat 提供 itemStock/fluidStock）
function model:refreshStock(compat, me)
  for _, slot in pairs(self.slots) do
    local v, err
    if slot.isFluid then
      v, err = compat.fluidStock(me, slot.fluid and slot.fluid.name or slot.name)
    else
      local filter = { name = slot.name }
      if slot.damage and slot.damage > 0 then filter.damage = slot.damage end
      v, err = compat.itemStock(me, filter)
    end
    if v == nil then
      slot.cur = nil
      slot.stockErr = tostring(err)
    else
      slot.cur = v
      slot.stockErr = nil
    end
  end
end

-- ==================== 机器（球仓）管理 ====================

--- 注入 discovery 扫描结果（维持既有运行时字段）
function model:setMachines(orbProxies)
  local new = {}
  for _, p in ipairs(orbProxies) do
    local old = self.machines[p.address]
    new[p.address] = old or { addr = p.address, proxy = p }
    new[p.address].proxy = p
    if not new[p.address].mode then new[p.address].mode = "auto" end
  end
  self.machines = new
end

function model:machineList()
  local list = {}
  for addr, m in pairs(self.machines) do
    list[#list + 1] = m
  end
  table.sort(list, function(a, b) return a.addr < b.addr end)
  return list
end

--- 槽名缩写（UI 显示用）：label 去命名空间取尾巴
function model.slotShortLabel(slot)
  local l = slot.label or slot.name or "?"
  return l
end

-- ==================== 持久化 ====================

--- 保存用户设定（权重/停用/固定）到磁盘
function model:saveState(path)
  local path = path or self.statePath
  local data = { weights = {}, disabled = {}, pins = {} }
  for id, s in pairs(self.slots) do
    data.weights[id] = s.weight
    data.disabled[id] = s.disabled or false
  end
  for addr, m in pairs(self.machines) do
    if m.mode == "pinned" then
      data.pins[addr] = m.pin
    end
  end
  local f, err = io.open(path, "w")
  if not f then
    self.log:add("[持久化] 写入失败: " .. tostring(err))
    return false
  end
  f:write("return " .. serialization.serialize(data))
  f:close()
  return true
end

--- 载入持久化设定（启动时一次）
function model:loadState(path)
  local path = path or self.statePath
  local f = io.open(path, "r")
  if not f then return false end
  local chunk, err = loadfile(path)
  if not chunk then f:close() return false end
  local ok, data = pcall(chunk)
  f:close()
  if not ok or type(data) ~= "table" then return false end
  self._pendingState = data  -- 槽 id 可能还没建立，refresh 后由 main 应用
  return true
end

--- 应用持久化设定（refreshSlots 之后调用）
function model:applyState()
  local data = self._pendingState
  if not data then return end
  self._pendingState = nil
  for id, w in pairs(data.weights or {}) do
    local s = self.slots[id]
    if s then
      s.weight = math.max(self.cfg.policy.minWeight, math.min(self.cfg.policy.maxWeight, tonumber(w) or 3))
    end
  end
  for id, d in pairs(data.disabled or {}) do
    local s = self.slots[id]
    if s and d then s.disabled = true end
  end
  -- pins 由 main 在 setMachines 后应用
  self._pendingPins = data.pins or {}
end

function model:applyPins()
  local pins = self._pendingPins
  if not pins then return end
  self._pendingPins = nil
  for addr, pin in pairs(pins) do
    local m = self.machines[addr]
    if m then
      m.mode = "pinned"
      m.pin = pin
    end
  end
end

return model
