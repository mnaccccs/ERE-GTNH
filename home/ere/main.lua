-- main.lua —— ERE 元素复制调度台 入口：模块装配、主事件循环、崩溃保护
-- 用法：游戏内运行 /home/ere/main.lua（或配置 rc.d 自启）
-- 骨架沿用 SEUI/FPB：package.path 自定位、时间戳到点执行 + 动态 event.pull、xpcall 保护。

-- 自定位：从任意目录运行都能找到同目录模块
local runningProgram = os.getenv("_")
local baseDir = "/home/ere/"
if runningProgram then
  local p = require("filesystem").path(runningProgram)
  if p and #p > 0 then baseDir = p end
end
if baseDir:sub(-1) ~= "/" then baseDir = baseDir .. "/" end
package.path = baseDir .. "?.lua;" .. package.path

local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")

local config = require("config")
local util = require("util")
local compat = require("compat")
local discovery = require("discovery")
local uumM = require("uum")
local modelM = require("model")
local schedulerM = require("scheduler")
local ui = require("ui")

local log = util.newLog(config.logCap)
local mdl = modelM.new(config, log)
local sched = schedulerM.new(config, mdl, log)
sched.discovery = discovery
sched.compat = compat
local uum = uumM.new(config)

-- ==================== 应用状态 ====================

local app = {
  running = true,
  autoMode = true,
  now = computer.uptime(),
  osTime = 0,
  compatLabel = "?",
  meOk = false,
  me = nil,
  maintainers = {},
  machines = {},          -- addr -> machine（mdl.machines 的引用视图）
  slots = {},             -- id -> slot（mdl.slots 引用视图）
  orderedSlots = {},
  machIndexByAddr = {},
  uumStats = nil,
  sparkBins, sparkVmin, sparkVmax = nil, nil, nil,
  nextTick = 0,
  nextDiscover = 0,
  exitRequested = false,
}

-- ==================== 组件发现 ====================

local function doDiscover()
  local res = discovery.scan(config.addresses)
  local nM = #res.maintainers
  local nO = #res.orbs

  -- ME 通道
  local me, meErr = compat.findME(config.addresses.me)
  app.me = me
  app.meOk = (me ~= nil)
  if not me and meErr then
    log:add("[错误] ME: " .. meErr)
  end

  mdl.maintainers = res.maintainers
  mdl:setMachines(res.orbs)
  mdl:applyPins()
  app.maintainers = res.maintainers
  app.machines = mdl.machines
  app.slots = mdl.slots

  -- 索引：地址 → 序号
  app.machIndexByAddr = {}
  for i, m in ipairs(mdl:machineList()) do
    app.machIndexByAddr[m.addr] = i
  end

  if nM == 0 then log:add("[错误] 未发现请求器（level_maintainer）——检查 AE2FC 与 OC 适配器") end
  if nO == 0 then log:add("[错误] 未发现数据球仓（gt_machine 电路组件）——适配器需贴在球仓上") end
  return nM, nO
end

-- ==================== 每拍逻辑 ====================

local function tick()
  local now = computer.uptime()
  app.now = now
  app.osTime = os.time() / 3600  -- os.time() 毫秒 → 小时（0-24）

  -- 库存刷新（ME 断线时跳过，保留上次值）
  if app.me then
    mdl:refreshSlots(5)
    -- UUM 停配阈值：请求器「UU物质液滴」槽的数量优先，缺省回落配置默认
    local effTh = mdl.uumThreshold or config.uum.warnThreshold
    uum.threshold = effTh
    app.uumThreshold = effTh
    if mdl.uumThreshold and app.lastUumThresholdLog ~= effTh then
      log:add(string.format("[UUM ] 停配阈值 ← 请求器 UU 物质槽：%s mB（改槽内数量即改阈值）", util.fmtNum(effTh)))
      app.lastUumThresholdLog = effTh
    end
    mdl:refreshStock(compat, app.me)
    -- UUM 采样
    local v = compat.fluidStock(app.me, config.uum.fluidName)
    if v ~= nil then
      uum:sample(now, v)
      app.uumStats = uum:stats(now)
      app.sparkBins, app.sparkVmin, app.sparkVmax = uum:sparkline()
      app.meOk = true
    else
      app.meOk = false
    end
  end

  -- 分配（仅自动模式）
  if app.autoMode then
    local evs = sched:tick(now, app.uumStats, app.me)
    for _, e in ipairs(evs) do log:add(e) end
  end

  -- 排序目标槽（页内顺序：请求器地址+槽号）
  local list = {}
  for _, s in pairs(mdl.slots) do list[#list + 1] = s end
  table.sort(list, function(a, b)
    if a.maintainerAddr ~= b.maintainerAddr then return a.maintainerAddr < b.maintainerAddr end
    return a.slot < b.slot
  end)
  app.orderedSlots = list
end

-- ==================== 渲染 ====================

local function render()
  ui.beginFrame()
  ui.drawTitle(app)
  ui.drawUum(app, app.uumStats, app.sparkBins, app.sparkVmin, app.sparkVmax)
  ui.drawMachines(app)
  ui.drawTargets(app)
  ui.drawOps(app)
  ui.drawLog(app, log)
end

-- ==================== 交互处理 ====================

--- 立即重新分配：清空自动机器在产任务与时间片，马上重跑一次调度。
--- 手动模式下也生效（用户显式指令，一次性分配；自动循环仍挂起）。
local function reallocate(reason)
  local cleared = 0
  for _, m in ipairs(mdl:machineList()) do
    if m.mode ~= "pinned" then
      if m.targetSlot then
        local s = mdl.slots[m.targetSlot]
        if s and s.supplier == m.addr then s.supplier = nil end
        m.targetSlot = nil
        cleared = cleared + 1
      end
      m.since = nil  -- 清时间片，保证立即重评
    end
  end
  local evs = sched:tick(computer.uptime(), app.uumStats, app.me)
  for _, e in ipairs(evs) do log:add(e) end
  log:add(string.format("[分配] %s：清 %d 台在产，已立即重新分配", reason, cleared))
end

--- 解除固定后立即参与分配（仅自动模式；手动模式电路保持，不打扰）
local function schedNow()
  if not app.autoMode then return end
  local evs = sched:tick(computer.uptime(), app.uumStats, app.me)
  for _, e in ipairs(evs) do log:add(e) end
end

local function handleAction(action, payload)
  if action == "selectSlot" then
    if app.selectedSlot == payload then
      app.selectedSlot = nil  -- 再点取消
    else
      app.selectedSlot = payload
    end
  elseif action == "selectMach" then
    if app.selectedMach == payload then
      app.selectedMach = nil
    else
      app.selectedMach = payload
    end
  elseif action == "page" then
    local pages = math.max(1, math.ceil(#app.orderedSlots / ui.L.tgtRows))
    ui.page = ((ui.page - 1 + payload) % pages) + 1
  elseif action == "mode" then
    app.autoMode = not app.autoMode
    log:add(app.autoMode and "[模式] 自动调度启用" or "[模式] 手动模式（调度挂起，电路保持）")
  elseif action == "weight" then
    local s = app.selectedSlot and mdl.slots[app.selectedSlot]
    if s then
      local nw = (s.weight or 3) + payload
      nw = math.max(config.policy.minWeight, math.min(config.policy.maxWeight, nw))
      if nw ~= s.weight then
        s.weight = nw
        mdl:saveState()
        log:add(string.format("[权重] %s → %d", util.truncate(s.label or s.name, 10), nw))
      end
    end
  elseif action == "pin" then
    local addr = app.selectedMach
    local m = addr and mdl.machines[addr]
    if m then
      if m.mode == "pinned" then
        m.mode = "auto"
        m.pin = nil
        mdl:saveState()
        log:add(string.format("[固定] #%s 解除，立即参与自动分配", tostring(app.machIndexByAddr[addr])))
        schedNow()
      else
        -- 双选（机器行+元素槽行）→ 固定复制该元素（电路=槽号）；仅选机器 → 固定当前电路
        local s = app.selectedSlot and mdl.slots[app.selectedSlot]
        m.mode = "pinned"
        if s and s.slot >= config.circuitMin and s.slot <= config.circuitMax then
          m.pin = s.slot
          mdl:saveState()
          log:add(string.format("[固定] #%s 固定复制 %s（电路%02d）",
            tostring(app.machIndexByAddr[addr]), util.truncate(s.label or s.name, 10), m.pin))
        else
          m.pin = m.curcircuit or m.targetSlot and mdl.slots[m.targetSlot] and mdl.slots[m.targetSlot].slot or 1
          mdl:saveState()
          log:add(string.format("[固定] #%s 电路→%d", tostring(app.machIndexByAddr[addr]), m.pin))
        end
        -- 立即下发电路：手动模式下调度挂起不等下一拍（自动模式调度器每拍也会兜底）
        local ok, werr = discovery.writeCircuit(m.proxy, m.pin)
        if not ok then log:add("[错误] 固定写入电路失败: " .. tostring(werr)) end
      end
    end
  elseif action == "unpin" then
    local addr = app.selectedMach
    local m = addr and mdl.machines[addr]
    if m and m.mode == "pinned" then
      m.mode = "auto"
      m.pin = nil
      mdl:saveState()
      log:add(string.format("[固定] #%s 解除，立即参与自动分配", tostring(app.machIndexByAddr[addr])))
      schedNow()
    end
  elseif action == "pinCur" then
    local addr = app.selectedMach
    local m = addr and mdl.machines[addr]
    if m and m.mode ~= "pinned" then
      m.mode = "pinned"
      m.pin = m.curcircuit or 1
      mdl:saveState()
      log:add(string.format("[固定] #%s 电路→%d", tostring(app.machIndexByAddr[addr]), m.pin))
    end
  elseif action == "scan" then
    local nM, nO = doDiscover()
    log:add(string.format("[扫描] 请求器%d台 · 球仓%d个 · ME:%s", nM, nO, app.meOk and "正常" or "断开"))
    mdl:applyState()
  elseif action == "edit" then
    local s = app.selectedSlot and mdl.slots[app.selectedSlot]
    if s then
      log:add(string.format("[编辑] %s 当前 quantity=%s batch=%s（GUI 改数走请求器；此处仅提示）",
        util.truncate(s.label or s.name, 10), util.fmtNum(s.quantity), util.fmtNum(s.batch)))
      log:add("[编辑] 数值修改请用请求器 GUI 或 setSlot；ERE v1 权重优先")
    else
      log:add("[编辑] 先选中一个目标槽")
    end
  elseif action == "policy" then
    local p = config.policy
    if p.weighting == "linear" then p.weighting = "quad"
    else p.weighting = "linear" end
    log:add(string.format("[策略] 缺口加权: %s", p.weighting == "quad" and "平方（重伤优先）" or "线性（均衡）"))
    reallocate("策略切换")  -- 策略变了立即重排，不等时间片
  elseif action == "reassign" then
    reallocate("手动重新分配")
  elseif action == "halt" then
    -- 全部机器电路 -1，自动模式挂起（安全停机）
    for _, m in ipairs(mdl:machineList()) do
      if m.proxy then
        local ok = discovery.writeCircuit(m.proxy, config.idleCircuit)
        if ok then m.targetSlot = nil end
      end
    end
    app.autoMode = false
    log:add("[停机] 全部电路→-1，自动调度挂起（点[手动模式]恢复）")
  end
end

-- ==================== 主循环 ====================

local function mainLoop()
  -- GPU/屏幕
  local gpu = component.gpu
  local screen = component.list("screen")()
  if not gpu then
    print("需要 GPU（显卡）")
    return
  end
  ui.init(gpu, screen and component.proxy(screen) or nil, config)

  -- 版本探测 + 启动横幅
  local env = compat.detect()
  app.compatLabel = env.label
  log:add("[启动] " .. config.startupBanner)
  doDiscover()
  mdl:loadState()
  mdl:applyState()
  mdl:applyPins()
  log:add(string.format("[启动] 已发现复制机%d台 · 请求器%d台 · 球仓%d个 · ME通道%s",
    #(mdl:machineList()), #app.maintainers, #(mdl:machineList()), app.meOk and "正常" or "断开"))
  log:add(string.format("[启动] UUM 停配阈值默认 %s mB；在请求器放「UU物质液滴」槽、把数量设为阈值即可更改",
    util.fmtNum(config.uum.warnThreshold)))

  app.nextTick = computer.uptime()
  app.nextDiscover = computer.uptime() + config.discoveryInterval

  while app.running do
    local now = computer.uptime()

    -- 调度拍
    if now >= app.nextTick then
      local ok, err = xpcall(tick, debug.traceback)
      if not ok then
        log:add("[错误] tick: " .. tostring(err))
      end
      app.nextTick = now + config.pollInterval
    end

    -- 周期重发现
    if now >= app.nextDiscover then
      local ok, err = xpcall(doDiscover, debug.traceback)
      if not ok then
        log:add("[错误] 发现: " .. tostring(err))
      end
      app.nextDiscover = now + config.discoveryInterval
    end

    -- 渲染
    local ok, err = xpcall(render, debug.traceback)
    if not ok then
      ui.restore()
      print("[渲染崩溃] " .. tostring(err))
      return
    end

    -- 事件（触摸/按键），动态超时到下一拍
    local timeout = math.max(0.05, math.min(0.25, app.nextTick - computer.uptime()))
    local ev = table.pack(event.pull(timeout))
    if ev.n > 0 then
      local name = ev[1]
      if name == "touch" then
        handleAction(ui.onTouch(ev[3], ev[4]))
      elseif name == "key_down" then
        local ch = ev[3]
        if ch == string.byte("q") or ch == string.byte("Q") then
          app.running = false
        end
      end
    end
  end
end

-- ==================== 退出保护 ====================

local ok, err = xpcall(mainLoop, debug.traceback)
ui.restore()
if not ok then
  print("ERE 崩溃: " .. tostring(err))
  print("按任意键退出（Ctrl+Alt+R 重启电脑）")
  event.pull("key_down")
end
