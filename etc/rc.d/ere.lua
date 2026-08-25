-- /etc/rc.d/ere.lua —— ERE 开机自启
-- 安装：把本文件放到 /etc/rc.d/ere.lua，然后 rc ere enable add default

local fs = require("filesystem")

if fs.exists("/home/ere/main.lua") then
  return function()
    -- 后台启动主程序（shell 级，可被 rc ere disable 移除）
    require("shell").execute("/home/ere/main.lua")
  end
end
