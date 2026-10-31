-- tests/picking_test.lua
-- Тесты модуля client/picking

local T = require("lib")
local mock = require("engine_mock")

mock.install(_G)

local picking = require("client/picking")
local grid = require("core/grid")

local function approx_eq(a, b, eps, msg)
    eps = eps or 1e-4
    if math.abs(a - b) > eps then
        error(string.format("%s: ожидалось ~%f, получено %f (дельта %f > %f)",
            msg or "approx_eq", b, a, math.abs(a - b), eps), 2)
    end
end

local function make_mock_cam(opts)
    opts = opts or {}
    local persp = true
    if opts.perspective ~= nil then
        persp = opts.perspective
    end
    local cam_state = {
        pos = opts.pos or { 0, 10, 0 },
        front = opts.front or { 0, -1, 0 },
        right = opts.right or { 1, 0, 0 },
        up = opts.up or { 0, 0, -1 },
        fov = opts.fov or 60.0,
        zoom = opts.zoom or 1.0,
        perspective = persp,
        flipped = opts.flipped or false,
    }
    return {
        get_pos = function(_) return cam_state.pos end,
        get_front = function(_) return cam_state.front end,
        get_right = function(_) return cam_state.right end,
        get_up = function(_) return cam_state.up end,
        get_fov = function(_) return cam_state.fov end,
        get_zoom = function(_) return cam_state.zoom end,
        is_perspective = function(_) return cam_state.perspective end,
        is_flipped = function(_) return cam_state.flipped end,
    }
end

T.test("picking: screen_to_ray в центре экрана (ndc = 0, 0)", function()
    mock.reset()
    local cam = make_mock_cam({
        pos = { 0, 10, 0 },
        front = { 0, -1, 0 },
        right = { 1, 0, 0 },
        up = { 0, 0, -1 },
        fov = 60.0,
        zoom = 1.0,
        perspective = true,
    })
    mock.override("gui.get_viewport", function() return { 1920, 1080 } end)
    mock.override("cameras.get", function(name)
        if name == "vtt:tactical" then return cam end
        return nil
    end)

    -- Экранный центр: 1920/2 = 960, 1080/2 = 540
    local origin, dir = picking.screen_to_ray(960, 540)

    T.eq(origin[1], 0)
    T.eq(origin[2], 10)
    T.eq(origin[3], 0)

    approx_eq(dir[1], 0, 1e-4, "dir.x в центре")
    approx_eq(dir[2], -1, 1e-4, "dir.y в центре")
    approx_eq(dir[3], 0, 1e-4, "dir.z в центре")
end)

T.test("picking: screen_to_ray по четырём углам экрана", function()
    mock.reset()
    local cam = make_mock_cam({
        pos = { 0, 10, 0 },
        front = { 0, -1, 0 },
        right = { 1, 0, 0 },
        up = { 0, 0, -1 },
        fov = 60.0,
        zoom = 1.0,
        perspective = true,
    })
    mock.override("gui.get_viewport", function() return { 1920, 1080 } end)
    mock.override("cameras.get", function(name)
        if name == "vtt:tactical" then return cam end
        return nil
    end)

    local corners = {
        { name = "top-left",     x = 0,    y = 0,    sign_x = -1, sign_z = -1 },
        { name = "top-right",    x = 1920, y = 0,    sign_x = 1,  sign_z = -1 },
        { name = "bottom-left",  x = 0,    y = 1080, sign_x = -1, sign_z = 1 },
        { name = "bottom-right", x = 1920, y = 1080, sign_x = 1,  sign_z = 1 },
    }

    for _, c in ipairs(corners) do
        local origin, dir = picking.screen_to_ray(c.x, c.y)
        T.eq(origin[1], 0)
        T.eq(origin[2], 10)
        T.eq(origin[3], 0)

        -- Длина вектора направления должна быть строго 1.0 (нормализован)
        local len = math.sqrt(dir[1]*dir[1] + dir[2]*dir[2] + dir[3]*dir[3])
        approx_eq(len, 1.0, 1e-4, c.name .. " длина луча")

        -- Направление должно смотреть вниз по Y
        T.truthy(dir[2] < 0, c.name .. " dir.y < 0")

        -- Проверяем знаки отклонений по осям X и Z
        if c.sign_x > 0 then
            T.truthy(dir[1] > 0, c.name .. " dir.x должен быть > 0")
        else
            T.truthy(dir[1] < 0, c.name .. " dir.x должен быть < 0")
        end

        if c.sign_z > 0 then
            T.truthy(dir[3] > 0, c.name .. " dir.z должен быть > 0")
        else
            T.truthy(dir[3] < 0, c.name .. " dir.z должен быть < 0")
        end
    end
end)

T.test("picking: screen_to_ray fallback на камеру 'tactical' если 'vtt:tactical' отсутствует", function()
    mock.reset()
    local fallback_cam = make_mock_cam({ pos = { 5, 20, 5 } })
    mock.override("gui.get_viewport", function() return { 800, 600 } end)
    mock.override("cameras.get", function(name)
        if name == "tactical" then return fallback_cam end
        return nil
    end)

    local origin, _ = picking.screen_to_ray(400, 300)
    T.eq(origin[1], 5)
    T.eq(origin[2], 20)
    T.eq(origin[3], 5)
end)

T.test("picking: screen_to_ray безопасный возврат при отсутствии камеры или вьюпорта", function()
    mock.reset()
    mock.override("gui.get_viewport", function() return { 0, 0 } end)
    local origin, dir = picking.screen_to_ray(10, 10)
    T.truthy(origin ~= nil)
    T.truthy(dir ~= nil)

    mock.override("gui.get_viewport", function() return { 800, 600 } end)
    mock.override("cameras.get", function(_) return nil end)
    origin, dir = picking.screen_to_ray(10, 10)
    T.truthy(origin ~= nil)
    T.truthy(dir ~= nil)
end)

T.test("picking: screen_to_ray в перспективном режиме масштабирует угол луча от effective_fov = fov * zoom", function()
    mock.reset()
    local cam1 = make_mock_cam({
        pos = { 0, 16, 12 },
        front = { 0, -0.8, -0.6 },
        right = { 1, 0, 0 },
        up = { 0, 0.6, -0.8 },
        fov = 45.0,
        zoom = 1.0,
        perspective = true,
    })
    local cam2 = make_mock_cam({
        pos = { 0, 32, 24 },
        front = { 0, -0.8, -0.6 },
        right = { 1, 0, 0 },
        up = { 0, 0.6, -0.8 },
        fov = 45.0,
        zoom = 2.0,
        perspective = true,
    })
    mock.override("gui.get_viewport", function() return { 1920, 1080 } end)

    -- В центре экрана луч всегда совпадает с front независимо от зума
    mock.override("cameras.get", function() return cam1 end)
    local _, center_dir1 = picking.screen_to_ray(960, 540)
    mock.override("cameras.get", function() return cam2 end)
    local _, center_dir2 = picking.screen_to_ray(960, 540)

    approx_eq(center_dir1[1], center_dir2[1], 1e-4, "center dir.x одинаков")
    approx_eq(center_dir1[2], center_dir2[2], 1e-4, "center dir.y одинаков")
    approx_eq(center_dir1[3], center_dir2[3], 1e-4, "center dir.z одинаков")

    -- На краю экрана угол луча расширяется пропорционально effective_fov = fov * zoom
    mock.override("cameras.get", function() return cam1 end)
    local _, dir1 = picking.screen_to_ray(1920, 540)
    mock.override("cameras.get", function() return cam2 end)
    local _, dir2 = picking.screen_to_ray(1920, 540)

    T.truthy(dir2[1] > dir1[1], "dir.x при zoom=2.0 шире чем при zoom=1.0 согласно проекции движка")
end)

T.test("picking: screen_to_ray в ортографическом режиме", function()
    mock.reset()
    local cam = make_mock_cam({
        pos = { 0, 15, 0 },
        front = { 0, -1, 0 },
        right = { 1, 0, 0 },
        up = { 0, 0, -1 },
        fov = 40.0,
        zoom = 2.0,
        perspective = false,
    })
    mock.override("gui.get_viewport", function() return { 1000, 1000 } end)
    mock.override("cameras.get", function(name) return cam end)

    -- В центре (500, 500): origin = pos, dir = front
    local origin_c, dir_c = picking.screen_to_ray(500, 500)
    approx_eq(origin_c[1], 0, 1e-4)
    approx_eq(origin_c[3], 0, 1e-4)
    approx_eq(dir_c[2], -1, 1e-4)

    -- В углу (1000, 500): смещение по X вправо, направление параллельно front
    local origin_r, dir_r = picking.screen_to_ray(1000, 500)
    T.truthy(origin_r[1] > 0, "ортографический origin.x смещен вправо")
    approx_eq(dir_r[1], 0, 1e-4, "ортографический dir.x параллелен")
    approx_eq(dir_r[2], -1, 1e-4, "ортографический dir.y параллелен")
end)

T.test("picking: get_cursor_cell успешный луч и перевод разных bx, bz через grid.cell_of", function()
    mock.reset()
    local cam = make_mock_cam({ pos = { 0, 10, 0 } })
    mock.override("gui.get_viewport", function() return { 1920, 1080 } end)
    mock.override("cameras.get", function(_) return cam end)
    -- Мышь возвращает таблицу {int, int} по libinput.md:55
    mock.override("input.get_mouse_pos", function() return { 960, 540 } end)

    local test_coords = {
        { bx = 0,  bz = 0,  expected_cx = 0,  expected_cz = 0 },
        { bx = 1,  bz = 1,  expected_cx = 0,  expected_cz = 0 },
        { bx = 3,  bz = 4,  expected_cx = 1,  expected_cz = 1 },
        { bx = 6,  bz = -2, expected_cx = 2,  expected_cz = -1 },
        { bx = -1, bz = -1, expected_cx = -1, expected_cz = -1 },
        { bx = -4, bz = 6,  expected_cx = -2, expected_cz = 2 },
    }

    local raycast_called = false
    local raycast_dist = 0

    for _, tc in ipairs(test_coords) do
        mock.override("block.raycast", function(start, dir, max_dist)
            raycast_called = true
            raycast_dist = max_dist
            return {
                block = 1,
                endpoint = { tc.bx + 0.5, 0, tc.bz + 0.5 },
                iendpoint = { tc.bx, 0, tc.bz },
                length = 10,
                normal = { 0, 1, 0 },
            }
        end)

        local cell = picking.get_cursor_cell()
        T.truthy(cell ~= nil, "cell не должна быть nil")
        T.eq(cell.cx, tc.expected_cx, "cell.cx для bx=" .. tc.bx)
        T.eq(cell.cz, tc.expected_cz, "cell.cz для bz=" .. tc.bz)
        T.eq(cell.level, 0, "cell.level в MVP-0 равен 0")
    end

    T.truthy(raycast_called, "block.raycast был вызван")
    T.eq(raycast_dist, 128.0, "block.raycast вызван с max_distance 128.0")
end)

T.test("picking: get_cursor_cell динамически зависит от grid.cell_of и CELL_SIZE", function()
    mock.reset()
    local cam = make_mock_cam()
    mock.override("gui.get_viewport", function() return { 800, 600 } end)
    mock.override("cameras.get", function(_) return cam end)
    mock.override("input.get_mouse_pos", function() return { 400, 300 } end)
    mock.override("block.raycast", function()
        return { iendpoint = { 8, 0, 12 } }
    end)

    -- Стандартный размер клетки = 3 (8/3=2, 12/3=4)
    local cell1 = picking.get_cursor_cell()
    T.eq(cell1.cx, 2)
    T.eq(cell1.cz, 4)

    -- Временно меняем CELL_SIZE для проверки, что масштаб сетки не захардкожен
    local old_size = grid.CELL_SIZE
    grid.CELL_SIZE = 4
    local cell2 = picking.get_cursor_cell()
    grid.CELL_SIZE = old_size

    -- При CELL_SIZE = 4: 8/4 = 2, 12/4 = 3
    T.eq(cell2.cx, 2)
    T.eq(cell2.cz, 3)
end)

T.test("picking: get_cursor_cell возврат nil при промахе луча", function()
    mock.reset()
    local cam = make_mock_cam()
    mock.override("gui.get_viewport", function() return { 800, 600 } end)
    mock.override("cameras.get", function(_) return cam end)
    mock.override("input.get_mouse_pos", function() return { 100, 100 } end)

    -- Случай 1: raycast возвращает nil
    mock.override("block.raycast", function() return nil end)
    local cell1 = picking.get_cursor_cell()
    T.eq(cell1, nil)

    -- Случай 2: raycast возвращает результат без iendpoint
    mock.override("block.raycast", function() return { block = 0 } end)
    local cell2 = picking.get_cursor_cell()
    T.eq(cell2, nil)
end)

T.test("picking: get_cursor_cell возврат nil если позиция мыши недоступна", function()
    mock.reset()
    mock.override("input.get_mouse_pos", function() return nil end)
    local cell = picking.get_cursor_cell()
    T.eq(cell, nil)
end)

T.test("picking: get_cursor_token успешное определение токена под курсором с ignore_uid", function()
    mock.reset()
    local cam = make_mock_cam()
    mock.override("gui.get_viewport", function() return { 1920, 1080 } end)
    mock.override("cameras.get", function(_) return cam end)
    mock.override("input.get_mouse_pos", function() return { 960, 540 } end)
    mock.override("hud.get_player", function() return 2 end)
    mock.override("player.get_entity", function(pid)
        if pid == 2 then return 42 end
        return -1
    end)

    local entities_raycast_called = false
    local entities_raycast_dist = 0
    local entities_raycast_ignore = nil
    mock.override("entities.raycast", function(start, dir, max_dist, ignore)
        entities_raycast_called = true
        entities_raycast_dist = max_dist
        entities_raycast_ignore = ignore
        return {
            entity = 777,
            endpoint = { 0, 1, 0 },
            length = 9,
        }
    end)

    local token = picking.get_cursor_token()
    T.truthy(entities_raycast_called, "entities.raycast был вызван")
    T.eq(entities_raycast_dist, 128.0, "entities.raycast вызван с max_distance 128.0")
    T.eq(entities_raycast_ignore, 42, "entities.raycast вызван с ignore_uid игрока")
    T.eq(token, 777, "возвращает числовой hit.entity")
end)

T.test("picking: get_cursor_token поддержка таблицы сущности", function()
    mock.reset()
    local cam = make_mock_cam()
    mock.override("gui.get_viewport", function() return { 1920, 1080 } end)
    mock.override("cameras.get", function(_) return cam end)
    mock.override("input.get_mouse_pos", function() return { 960, 540 } end)

    local ent_tbl = { uid = 999, name = "hero" }
    mock.override("entities.raycast", function()
        return { entity = ent_tbl }
    end)

    local token = picking.get_cursor_token()
    T.eq(token, ent_tbl, "возвращает таблицу сущности")
end)

T.test("picking: get_cursor_token возврат nil при промахе или отсутствии сущности", function()
    mock.reset()
    local cam = make_mock_cam()
    mock.override("gui.get_viewport", function() return { 800, 600 } end)
    mock.override("cameras.get", function(_) return cam end)
    mock.override("input.get_mouse_pos", function() return { 200, 200 } end)

    -- Промах (nil)
    mock.override("entities.raycast", function() return nil end)
    T.eq(picking.get_cursor_token(), nil)

    -- Попадание в блок, но не в сущность (поле entity отсутствует)
    mock.override("entities.raycast", function() return { block = 3 } end)
    T.eq(picking.get_cursor_token(), nil)

    -- Позиция мыши недоступна
    mock.override("input.get_mouse_pos", function() return nil end)
    T.eq(picking.get_cursor_token(), nil)
end)
