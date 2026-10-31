-- server/world.lua
-- Слой: server
-- Спека: specs/server-world.md, specs/net-block-revert.md
-- Назначение: Единственная точка входа для всех изменений блоков воксельного мира на сервере.
-- Публичные функции:
--   set_block(x, y, z, id, states)
--   get_block(x, y, z)
--   get_block_state(x, y, z)
--   get_block_name(x, y, z)
--   set_cell_blocks(cx, cz, y, id, states)
--   raycast(start_pos, dir, max_dist)

local grid = require("core/grid")
local log = require("core/log")

local M = {}

-- Установка блока по координатам
function M.set_block(x, y, z, id, states)
    -- docs: docs/engine/scripting/builtins/libblock.md:32: block.set(x: int, y: int, z: int, id: int, states: int, noupdate: boolean=false)
    local res = block.set(x, y, z, id, states or 0)
    log("world_set_block", { x = x, y = y, z = z, id = id })
    return res
end

-- Получение ID блока по координатам
function M.get_block(x, y, z)
    -- docs: docs/engine/scripting/builtins/libblock.md:24: block.get(x: int, y: int, z: int) -> int
    return block.get(x, y, z)
end

-- Получение ID и состояния блока по координатам
-- Возвращает id, state или nil, если блок не загружен или некорректен
function M.get_block_state(x, y, z)
    -- docs: docs/engine/scripting/builtins/libblock.md:24: block.get(x: int, y: int, z: int) -> int
    local id = block.get(x, y, z)
    if id == nil or id < 0 then
        return nil
    end

    -- docs: docs/engine/scripting/builtins/libblock.md:28: block.get_states(x: int, y: int, z: int) -> int
    local state = block.get_states(x, y, z)
    if state == nil or state < 0 then
        return nil
    end

    return id, state
end

-- Получение строкового имени блока по координатам
function M.get_block_name(x, y, z)
    -- docs: docs/engine/scripting/builtins/libblock.md:24: block.get(x: int, y: int, z: int) -> int
    local id = block.get(x, y, z)
    -- docs: docs/engine/scripting/builtins/libblock.md:5: block.name(blockid: int) -> str
    return block.name(id)
end

-- Установка всех 4 блоков клетки 2x2 на заданной высоте
function M.set_cell_blocks(cx, cz, y, id, states)
    local blocks = grid.blocks_of(cx, cz)
    local last_res
    for _, b in ipairs(blocks) do
        last_res = M.set_block(b[1], y, b[2], id, states)
    end
    return last_res
end

-- Трассировка луча по вокселям мира
function M.raycast(start_pos, dir, max_dist)
    -- docs: docs/engine/scripting/builtins/libblock.md:140: block.raycast(start: vec3, dir: vec3, max_distance: number, [optional] dest: table, [optional] filter: table) -> table or nil
    return block.raycast(start_pos, dir, max_dist)
end

return M
