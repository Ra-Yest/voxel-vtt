local T = require("lib")

T.test("mock: неподтверждённый API падает с понятной ошибкой", function()
    local env = {}
    require("engine_mock").install(env)
    local ok, err = pcall(function() return env.block.nothing end)
    T.eq(ok, false)
    T.truthy(tostring(err):find("API не подтверждён", 1, true), "сообщение об ошибке")
end)

T.test("mock: override неподтверждённого API запрещён", function()
    T.throws(function() require("engine_mock").override("block.nothing", function() end) end)
end)
