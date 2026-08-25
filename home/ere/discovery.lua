-- discovery.lua —— ERE 组件发现：请求器 × N、数据球仓 × N、ME 通道
-- 机制（源码级审计结论）：
--   数据球仓（MTEHatchElementalDataOrbHolder）实现 IConfigurationCircuitSupport，
--   Computronics 电路驱动为它注册 gt_machine 组件（get/setCircuitConfiguration）。
--   复制机控制器本体不注册可写电路组件，适配器必须贴在数据球仓上。
--
-- 球仓识别（双版本兼容，关键！）：
--   OC 的 Registry.driverFor 返回 CompoundBlockDriver——同一方块上所有 worksWith
--   命中的驱动合并成一个环境（Registry.scala:117-121），并非只取 priority 最高者。
--   → 290b1：球仓环境 ≈ 电路驱动单独（2 方法）
--   → daily690：球仓环境 = GT5U 能量驱动（26 方法）+ 电路驱动（2）= 28 方法合并
--   因此不能用「方法数 ≤ 2」判球仓（daily 上会把球仓漏掉）。正确判据：
--     必要条件：hasCircuitPair（get+setCircuitConfiguration）
--     首选：getName() 含 "orb"（球仓 metaName = hatch.input_bus.elementalorbholder）
--     退回：无 getName 时按方法数 ≤ 2（290b1 独立电路环境）
--   每轮重发现沿用 FPB 975ff69 教训：区块卸载/组件离线不崩溃，跳过并告警。

local component = require("component")

local discovery = {}

-- ==================== 工具 ====================

--- 组件方法存在性判定：OC 1.8+（daily690）把代理方法暴露为「可调用表」
--- （type=="table" 且元表带 __call），旧版为 function，两种都认
local function isCallable(f)
  local t = type(f)
  if t == "function" then return true end
  if t == "table" then
    local mt = getmetatable(f)
    return mt ~= nil and mt.__call ~= nil
  end
  return false
end

local function methods(p)
  if not p then return nil end
  local ok, m = pcall(component.methods, p.address)
  if ok and type(m) == "table" then return m end
  return nil
end

--- 方法计数（退回判据用：290b1 独立电路环境恰好 2 方法）
local function methodCount(p)
  if type(p.address) ~= "string" then return -1 end
  local m = methods(p)
  if not m then return -1 end
  local n = 0
  for _ in pairs(m) do n = n + 1 end
  return n
end

local function hasCircuitPair(p)
  return isCallable(p.getCircuitConfiguration)
     and isCallable(p.setCircuitConfiguration)
end

--- 判定某 gt_machine 是否为数据球仓
--- @return boolean
local function isOrbHolder(p)
  if not hasCircuitPair(p) then return false end
  -- 首选：getName() 含 "orb"（球仓 metaName = hatch.input_bus.elementalorbholder）
  local okn, metaName = pcall(function() return p.getName() end)
  if okn and type(metaName) == "string" then
    return metaName:lower():find("orb") ~= nil
  end
  -- 退回：无 getName（290b1 独立电路环境仅 2 方法）
  local mc = methodCount(p)
  return mc >= 0 and mc <= 2
end

-- ==================== 发现入口 ====================

--- 扫描全部组件。返回 { maintainers={proxy,...}, orbs={proxy,...}, errors={...} }
--- addrFilter 可选：{ maintainer="前缀", orb="前缀" } 人工消歧
function discovery.scan(addrFilter)
  local out = { maintainers = {}, orbs = {}, errors = {} }
  addrFilter = addrFilter or {}

  -- 请求器：level_maintainer（AE2FC 驱动，getSlot 为特征方法）
  for addr, _ in component.list("level_maintainer", true) do
    local ok, p = pcall(component.proxy, addr)
    if ok and p and isCallable(p.getSlot) then
      if not addrFilter.maintainer or addr:sub(1, #addrFilter.maintainer) == addrFilter.maintainer then
        out.maintainers[#out.maintainers + 1] = p
      end
    end
  end

  -- 数据球仓：gt_machine 中含电路对，再用 getName("orb")/方法数判定
  for addr, _ in component.list("gt_machine", true) do
    local ok, p = pcall(component.proxy, addr)
    if ok and p and isOrbHolder(p) then
      if not addrFilter.orb or addr:sub(1, #addrFilter.orb) == addrFilter.orb then
        out.orbs[#out.orbs + 1] = p
      end
    end
  end

  -- 同一物理球仓被多个适配器重复暴露（直连 + MFU 并存）→ 按坐标去重
  local coordSeen = {}
  local dedup = {}
  for _, p in ipairs(out.orbs) do
    local key = p.address
    local okc, x, y, z = pcall(p.getCoordinates)
    if okc and x then key = table.concat({ x, y, z }, ",") end
    if not coordSeen[key] then
      coordSeen[key] = true
      dedup[#dedup + 1] = p
    end
  end
  out.orbs = dedup

  table.sort(out.maintainers, function(a, b) return a.address < b.address end)
  table.sort(out.orbs, function(a, b) return a.address < b.address end)
  return out
end

--- 探测球仓当前电路（含离线容错）
--- @return number or nil, err
function discovery.readCircuit(orb)
  if not orb then return nil, "球仓未连接" end
  local ok, v = pcall(orb.getCircuitConfiguration)
  if not ok then return nil, tostring(v) end
  if v == nil then return nil, "返回 nil（机器不支持）" end
  return tonumber(v)
end

--- 写球仓电路。circuit = 1..16 写入；-1 拔除；其余报错
--- @return true or nil, err
function discovery.writeCircuit(orb, circuit)
  if not orb then return nil, "球仓未连接" end
  local ok, r = pcall(orb.setCircuitConfiguration, circuit)
  if not ok then return nil, tostring(r) end
  if r == true then return true end
  return nil, "写入被拒绝"
end

-- ==================== 球仓内容扫描（inventory_controller）====================

--- 发现全部 inventory_controller 及其读到的 GT 机器库存面
--- 返回 { { addr, proxy, side, size }... }（每台 invc 取第一个 size>1 的库存面）
function discovery.scanInvControllers()
  local out = {}
  for addr, _ in component.list("inventory_controller") do
    local ok, p = pcall(component.proxy, addr)
    if ok and p then
      for side = 0, 5 do
        local oks, sz = pcall(p.getInventorySize, side)
        if oks and type(sz) == "number" and sz > 1 then
          out[#out + 1] = { addr = addr, proxy = p, side = side, size = sz }
          break
        end
      end
    end
  end
  return out
end

--- 读一个库存面的数据球布局。
--- 返回 orbs（{[槽位]=元素符号}）、circuitDmg（编程电路号，无电路=nil）
--- @param inv table  scanInvControllers 的条目
--- @param nbt table  nbt 模块（解析球 NBT 取 mDataName）
--- @param maxSlot number  球槽扫描上限（电路槽在其后）
function discovery.readOrbLayout(inv, nbt, maxSlot)
  local orbs = {}
  local circuitDmg = nil
  for slot = 1, inv.size do
    local ok, it = pcall(inv.proxy.getStackInSlot, inv.side, slot)
    if ok and it then
      if it.name == "gregtech:gt.metaitem.01" and it.damage == 32707 and it.hasTag and it.tag then
        -- 数据球：NBT 的 mDataName = 元素符号
        if slot <= (maxSlot or 16) then
          local okn, data = pcall(nbt.fromGzip, it.tag)
          if okn and type(data) == "table" and type(data.mDataName) == "string" then
            orbs[slot] = data.mDataName
          end
        end
      elseif it.name == "gregtech:gt.integrated_circuit" then
        circuitDmg = it.damage
      end
    end
  end
  return orbs, circuitDmg
end

--- 主动配对：给空闲球仓写一次探测电路，看哪个库存的电路槽跟着变，随后还原。
--- invc 与球仓 gt_machine 没有直接关联 API，这是最可靠的配对手段。
--- @param orb proxy  球仓 gt_machine 代理
--- @param invs table  scanInvControllers 结果
--- @param probeCircuit number  探测电路号（应与众机当前值不同，如 16）
--- @return string|nil invAddr, string|nil err
function discovery.pairByProbe(orb, invs, probeCircuit)
  local cur = discovery.readCircuit(orb)
  if cur == nil then return nil, "球仓离线" end
  -- 写入探测值
  local ok, werr = discovery.writeCircuit(orb, probeCircuit)
  if not ok then return nil, "探测电路写入失败: " .. tostring(werr) end
  local found, foundN = nil, 0
  for _, inv in ipairs(invs) do
    local _, dmg = discovery.readOrbLayout(inv, nil, 0)  -- nbt=nil 不解析球，只看电路槽
    if dmg == probeCircuit then
      found, foundN = inv.addr, foundN + 1
    end
  end
  -- 还原
  discovery.writeCircuit(orb, cur)
  if foundN == 1 then return found end
  if foundN == 0 then return nil, "无库存同步（该球仓无 invc 贴着）" end
  return nil, "多个库存同步（探测值撞车）"
end

--- 被动配对：比较球仓当前电路与各库存电路槽，唯一匹配即配对（不打扰生产）
--- @return string|nil invAddr
function discovery.pairPassive(orb, invs)
  local cur = discovery.readCircuit(orb)
  if cur == nil or cur < 0 then return nil end  -- 无电路时电路槽为空，无法比对
  local found, foundN = nil, 0
  for _, inv in ipairs(invs) do
    local _, dmg = discovery.readOrbLayout(inv, nil, 0)
    if dmg == cur then
      found, foundN = inv.addr, foundN + 1
    end
  end
  if foundN == 1 then return found end
  return nil
end

return discovery
