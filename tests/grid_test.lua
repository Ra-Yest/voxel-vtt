local T = require("lib")
local grid = require("core.grid")

T.test("cell_of: положительные координаты", function()
    local cx, cz = grid.cell_of(7, 4)
    T.eq(cx, 2); T.eq(cz, 1)
end)

T.test("cell_of: границы клетки", function()
    local cx = grid.cell_of(2.99, 0)
    T.eq(cx, 0)
    cx = grid.cell_of(3, 0)
    T.eq(cx, 1)
end)

T.test("cell_of: отрицательные координаты считаются через floor", function()
    local cx, cz = grid.cell_of(-0.5, -3)
    T.eq(cx, -1); T.eq(cz, -1)
end)

T.test("make_cell: level по умолчанию 0", function()
    local c = grid.make_cell(6, 6)
    T.eq(c.cx, 2); T.eq(c.cz, 2); T.eq(c.level, 0)
end)

T.test("center_of: центр клетки", function()
    local x, z = grid.center_of(0, 0)
    T.eq(x, 1.5); T.eq(z, 1.5)
    x, z = grid.center_of(-1, 2)
    T.eq(x, -1.5); T.eq(z, 7.5)
end)

T.test("blocks_of: девять блоков клетки при CELL_SIZE = 3", function()
    local b = grid.blocks_of(-1, 0)
    T.eq(#b, 9)
    T.eq(b[1][1], -3); T.eq(b[1][2], 0)
    T.eq(b[9][1], -1); T.eq(b[9][2], 2)
end)

T.test("blocks_of и cell_of согласованы", function()
    for _, blk in ipairs(grid.blocks_of(3, -2)) do
        local cx, cz = grid.cell_of(blk[1], blk[2])
        T.eq(cx, 3); T.eq(cz, -2)
    end
end)

T.test("neighbors4: четыре соседа на том же уровне", function()
    local n = grid.neighbors4({ cx = 0, cz = 0, level = 1 })
    T.eq(#n, 4)
    for _, c in ipairs(n) do T.eq(c.level, 1) end
end)

T.test("key: строка клетки", function()
    T.eq(grid.key({ cx = 1, cz = -2, level = 0 }), "1:-2:0")
    T.eq(grid.key({ cx = 1, cz = -2 }), "1:-2:0")
end)

T.test("distance: манхэттенское расстояние", function()
    local c1 = { cx = 2, cz = 3 }
    local c2 = { cx = -1, cz = 5 }
    T.eq(grid.distance(c1, c2), 3 + 2)
    T.eq(grid.distance(c1, c1), 0)
end)

T.test("reachable_cells: дефолтный радиус 5 без старта", function()
    local start = { cx = 0, cz = 0, level = 0 }
    local cells = grid.reachable_cells(start)
    T.eq(#cells, 60)
    for _, c in ipairs(cells) do
        local dist = grid.distance(start, c)
        T.truthy(dist >= 1 and dist <= 5)
        T.eq(c.level, 0)
    end
end)

T.test("reachable_cells: с включением стартовой клетки", function()
    local start = { cx = 2, cz = -3, level = 1 }
    local cells = grid.reachable_cells(start, 2, true)
    -- R=2: 1 + 2*2*3 = 13
    T.eq(#cells, 13)
    local found_start = false
    for _, c in ipairs(cells) do
        if c.cx == start.cx and c.cz == start.cz then
            found_start = true
        end
        T.truthy(grid.distance(start, c) <= 2)
        T.eq(c.level, 1)
    end
    T.truthy(found_start)
end)

T.test("build_path: сначала по X, затем по Z", function()
    local start = { cx = 0, cz = 0, level = 0 }
    local target = { cx = 2, cz = -1, level = 0 }
    local path = grid.build_path(start, target)
    T.eq(#path, 3)
    T.eq(path[1].cx, 1); T.eq(path[1].cz, 0)
    T.eq(path[2].cx, 2); T.eq(path[2].cz, 0)
    T.eq(path[3].cx, 2); T.eq(path[3].cz, -1)
end)

T.test("build_path: та же клетка дает пустой путь", function()
    local c = { cx = 5, cz = 5, level = 0 }
    local path = grid.build_path(c, c)
    T.eq(#path, 0)
end)

T.test("build_path: отрицательные шаги и уровень", function()
    local start = { cx = 0, cz = 0, level = 2 }
    local target = { cx = -1, cz = 2, level = 2 }
    local path = grid.build_path(start, target)
    T.eq(#path, 3)
    T.eq(path[1].cx, -1); T.eq(path[1].cz, 0); T.eq(path[1].level, 2)
    T.eq(path[2].cx, -1); T.eq(path[2].cz, 1); T.eq(path[2].level, 2)
    T.eq(path[3].cx, -1); T.eq(path[3].cz, 2); T.eq(path[3].level, 2)
end)

