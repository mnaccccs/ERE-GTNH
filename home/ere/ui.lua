-- ui.lua —— ERE 160×50 触屏 UI（按定稿草图）
-- 渲染兼容：铺底一律 █+前景色=底色（daily690 新渲染器空格不画背景；290b1 同样兼容）
-- 骨架沿用 FPB/SEUI 惯例：脏标记 + hitbox 分组倒序命中 + 退出恢复终端。

local component = require("component")
local util = require("util")

local ui = {}

-- 调色板（SEUI/FPB 风格）
local C = {
  bg = 0x1a1a2e, fg = 0xc0c0c0, header = 0x00bfff,
  ok = 0x00ff00, run = 0xe8dc40, warn = 0xe8dc40, err = 0xff4444, off = 0x556677,
  dim = 0x666688, selected = 0x224466, button = 0x2a2a4a, buttonOn = 0x3a5a8a,
  uum = 0x9b59b6, spark = 0x3498db, barTrack = 0x2e2e40,
}
ui.C = C

function ui.init(gpu, screen, cfg)
  ui.gpu = gpu
  ui.screen = screen
  ui.cfg = cfg
  ui.L = cfg.layout
  -- 保存原始终端状态（退出恢复）
  ui.savedFg = gpu.getForeground()
  ui.savedBg = gpu.getBackground()
  ui.savedRes = { gpu.getResolution() }
  if screen then
    gpu.bind(screen.address or screen)
    pcall(function() screen.setTouchModeInverted(true) end)
    pcall(function() screen.setPrecise(false) end)
  end
  gpu.setResolution(cfg.screen.width, cfg.screen.height)
  pcall(function() gpu.setDepth(8) end)
  gpu.setBackground(C.bg)
  gpu.setForeground(C.fg)
  -- 新版渲染器铺底：█ 按前景色着色（FPB 0f6d3a6）
  gpu.setForeground(C.bg)
  gpu.fill(1, 1, cfg.screen.width, cfg.screen.height, "█")
  ui.hitboxGroups = { uum = {}, machines = {}, rows = {}, actions = {}, nav = {} }
  ui.dirty = { all = true }
  ui.selectedSlot = nil
  ui.selectedMach = nil
  ui.page = 1
  ui.modal = nil    -- { kind="weight"|"pin"|"edit"|"policy", ... }
  return ui
end

function ui.restore()
  if not ui.gpu then return end
  pcall(function()
    if ui.savedRes then ui.gpu.setResolution(ui.savedRes[1], ui.savedRes[2]) end
    ui.gpu.setForeground(ui.savedFg or 0xFFFFFF)
    ui.gpu.setBackground(ui.savedBg or 0x000000)
    require("term").clear()
  end)
end

-- ==================== 绘制原语（渲染器兼容层）====================

local function setColors(fg, bg)
  ui.gpu.setForeground(fg or C.fg)
  ui.gpu.setBackground(bg or C.bg)
end

local function fillBg(x, y, w, h, color)
  ui.gpu.setForeground(color)
  ui.gpu.fill(x, y, w, h, "█")
end

local function drawText(x, y, text, fg, bg)
  fillBg(x, y, util.wlen(text), 1, bg or C.bg)
  setColors(fg, bg)
  ui.gpu.set(x, y, text)
end

local function fillRect(x, y, w, h, char, fg, bg)
  if char == nil or char == " " then
    fillBg(x, y, w, h, bg or C.bg)
    return
  end
  setColors(fg, bg)
  ui.gpu.fill(x, y, w, h, char)
end

local function addHitbox(group, x, y, w, h, action, payload)
  ui.hitboxGroups[group][#ui.hitboxGroups[group] + 1] =
    { x = x, y = y, w = w, h = h, action = action, payload = payload }
end

-- ==================== 各区域绘制 ====================

--- 标题栏
function ui.drawTitle(app)
  local L = ui.L
  local mode = app.autoMode and "自动" or "手动"
  local ver = app.compatLabel or "?"
  local right = util.gameClock(app.osTime) .. " "
  local title = string.format(" ERE 元素复制调度台 · 模式:%s · ver:%s", mode, ver)
  drawText(1, L.rowTitle, util.padRight(title, ui.cfg.screen.width - util.wlen(right)) .. right, C.header, C.bg)
end

--- UUM 面板（行2-4）
function ui.drawUum(app, stats, bins, vmin, vmax)
  local L = ui.L
  if not stats then
    drawText(2, L.rowUum, "UUM 查询失败（ME 未连接或无 UUM）", C.err)
    return
  end
  -- 行2：储量条
  local W = ui.cfg.screen.width
  local barW = 30
  local pct = stats.now and stats.now > 0 and math.min(1.0, stats.now / (stats.now + (vmax and (vmax - stats.now) or stats.now))) or 0
  -- 用有效阈值的 2.5 倍做满刻度参考（有效阈值 = 请求器 UU 物质槽数量，缺省配置默认）
  local effTh = app.uumThreshold or ui.cfg.uum.warnThreshold or 1000000000
  local scaleMax = effTh * 2.5
  local filled = math.floor((stats.now / scaleMax) * barW + 0.5)
  if filled > barW then filled = barW end
  local barStr = string.rep("▓", filled) .. string.rep("░", barW - filled)
  local pctTxt = string.format("%d%%", math.floor(stats.now / scaleMax * 100))
  local status = stats.warn and "低" or "充足"
  local statusColor = stats.warn and C.err or C.ok
  local line = string.format(" UUM %s mB %s %s  阈值:%s  状态:%s",
    util.padLeft(util.fmtNum(stats.now), 7), barStr, util.padLeft(pctTxt, 4),
    util.fmtNum(effTh), status)
  drawText(1, L.rowUum, line, C.uum)
  -- 状态部分重新着色（简化：整行 UUM 色，低时整行告警色）
  if stats.warn then drawText(1, L.rowUum, line, C.err) end

  -- 行3：sparkline
  local sparkChars = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  local s = " 24h "
  for i = 1, (ui.cfg.uum.sparkBins or 24) do
    local v = bins and bins[i]
    if v == nil or vmin == nil or vmax == nil or vmax <= vmin then
      s = s .. "·"
    else
      local idx = math.floor((v - vmin) / (vmax - vmin) * 7 + 0.5) + 1
      if idx < 1 then idx = 1 end
      if idx > 8 then idx = 8 end
      s = s .. sparkChars[idx]
    end
  end
  s = s .. " (24格/每小时)"
  drawText(1, L.rowSpark, s, C.spark)

  -- 行4：三窗 + 速率
  local trendTxt = stats.trend == "up" and "▲上升" or
                   (stats.trend == "down" and "▼下降" or
                   (stats.trend == "flat" and "─平稳" or ""))
  local line4 = string.format(" Δ24h %s │ Δ1h %s │ Δ10m %s │ 净速率 %s %s",
    util.padLeft(util.fmtDelta(stats.d24h), 8),
    util.padLeft(util.fmtDelta(stats.d1h), 7),
    util.padLeft(util.fmtDelta(stats.d10m), 6),
    util.padLeft(util.fmtRate(stats.ratePerHour), 10), trendTxt)
  drawText(1, L.rowRate, line4, stats.warn and C.err or C.fg)
end

--- 复制机区（行5-13，最多 8 台）
function ui.drawMachines(app)
  local L = ui.L
  -- app.machines 是 addr→machine 哈希表（# 与 ipairs 对它无效），
  -- 先转成按地址排序的数组，顺序与 main 的 machIndexByAddr 一致（供给 #N 对得上）
  local machs = {}
  for _, m in pairs(app.machines) do machs[#machs + 1] = m end
  table.sort(machs, function(a, b) return a.addr < b.addr end)
  local head = string.format("─ 复制机 %d/%d ─ 请求器 %d 台 ─ 球仓 %d ─",
    #machs, #machs, #app.maintainers, #machs)
  drawText(1, L.rowMachHead, "├" .. util.padRight(head, ui.cfg.screen.width - 2) .. "┤", C.dim)

  for i, m in ipairs(machs) do
    if i > ui.L.machRows then break end
    local y = L.rowMachFirst + i - 1
    -- 行内容：#1 α·ZPM [生产] 电路03→铂锭 ▓▓▓▓▓░░░ 剩2.1s
    local tag = string.format("#%d %s", i, m.addr:sub(1, 4))
    local stateTxt, stateColor
    if m.mode == "pinned" then
      stateTxt, stateColor = "[固定]", C.warn
    elseif m.targetSlot then
      local s = app.slots[m.targetSlot]
      if s then
        stateTxt, stateColor = "[生产]", C.run
      else
        stateTxt, stateColor = "[空闲]", C.off
      end
    elseif m.paused then
      stateTxt, stateColor = "[暂停]", C.warn
    else
      stateTxt, stateColor = "[空闲]", C.off
    end
    local target = ""
    if m.targetSlot then
      local s = app.slots[m.targetSlot]
      if s then
        target = string.format("电路%02d→%s", m.curcircuit or s.slot, util.truncate(s.label or s.name, 8))
      end
    elseif m.mode == "pinned" then
      target = string.format("电路%02d (手动固定·自动调度让位)", m.pin or -1)
    else
      target = "电路-1"
    end
    local pre = string.format(" %s %s %s", util.padRight(tag, 10), stateTxt, util.padRight(target, 30))
    local line = pre
    local hasBar = app.autoMode and m.targetSlot and m.since
    local barW = 14
    if hasBar then
      local remain = math.max(0, (ui.cfg.timeSlice or 300) - (app.now - m.since))
      line = pre .. string.rep(" ", barW) .. " 剩" .. util.fmtDur(remain)
    elseif m.mode == "pinned" then
      line = pre .. "(手动固定·自动调度让位)"
    elseif m.targetSlot then
      line = pre .. "(手动模式·调度挂起，电路保持)"
    end
    -- 选中高亮
    local bg = (app.selectedMach == m.addr) and C.selected or C.bg
    drawText(1, y, util.padRight(line, ui.cfg.screen.width), stateColor, bg)
    -- 时间片进度条（SEUI 实心色块：轨道 + 填充，无抖动字符）
    if hasBar then
      local frac = math.min(1.0, (app.now - m.since) / (ui.cfg.timeSlice or 300))
      local fl = math.floor(frac * barW + 0.5)
      local bx = util.wlen(pre) + 1
      fillBg(bx, y, barW, 1, C.barTrack)
      if fl > 0 then fillBg(bx, y, fl, 1, C.spark) end
    end
    addHitbox("machines", 1, y, ui.cfg.screen.width, 1, "selectMach", m.addr)
  end
  -- 机器数 < 预留行：留白即可（初始化已铺底）
end

--- 目标槽表（行14-25）
function ui.drawTargets(app)
  local L = ui.L
  local slots = app.orderedSlots
  local total = #slots
  local pages = math.max(1, math.ceil(total / L.tgtRows))
  if ui.page > pages then ui.page = pages end
  local head = string.format("─ 目标槽 %d ─ 第%d/%d页 ", total, ui.page, pages)
  local pad = util.padRight(head, ui.cfg.screen.width - 12)
  drawText(1, L.rowTgtHead, "├" .. pad, C.dim)
  -- 翻页按钮（右侧）
  local btnW = 4
  local xR = ui.cfg.screen.width - 10
  drawText(xR, L.rowTgtHead, "[◀]", C.button)
  addHitbox("nav", xR, L.rowTgtHead, 3, 1, "page", -1)
  drawText(xR + 4, L.rowTgtHead, "[▶]", C.button)
  addHitbox("nav", xR + 4, L.rowTgtHead, 3, 1, "page", 1)
  drawText(xR + 8, L.rowTgtHead, "─┤", C.dim)

  -- 表头
  local hdr = string.format(" %s %s %s %s %s %s %s %s %s",
    util.padRight("槽", 3), util.padRight("权重", 4), util.padLeft("物品", 10),
    util.padLeft("现量/目标", 14), util.padRight("缺口", 6),
    util.padRight("状态", 6), util.padRight("供给", 6),
    util.padRight("开关", 4), "进度")
  drawText(1, L.rowTgtFirst - 1, hdr, C.dim)

  -- 行
  local start = (ui.page - 1) * L.tgtRows + 1
  for r = 0, L.tgtRows - 1 do
    local idx = start + r
    local y = L.rowTgtFirst + r
    local s = slots[idx]
    if not s then
      fillBg(1, y, ui.cfg.screen.width, 1, C.bg)
      goto cont
    end
    local stateTxt, stateColor
    if s.disabled then stateTxt, stateColor = "停用", C.off
    elseif s.stockErr then stateTxt, stateColor = "查询失败", C.err
    elseif s.supplier then stateTxt, stateColor = "生产中", C.run
    elseif (s.cur or 0) >= (s.quantity or 0) * (ui.cfg.switchHysteresis or 0.9) then stateTxt, stateColor = "达标", C.ok
    else stateTxt, stateColor = "排队", C.fg
    end
    local curTgt = string.format("%s/%s", util.fmtNum(s.cur), util.fmtNum(s.quantity))
    local supplier = s.supplier and ("#" .. tostring(app.machIndexByAddr[s.supplier] or "?")) or "—"
    local sw = s.disabled and "[关]" or "[开]"
    local gap = util.gapPct(s.cur, s.quantity)
    -- 进度条（现量/目标）：动态铺满到行尾（6~60 格，随屏宽自适应）
    local prefix = string.format(" %s %s %s %s %s %s %s %s ",
      util.padLeft(string.format("%02d", s.slot), 3),
      util.padLeft(string.format("[%d]", s.weight or 3), 4),
      util.padRight(util.truncate(s.label or s.name, 10), 10),
      util.padLeft(curTgt, 14),
      util.padLeft(string.format("%d%%", gap), 5) .. " ",
      util.padRight(stateTxt, 6),
      util.padLeft(supplier, 4) .. "  ",
      sw)
    local bw = math.max(6, math.min(60, ui.cfg.screen.width - util.wlen(prefix) - 2))
    local frac = (s.quantity and s.quantity > 0) and math.min(1.0, (s.cur or 0) / s.quantity) or 0
    local fl = math.floor(frac * bw + 0.5)
    local line = prefix .. string.rep(" ", bw)
    local bg = (app.selectedSlot == s.id) and C.selected or C.bg
    drawText(1, y, util.padRight(line, ui.cfg.screen.width), stateColor, bg)
    -- 进度条：SEUI 实心色块（轨道 + 按达成度分档的填充）
    local barColor = frac >= 0.9 and C.ok or (frac >= 0.5 and C.run or C.err)
    local bx = util.wlen(prefix) + 1
    fillBg(bx, y, bw, 1, C.barTrack)
    if fl > 0 then fillBg(bx, y, fl, 1, barColor) end
    addHitbox("rows", 1, y, ui.cfg.screen.width, 1, "selectSlot", s.id)
    ::cont::
  end
end

--- 操作区（行26-28）
function ui.drawOps(app)
  local L = ui.L
  drawText(1, L.rowOps, "├─ 操作 " .. string.rep("─", ui.cfg.screen.width - 9) .. "┤", C.dim)
  local btns = {}
  local x = 2
  local function btn(label, action, payload, color)
    btns[#btns + 1] = { x = x, label = label, action = action, payload = payload, color = color }
    x = x + util.wlen(label) + 2
  end
  btn(app.autoMode and "[自动模式]" or "[手动模式]", "mode", nil, app.autoMode and C.buttonOn or C.button)
  btn("[固定电路]", "pin", nil, C.button)
  btn("[扫描]", "scan", nil, C.button)
  btn("[编辑目标]", "edit", nil, C.button)
  btn("[策略]", "policy", nil, C.button)
  btn("[重新分配]", "reassign", nil, C.button)
  btn("[停机-1]", "halt", nil, C.err)

  fillBg(1, L.rowOpsMain, ui.cfg.screen.width, 1, C.bg)
  for _, b in ipairs(btns) do
    drawText(b.x, L.rowOpsMain, b.label, b.color)
    addHitbox("actions", b.x, L.rowOpsMain, util.wlen(b.label), 1, b.action, b.payload)
  end
  -- 右端：选中对象提示（机器与元素可同时选中）
  local selS = app.selectedSlot and app.slots[app.selectedSlot]
  local selM = app.selectedMach and app.machines[app.selectedMach]
  local selTxt = ""
  if selM then selTxt = "#" .. tostring(app.machIndexByAddr[selM.addr] or "?") end
  if selS then
    selTxt = (selTxt ~= "" and (selTxt .. "+") or "")
      .. string.format("%02d", selS.slot) .. util.truncate(selS.label or selS.name, 6)
  end
  if selTxt ~= "" then
    selTxt = "选中:" .. selTxt
    drawText(ui.cfg.screen.width - util.wlen(selTxt) - 1, L.rowOpsMain, selTxt, C.dim)
  end

  -- 上下文行
  fillBg(1, L.rowOpsCtx, ui.cfg.screen.width, 1, C.bg)
  local ctx = ""
  if selM and selS and selM.mode ~= "pinned" then
    -- 双选：固定该机复制选中元素（电路=槽号）
    local lab = "[确认固定]"
    ctx = string.format(" 机器#%s · 固定复制 %s（电路%02d） %s",
      tostring(app.machIndexByAddr[selM.addr]), util.truncate(selS.label or selS.name, 8), selS.slot, lab)
    drawText(2, L.rowOpsCtx, ctx, C.warn)
    local xb = 2 + util.wlen(ctx) - util.wlen(lab)
    addHitbox("actions", xb, L.rowOpsCtx, util.wlen(lab), 1, "pin", nil)
  elseif selS then
    local sup = selS.supplier and ("供给 #" .. tostring(app.machIndexByAddr[selS.supplier] or "?")) or "无供给"
    ctx = string.format(" 权重 [−] %d [+]  ·  %s · %s", selS.weight or 3, util.truncate(selS.label or selS.name, 8), sup)
    drawText(2, L.rowOpsCtx, ctx, C.fg)
    local xw = 4
    drawText(xw + 1, L.rowOpsCtx, "[−]", C.button)
    addHitbox("actions", xw + 1, L.rowOpsCtx, 3, 1, "weight", -1)
    drawText(xw + 9, L.rowOpsCtx, "[+]", C.button)
    addHitbox("actions", xw + 9, L.rowOpsCtx, 3, 1, "weight", 1)
  elseif selM then
    if selM.mode == "pinned" then
      ctx = string.format(" 机器#%s · 固定电路 %d  [解除固定]", tostring(app.machIndexByAddr[selM.addr]), selM.pin or -1)
      drawText(2, L.rowOpsCtx, ctx, C.warn)
      local xb = 2 + util.wlen(ctx) - 8
      addHitbox("actions", xb, L.rowOpsCtx, 8, 1, "unpin", nil)
    else
      ctx = string.format(" 机器#%s · 自动 · [固定当前电路%02d]", tostring(app.machIndexByAddr[selM.addr]), selM.curcircuit or -1)
      drawText(2, L.rowOpsCtx, ctx, C.fg)
      local xb = 2 + util.wlen(ctx) - 12
      addHitbox("actions", xb, L.rowOpsCtx, 12, 1, "pinCur", nil)
    end
  else
    drawText(2, L.rowOpsCtx, " （选槽行调权重；再点选机器行可[固定电路]让该机复制该元素）", C.dim)
  end
end

--- 日志区（行29-49）+ 状态栏（行50）
function ui.drawLog(app, log)
  local L = ui.L
  drawText(1, L.rowLogHead, "├─ 日志 " .. string.rep("─", ui.cfg.screen.width - 9) .. "┤", C.dim)
  local lines = log:tail(L.logRows)
  for i = 1, L.logRows do
    local y = L.rowLogFirst + i - 1
    local t = lines[i]
    if t then
      local color = C.fg
      if t:find("%[错误%]") or t:find("%[UUM %]") then color = C.err
      elseif t:find("%[分配%]") then color = C.run
      elseif t:find("%[固定%]") then color = C.warn
      elseif t:find("%[启动%]") then color = C.header end
      drawText(1, y, " " .. util.padRight(util.truncate(t, ui.cfg.screen.width - 2), ui.cfg.screen.width - 1), color)
    else
      fillBg(1, y, ui.cfg.screen.width, 1, C.bg)
    end
  end
  -- 状态栏
  local st = string.format(" 轮询%.0fs · ME:%s · 兼容层:%s · %s",
    ui.cfg.pollInterval,
    app.meOk and "正常" or "断开",
    app.compatLabel or "?",
    util.gameClock(app.osTime))
  drawText(1, L.rowStatus, util.padRight(st, ui.cfg.screen.width), C.dim)
end

-- ==================== 触摸事件分发 ====================

--- 处理触摸。返回 (action, payload) 或 nil
function ui.onTouch(x, y)
  -- 分组倒序命中：actions > nav > rows > machines > uum
  local order = { "actions", "nav", "rows", "machines", "uum" }
  for _, g in ipairs(order) do
    local boxes = ui.hitboxGroups[g]
    for i = #boxes, 1, -1 do
      local b = boxes[i]
      if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
        return b.action, b.payload
      end
    end
  end
  return nil
end

--- 每帧重置热区（绘制时重建）
function ui.beginFrame()
  for _, g in pairs(ui.hitboxGroups) do
    for i = #g, 1, -1 do g[i] = nil end
  end
end

return ui
