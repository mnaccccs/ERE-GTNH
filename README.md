# ERE-GTNH — 元素复制调度台

GTNH 大型元素复制机（Elemental Duplicator）多机智能调度系统，OpenComputers 触屏 UI。
同时兼容 **GTNH 2.9.0-beta-1** 与 **最新 daily 测试版（690+）**。

## 功能

- **多机智能分配**：按 `score = 权重 × 缺口%` 给每台复制机分配目标元素；
  权重触屏可调（1-9）；缺口加权可切线性/平方（平方 = 重伤优先）。
- **单元素独占保护**：≥2 个可产目标时，同元素最多占一半机器（向上取整）——
  永远不会全部复制机同时复制一个元素；只剩 1 个可产目标时自动放开。
- **UUM 储量监控**：当前储量、24h sparkline（144 点环形缓冲，10 分钟采样）、
  Δ24h / Δ1h / Δ10m 三窗口增量、净速率与趋势。
- **UUM 停配阈值（请求器可调）**：储量低于阈值自动停止新分配（保口粮，在产任务自然收尾）。
  默认 1G mB；**在请求器任意槽放「UU 物质液滴」，该槽数量即阈值**，游戏内随时改，
  不用动配置文件。撤掉该槽回落默认值。该槽只作阈值用，不会变成生产目标。
- **请求器全量读取**：自动发现全部 ME Level Maintainer，5 槽热读取目标/批量/开关。
- **固定模式**：
  - 双选固定——先点元素槽行、再点机器行，上下文行出现 `[确认固定]`，
    该机立即固定复制该元素（电路 = 槽号），手动模式下也即时下发电路；
  - 单选机器——`[固定电路]` 固定当前电路（排查数据球配置时用），自动调度让位；
  - 解除固定后立即参与自动分配，不等时间片。
- **重新分配按钮**：一键清空自动机器在产任务与时间片，立即重排——
  不用等时间片（默认 300s）到期；切换加权策略时也会自动触发立即重排。
- **时间片轮转**：每台机器生产同一元素的最长时限（默认 300s），防高分槽霸占。
- **切槽磁滞**：现量 ≥ 目标×90% 即视为达标，避免在临界点来回抖动。
- **SEUI 风格实心进度条**：目标槽达成度分档配色（≥90% 绿 / ≥50% 黄 / 否则红），
  无 ▓░ 抖动字符，远距离也清晰。
- **手动模式**：调度循环挂起、电路保持；`[重新分配]` 作为显式指令仍可做一次性分配。

## 硬件要求

- T3 屏幕（160×50）+ T3 显卡 + OC 适配器
- 适配器连接**数据球仓**（不是复制机控制器！）——电路配置组件在球仓上
- ME 网络：一个 me_controller / me_interface 供 OC 查询库存（方块和贴线缆的 part 形态都能被适配器读到）
- 请求器（AE2FC Level Maintainer）任意数量

### 无法把适配器贴到球仓上？用 MFU（远程适配器）

OC 适配器只能暴露**贴着的**方块，而数据球仓往往藏在机器结构里贴不到。解决方案是 **MFU**（T3 适配器升级卡，物品名就叫 MFU，设备信息 "Remote Adapter"）：

1. 手持 MFU **右键点目标方块**（数据球仓/请求器/ME 接口），MFU 即绑定该方块坐标+面（工具提示显示 Linked）
2. 把绑好的 MFU 塞进任意**适配器的升级槽**（每台适配器只能放 1 个 MFU）
3. 适配器照常接入 OC 网络

限制（源码核实，OC 1.12.x）：默认作用距离 **16 格**（`misc.mfuRange`，可 0-128 调）、必须同维度、目标区块必须已加载。

对 ERE 完全透明：MFU 走全局驱动注册表代理组件，`component.list` 里看到的就是同样的 `gt_machine` / `level_maintainer` / `me_controller`——发现逻辑、地址前缀消歧、球仓识别全部照常工作，无需任何代码改动。多台球仓就多组「适配器+MFU」，全挂同一线缆网络即可。

## 安装

```
/home/ere/          ← main.lua config.lua util.lua compat.lua
                       discovery.lua uum.lua model.lua scheduler.lua ui.lua
                       diagnose.lua（网络诊断工具，可选）
/etc/rc.d/ere.lua   ← 开机自启（rc ere enable add default）
```

把整个 `home/ere/` 目录拷进 OC 电脑，运行 `/home/ere/main.lua`，或配置 rc.d 开机自启。
按 `Q` 退出主程序。

## 使用

1. 请求器 GUI 里配好目标槽（物品 + quantity + batch），槽 N 对应数据球仓电路 N
2. 数据球仓内放好数据球（槽位顺序 = 电路号顺序，1-16）
3. 启动后自动扫描；点槽行选中 → 上下文行 `[−] 权重 [+]` 调节
4. 固定复制：点元素槽行 + 点机器行 → `[确认固定]`；再点 `[固定电路]`（或上下文行）解除
5. `[重新分配]`：清全部自动机器在产任务，立即按当前权重/缺口重排
6. `[策略]` 切换线性/平方加权（立即触发重排）；`[停机-1]` 全部电路拔停并挂起自动调度
7. 改 UUM 停配阈值：请求器里放「UU 物质液滴」槽，数量即阈值（默认 1G）

## 配置（config.lua）

| 键 | 默认 | 说明 |
|---|---|---|
| `pollInterval` | 2.0 | 主循环轮询秒 |
| `discoveryInterval` | 30.0 | 组件周期重发现秒（区块加载/新机器接入） |
| `circuitMin/Max` | 1 / 16 | 编程电路合法范围（数据球仓 1-16） |
| `idleCircuit` | -1 | 停产电路号（驱动语义：拔除电路） |
| `switchHysteresis` | 0.90 | 切槽磁滞系数 |
| `timeSlice` | 300 | 时间片秒（同机同元素最长连续生产） |
| `uum.fluidName` | `ic2uumatter` | UUM 流体注册名（AE2 查询键） |
| `uum.warnThreshold` | 1e9 | 默认停配阈值 mB；请求器 UU 物质槽数量覆盖它 |
| `uum.sampleSec/sampleCount` | 600 / 144 | 采样间隔 × 点数 = 24h |
| `policy.weighting` | `linear` | 缺口加权：`linear` / `quad` |
| `policy.soloGuard` | true | 单元素独占保护 |
| `policy.uumRation` | true | UUM 保口粮 |
| `addresses.me` | nil | 多个 ME 组件时填地址前缀消歧（前 4~8 位） |

## 兼容性说明（源码级审计 + 实机验证结论）

| 依赖 | 290beta1 | daily 690+ | ERE 策略 |
|---|---|---|---|
| 电路驱动 (Computronics gt_machine) | 1.9.8 ✓ | ✓ | 电路对 `get/setCircuitConfiguration` 为必要条件；`getName()` 含 "orb" 首选判定；无 getName 退回方法数≤2 |
| 请求器 level_maintainer | AE2FC 1.5.88 ✓ | ✓ | getSlot 特征方法、三参 setSlot |
| 流体库存查询 | me_controller/me_interface ✓ | ✓（fluid_interface 也可） | 统一走 me_* |
| **OC 组件方法表示** | function | **可调用表**（OC 1.8+，type=="table" 且元表带 __call） | 方法存在性一律用「function 或可调用表」判定，两种都认 |
| 渲染器铺底 | 空格可画背景 | 空格不画背景、█按前景色 | 统一 █ 铺底（双版兼容） |

> ⚠️ **OC 1.8+ 大坑**：新版 OC 把代理组件的方法暴露为「可调用表」而非 function，
> 用 `type(p.getSlot) == "function"` 判方法存在会在新版上全军覆没（发现不到任何硬件）。
> 本项目的判定辅助函数同时接受两种表示。

## 状态持久化

权重/停用/固定电路存 `/home/ere/ERE_STATE.lua`（运行时生成，勿提交），重启自动恢复。

## 诊断

游戏内运行 `/home/ere/diagnose.lua`：一次性列出 OC 网络全部组件、目标组件计数、
gt_machine 方法明细（找数据球仓），只读不改状态。

## 测试

宿主机（需 Python + lupa）：

```bash
pip install lupa
python tests/run_tests.py
```

lupa 模拟 OC 环境，16 项单测覆盖 util/uum/compat/discovery/model/scheduler
（分配、独占保护、保口粮、固定模式、阈值、持久化）。
Windows 宿主机注意：「model 持久化」用例写 `/tmp/`，需自建 `C:\tmp` 目录否则该例失败（其余不受影响）。

## 文件结构

```
home/ere/
  main.lua       入口：模块装配、主事件循环、触摸分发、崩溃保护
  config.lua     全部可调参数（布局/轮询/UUM/策略/地址绑定）
  discovery.lua  组件发现：请求器 × N、数据球仓 × N（双版本兼容识别）
  compat.lua     双版本适配层：ME 查询统一入口、版本探测
  model.lua      数据模型：目标槽/机器/权重持久化、UUM 阈值槽解析
  scheduler.lua  智能分配器：评分、独占保护、时间片、固定模式、保口粮
  uum.lua        UUM 采样：环形缓冲、三窗增量、sparkline
  ui.lua         触屏 UI：160×50 布局、实心进度条、热区分发
  util.lua       宽字符排版、数字格式化、日志环形缓冲
  diagnose.lua   网络诊断工具（独立运行）
etc/rc.d/ere.lua 开机自启脚本
tests/           lupa 单测（oc_mock 模拟 OC 环境）
```
