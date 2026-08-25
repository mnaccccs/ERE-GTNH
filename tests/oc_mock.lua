-- tests/oc_mock.lua —— OpenComputers 环境模拟（供宿主 lupa 驱动）
-- 在真实 Lua 里构造假的 component/computer/event/term/filesystem/os 环境，
-- 让 ere 各模块以为自己在 OC 里跑。

local M = {}

-- ==================== 假组件网 ====================

-- 状态仓库（宿主可改）
M.state = {
  uum = 1200000,          -- UUM mB
  items = {               -- name -> 数量
    ["gregtech:gt_dust_platinum"] = 12400,
    ["gregtech:gt_dust_iridium"]  = 8900,
    ["gregtech:gt_dust_osmium"]   = 15000,
  },
  circuits = {},          -- orbAddr -> 电路号
}

local ORBS = {
  "aaaa0000-orb1",
  "bbbb0000-orb2",
}
-- daily690 干扰项：组装机（28 方法合并环境，含电路对但 getName 不含 orb）
local ASSEMBLER = "9999aaaa-asm1"
-- 290b1 风格球仓：独立电路环境（无 getName，仅 2 方法）
local ORB_LEGACY = "cccc1111-orb3"
local MAINTAINERS = {
  "cccc0000-lm1",
}

local function orbProxy(addr)
  return {
    address = addr,
    getName = function()
      return "hatch.input_bus.elementalorbholder"
    end,
    getCircuitConfiguration = function()
      return M.state.circuits[addr] or -1
    end,
    setCircuitConfiguration = function(n)
      M.state.circuits[addr] = n
      return true
    end,
  }
end

-- 290b1 独立电路环境：无 getName，只有电路对
local function orbLegacyProxy(addr)
  return {
    address = addr,
    getCircuitConfiguration = function()
      return M.state.circuits[addr] or -1
    end,
    setCircuitConfiguration = function(n)
      M.state.circuits[addr] = n
      return true
    end,
  }
end

-- daily 组装机：28 方法合并环境（有电路对但 metaName 不含 orb → 必须被排除）
local function assemblerProxy(addr)
  local p = {
    address = addr,
    getName = function()
      return "basicmachine.assembler.tier.02"
    end,
    getCircuitConfiguration = function()
      return M.state.circuits[addr] or -1
    end,
    setCircuitConfiguration = function(n)
      M.state.circuits[addr] = n
      return true
    end,
  }
  return p
end

local function lmProxy(addr)
  local slots = {
    [1] = { name = "gregtech:gt_dust_platinum", damage = 0, label = "铂粉",
            quantity = 16000, batch = 512, isFluid = false, isEnable = true, isDone = false },
    [2] = { name = "gregtech:gt_dust_iridium", damage = 0, label = "铱粉",
            quantity = 9000, batch = 512, isFluid = false, isEnable = true, isDone = false },
    [3] = nil,
  }
  return {
    address = addr,
    getSlot = function(s) return slots[s] end,
  }
end

local function meProxy(addr)
  return {
    address = addr,
    getItemsInNetwork = function(filter)
      if filter and filter.name then
        local n = M.state.items[filter.name]
        if n then return { { name = filter.name, size = n } } end
        return {}
      end
      local out = {}
      for k, v in pairs(M.state.items) do out[#out+1] = { name = k, size = v } end
      return out
    end,
    getFluidInNetwork = function(filter)
      local name = type(filter) == "table" and (filter.fluid or filter.name) or filter
      if name and name:find("uu_matter") then
        return { fluid = "uu_matter", amount = M.state.uum }
      end
      return {}
    end,
    getFluidsInNetwork = function()
      return { { fluid = "uu_matter", amount = M.state.uum } }
    end,
  }
end

-- ==================== component 模拟 ====================

local COMPONENTS = {}
for _, a in ipairs(ORBS) do COMPONENTS[a] = { type = "gt_machine", proxy = orbProxy(a) } end
COMPONENTS[ORB_LEGACY] = { type = "gt_machine", proxy = orbLegacyProxy(ORB_LEGACY) }
COMPONENTS[ASSEMBLER] = { type = "gt_machine", proxy = assemblerProxy(ASSEMBLER) }
for _, a in ipairs(MAINTAINERS) do COMPONENTS[a] = { type = "level_maintainer", proxy = lmProxy(a) } end
COMPONENTS["me00-ctrl"] = { type = "me_controller", proxy = meProxy("me00-ctrl") }

local component = {
  list = function(ctype)
    local pairs_fn = function()
      local keys = {}
      for a, c in pairs(COMPONENTS) do
        if not ctype or c.type == ctype then keys[#keys+1] = a end
      end
      local i = 0
      return function()
        i = i + 1
        local a = keys[i]
        if a then return a, COMPONENTS[a].type end
      end
    end
    return pairs_fn()
  end,
  proxy = function(addr)
    local c = COMPONENTS[addr]
    if c then return c.proxy end
    return nil, "no such component"
  end,
  methods = function(addr)
    local c = COMPONENTS[addr]
    if c and c.type == "gt_machine" then
      -- 电路驱动环境：恰好 2 方法
      return { getCircuitConfiguration = true, setCircuitConfiguration = true }
    end
    return {}
  end,
  gpu = nil, -- UI 测试另行注入
}

-- ==================== computer/event/serialization 等 ====================

local MOCK_UPTIME = { v = 1000.0 }

local computer = {
  uptime = function() return MOCK_UPTIME.v end,
}

local event = {
  pulled = {},
  pull = function(timeout, ...)
    -- 立即返回空（测试不依赖真实事件）
    return nil
  end,
}

local serialization = {
  serialize = function(t)
    -- 极简序列化（够用即可）
    local function ser(v, indent)
      local t = type(v)
      if t == "string" then return string.format("%q", v)
      elseif t == "number" or t == "boolean" then return tostring(v)
      elseif t == "table" then
        local parts = {}
        for k, val in pairs(v) do
          local key = type(k) == "string" and ("[\"" .. k .. "\"]") or ("[" .. tostring(k) .. "]")
          parts[#parts+1] = key .. " = " .. ser(val, indent)
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n}"
      end
      return "nil"
    end
    return ser(t)
  end,
  unserialize = function(s)
    local f = load("return " .. s)
    if f then return f() end
    return nil
  end,
}

M.component = component
M.computer = computer
M.event = event
M.serialization = serialization
M.uptime = MOCK_UPTIME
M.ORBS = ORBS
M.MAINTAINERS = MAINTAINERS

return M
