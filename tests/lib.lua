-- tests/lib.lua: минимальный тестовый каркас без внешних зависимостей.

local M = {}
local tests = {}

function M.test(name, fn)
    tests[#tests + 1] = { name = name, fn = fn }
end

function M.eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "eq") .. ": ожидалось " .. tostring(expected) ..
            ", получено " .. tostring(actual), 2)
    end
end

function M.truthy(v, msg)
    if not v then error((msg or "truthy") .. ": значение ложно", 2) end
end

function M.throws(fn, msg)
    local ok = pcall(fn)
    if ok then error((msg or "throws") .. ": ожидалась ошибка", 2) end
end

-- Запускает накопленные тесты, возвращает число падений.
function M.run()
    local failed = 0
    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if ok then
            print("ok    " .. t.name)
        else
            failed = failed + 1
            print("FAIL  " .. t.name .. "\n      " .. tostring(err))
        end
    end
    print(string.format("\n%d тестов, %d упало", #tests, failed))
    return failed
end

return M
