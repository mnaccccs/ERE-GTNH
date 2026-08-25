-- diagnose.lua —— ERE 网络诊断：一次性列出 OC 网络全部组件，定位"发现不到"问题
-- 用法：把本文件放进 /home/ere/ 旁边，运行 /home/ere/diagnose.lua
-- 只读，不改任何方块状态。跑完截图发给小雪。

local component = require("component")

print("===== ERE 网络诊断 =====")

-- 1. 全量组件列表（类型 + 地址前 8 位）
print("-- 1. 网络内全部组件 --")
local count = 0
for addr, ctype in component.list() do
  count = count + 1
  print(string.format("  %-28s %s", ctype, addr:sub(1, 8)))
end
if count == 0 then
  print("  （空！OC 网络没有任何组件——检查线缆/贴附）")
end
print(string.format("  合计 %d 个组件", count))

-- 2. 基准检查：GPU/屏幕（UI 能画的前提）
print("-- 2. 基准组件 --")
local function countType(t)
  local n = 0
  for _ in component.list(t) do n = n + 1 end
  return n
end
for _, t in ipairs({ "gpu", "screen", "keyboard", "redstone" }) do
  local n = countType(t)
  print(string.format("  %-10s %d 个%s", t, n, n > 0 and "" or "  <-- 异常"))
end

-- 3. ERE 目标组件
print("-- 3. ERE 目标组件 --")
local targets = {
  { "level_maintainer", "请求器（AE2FC Level Maintainer）" },
  { "gt_machine", "GT 机器（含数据球仓电路组件）" },
  { "me_controller", "ME 控制器" },
  { "me_interface", "ME 接口（方块或 part）" },
  { "me_dual_interface", "ME 双接口（AE2FC）" },
  { "fluid_interface", "流体接口（AE2FC）" },
}
for _, t in ipairs(targets) do
  local addrs = {}
  for addr, _ in component.list(t[1]) do addrs[#addrs + 1] = addr end
  print(string.format("  %-18s %d 个", t[1], #addrs))
  for _, a in ipairs(addrs) do
    print("    " .. a:sub(1, 8))
  end
  if #addrs == 0 then
    print("    （无——若应存在，检查适配器是否贴对方块/是否接入网络）")
  end
end

-- 4. gt_machine 方法明细（区分球仓电路组件与普通机器）
print("-- 4. gt_machine 组件方法（找只有 2 个方法的 = 数据球仓）--")
for addr, _ in component.list("gt_machine") do
  local ok, p = pcall(component.proxy, addr)
  if ok and p then
    local methods = {}
    local okm, m = pcall(component.methods, addr)
    if okm and type(m) == "table" then
      for name, _ in pairs(m) do methods[#methods + 1] = name end
      table.sort(methods)
    end
    -- OC 1.8+ 代理方法是可调用表（元表带 __call），旧版是 function，两种都认
    local function isCallable(f)
      local t = type(f)
      if t == "function" then return true end
      if t == "table" then
        local mt = getmetatable(f)
        return mt ~= nil and mt.__call ~= nil
      end
      return false
    end
    local hasCircuit = isCallable(p.getCircuitConfiguration)
    print(string.format("  %s: %d 方法%s | 电路对=%s",
      addr:sub(1, 8), #methods,
      #methods <= 2 and " ★疑似数据球仓" or "",
      hasCircuit and "有" or "无"))
    if #methods > 0 then
      print("    [" .. table.concat(methods, ", ") .. "]")
    end
  else
    print(string.format("  %s: proxy 失败 %s", addr:sub(1, 8), tostring(p)))
  end
end

-- 5. 网络拓扑提示
print("-- 5. 连接方式检查 --")
print("  适配器组件数: " .. countType("adapter"))
local nCable = countType("oc:cable")
print("  线缆存在: " .. (nCable > 0 and "是" or "无法判断（线缆不注册组件）"))
print()
print("判读速查：")
print("  ① 第 1 节空 → 电脑没入网（检查机箱供电/线缆）")
print("  ② adapter=0 但目标组件存在 → 组件由机箱直贴或无线暴露")
print("  ③ 目标组件 0 但 adapter>0 → 适配器贴错方块/方向")
print("  ④ 全部都在但 ERE 仍报错 → 把本截图发给小雪")
