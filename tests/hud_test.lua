-- tests/hud_test.lua
-- Тесты интеграции HUD (скрипт vtt/scripts/hud.lua, управление подсветкой и сеткой)

local T = require("lib")
local mock = require("engine_mock")

mock.install(_G)

local camera = require("client/camera")
local picking = require("client/picking")
local overlay = require("client/overlay")
local grid = require("core/grid")

local function setup_hud_test()
    mock.reset()

    local fake_tactical = {
        get_index = function() return 7 end,
        get_name = function() return "vtt:tactical" end,
        set_pos = function() end,
        get_pos = function() return { 0, 10, 0 } end,
        set_zoom = function() end,
        get_zoom = function() return 1.0 end,
        set_fov = function() end,
        get_fov = function() return 45.0 end,
        is_perspective = function() return true end,
        set_perspective = function() end,
        look_at = function() end,
        get_front = function() return { 0, -1, 0 } end,
        get_right = function() return { 1, 0, 0 } end,
        get_up = function() return { 0, 0, -1 } end,
        is_flipped = function() return false end,
    }
    local fake_fp = {
        get_index = function() return 0 end,
        get_name = function() return "core:first-person" end,
    }

    mock.override("cameras.get", function(val)
        if val == "vtt:tactical" or val == "tactical" or val == 7 then return fake_tactical end
        if val == "core:first-person" or val == 0 then return fake_fp end
        return nil
    end)
    mock.override("player.get_camera", function() return 0 end)
    mock.override("player.get_pos", function() return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("input.get_bindings", function() return { "vtt.camera_toggle", "vtt.grid_toggle" } end)
    mock.override("time.delta", function() return 0.016 end)

    local wrap_seq = 1
    local wrapped = {}
    local wrap_fn = function(pos, texture, emission)
        local id = wrap_seq
        wrap_seq = wrap_seq + 1
        wrapped[id] = { pos = pos, texture = texture }
        return id
    end
    local unwrap_fn = function(id)
        wrapped[id] = nil
    end

    mock.override("gfx.blockwraps", {
        wrap = wrap_fn,
        unwrap = unwrap_fn,
    })
    mock.override("gfx.blockwraps.wrap", wrap_fn)
    mock.override("gfx.blockwraps.unwrap", unwrap_fn)
end

T.test("hud: on_hud_open регистрирует vtt.grid_toggle и переключает сетку", function()
    setup_hud_test()

    local callbacks = {}
    mock.override("input.add_callback", function(bind, cb)
        callbacks[bind] = cb
    end)

    local paused = false
    mock.override("hud.is_paused", function() return paused end)

    dofile("vtt/scripts/hud.lua")
    on_hud_open(1)

    T.truthy(callbacks["vtt.grid_toggle"] ~= nil, "callback vtt.grid_toggle зарегистрирован")

    camera.set_mode("tactical")
    overlay.set_grid_visible(false)
    T.eq(overlay.grid_visible, false)

    -- Нажатие G включает сетку
    callbacks["vtt.grid_toggle"]()
    T.eq(overlay.grid_visible, true, "сетка должна включиться")

    -- Повторное нажатие G выключает сетку
    callbacks["vtt.grid_toggle"]()
    T.eq(overlay.grid_visible, false, "сетка должна выключиться")

    -- При паузе переключение сетки блокируется
    paused = true
    callbacks["vtt.grid_toggle"]()
    T.eq(overlay.grid_visible, false, "в паузе сетка не переключается")
    paused = false

    -- В режиме first_person переключение сетки также блокируется
    camera.set_mode("first_person")
    callbacks["vtt.grid_toggle"]()
    T.eq(overlay.grid_visible, false, "в first_person сетка не переключается")
end)

T.test("hud: vtt.camera_toggle при переходе в first_person очищает все оверлеи (clear_all)", function()
    setup_hud_test()

    local callbacks = {}
    mock.override("input.add_callback", function(bind, cb)
        callbacks[bind] = cb
    end)
    mock.override("hud.is_paused", function() return false end)

    dofile("vtt/scripts/hud.lua")
    on_hud_open(1)

    camera.set_mode("tactical")
    overlay.set_grid_visible(true)
    overlay.highlight_cell(1, 1, 1)

    T.truthy(overlay.grid_visible, "сетка включена")
    T.truthy(next(overlay.active_wraps) ~= nil, "есть активные подсветки")

    -- Переключаем режим в first_person через биндинг
    callbacks["vtt.camera_toggle"]()
    T.eq(camera.get_mode(), "first_person")
    T.eq(overlay.grid_visible, false, "сетка очищена через clear_all")
    T.truthy(next(overlay.active_wraps) == nil, "все подсветки клеток сняты")
end)

T.test("hud: on_hud_render вызывает highlight_cell только при смене клетки (cx, cz)", function()
    setup_hud_test()

    mock.override("input.add_callback", function() end)
    mock.override("hud.is_paused", function() return false end)

    dofile("vtt/scripts/hud.lua")
    on_hud_open(1)
    camera.set_mode("tactical")

    local current_cursor_cell = { cx = 3, cz = 4, level = 0 }
    mock.override("input.get_mouse_pos", function() return { 500, 500 } end)
    mock.override("gui.get_viewport", function() return { 1000, 1000 } end)
    mock.override("block.raycast", function()
        return { iendpoint = { current_cursor_cell.cx * grid.CELL_SIZE, 0, current_cursor_cell.cz * grid.CELL_SIZE } }
    end)

    local highlight_calls = {}
    local clear_calls = {}

    local orig_highlight = overlay.highlight_cell
    local orig_clear = overlay.clear_highlight

    overlay.highlight_cell = function(cx, cz, color_id)
        highlight_calls[#highlight_calls + 1] = { cx = cx, cz = cz, color_id = color_id }
        orig_highlight(cx, cz, color_id)
    end

    overlay.clear_highlight = function(cx, cz)
        clear_calls[#clear_calls + 1] = { cx = cx, cz = cz }
        orig_clear(cx, cz)
    end

    -- Кадр 1: наведение на клетку (3, 4)
    on_hud_render()
    T.eq(#highlight_calls, 1, "первый кадр: подсветка вызвана")
    T.eq(highlight_calls[1].cx, 3)
    T.eq(highlight_calls[1].cz, 4)
    T.eq(highlight_calls[1].color_id, 1)

    -- Кадр 2: курсор остаётся в клетке (3, 4) -> НЕ должно вызывать highlight_cell повторно!
    on_hud_render()
    T.eq(#highlight_calls, 1, "второй кадр в той же клетке: highlight_cell НЕ вызывается")

    -- Кадр 3: курсор всё ещё в клетке (3, 4)
    on_hud_render()
    T.eq(#highlight_calls, 1, "третий кадр в той же клетке: highlight_cell НЕ вызывается")

    -- Кадр 4: перемещение курсора в клетку (5, 6)
    local clear_count_before = #clear_calls
    current_cursor_cell = { cx = 5, cz = 6, level = 0 }
    on_hud_render()
    T.eq(#highlight_calls, 2, "новая клетка (5, 6) подсвечена")
    T.eq(highlight_calls[2].cx, 5)
    T.eq(highlight_calls[2].cz, 6)
    -- Проверяем, что среди вызовов clear_highlight был вызов для старой клетки (3, 4)
    T.eq(clear_calls[clear_count_before + 1].cx, 3)
    T.eq(clear_calls[clear_count_before + 1].cz, 4)

    -- Кадр 5: курсор ушёл с поля (промах луча, cell = nil)
    local clear_count_before_leave = #clear_calls
    mock.override("block.raycast", function() return nil end)
    on_hud_render()
    T.eq(#highlight_calls, 2, "новых подсветок не создано")
    -- Проверяем, что для клетки (5, 6) был вызван clear_highlight при уходе курсора
    T.eq(clear_calls[clear_count_before_leave + 1].cx, 5)
    T.eq(clear_calls[clear_count_before_leave + 1].cz, 6)

    -- Восстанавливаем функции overlay
    overlay.highlight_cell = orig_highlight
    overlay.clear_highlight = orig_clear
end)

T.test("hud: on_hud_render не обновляет подсветку клетки при паузе, инвентаре или чате", function()
    setup_hud_test()

    mock.override("input.add_callback", function() end)

    local is_paused = false
    local is_inv_open = false
    local active_frame = "vtt:tactical_frame"

    mock.override("hud.is_paused", function() return is_paused end)
    mock.override("hud.is_inventory_open", function() return is_inv_open end)
    mock.override("gui.get_active_frame", function() return active_frame end)
    mock.override("input.get_mouse_pos", function() return { 500, 500 } end)
    mock.override("gui.get_viewport", function() return { 1000, 1000 } end)

    local current_cursor_cell = { cx = 3, cz = 4, level = 0 }
    mock.override("block.raycast", function()
        return { iendpoint = { current_cursor_cell.cx * grid.CELL_SIZE, 0, current_cursor_cell.cz * grid.CELL_SIZE } }
    end)

    local highlight_calls = {}
    local orig_highlight = overlay.highlight_cell
    overlay.highlight_cell = function(cx, cz, color_id)
        highlight_calls[#highlight_calls + 1] = { cx = cx, cz = cz, color_id = color_id }
        orig_highlight(cx, cz, color_id)
    end

    dofile("vtt/scripts/hud.lua")
    on_hud_open(1)
    camera.set_mode("tactical")

    -- 1. Нормальный кадр: подсветка срабатывает
    on_hud_render()
    T.eq(#highlight_calls, 1, "в нормальном режиме подсветка вызвана")

    -- 2. При паузе: курсор сменил клетку, но highlight_cell НЕ вызывается
    is_paused = true
    current_cursor_cell = { cx = 10, cz = 20, level = 0 }
    on_hud_render()
    T.eq(#highlight_calls, 1, "при паузе подсветка не обновляется")
    is_paused = false

    -- 3. При открытом инвентаре: курсор сменил клетку, но highlight_cell НЕ вызывается
    is_inv_open = true
    current_cursor_cell = { cx = 30, cz = 40, level = 0 }
    on_hud_render()
    T.eq(#highlight_calls, 1, "при инвентаре подсветка не обновляется")
    is_inv_open = false

    -- 4. При открытом чате (фрейм core:console): highlight_cell НЕ вызывается
    active_frame = "core:console"
    current_cursor_cell = { cx = 50, cz = 60, level = 0 }
    on_hud_render()
    T.eq(#highlight_calls, 1, "при активном чате подсветка не обновляется")

    overlay.highlight_cell = orig_highlight
end)

T.test("hud: интерактивный выбор токена, превью пути и отправка MoveToken", function()
    setup_hud_test()

    local callbacks = {}
    mock.override("input.add_callback", function(bind, cb)
        callbacks[bind] = cb
    end)

    local current_time = 1.0
    mock.override("time.uptime", function()
        current_time = current_time + 0.1
        return current_time
    end)

    local sent_messages = {}
    _G.Message = {
        new = function(pack, event, schema)
            return {
                send = function(self, data)
                    sent_messages[#sent_messages + 1] = { name = event, data = data }
                end,
                on = function() end,
            }
        end,
    }

    local block_interceptor = require("net/block_interceptor")
    block_interceptor.client_tokens = {}
    block_interceptor.client_tokens[500] = {
        uid = 500,
        token_id = "test_mage",
        pos = { 4.5, 0.0, 4.5 }, -- Клетка (1, 1)
        cell = { cx = 1, cz = 1, level = 0 },
    }

    -- Курсор мыши над токеном в клетке (1, 1)
    local cur_ent = 500
    local cur_block_endpoint = { 4.5, 0, 4.5 }
    mock.override("entities.raycast", function()
        if cur_ent then return { entity = cur_ent } end
        return nil
    end)
    mock.override("block.raycast", function()
        if cur_block_endpoint then return { iendpoint = cur_block_endpoint } end
        return nil
    end)
    mock.override("input.get_mouse_pos", function() return { 500, 500 } end)
    mock.override("gui.get_viewport", function() return { 1000, 1000 } end)

    dofile("vtt/scripts/hud.lua")
    on_hud_open(1)
    camera.set_mode("tactical")

    local click_cb = callbacks["vtt.tactical_click"]
    T.truthy(click_cb ~= nil, "vtt.tactical_click зарегистрирован")

    -- 1. Клик ЛКМ по токену -> токен выбран, зона 3 подсвечена
    click_cb()

    local st = _G.__vtt_hud_state.get_selected_token()
    T.truthy(st ~= nil, "токен выбран")
    T.eq(st.token_id, "test_mage")
    T.eq(st.cell.cx, 1)
    T.eq(st.cell.cz, 1)

    T.truthy(#overlay.zone_cells > 0, "зона перемещения отображается")
    T.eq(overlay.get_cell_layer(2, 1), "zone", "соседняя клетка имеет слой zone")

    -- 2. Наведение курсора на клетку (3, 1) внутри зоны -> превью пути (слой path)
    cur_ent = nil
    cur_block_endpoint = { 3 * 3 + 1.5, 0, 1 * 3 + 1.5 } -- Клетка (3, 1), дистанция 2 шага
    on_hud_render()

    T.truthy(#overlay.path_cells > 0, "путь отображается")
    T.eq(overlay.get_cell_layer(2, 1), "path", "клетка (2, 1) на пути имеет слой path")
    T.eq(overlay.get_cell_layer(3, 1), "active", "клетка (3, 1) под курсором имеет слой active (приоритет)")

    -- 3. Наведение курсора вне зоны (10, 10) -> очистка превью пути
    cur_block_endpoint = { 10 * 3 + 1.5, 0, 10 * 3 + 1.5 }
    on_hud_render()
    T.eq(#overlay.path_cells, 0, "путь очищен при уходе курсора из зоны")

    -- 4. Клик ЛКМ по клетке внутри зоны (2, 2) -> отправка намерения MoveToken и сброс выбора
    cur_block_endpoint = { 2 * 3 + 1.5, 0, 2 * 3 + 1.5 } -- Клетка (2, 2), дистанция 2 шага (в пределах 5)
    click_cb()

    T.eq(#sent_messages, 1, "MoveToken отправлен на сервер")
    T.eq(sent_messages[1].name, "MoveToken")
    T.eq(sent_messages[1].data.payload.token_id, "test_mage")
    T.eq(sent_messages[1].data.payload.target_cell.cx, 2)
    T.eq(sent_messages[1].data.payload.target_cell.cz, 2)

    T.eq(_G.__vtt_hud_state.get_selected_token(), nil, "выбор токена сброшен после хода")
    T.eq(#overlay.zone_cells, 0, "зона очищена")
    T.eq(#overlay.path_cells, 0, "путь очищен")

    -- 5. Повторный выбор и клик вне зоны -> отмена выбора
    cur_ent = 500
    cur_block_endpoint = { 4.5, 0, 4.5 }
    click_cb()
    T.truthy(_G.__vtt_hud_state.get_selected_token() ~= nil, "токен снова выбран")

    -- Клик по клетке далеко (10, 10)
    cur_ent = nil
    cur_block_endpoint = { 10 * 3 + 1.5, 0, 10 * 3 + 1.5 }
    click_cb()
    T.eq(_G.__vtt_hud_state.get_selected_token(), nil, "выбор сброшен при клике вне зоны")

    -- 6. Выбор и сброс при клике на саму клетку токена
    cur_ent = 500
    cur_block_endpoint = { 4.5, 0, 4.5 }
    click_cb()
    T.truthy(_G.__vtt_hud_state.get_selected_token() ~= nil, "токен выбран")

    -- Клик по той же клетке (1, 1)
    cur_ent = nil
    cur_block_endpoint = { 4.5, 0, 4.5 }
    click_cb()
    T.eq(_G.__vtt_hud_state.get_selected_token(), nil, "выбор сброшен при повторном клике по токену")

    -- 7. Выбор и сброс при переключении камеры в first_person
    cur_ent = 500
    cur_block_endpoint = { 4.5, 0, 4.5 }
    click_cb()
    T.truthy(_G.__vtt_hud_state.get_selected_token() ~= nil, "токен выбран")

    callbacks["vtt.camera_toggle"]()
    T.eq(_G.__vtt_hud_state.get_selected_token(), nil, "выбор сброшен при смене камеры в first_person")
    T.eq(#overlay.zone_cells, 0, "зона очищена")
end)
