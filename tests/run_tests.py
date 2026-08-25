#!/usr/bin/env python3
"""ERE 测试驱动：用 lupa(Lua 5.5) 跑 tests/run_tests.lua"""
import sys
from pathlib import Path
from lupa import LuaRuntime

# ERE 根目录 = 本脚本所在 tests/ 的上一级（自定位，不依赖机器路径）
ROOT = str(Path(__file__).resolve().parent.parent).replace("\\", "/")

lua = LuaRuntime(unpack_returned_tuples=True)

# package.path 指向 ERE 根目录
lua.execute(f"""
package.path = "{ROOT}/home/ere/?.lua;{ROOT}/tests/?.lua;" .. package.path
""")

# os.exit 在 lupa 里会杀宿主进程，替换成抛错
lua.execute("""
os.exit = function(code)
  error("LUA_TEST_EXIT_" .. tostring(code))
end
""")

try:
    result = lua.execute(f'dofile("{ROOT}/tests/run_tests.lua")')
except Exception as e:
    msg = str(e)
    if "LUA_TEST_EXIT_1" in msg:
        print("\n[runner] tests exited with failure")
        sys.exit(1)
    elif "LUA_TEST_EXIT_0" in msg:
        pass  # success
    else:
        print(f"[runner] crash: {msg}")
        sys.exit(2)
