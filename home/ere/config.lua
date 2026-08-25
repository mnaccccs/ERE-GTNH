-- config.lua —— ERE 元素复制调度台 配置
-- 所有可调参数集中在此。布局参数与调度参数分开，改布局不影响逻辑。

local config = {}

-- ==================== 硬件假设 ====================
-- 屏幕：T3 160×50 触屏。若用小屏改这里，布局按比例压缩（目标区行数优先受影响）。
config.screen = { width = 160, height = 50 }

-- ==================== 布局（160×50 行分配，改这里=改草图）====================
config.layout = {
  rowTitle     = 1,   -- 标题栏
  rowUum       = 2,   -- UUM 储量条
  rowSpark     = 3,   -- UUM 24h sparkline
  rowRate      = 4,   -- Δ24h/Δ1h/Δ10m/净速率
  rowMachHead  = 5,   -- 复制机区标题
  rowMachFirst = 6,   -- 第一台复制机行（预排 8 行，按实际台数绘制）
  machRows     = 8,   -- 复制机区预留行数
  rowTgtHead   = 14,  -- 目标槽表头
  rowTgtFirst  = 15,  -- 第一行目标槽
  tgtRows      = 10,  -- 目标槽每页可见行数（20 槽 → 2 页）
  rowOps       = 26,  -- 操作区分隔条
  rowOpsMain   = 27,  -- 主按钮行
  rowOpsCtx    = 28,  -- 上下文行（权重 ± / 固定电路）
  rowLogHead   = 29,  -- 日志区分隔条
  rowLogFirst  = 30,  -- 第一行日志
  logRows      = 19,  -- 日志可见行数
  rowStatus    = 50,  -- 底部状态栏
}

-- ==================== 轮询与调度 ====================
config.pollInterval = 2.0        -- 主循环轮询秒（读取请求器/ME/UUM）
config.discoveryInterval = 30.0  -- 组件重发现周期（区块加载/新机器接入）
config.circuitMin = 1            -- 编程电路合法下界（数据球仓 1-16）
config.circuitMax = 16           -- 编程电路合法上界（数据球仓 1-16）
config.idleCircuit = -1          -- 停产电路号（驱动语义：拔除电路）
config.switchHysteresis = 0.90   -- 切槽磁滞：现量 ≥ 目标×系数 才算达标，防抖动
config.timeSlice = 300.0         -- 时间片秒：每台机器生产同一元素的最长时限，
                                 -- 到期强制重新评估分配（防长任务饿死其他槽）

-- ==================== UUM 监控 ====================
config.uum = {
  fluidName     = "ic2uumatter",    -- UU Matter 流体注册名（AE2 查询键，实测 daily690 网络内叫 ic2uumatter）
  warnThreshold = 1000000000,       -- 默认停配阈值 1G mB（低于则新任务停止分配）；
                                    -- 请求器里放「UU物质液滴」槽时，该槽数量会覆盖此默认值
  sampleSec     = 600,              -- 采样间隔秒（10 分钟一点）
  sampleCount   = 144,              -- 环形缓冲容量（144 点 = 24h）
  sparkBins     = 24,               -- sparkline 聚合格数（24 格 = 每小时一格）
}

-- ==================== 智能分配策略 ====================
config.policy = {
  weighting     = "linear",   -- 缺口加权模式："linear" | "quad"（平方：重伤优先）
  soloGuard     = true,       -- 单元素独占保护：≥2 个可产目标时禁止全部机器复制同一元素
  uumRation     = true,       -- UUM 保口粮：低于阈值时暂停最低优先级机器
  minWeight     = 1,          -- 权重下限（触屏调节范围）
  maxWeight     = 9,          -- 权重上限
}

-- ==================== 兼容层 ====================
-- daily690 新渲染器：空格不画背景、█ 按前景色着色 → 全部铺底走 █ + 前景色=底色
-- 该行为已在 FPB 0f6d3a6/dd1730d 实装验证，ERE 直接继承，无需探测分支。
config.compat = {
  blockFill = true,  -- true: fillBg 用 █+前景色（daily690/新版渲染器）
}

-- ==================== 日志 ====================
config.logCap = 300               -- 日志环形缓冲容量
config.startupBanner = "安装19个能源仓的复制机最优并行为40并"
                                  -- 启动横幅：日志第一行展示（主人定的文案，纯展示不参与调度）
                                  -- 语义：无损超频下并行只受能源仓电流上限约束
                                  -- (2*19)/(15/16)=40.53 → 40 并

-- ==================== 地址绑定（可选，留空自动发现）====================
-- 多个同类组件时填写地址前缀（前 4~8 位）消除歧义。例：config.addresses.me = "a1b2"
config.addresses = {
  me         = "1bd4f43a",   -- ME 控制器/接口（物品+流体库存查询：getItemsInNetwork/getFluidInNetwork）
                              -- 实测网络上有 2 台 me_controller 适配器（同一 ME 网），按设计填前缀消歧
  -- 请求器与数据球仓不在这里绑定：全部自动发现（扫描 level_maintainer / 方法数≤2 的 gt_machine）
}

return config
