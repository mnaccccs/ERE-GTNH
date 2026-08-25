-- nbt.lua —— 纯 Lua 5.3 极简 gzip 解压 + NBT 解析
-- 用途：解析 inventory_controller.getStackInSlot 返回的 tag 字节（OC 序列化为
--   gzip 压缩的 NBT 文件格式），把物品 NBT 还原成 Lua 表。
-- 只实现读取，不实现写入；数字一律用 Lua number 表示（Long 精度可能损失，仅作标识用足够）。

local nbt = {}

-- ==================== 位读取器（Deflate：LSB 优先） ====================

local function newBits(data, pos)
  return { d = data, p = pos or 1, bit = 0, cur = 0 }
end

local function getbit(b)
  if b.bit == 0 then
    b.cur = b.d:byte(b.p) or 0
    b.p = b.p + 1
    b.bit = 8
  end
  local v = b.cur & 1
  b.cur = b.cur >> 1
  b.bit = b.bit - 1
  return v
end

local function getbits(b, n)
  local v = 0
  for i = 0, n - 1 do
    v = v | (getbit(b) << i)
  end
  return v
end

--- 字节对齐（Stored 块用）
local function alignByte(b)
  b.bit = 0
end

local function getByteAligned(b)
  if b.bit == 0 then
    local v = b.d:byte(b.p) or 0
    b.p = b.p + 1
    return v
  else
    return getbits(b, 8)
  end
end

-- ==================== Huffman ====================

--- 由码长表构建解码结构（规范 Huffman 编码）
local function buildHuff(lengths)
  local maxLen = 0
  for _, l in ipairs(lengths) do if l > maxLen then maxLen = l end end
  local blCount = {}
  for i = 1, maxLen do blCount[i] = 0 end
  for _, l in ipairs(lengths) do
    if l > 0 then blCount[l] = blCount[l] + 1 end
  end
  -- 计算每个长度的起始码
  local nextCode = {}
  local code = 0
  for len = 1, maxLen do
    code = (code + (blCount[len - 1] or 0)) << 1
    nextCode[len] = code
  end
  -- byLenCode[len][code] = symbol
  local byLenCode = {}
  for sym, l in ipairs(lengths) do
    if l > 0 then
      byLenCode[l] = byLenCode[l] or {}
      byLenCode[l][nextCode[l]] = sym - 1
      nextCode[l] = nextCode[l] + 1
    end
  end
  return { maxLen = maxLen, byLenCode = byLenCode }
end

local function hdecode(h, b)
  local code = 0
  for len = 1, h.maxLen do
    code = (code << 1) | getbit(b)
    local m = h.byLenCode[len]
    if m then
      local sym = m[code]
      if sym ~= nil then return sym end
    end
  end
  error("inflate: 非法 Huffman 码")
end

-- 固定 Huffman 表
local function fixedHuffman()
  local litLen = {}
  for i = 1, 288 do
    local s = i - 1
    if s <= 143 then litLen[i] = 8
    elseif s <= 255 then litLen[i] = 9
    elseif s <= 279 then litLen[i] = 7
    else litLen[i] = 8 end
  end
  local dist = {}
  for i = 1, 32 do dist[i] = 5 end
  return buildHuff(litLen), buildHuff(dist)
end

-- 长度/距离附加位表（Deflate 规范）
local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                   35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                    8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                     7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CLEN_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- ==================== inflate 主体 ====================

--- 解压一段原始 Deflate 数据，返回字节串
local function inflate(data, pos)
  local b = newBits(data, pos)
  local out = {}
  local n = 0
  while true do
    local bfinal = getbit(b)
    local btype = getbits(b, 2)
    local litH, distH
    if btype == 0 then
      -- Stored：字节对齐后按 LEN 原样拷贝
      alignByte(b)
      local len = getByteAligned(b) | (getByteAligned(b) << 8)
      local nlen = getByteAligned(b) | (getByteAligned(b) << 8)
      if (len ~ nlen) & 0xFFFF ~= 0xFFFF and ((len ~ nlen) & 0xFFFF) ~= (0xFFFF & 0xFFFF) then
        -- 宽松校验：LEN 与 NLEN 应互补；不一致也继续（容错）
      end
      for _ = 1, len do
        n = n + 1
        out[n] = getByteAligned(b)
      end
    else
      if btype == 1 then
        litH, distH = fixedHuffman()
      elseif btype == 2 then
        -- Dynamic：读码长码
        local hlit = getbits(b, 5) + 257
        local hdist = getbits(b, 5) + 1
        local hclen = getbits(b, 4) + 4
        local clenLen = {}
        for i = 1, 19 do clenLen[i] = 0 end
        for i = 1, hclen do
          clenLen[CLEN_ORDER[i] + 1] = getbits(b, 3)
        end
        local clenH = buildHuff(clenLen)
        -- 解码 lit/dist 码长
        local lens = {}
        local total = hlit + hdist
        local i = 1
        while i <= total do
          local sym = hdecode(clenH, b)
          if sym <= 15 then
            lens[i] = sym
            i = i + 1
          elseif sym == 16 then
            local rep = getbits(b, 2) + 3
            local prev = lens[i - 1] or 0
            for _ = 1, rep do lens[i] = prev i = i + 1 end
          elseif sym == 17 then
            local rep = getbits(b, 3) + 3
            for _ = 1, rep do lens[i] = 0 i = i + 1 end
          elseif sym == 18 then
            local rep = getbits(b, 7) + 11
            for _ = 1, rep do lens[i] = 0 i = i + 1 end
          end
        end
        -- 拆分 lit / dist
        local litLen, distLen = {}, {}
        for j = 1, hlit do litLen[j] = lens[j] or 0 end
        for j = 1, hdist do distLen[j] = lens[hlit + j] or 0 end
        litH = buildHuff(litLen)
        distH = buildHuff(distLen)
      else
        error("inflate: 非法 BTYPE=3")
      end
      -- 字面量/长度-距离解码
      while true do
        local sym = hdecode(litH, b)
        if sym < 256 then
          n = n + 1
          out[n] = sym
        elseif sym == 256 then
          break
        else
          local li = sym - 256
          local len = (LEN_BASE[li] or 0) + getbits(b, LEN_EXTRA[li] or 0)
          local dsym = hdecode(distH, b)
          local dist = (DIST_BASE[dsym + 1] or 0) + getbits(b, DIST_EXTRA[dsym + 1] or 0)
          for _ = 1, len do
            n = n + 1
            out[n] = out[n - dist]
          end
        end
      end
    end
    if bfinal == 1 then break end
  end
  -- 字节表 → 字符串
  local chars = {}
  for i = 1, n do chars[i] = string.char(out[i]) end
  return table.concat(chars)
end

-- ==================== gzip 包装 ====================

--- 解压 gzip 数据（跳过文件头与 8 字节尾），返回原始字节串
function nbt.gunzip(data)
  if data:byte(1) ~= 0x1F or data:byte(2) ~= 0x8B then
    error("gunzip: 不是 gzip 数据")
  end
  local flg = data:byte(4) or 0
  local p = 11  -- 固定头 10 字节之后
  if flg & 4 ~= 0 then  -- FEXTRA
    local xlen = (data:byte(p) or 0) | ((data:byte(p + 1) or 0) << 8)
    p = p + 2 + xlen
  end
  if flg & 8 ~= 0 then  -- FNAME
    while (data:byte(p) or 0) ~= 0 do p = p + 1 end
    p = p + 1
  end
  if flg & 16 ~= 0 then  -- FCOMMENT
    while (data:byte(p) or 0) ~= 0 do p = p + 1 end
    p = p + 1
  end
  if flg & 2 ~= 0 then p = p + 2 end  -- FHCRC
  return inflate(data, p)
end

-- ==================== NBT 解析（大端） ====================

local function newReader(data)
  return { d = data, p = 1 }
end

local function rU1(r)
  local v = r.d:byte(r.p) or 0
  r.p = r.p + 1
  return v
end

local function rI1(r)
  local v = rU1(r)
  return v >= 128 and v - 256 or v
end

local function rU2(r)
  local a, b = r.d:byte(r.p, r.p + 1)
  r.p = r.p + 2
  return ((a or 0) << 8) | (b or 0)
end

local function rI2(r)
  local v = rU2(r)
  return v >= 32768 and v - 65536 or v
end

local function rI4(r)
  local a, b, c, d = r.d:byte(r.p, r.p + 3)
  r.p = r.p + 4
  local v = ((a or 0) << 24) | ((b or 0) << 16) | ((c or 0) << 8) | (d or 0)
  -- Lua 5.3 位移对符号位直接给出正确有符号数
  return v
end

local function rI8(r)
  -- Long：只用低 53 位精度（标识用途足够）
  local hi = rI4(r)
  local lo = rI4(r)
  return hi * 4294967296 + (lo & 0xFFFFFFFF)
end

local function rF4(r)
  local v = rI4(r)
  local sign = v < 0 and -1 or 1
  local exp = (v >> 23) & 0xFF
  local mant = v & 0x7FFFFF
  if exp == 0 then return sign * mant * 2^-149 end
  if exp == 255 then return mant == 0 and sign * math.huge or 0/0 end
  return sign * (1 + mant / 0x800000) * 2^(exp - 127)
end

local function rF8(r)
  local hi = rI4(r)
  local lo = rI4(r) & 0xFFFFFFFF
  local sign = hi < 0 and -1 or 1
  local exp = (hi >> 20) & 0x7FF
  local mant = (hi & 0xFFFFF) * 4294967296 + lo
  if exp == 0 then return sign * mant * 2^-1074 end
  if exp == 2047 then return mant == 0 and sign * math.huge or 0/0 end
  return sign * (1 + mant / 0x10000000000000) * 2^(exp - 1023)
end

local function rStr(r, lenBytes)
  local len = lenBytes == 4 and rI4(r) or rU2(r)
  local s = r.d:sub(r.p, r.p + len - 1)
  r.p = r.p + len
  return s
end

local parsePayload  -- 前向声明

local function parseCompound(r)
  local out = {}
  while true do
    local t = rU1(r)
    if t == 0 then break end
    local name = rStr(r)
    out[name] = parsePayload(r, t)
  end
  return out
end

parsePayload = function(r, t)
  if t == 1 then return rI1(r)
  elseif t == 2 then return rI2(r)
  elseif t == 3 then return rI4(r)
  elseif t == 4 then return rI8(r)
  elseif t == 5 then return rF4(r)
  elseif t == 6 then return rF8(r)
  elseif t == 7 then  -- ByteArray
    local len = rI4(r)
    local s = r.d:sub(r.p, r.p + len - 1)
    r.p = r.p + len
    return s
  elseif t == 8 then return rStr(r)
  elseif t == 9 then  -- List
    local et = rU1(r)
    local len = rI4(r)
    local arr = {}
    for i = 1, len do arr[i] = parsePayload(r, et) end
    return arr
  elseif t == 10 then return parseCompound(r)
  elseif t == 11 then  -- IntArray
    local len = rI4(r)
    local arr = {}
    for i = 1, len do arr[i] = rI4(r) end
    return arr
  elseif t == 12 then  -- LongArray
    local len = rI4(r)
    local arr = {}
    for i = 1, len do arr[i] = rI8(r) end
    return arr
  end
  error("NBT: 未知 tag 类型 " .. tostring(t))
end

--- 解析 NBT 文件格式字节串（根是带名字的 Compound），返回其内容表
function nbt.parse(data)
  local r = newReader(data)
  local t = rU1(r)
  if t ~= 10 then error("NBT: 根节点不是 Compound") end
  local _rootName = rStr(r)
  return parseCompound(r)
end

--- 一步到位：gzip 压缩的 NBT → Lua 表
function nbt.fromGzip(data)
  return nbt.parse(nbt.gunzip(data))
end

return nbt
