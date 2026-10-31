-- tests/world_test.lua
-- Тесты модуля server/world (чтение состояния блоков get_block_state)

local T = require("lib")
local mock = require("engine_mock")
mock.install()

local world = require("server/world")

T.test("world: get_block_state возвращает пару (id, state) из мока block", function()
    mock.override("block.get", function(x, y, z)
        if x == 10 and y == 64 and z == -5 then
            return 42
        end
        return 0
    end)
    mock.override("block.get_states", function(x, y, z)
        if x == 10 and y == 64 and z == -5 then
            return 7
        end
        return 0
    end)

    T.truthy(type(world.get_block_state) == "function", "world.get_block_state должна быть функцией")
    local id, state = world.get_block_state(10, 64, -5)
    T.eq(id, 42)
    T.eq(state, 7)
end)

T.test("world: get_block_state возвращает nil для незагруженного или невалидного блока", function()
    mock.override("block.get", function(x, y, z)
        if x == 999 then
            return -1 -- незагруженный блок
        elseif x == 1000 then
            return nil
        end
        return 1
    end)
    mock.override("block.get_states", function(x, y, z)
        if x == 1001 then
            return nil
        end
        return 0
    end)

    T.truthy(type(world.get_block_state) == "function", "world.get_block_state должна быть функцией")
    T.eq(world.get_block_state(999, 64, 0), nil, "id = -1 -> nil")
    T.eq(world.get_block_state(1000, 64, 0), nil, "id = nil -> nil")
    T.eq(world.get_block_state(1001, 64, 0), nil, "state = nil -> nil")
end)
