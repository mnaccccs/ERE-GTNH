-- compat.lua —— ERE 双版本适配层：GTNH 2.9.0-beta-1 与最新 daily 测试版（690）
--
-- 两版本 OC API 语义差异（源码级审计结论，勿重复研究）：
--
-- ① 渲染（OC 1.12.44 vs 1.12.48+，daily690 为新渲染器）
--    新版：空格不画背景色、全块字符 █ 按前景色着色 → 铺底必须 "█"+前景色=底色
--    旧版：空格正常画背景，█ 写法同样兼容（█ 用前景色着色是两版共同行为）
--    结论：统一走 █ 铺底即可双版本兼容，无需探测分支（FPB 0f6d3a6 实装验证）
--
-- ② AE2FC 版本（1.5.88-gtnh vs daily 更新版）
--    fluid_interface 组件：1.5.88 上只有 get/setFluidInterfaceConfiguration（无库存查询）；
--    新版加入了 getFluidInNetwork/getFluidsInNetwork。
--    fluid 查询策略：优先 me_interface/me_controller（两版都有 NetworkControl 的
--    getFluidInNetwork/getFluidsInNetwork），fluid_interface 仅作补充候选——
--    这样在两个版本上都走同一条稳定路径。
--
-- ③ Computronics 电路驱动（1.9.8-GTNH 起）
--    gt_machine 组件（DriverGregTechCircuitConfigurableMachine）暴露：
--      getCircuitConfiguration():number   当前电路号，无电路返回 -1
--      setCircuitConfiguration(n):boolean n=1..24 写入，-1 拔除电路
--    组件名与老 DriverMachine 同名 "gt_machine"！区分方法：该驱动的环境只有这
--    两个方法（方法数≤2 的 gt_machine = 电路配置驱动 = 数据球仓）。
--    两版本的 Computronics 均含此驱动（PR#30 于 2025-06 合入，早于 2.9.0-beta-1）。
--
-- ④ level_maintainer（AE2FC 两版一致）
--    getSlot(slot):table {name,damage,label,quantity,batch,isFluid,fluid,isEnable,isDone}
--    setSlot(slot, quantity, batch):boolean  三参版只改数量不动槽内物品
--    setEnable(slot, bool):boolean
--    290beta1 的 5 槽（REQ_COUNT=5）；daily 同为 5 槽，防御性兼容 6 槽以上。

local component = require("component")

local compat = {}

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

-- ==================== 版本探测 ====================

--- 探测运行环境版本标签（用于状态栏显示与日志）
--- 判据：OC 互联网卡/系统无直接版本号 API，改用行为探测——
---   新渲染器：gpu.copy 存在且 gpu.getDensity 可调 → 无法可靠区分，
---   故只用 gpu.maxResolution 差异 + 文档字符串不可用。
--- 实际方案：不硬探测渲染器（铺底写法已统一），只探测 AE2FC 能力面：
---   fluid_interface 是否有 getFluidInNetwork（新版 AE2FC 特征）。
--- 返回 table：{ label="290b1"|"daily", fluidIfaceHasStock=bool }
function compat.detect()
  local t = { label = "290b1", fluidIfaceHasStock = false }
  for addr, ctype in component.list("fluid_interface") do
    local ok, p = pcall(component.proxy, addr)
    if ok and p and isCallable(p.getFluidInNetwork) then
      t.fluidIfaceHasStock = true
      t.label = "daily"
      break
    end
  end
  return t
end

-- ==================== ME 查询（物品+流体统一入口）====================

--- 找一个能查物品与流体库存的 ME 组件
--- 优先级：me_controller > me_interface > me_dual_interface > fluid_interface(仅新版)
--- @return proxy or nil, errmsg
function compat.findME(prefPrefix)
  local types = {
    { "me_controller",     "controller" },
    { "me_interface",      "iface" },
    { "me_dual_interface", "dual" },
  }
  local function hasStockMethods(p)
    return isCallable(p.getItemsInNetwork)
       and isCallable(p.getFluidsInNetwork)
  end

  if prefPrefix then
    for _, e in ipairs(types) do
      for addr, _ in component.list(e[1]) do
        if addr:sub(1, #prefPrefix) == prefPrefix then
          local ok, p = pcall(component.proxy, addr)
          if ok and p and hasStockMethods(p) then return p end
        end
      end
    end
    return nil, "地址前缀未匹配到可查询 ME 组件"
  end

  for _, e in ipairs(types) do
    local found = nil
    local n = 0
    for addr, _ in component.list(e[1]) do
      local ok, p = pcall(component.proxy, addr)
      if ok and p and hasStockMethods(p) then
        found = p
        n = n + 1
      end
    end
    if n == 1 then return found end
    if n > 1 then
      return nil, string.format("发现 %d 个 %s，请在 config.addresses.me 填前缀", n, e[1])
    end
  end
  return nil, "未找到支持库存查询的 ME 组件（me_controller/me_interface）"
end

--- 查物品库存数量。filter: {name="gregtech:gt_dust", damage=0}
--- @return number or nil, err
function compat.itemStock(me, filter)
  if not me then return nil, "ME 未连接" end
  local ok, res = pcall(me.getItemsInNetwork, filter)
  if not ok then return nil, tostring(res) end
  -- 返回数组：取第一条 size（精确过滤通常 0 或 1 条）
  if type(res) ~= "table" then return nil, "返回类型异常" end
  for _, it in ipairs(res) do
    if it.size then return it.size end
  end
  return 0
end

--- 查流体库存数量（mB）。name 带不带命名空间均可（内部归一化）
--- @return number or nil, err
function compat.fluidStock(me, name)
  if not me then return nil, "ME 未连接" end
  local filter = { fluid = name } -- AE2 按 fluid 键过滤（NetworkControl 语义）
  local ok, res = pcall(me.getFluidInNetwork, filter)
  if not ok then
    -- 某些版本签名是 getFluidInNetwork(name)；两种都试
    ok, res = pcall(me.getFluidInNetwork, name)
    if not ok then return nil, tostring(res) end
  end
  if type(res) ~= "table" then return nil, "返回类型异常" end
  -- 单条表 {fluid=..., amount/size=...}
  if res.amount or res.size then return res.amount or res.size end
  -- 数组形态（getFluidsInNetwork 风格）
  for _, f in ipairs(res) do
    if f.amount or f.size then return f.amount or f.size end
  end
  return 0
end

return compat
