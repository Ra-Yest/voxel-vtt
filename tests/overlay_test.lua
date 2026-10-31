-- tests/overlay_test.lua
-- Тесты модуля client/overlay (краевые тайлы, маски, круглая сетка, приоритеты слоёв active > path > zone > grid)

local T = require("lib")
local mock = require("engine_mock")

mock.install(_G)

local overlay = require("client/overlay")
local grid = require("core/grid")

local wrapped = {}
local unwrap_calls = {}
local set_faces_calls = {}
local set_tints_calls = {}
local wrap_seq = 1

local function reset_wrap_state()
    wrapped = {}
    unwrap_calls = {}
    set_faces_calls = {}
    set_tints_calls = {}
    wrap_seq = 1

    local wrap_fn = function(pos, texture, emission)
        local id = wrap_seq
        wrap_seq = wrap_seq + 1
        wrapped[id] = {
            id = id,
            pos = { pos[1], pos[2], pos[3] },
            texture = texture,
            emission = emission or 1.0,
            faces = nil,
            tints = nil,
        }
        return id
    end

    local unwrap_fn = function(id)
        unwrap_calls[#unwrap_calls + 1] = id
        wrapped[id] = nil
    end

    local set_faces_fn = function(id, f1, f2, f3, f4, f5, f6)
        set_faces_calls[#set_faces_calls + 1] = { id = id, faces = { f1, f2, f3, f4, f5, f6 } }
        if wrapped[id] then
            wrapped[id].faces = { f1, f2, f3, f4, f5, f6 }
        end
    end

    local set_tints_fn = function(id, f1, f2, f3, f4, f5, f6)
        set_tints_calls[#set_tints_calls + 1] = { id = id, tints = { f1, f2, f3, f4, f5, f6 } }
        if wrapped[id] then
            wrapped[id].tints = { f1, f2, f3, f4, f5, f6 }
        end
    end

    local wraps_lib = {
        wrap = wrap_fn,
        unwrap = unwrap_fn,
        set_faces = set_faces_fn,
        set_tints = set_tints_fn,
    }
    mock.override("gfx.blockwraps", wraps_lib)
    mock.override("gfx.blockwraps.wrap", wrap_fn)
    mock.override("gfx.blockwraps.unwrap", unwrap_fn)
    mock.override("gfx.blockwraps.set_faces", set_faces_fn)
    mock.override("gfx.blockwraps.set_tints", set_tints_fn)

    overlay.clear_all()
    unwrap_calls = {}
end

T.test("overlay: get_block_edge_mask вычисляет правильные маски с учётом 180° UV развёртки", function()
    -- Для клетки 2x2:
    -- С учётом 180° развёртки UV на грани +Y VoxelCore:
    -- (0, 0) внешние границы North + West -> текстурные биты Bottom (4) + Right (2) = 6
    -- (1, 0) внешние границы North + East -> текстурные биты Bottom (4) + Left (8) = 12
    -- (0, 1) внешние границы South + West -> текстурные биты Top (1) + Right (2) = 3
    -- (1, 1) внешние границы South + East -> текстурные биты Top (1) + Left (8) = 9
    T.eq(overlay.get_block_edge_mask(0, 0, 2), 6, "угол (0,0) при s=2")
    T.eq(overlay.get_block_edge_mask(1, 0, 2), 12, "угол (1,0) при s=2")
    T.eq(overlay.get_block_edge_mask(0, 1, 2), 3, "угол (0,1) при s=2")
    T.eq(overlay.get_block_edge_mask(1, 1, 2), 9, "угол (1,1) при s=2")

    -- Для клетки 3x3:
    -- (1, 1) центральный блок без внешних границ
    T.eq(overlay.get_block_edge_mask(1, 1, 3), 0, "центральный блок (1,1) при s=3 имеет mask=0")
    T.eq(overlay.get_block_edge_mask(0, 0, 3), 6, "угол (0,0) при s=3")
    T.eq(overlay.get_block_edge_mask(1, 0, 3), 4, "северный край (1,0) при s=3")
    T.eq(overlay.get_block_edge_mask(2, 0, 3), 12, "угол (2,0) при s=3")
    T.eq(overlay.get_block_edge_mask(0, 1, 3), 2, "западный край (0,1) при s=3")
    T.eq(overlay.get_block_edge_mask(2, 1, 3), 8, "восточный край (2,1) при s=3")
    T.eq(overlay.get_block_edge_mask(0, 2, 3), 3, "угол (0,2) при s=3")
    T.eq(overlay.get_block_edge_mask(1, 2, 3), 1, "южный край (1,2) при s=3")
    T.eq(overlay.get_block_edge_mask(2, 2, 3), 9, "угол (2,2) при s=3")

    -- Для клетки 1x1: все 4 грани внешние (4+8+1+2 = 15)
    T.eq(overlay.get_block_edge_mask(0, 0, 1), 15, "одиночный блок s=1 имеет mask=15")
end)

T.test("overlay: find_surface_y возвращает высоту из block.raycast или DEFAULT_Y", function()
    mock.reset()
    reset_wrap_state()

    local raycast_args
    mock.override("block.raycast", function(start, dir, dist)
        raycast_args = { start = start, dir = dir, dist = dist }
        return {
            iendpoint = { 10, 64, 20 },
        }
    end)

    local y = overlay.find_surface_y(10, 20)
    T.eq(y, 64, "высота должна быть взята из hit.iendpoint[2]")
    T.eq(raycast_args.start[1], 10.5, "рейкаст из центра блока X")
    T.eq(raycast_args.start[2], overlay.RAYCAST_START_Y, "рейкаст с вершины мира Y")
    T.eq(raycast_args.start[3], 20.5, "рейкаст из центра блока Z")
    T.eq(raycast_args.dir[2], -1, "направление строго вниз")
    T.eq(raycast_args.dist, overlay.RAYCAST_DIST, "дистанция рейкаста")

    -- Промах рейкаста: возвращает DEFAULT_Y = 0
    mock.override("block.raycast", function() return nil end)
    local fallback_y = overlay.find_surface_y(5, 5)
    T.eq(fallback_y, overlay.DEFAULT_Y, "при промахе возвращает DEFAULT_Y")
end)

T.test("overlay: find_surface_y спускается сквозь неполные блоки (трава, факелы) до твердого основания", function()
    mock.reset()
    reset_wrap_state()

    mock.override("block.raycast", function()
        return {
            iendpoint = { 10, 65, 20 },
        }
    end)
    mock.override("block.is_solid_at", function(x, y, z)
        if y == 65 then return false end
        if y == 64 then return true end
        return false
    end)
    mock.override("block.is_replaceable_at", function(x, y, z)
        if y == 65 then return true end
        return false
    end)

    local y = overlay.find_surface_y(10, 20)
    T.eq(y, 64, "высота должна спуститься с травы (65) на твердый блок земли (64)")
end)

T.test("overlay: highlight_cell создаёт обёртки с set_faces (только +Y) и set_tints (жёлтый color_id=1)", function()
    mock.reset()
    reset_wrap_state()

    mock.override("block.raycast", function(start)
        local bx = math.floor(start[1])
        return {
            iendpoint = { bx, 10 + bx, math.floor(start[3]) },
        }
    end)

    -- Стандартный CELL_SIZE = 3 -> 9 блоков
    overlay.highlight_cell(0, 0, 1)

    local k = grid.key({ cx = 0, cz = 0, level = 0 })
    local ids = overlay.active_wraps[k]
    T.truthy(ids ~= nil, "обёртки сохранены в active_wraps")
    T.eq(#ids, 9, "ровно 9 обёрток для клетки 3x3")

    for _, id in ipairs(ids) do
        local w = wrapped[id]
        T.truthy(w ~= nil, "обёртка зарегистрирована в движке")
        T.eq(w.pos[2], 10 + w.pos[1], "высота Y соответствует рельефу")

        -- Проверка set_faces: только 4-я грань (+Y) включена, остальные nil
        T.truthy(w.faces ~= nil, "set_faces был вызван")
        T.eq(w.faces[1], nil, "грань 1 (-X) отключена")
        T.eq(w.faces[2], nil, "грань 2 (+X) отключена")
        T.eq(w.faces[3], nil, "грань 3 (-Y) отключена")
        T.truthy(w.faces[4] ~= nil and w.faces[4]:find("blocks:cell_edge_"), "грань 4 (+Y) активна")
        T.eq(w.faces[5], nil, "грань 5 (-Z) отключена")
        T.eq(w.faces[6], nil, "грань 6 (+Z) отключена")

        -- Проверка set_tints: жёлтый цвет (color_id = 1) на грани 4 (+Y)
        T.truthy(w.tints ~= nil, "set_tints был вызван")
        T.eq(w.tints[1], nil)
        T.eq(w.tints[2], nil)
        T.eq(w.tints[3], nil)
        T.truthy(w.tints[4] ~= nil, "тинт грани 4 (+Y) задан")
        T.eq(w.tints[4][1], overlay.TINTS[1][1], "R жёлтого тинта")
        T.eq(w.tints[4][2], overlay.TINTS[1][2], "G жёлтого тинта")
        T.eq(w.tints[4][3], overlay.TINTS[1][3], "B жёлтого тинта")
        T.eq(w.tints[5], nil)
        T.eq(w.tints[6], nil)
    end
end)

T.test("overlay: повторный highlight_cell вызывает unwrap для старых обёрток без утечки ID", function()
    mock.reset()
    reset_wrap_state()

    mock.override("block.raycast", function() return { iendpoint = { 0, 5, 0 } } end)

    overlay.highlight_cell(2, 3, 1)
    local k = grid.key({ cx = 2, cz = 3, level = 0 })
    local first_ids = {}
    for _, id in ipairs(overlay.active_wraps[k]) do first_ids[#first_ids + 1] = id end
    T.eq(#first_ids, 9, "9 обёрток при CELL_SIZE = 3")
    T.eq(#unwrap_calls, 0, "до повторного вызова unwrap не вызывался")

    -- Повторная подсветка той же клетки стилем 2
    overlay.highlight_cell(2, 3, 2)
    local second_ids = overlay.active_wraps[k]
    T.eq(#second_ids, 9)

    -- Проверяем, что все 9 старых ID были удалены через unwrap
    T.eq(#unwrap_calls, 9, "все старые 9 обёрток были очищены через unwrap")
    for _, id in ipairs(first_ids) do
        T.truthy(wrapped[id] == nil, "старый id " .. id .. " снят")
    end
    for _, id in ipairs(second_ids) do
        T.truthy(wrapped[id] ~= nil, "новый id " .. id .. " активен")
        T.eq(wrapped[id].tints[4][1], overlay.TINTS[2][1], "тинт обновлён на стиль 2")
    end

    -- clear_highlight снимает активные обёртки
    overlay.clear_highlight(2, 3)
    T.eq(#unwrap_calls, 18, "clear_highlight вызвал unwrap для второй партии")
    T.eq(overlay.active_wraps[k], nil, "ключ клетки удалён из active_wraps")
end)

T.test("overlay: highlight_cell корректно масштабируется при CELL_SIZE = 3, включая внутренний блок mask=0", function()
    mock.reset()
    reset_wrap_state()

    mock.override("block.raycast", function() return { iendpoint = { 0, 2, 0 } } end)

    overlay.highlight_cell(1, 1, 3)

    local k = grid.key({ cx = 1, cz = 1, level = 0 })
    local ids = overlay.active_wraps[k]
    T.eq(#ids, 9, "при CELL_SIZE = 3 создаётся ровно 9 обёрток")

    local found_center_mask = false
    for _, id in ipairs(ids) do
        if wrapped[id].texture == "blocks:cell_edge_0" then
            found_center_mask = true
        end
    end
    T.truthy(found_center_mask, "центральный блок клетки 3x3 обёрнут с cell_edge_0")
end)

T.test("overlay: set_grid_visible создаёт 4 угловых маркера (corner brackets) на клетку", function()
    mock.reset()
    reset_wrap_state()

    local cam = {
        get_pos = function() return { 0, 20, 0 } end,
        get_front = function() return { 0, -1, 0 } end,
    }
    mock.override("cameras.get", function(name)
        if name == "vtt:tactical" then return cam end
        return nil
    end)
    -- Высота зависит от X для проверки уступов рельефа: bx == 0 -> y=10, bx > 0 -> y=12
    mock.override("block.raycast", function(start)
        local bx = math.floor(start[1])
        local bz = math.floor(start[3])
        local y = (bx == 0) and 10 or 12
        return { iendpoint = { bx, y, bz } }
    end)

    -- Включение сетки (r = 8, круговой фильтр dcx^2 + dcz^2 <= 64, 197 клеток)
    overlay.set_grid_visible(true)
    T.eq(overlay.grid_visible, true)

    -- В круге радиуса 8 ровно 197 клеток. Каждая клетка имеет ровно 4 угловых маркера -> 197 * 4 = 788 обёрток
    T.eq(#overlay.grid_wraps, 197 * 4, "число обёрток круглой сетки равно 788 (197 клеток по 4 уголка)")

    -- Проверяем, что угловая клетка квадрата (8, 8) отсечена круговым радиусом (8^2 + 8^2 = 128 > 64)
    local corner_found = false
    for _, wid in ipairs(overlay.grid_wraps) do
        local pos = wrapped[wid].pos
        local cx, cz = grid.cell_of(pos[1], pos[3])
        if cx == 8 and cz == 8 then
            corner_found = true
        end
    end
    T.truthy(not corner_found, "угловая клетка (8, 8) отсечена круговым фильтром")

    -- Проверяем, что для клетки (0, 0) при CELL_SIZE = 3 созданы именно 4 уголка с правильными текстурами и высотами
    local cell0_wraps = {}
    for _, wid in ipairs(overlay.grid_wraps) do
        local w = wrapped[wid]
        local cx, cz = grid.cell_of(w.pos[1], w.pos[3])
        if cx == 0 and cz == 0 then
            cell0_wraps[w.texture] = w
        end
    end

    T.truthy(cell0_wraps["blocks:bracket_nw"] ~= nil, "NW маркер создан")
    T.truthy(cell0_wraps["blocks:bracket_ne"] ~= nil, "NE маркер создан")
    T.truthy(cell0_wraps["blocks:bracket_sw"] ~= nil, "SW маркер создан")
    T.truthy(cell0_wraps["blocks:bracket_se"] ~= nil, "SE маркер создан")

    -- Проверка уступа рельефа: угол на bx=0 встал на y=10, угол на bx=s-1 (2) встал на y=12
    T.eq(cell0_wraps["blocks:bracket_nw"].pos[2], 10, "NW угол на нижней ступеньке y=10")
    T.eq(cell0_wraps["blocks:bracket_ne"].pos[2], 12, "NE угол на верхней ступеньке y=12")
    T.eq(cell0_wraps["blocks:bracket_sw"].pos[2], 10, "SW угол на нижней ступеньке y=10")
    T.eq(cell0_wraps["blocks:bracket_se"].pos[2], 12, "SE угол на верхней ступеньке y=12")

    -- Проверка set_faces и set_tints: только грань 4 (+Y) активна, цвет {0.85, 0.85, 0.85}
    for _, w in pairs(cell0_wraps) do
        T.eq(w.faces[1], nil)
        T.eq(w.faces[2], nil)
        T.eq(w.faces[3], nil)
        T.truthy(w.faces[4] ~= nil and w.faces[4]:find("blocks:bracket_"))
        T.eq(w.faces[5], nil)
        T.eq(w.faces[6], nil)
        T.eq(w.tints[4][1], overlay.TINTS.grid[1])
        T.eq(w.tints[4][2], overlay.TINTS.grid[2])
        T.eq(w.tints[4][3], overlay.TINTS.grid[3])
    end

    -- Проверяем работу при CELL_SIZE = 2 (по требованию спеки)
    overlay.set_grid_visible(false)
    T.eq(#overlay.grid_wraps, 0)

    local old_size = grid.CELL_SIZE
    grid.CELL_SIZE = 2
    overlay.set_grid_visible(true)
    grid.CELL_SIZE = old_size

    T.eq(#overlay.grid_wraps, 197 * 4, "при CELL_SIZE = 2 создаётся ровно 4 обёртки-уголка на клетку (197 * 4 = 788)")

    -- Выключение сетки
    overlay.set_grid_visible(false)
    T.eq(#overlay.grid_wraps, 0)
    T.eq(overlay.grid_visible, false)
end)

T.test("overlay: preview_path создаёт обёртки в слое path_wraps с зелёным тинтом", function()
    mock.reset()
    reset_wrap_state()

    mock.override("block.raycast", function() return { iendpoint = { 0, 0, 0 } } end)

    local path1 = {
        { cx = 0, cz = 0 },
        { cx = 1, cz = 0 },
    }

    overlay.preview_path(path1)
    T.eq(#overlay.path_cells, 2, "2 клетки в path1")
    T.eq(#overlay.path_wraps, 8, "8 обёрток в слое path_wraps для 2 клеток по 4 уголка (2 * 4)")
    T.eq(next(overlay.active_wraps), nil, "active_wraps не затронут")
    T.eq(#overlay.zone_wraps, 0, "zone_wraps не затронут")

    -- Проверяем зелёный цвет пути и текстуру длинных уголков
    for _, wid in ipairs(overlay.path_wraps) do
        local w = wrapped[wid]
        T.eq(w.tints[4][1], overlay.TINTS[2][1], "зелёный тинт пути R")
        T.truthy(w.texture:find("blocks:bracket_long_"), "текстура пути использует длинный уголок blocks:bracket_long_*")
        T.eq(w.faces[4], w.texture, "грань +Y установлена")
    end

    -- preview_path(nil) очищает путь
    overlay.preview_path(nil)
    T.eq(#overlay.path_cells, 0)
    T.eq(#overlay.path_wraps, 0)
end)

T.test("overlay: show_zone и clear_zone управляют слоем zone_wraps с голубым тинтом", function()
    mock.reset()
    reset_wrap_state()

    mock.override("block.raycast", function() return { iendpoint = { 0, 0, 0 } } end)

    local zone = {
        { cx = 3, cz = 3 },
        { cx = 3, cz = 4 },
        { cx = 4, cz = 3 },
    }

    overlay.show_zone(zone)
    T.eq(#overlay.zone_wraps, 12, "12 обёрток в слое zone_wraps для 3 клеток по 4 уголка (3 * 4)")
    T.eq(next(overlay.active_wraps), nil, "active_wraps не затронут")
    T.eq(#overlay.path_wraps, 0, "path_wraps не затронут")

    -- Проверяем голубой цвет зоны (color_id = 3) и текстуру длинных уголков
    for _, wid in ipairs(overlay.zone_wraps) do
        local w = wrapped[wid]
        T.eq(w.tints[4][1], overlay.TINTS[3][1], "голубой тинт зоны R")
        T.truthy(w.texture:find("blocks:bracket_long_"), "текстура зоны использует длинный уголок blocks:bracket_long_*")
        T.eq(w.faces[4], w.texture, "грань +Y установлена")
    end

    -- clear_zone снимает обёртки
    overlay.clear_zone()
    T.eq(#overlay.zone_wraps, 0, "zone_wraps очищен")
    T.eq(#unwrap_calls, 12, "все 12 обёрток зоны сняты")
end)

T.test("overlay: иерархия приоритетов active > path > zone > grid и динамическое восстановление слоёв", function()
    mock.reset()
    reset_wrap_state()

    mock.override("block.raycast", function(start)
        return { iendpoint = { math.floor(start[1]), 0, math.floor(start[3]) } }
    end)
    local cam = {
        get_pos = function() return { 0, 20, 0 } end,
        get_front = function() return { 0, -1, 0 } end,
    }
    mock.override("cameras.get", function() return cam end)

    -- 1. Включаем базовую сетку (grid, низший приоритет 1)
    overlay.set_grid_visible(true)
    T.eq(overlay.get_cell_layer(1, 1), "grid", "клетка (1,1) изначально отображается сеткой grid")

    -- 2. Включаем зону перемещения токена на (1, 1): zone > grid (приоритет 2 > 1)
    overlay.show_zone({ { cx = 1, cz = 1 } }, 3)
    T.eq(overlay.get_cell_layer(1, 1), "zone", "zone перекрывает grid на клетке (1,1)")
    local k = grid.key({ cx = 1, cz = 1, level = 0 })
    T.truthy(overlay.rendered_cells[k] ~= nil, "клетка отрендерена")
    T.eq(#overlay.zone_wraps, 4, "зона отрисована 4 уголками")

    -- 3. Включаем превью пути через (1, 1): path > zone (приоритет 3 > 2)
    overlay.preview_path({ { cx = 1, cz = 1 } })
    T.eq(overlay.get_cell_layer(1, 1), "path", "path перекрывает zone на клетке (1,1)")
    T.eq(#overlay.path_wraps, 4, "путь отрисован 4 уголками")

    -- 4. Наводим курсор мыши на (1, 1): active > path (приоритет 4 > 3, наивысший)
    overlay.highlight_cell(1, 1, 1)
    T.eq(overlay.get_cell_layer(1, 1), "active", "active курсор имеет высший приоритет над path")
    T.eq(#overlay.active_wraps[k], 9, "курсор отрисован на 9 блоках")

    -- 5. Курсор уходит с клетки (1, 1): active снят -> восстанавливается path (приоритет 3)
    overlay.clear_highlight(1, 1)
    T.eq(overlay.active_wraps[k], nil, "active снят")
    T.eq(overlay.get_cell_layer(1, 1), "path", "восстановлен path после ухода курсора")
    T.eq(#overlay.path_wraps, 4, "обёртки пути восстановлены (4 уголка)")

    -- 6. Очищаем путь: path снят -> восстанавливается zone (приоритет 2)
    overlay.clear_path()
    T.eq(overlay.get_cell_layer(1, 1), "zone", "восстановлен zone после очистки пути")
    T.eq(#overlay.zone_wraps, 4, "обёртки зоны восстановлены (4 уголка)")

    -- 7. Очищаем зону: zone снята -> восстанавливается базовая сетка grid (приоритет 1)
    overlay.clear_zone()
    T.eq(overlay.get_cell_layer(1, 1), "grid", "восстановлена сетка grid после очистки зоны")

    -- 8. Выключаем базовую сетку: никаких обёрток на клетке не остаётся
    overlay.set_grid_visible(false)
    T.eq(overlay.get_cell_layer(1, 1), nil, "клетка не имеет активных обёрток после выключения сетки")
end)

T.test("overlay: clear_all очищает все 4 слоя (active_wraps, path_wraps, zone_wraps, grid_wraps)", function()
    mock.reset()
    reset_wrap_state()

    mock.override("block.raycast", function(start)
        return { iendpoint = { math.floor(start[1]), 1, math.floor(start[3]) } }
    end)
    local cam = {
        get_pos = function() return { 0, 20, 0 } end,
        get_front = function() return { 0, -1, 0 } end,
    }
    mock.override("cameras.get", function() return cam end)

    overlay.highlight_cell(0, 0, 1)
    overlay.preview_path({ { cx = 5, cz = 5 } })
    overlay.show_zone({ { cx = 3, cz = 3 } })
    overlay.set_grid_visible(true)

    T.truthy(next(overlay.active_wraps) ~= nil)
    T.truthy(#overlay.path_wraps > 0)
    T.truthy(#overlay.zone_wraps > 0)
    T.truthy(#overlay.grid_wraps > 0)
    T.eq(overlay.grid_visible, true)

    overlay.clear_all()

    T.truthy(next(overlay.active_wraps) == nil, "active_wraps пуста")
    T.eq(#overlay.path_wraps, 0, "path_wraps пуста")
    T.eq(#overlay.path_cells, 0, "path_cells пуста")
    T.eq(#overlay.zone_wraps, 0, "zone_wraps пуста")
    T.eq(#overlay.grid_wraps, 0, "grid_wraps пуста")
    T.eq(overlay.grid_visible, false, "grid_visible сброшен")
    T.truthy(next(wrapped) == nil, "все обёртки сняты из движка")
end)
