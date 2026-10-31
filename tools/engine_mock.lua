-- tools/engine_mock.lua
-- Заглушка движка для тестов на обычном LuaJIT.
-- Разрешены только функции из tools/api_allowlist.lua. Обращение к любой другой
-- функции библиотеки падает с понятной ошибкой: так агент сам видит выдуманный вызов.
--
-- Использование в тесте:
--   local mock = require("engine_mock")
--   mock.install()
--   mock.override("block.get", function(x, y, z) return 1 end)

local M = {}

local allow = require("api_allowlist")
local impl = {}

local function make_lib(name)
    return setmetatable({}, {
        __index = function(_, fname)
            local full = name .. "." .. tostring(fname)
            local colon = name .. ":" .. tostring(fname)
            local is_allowed = (allow.functions and allow.functions[full])
                or (allow.methods and (allow.methods[full] or allow.methods[colon]))
            if not is_allowed then
                error("API не подтверждён: " .. full ..
                    ". Добавьте в docs/api-notes.md и tools/api_allowlist.lua", 2)
            end
            return impl[full] or impl[colon] or function() return nil end
        end,
        __newindex = function(_, fname)
            error("Заглушка движка: запись в " .. name .. "." .. tostring(fname) .. " запрещена", 2)
        end,
    })
end

-- Ставит защищённые библиотеки в таблицу env (по умолчанию _G).
function M.install(env)
    env = env or _G
    for _, name in ipairs(allow.libs) do
        env[name] = make_lib(name)
    end
end

-- Задаёт реализацию подтверждённой функции для теста.
function M.override(full, fn)
    local is_allowed = (allow.functions and allow.functions[full])
        or (allow.methods and allow.methods[full])
    if not is_allowed then
        error("override для неподтверждённого API: " .. full, 2)
    end
    impl[full] = fn
end

-- Сбрасывает все реализации.
function M.reset()
    impl = {}
end

return M
