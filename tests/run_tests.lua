-- tests/run_tests.lua —— ERE 模块冒烟测试（在 mock OC 环境里跑）
-- 宿主：python lupa（Lua 5.5）。加载方式见 run_tests.py。

local mock = require("tests.oc_mock")

-- 注入假环境（模块里 require 的全局）
package.preload["component"] = function() return mock.component end
package.preload["computer"] = function() return mock.computer end
package.preload["event"] = function() return mock.event end
package.preload["serialization"] = function() return mock.serialization end
package.preload["term"] = function() return { clear = function() end } end
package.preload["filesystem"] = function()
  return { path = function(p) return p:match("^(.*)/") or p end }
end
package.preload["shell"] = function() return { execute = function() end } end

-- os.getenv / os.time / os.sleep 覆盖
local real_os_time = os.time
os.getenv = function(k)
  if k == "_" then return nil end
  return nil
end
os.time = function() return 6000 end  -- 游戏内 6:00（os.time 毫秒）

local tests = {}
local failures = 0

local function T(name, fn)
  tests[#tests+1] = { name = name, fn = fn }
end

-- ==================== util ====================

T("util.fmtNum", function()
  local util = require("util")
  assert(util.fmtNum(12400) == "12.4K", "got " .. tostring(util.fmtNum(12400)))
  assert(util.fmtNum(980) == "980", "got " .. tostring(util.fmtNum(980)))
  assert(util.fmtNum(-2100) == "-2.1K")
  assert(util.fmtNum(nil) == "-")
end)

T("util.fmtDelta/fmtRate", function()
  local util = require("util")
  assert(util.fmtDelta(118000) == "+118.0K")
  assert(util.fmtDelta(-2100) == "-2.1K")
  assert(util.fmtRate(8900) == "+8.9K/h")
end)

T("util.fmtDur", function()
  local util = require("util")
  assert(util.fmtDur(8.4) == "8.4s", "got " .. tostring(util.fmtDur(8.4)))
  assert(util.fmtDur(125) == "2m05s", "got " .. tostring(util.fmtDur(125)))
  assert(util.fmtDur(3725) == "1h02m")
end)

T("util.gapPct", function()
  local util = require("util")
  assert(util.gapPct(12400, 16000) == 23)  -- 22.5 → 23
  assert(util.gapPct(40000, 40000) == 0)
  assert(util.gapPct(0, 100) == 100)
  assert(util.gapPct(10, 0) == 0)
end)

T("util.wlen/truncate/pad", function()
  local util = require("util")
  assert(util.wlen("铂锭") == 4)
  assert(util.wlen("Pt") == 2)
  assert(util.wlen("铂Pt") == 4, "铂宽2+P+t=4")
  assert(util.wlen("") == 0)
  assert(util.truncate("铂锭铱粉", 5) == "铂锭")  -- 4+2>5 → 截到 4
  assert(util.padLeft("ab", 4) == "  ab")
  assert(util.padRight("铂", 4) == "铂  ")
  -- padLeft 中文
  assert(util.padLeft("铂锭", 6) == "  铂锭")
end)

T("util.Log", function()
  local util = require("util")
  local lg = util.newLog(3)
  lg:add("a"); lg:add("b"); lg:add("c"); lg:add("d")
  local t = lg:tail(3)
  assert(#t == 3 and t[1] == "b" and t[3] == "d", "got " .. table.concat(t, ","))
end)

-- ==================== uum ====================

T("uum 采样与三窗口", function()
  local config = require("config")
  local uumMod = require("uum")
  local u = uumMod.new(config)
  -- 10 分钟采样间隔（600s），测试加速时钟
  u:sample(0, 900000)
  u:sample(300, 900000)    -- 不落点（<600）
  assert(u.count == 1, "count=" .. u.count)
  u:sample(610, 950000)    -- 落点
  assert(u.count == 2)
  u:sample(1210, 1000000)
  u:sample(1810, 1003000)
  local st = u:stats(1810)
  assert(st ~= nil)
  assert(st.now == 1003000)
  -- Δ10m：1810-1210=600 窗口内最老点=1210
  assert(st.d10m == 1003000 - 1000000, "d10m=" .. tostring(st.d10m))
  -- Δ1h 全窗口
  assert(st.d1h == 1003000 - 900000)
  -- sparkline
  local bins, vmin, vmax = u:sparkline(24)
  assert(vmin == 900000 and vmax == 1003000)
  assert(st.trend == "up", "Δ1h=103000 > 1%×1003000 应为 up")
end)

T("uum 告警阈值", function()
  local config = require("config")
  local uumMod = require("uum")
  local u = uumMod.new(config)
  u:sample(0, 300000)
  local st = u:stats(100)
  assert(st.warn == true, "300K < 400K 应告警")
end)

-- ==================== compat ====================

T("compat.findME + 库存查询", function()
  local compat = require("compat")
  local me, err = compat.findME(nil)
  assert(me ~= nil, "ME 未找到: " .. tostring(err))
  local n = compat.itemStock(me, { name = "gregtech:gt_dust_platinum" })
  assert(n == 12400, "platinum stock=" .. tostring(n))
  local u = compat.fluidStock(me, "uu_matter")
  assert(u == 1200000, "uum=" .. tostring(u))
  local n2 = compat.itemStock(me, { name = "gregtech:none" })
  assert(n2 == 0, "不存在的物品应为 0，got " .. tostring(n2))
end)

T("compat.detect 版本标签", function()
  local compat = require("compat")
  local t = compat.detect()
  -- mock 里 fluid_interface 不存在 → 290b1
  assert(t.label == "290b1", "label=" .. t.label)
  assert(t.fluidIfaceHasStock == false)
end)

-- ==================== discovery ====================

T("discovery.scan 球仓/请求器", function()
  local discovery = require("discovery")
  local res = discovery.scan(nil)
  -- 3 台球仓：2 daily 合并环境（getName 含 orb）+ 1 legacy（无 getName 仅 2 方法）
  -- 干扰项组装机（有电路对但 getName 不含 orb）必须被排除
  assert(#res.orbs == 3, "orbs=" .. #res.orbs)
  for _, o in ipairs(res.orbs) do
    assert(o.address:sub(1, 8) ~= "9999aaaa", "组装机不应被识别为球仓")
  end
  assert(#res.maintainers == 1, "maintainers=" .. #res.maintainers)
  -- 读电路
  local c = discovery.readCircuit(res.orbs[1])
  assert(c == -1, "初始电路应为 -1，got " .. tostring(c))
  -- 写电路
  local ok = discovery.writeCircuit(res.orbs[1], 3)
  assert(ok == true)
  c = discovery.readCircuit(res.orbs[1])
  assert(c == 3)
  -- 越界值（驱动拒绝 0 与 25）
  local ok2 = discovery.writeCircuit(res.orbs[1], 0)
  -- mock 不校验，但真实驱动会拒绝；这里只确认调用不崩
  assert(ok2 ~= nil)
end)

-- ==================== model + scheduler ====================

T("model 刷新槽/库存", function()
  local config = require("config")
  local util = require("util")
  local modelM = require("model")
  local compat = require("compat")
  local discovery = require("discovery")

  local log = util.newLog(50)
  local mdl = modelM.new(config, log)
  local res = discovery.scan(nil)
  mdl.maintainers = res.maintainers
  mdl:setMachines(res.orbs)

  local changed = mdl:refreshSlots(5)
  assert(changed == true)
  local n = 0
  for _ in pairs(mdl.slots) do n = n + 1 end
  assert(n == 2, "应有 2 个槽（铂/铱），got " .. n)

  local me, _ = compat.findME(nil)
  mdl:refreshStock(compat, me)
  local pt = nil
  for _, s in pairs(mdl.slots) do
    if s.slot == 1 then pt = s end
  end
  assert(pt ~= nil and pt.cur == 12400, "铂现量=" .. tostring(pt and pt.cur))
  assert(pt.quantity == 16000)
end)

T("scheduler 分配与独占保护", function()
  local config = require("config")
  local util = require("util")
  local modelM = require("model")
  local compat = require("compat")
  local discovery = require("discovery")
  local schedM = require("scheduler")

  local log = util.newLog(50)
  local mdl = modelM.new(config, log)
  local sched = schedM.new(config, mdl, log)
  sched.discovery = discovery

  local res = discovery.scan(nil)
  mdl.maintainers = res.maintainers
  mdl:setMachines(res.orbs)
  mdl:refreshSlots(5)
  local me, _ = compat.findME(nil)
  mdl:refreshStock(compat, me)

  -- 铱现量压到磁滞线下：mock 库存 8900 → 4500（缺口 50%，score=3*50=150）
  mock.state.items["gregtech:gt_dust_iridium"] = 4500
  mdl:refreshStock(compat, me)
  -- 3 台机器、2 个缺货槽（铱 150 > 铂 69），权重默认 3
  -- 独占保护 limit=ceil(3/2)=2：铱认领 2 台、铂 1 台（高缺口多机、不全扎堆）
  local evs = sched:tick(2000, nil, me)
  assert(#mdl:machineList() == 3)
  local machs = mdl:machineList()
  local count = {}
  for _, m in ipairs(machs) do
    assert(m.targetSlot ~= nil, "所有机器都应认领任务（2 候选 ≤ 3 机）")
    local s = mdl.slots[m.targetSlot]
    count[s.name] = (count[s.name] or 0) + 1
  end
  assert(count["gregtech:gt_dust_iridium"] == 2, "高缺口铱应占 2 台，got " .. tostring(count["gregtech:gt_dust_iridium"]))
  assert(count["gregtech:gt_dust_platinum"] == 1, "低缺口铂应占 1 台")
  assert(count["gregtech:gt_dust_iridium"] < #machs, "不允许全部机器同产一元素")
  -- 电路已写入（槽号）
  for _, m in ipairs(machs) do
    local s = mdl.slots[m.targetSlot]
    assert(mock.state.circuits[m.addr] == s.slot, "circuit=" .. tostring(mock.state.circuits[m.addr]))
  end

  -- 时间片内第二拍：不切换（keep 分支）
  local evs2 = sched:tick(2002, nil, me)
  local m1b = mdl:machineList()[1]
  assert(m1b.targetSlot == machs[1].targetSlot, "时间片内不应换槽")

  -- 时间片到期：重新评估（仍是最高分 → 同槽，但流程走通）
  local evs3 = sched:tick(2500, nil, me)
  assert(type(evs3) == "table")
end)

T("scheduler UUM 保口粮", function()
  local config = require("config")
  local util = require("util")
  local modelM = require("model")
  local compat = require("compat")
  local discovery = require("discovery")
  local schedM = require("scheduler")

  local log = util.newLog(50)
  local mdl = modelM.new(config, log)
  local sched = schedM.new(config, mdl, log)
  sched.discovery = discovery

  local res = discovery.scan(nil)
  mdl.maintainers = res.maintainers
  mdl:setMachines(res.orbs)
  mdl:refreshSlots(5)
  local me, _ = compat.findME(nil)
  mdl:refreshStock(compat, me)

  -- UUM 低于阈值（400K）：mock 里 1.2M → 改低
  mock.state.uum = 300000
  local uumStats = { now = 300000, warn = true }
  sched:tick(3000, uumStats, me)
  for _, m in ipairs(mdl:machineList()) do
    assert(m.targetSlot == nil, "UUM 保口粮下不应分配任务")
    assert(mock.state.circuits[m.addr] == -1 or mock.state.circuits[m.addr] == nil,
      "电路应为 -1，got " .. tostring(mock.state.circuits[m.addr]))
  end
  mock.state.uum = 1200000
end)

T("scheduler 固定模式", function()
  local config = require("config")
  local util = require("util")
  local modelM = require("model")
  local compat = require("compat")
  local discovery = require("discovery")
  local schedM = require("scheduler")

  local log = util.newLog(50)
  local mdl = modelM.new(config, log)
  local sched = schedM.new(config, mdl, log)
  sched.discovery = discovery

  local res = discovery.scan(nil)
  mdl.maintainers = res.maintainers
  mdl:setMachines(res.orbs)
  mdl:refreshSlots(5)
  local me, _ = compat.findME(nil)
  mdl:refreshStock(compat, me)

  -- 固定 #2 电路 11
  local m2 = mdl:machineList()[2]
  m2.mode = "pinned"
  m2.pin = 11
  sched:tick(4000, nil, me)
  assert(mock.state.circuits[m2.addr] == 11, "固定电路未生效: " .. tostring(mock.state.circuits[m2.addr]))
  assert(m2.targetSlot == nil, "固定模式不应认领自动任务")
  -- #1 仍自动
  local m1 = mdl:machineList()[1]
  assert(m1.targetSlot ~= nil, "#1 应正常自动分配")
end)

T("model 持久化", function()
  local config = require("config")
  local util = require("util")
  local modelM = require("model")

  local log = util.newLog(50)
  local mdl = modelM.new(config, log)
  mdl.statePath = "/tmp/ere_test_state.lua"

  mdl.slots = {
    a = { id = "a", weight = 5, disabled = false, label = "铂" },
    b = { id = "b", weight = 2, disabled = true, label = "铱" },
  }
  mdl.machines = { ["x1"] = { addr = "x1", mode = "pinned", pin = 7 } }
  assert(mdl:saveState() == true)

  -- 新实例载入
  local mdl2 = modelM.new(config, log)
  mdl2.statePath = "/tmp/ere_test_state.lua"
  assert(mdl2:loadState() == true)
  mdl2.slots = {
    a = { id = "a", weight = 3, label = "铂" },
    b = { id = "b", weight = 3, label = "铱" },
  }
  mdl2:applyState()
  assert(mdl2.slots.a.weight == 5)
  assert(mdl2.slots.b.disabled == true)
end)

-- ==================== 运行 ====================

local passed, failed = 0, 0
for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then
    passed = passed + 1
    print("PASS  " .. t.name)
  else
    failed = failed + 1
    print("FAIL  " .. t.name .. "  →  " .. tostring(err))
  end
end
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
