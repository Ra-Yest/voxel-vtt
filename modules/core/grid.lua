-- core/grid.lua
-- Слой: core (чистый Lua, без вызовов движка).
-- Спека: specs/core-grid.md
-- Клетка 3x3 блока (MVP-0, апгрейд с 2x2 до 3x3).

local M = {}

M.CELL_SIZE = 3

local floor = math.floor

-- Мировые координаты (блоки) -> индексы клетки.
function M.cell_of(x, z)
    return floor(x / M.CELL_SIZE), floor(z / M.CELL_SIZE)
end

-- Клетка как значение (cx, cz, level). В MVP-0 level = 0.
function M.make_cell(x, z, level)
    local cx, cz = M.cell_of(x, z)
    return { cx = cx, cz = cz, level = level or 0 }
end

-- Центр клетки в мировых координатах.
function M.center_of(cx, cz)
    local s = M.CELL_SIZE
    return (cx + 0.5) * s, (cz + 0.5) * s
end

-- Координаты блоков клетки: список пар {x, z}.
function M.blocks_of(cx, cz)
    local s = M.CELL_SIZE
    local res = {}
    for dx = 0, s - 1 do
        for dz = 0, s - 1 do
            res[#res + 1] = { cx * s + dx, cz * s + dz }
        end
    end
    return res
end

-- Четыре соседа на том же уровне.
function M.neighbors4(cell)
    local l = cell.level or 0
    return {
        { cx = cell.cx + 1, cz = cell.cz, level = l },
        { cx = cell.cx - 1, cz = cell.cz, level = l },
        { cx = cell.cx, cz = cell.cz + 1, level = l },
        { cx = cell.cx, cz = cell.cz - 1, level = l },
    }
end

-- Строковый ключ клетки для таблиц.
function M.key(cell)
    return cell.cx .. ":" .. cell.cz .. ":" .. (cell.level or 0)
end

-- Манхэттенское расстояние между двумя клетками в плоскости (cx, cz).
function M.distance(cell_a, cell_b)
    return math.abs(cell_a.cx - cell_b.cx) + math.abs(cell_a.cz - cell_b.cz)
end

-- Клетки в пределах манхэттенского расстояния max_steps (по умолчанию 5).
-- По умолчанию не включает стартовую клетку (если include_start ~= true).
function M.reachable_cells(start_cell, max_steps, include_start)
    local max_s = max_steps or 5
    local l = start_cell.level or 0
    local res = {}
    for dx = -max_s, max_s do
        local rem = max_s - math.abs(dx)
        for dz = -rem, rem do
            if include_start or (dx ~= 0 or dz ~= 0) then
                res[#res + 1] = { cx = start_cell.cx + dx, cz = start_cell.cz + dz, level = l }
            end
        end
    end
    return res
end

-- Пошаговая цепочка соседних 4-связных клеток (сначала по X, затем по Z)
-- от start_cell (не включая старт) до target_cell (включительно).
function M.build_path(start_cell, target_cell)
    local l = start_cell.level or target_cell.level or 0
    local cur_x = start_cell.cx
    local cur_z = start_cell.cz
    local target_x = target_cell.cx
    local target_z = target_cell.cz
    local res = {}

    local step_x = target_x > cur_x and 1 or -1
    while cur_x ~= target_x do
        cur_x = cur_x + step_x
        res[#res + 1] = { cx = cur_x, cz = cur_z, level = l }
    end

    local step_z = target_z > cur_z and 1 or -1
    while cur_z ~= target_z do
        cur_z = cur_z + step_z
        res[#res + 1] = { cx = cur_x, cz = cur_z, level = l }
    end

    return res
end

return M
