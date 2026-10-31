local T = require("lib")
local log = require("core/log")

T.test("log: формат строки с таблицей", function()
    local out
    log.sink = function(s) out = s end
    log("server.cmd", { name = "MoveToken", id = 3 })
    log.sink = print
    T.eq(out, '[server.cmd] {id=3, name="MoveToken"}')
end)

T.test("log: без данных", function()
    local out
    log.sink = function(s) out = s end
    log("boot")
    log.sink = print
    T.eq(out, "[boot]")
end)

T.test("log: выключен", function()
    local called = false
    log.sink = function() called = true end
    log.enabled = false
    log("x", 1)
    log.enabled = true
    log.sink = print
    T.eq(called, false)
end)
