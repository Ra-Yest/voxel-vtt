local T = require("lib")
local mock = require("engine_mock")

-- Устанавливаем мок библиотек
mock.install(_G)

local function make_fake_cam(idx)
    local state = {
        index = idx or 42,
        pos = { 0, 0, 0 },
        zoom = 1,
        fov = 45,
        perspective = true,
        look_at_pos = nil,
        name = "vtt:tactical",
    }
    local cam = {}
    function cam:get_index() return state.index end
    function cam:get_name() return state.name end
    function cam:set_pos(pos) state.pos = pos end
    function cam:get_pos() return state.pos end
    function cam:set_zoom(z) state.zoom = z end
    function cam:get_zoom() return state.zoom end
    function cam:set_fov(f) state.fov = f end
    function cam:set_perspective(p) state.perspective = p end
    function cam:look_at(p) state.look_at_pos = p end
    return cam, state
end

local camera = require("client/camera")

T.test("camera: init привязывает тактическую камеру, сохраняет default_cam и позицию игрока", function()
    local fake_cam, state = make_fake_cam(7)
    local assigned_pid, assigned_cam_idx
    mock.override("cameras.get", function(name)
        if name == "vtt:tactical" then return fake_cam end
        return nil
    end)
    mock.override("player.get_camera", function(pid)
        return 3
    end)
    mock.override("player.get_pos", function(pid)
        return 100, 64, 200
    end)
    mock.override("player.set_camera", function(pid, idx)
        assigned_pid = pid
        assigned_cam_idx = idx
    end)

    camera.init(1)

    T.eq(camera.player_id, 1)
    T.eq(camera.default_cam_idx, 3)
    T.eq(assigned_pid, 1)
    T.eq(assigned_cam_idx, 7)
    T.eq(camera.current_pos[1], 100)
    T.eq(camera.current_pos[2], 64)
    T.eq(camera.current_pos[3], 200)
    T.eq(state.perspective, true)
    T.eq(state.fov, camera.DEFAULT_FOV)
    -- Проверяем масштабирование позиции камеры от zoom
    T.eq(state.pos[1], 100 + camera.CAMERA_OFFSET_X * camera.current_zoom)
    T.eq(state.pos[2], 64 + camera.CAMERA_HEIGHT * camera.current_zoom)
    T.eq(state.pos[3], 200 + camera.CAMERA_OFFSET_Z * camera.current_zoom)
    T.eq(camera.get_mode(), "tactical")
end)

T.test("camera: init падает при отсутствии ресурса камеры", function()
    mock.override("cameras.get", function(_) return nil end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    T.throws(function() camera.init() end)
end)

T.test("camera: set_mode переключает между tactical и сохранённым default_cam", function()
    local fake_cam, state = make_fake_cam(7)
    local last_pid, last_cam_idx
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 5 end)
    mock.override("player.get_pos", function(_) return 10, 20, 30 end)
    mock.override("player.set_camera", function(pid, idx)
        last_pid = pid
        last_cam_idx = idx
    end)

    camera.init(2)
    T.eq(camera.get_mode(), "tactical")
    T.eq(camera.default_cam_idx, 5)
    T.eq(last_cam_idx, 7)

    -- Переход в first_person возвращает сохранённый default_cam_idx (5), а не жесткий 0
    camera.set_mode("first_person")
    T.eq(camera.get_mode(), "first_person")
    T.eq(last_cam_idx, 5)
    T.eq(last_pid, 2)

    -- Переход обратно в tactical синхронизирует позицию с игроком и ставит idx тактической камеры
    mock.override("player.get_pos", function(_) return 50, 25, 70 end)
    camera.set_mode("tactical")
    T.eq(camera.get_mode(), "tactical")
    T.eq(last_cam_idx, 7)
    T.eq(camera.current_pos[1], 50)
    T.eq(camera.current_pos[2], 25)
    T.eq(camera.current_pos[3], 70)

    T.throws(function() camera.set_mode("invalid_mode") end)
end)

T.test("camera: focus_on_cell центрирует target_pos на клетке и сохраняет высоту Y", function()
    camera.current_pos = { 0, 64, 0 }
    camera.focus_on_cell(3, 5)
    -- клетка (3, 5) при CELL_SIZE=3: центр = (3 + 0.5)*3 = 10.5, (5 + 0.5)*3 = 16.5
    T.eq(camera.target_pos[1], 10.5)
    T.eq(camera.target_pos[2], 64) -- Высота Y не сбрасывается в 0
    T.eq(camera.target_pos[3], 16.5)
end)

T.test("camera: update масштабирует отступ камеры по высоте и Z от zoom", function()
    local fake_cam, state = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 10, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("input.is_pressed", function(_) return false end)
    mock.override("input.get_mouse_delta", function() return { 0, 0 } end)
    mock.override("input.get_mouse_scroll", function() return 0 end)

    camera.init()
    camera.current_pos = { 0, 10, 0 }
    camera.target_pos = { 0, 10, 0 }
    camera.current_zoom = 2.0
    camera.target_zoom = 2.0

    camera.update(0.1)

    T.eq(state.pos[1], 0)
    T.eq(state.pos[2], 10 + camera.CAMERA_HEIGHT * 2.0)
    T.eq(state.pos[3], camera.CAMERA_OFFSET_Z * 2.0)
    T.truthy(state.look_at_pos ~= nil, "look_at установлен")
end)

T.test("camera: update обрабатывает панорамирование через input.is_active и стрелки", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("input.get_mouse_delta", function() return { 0, 0 } end)
    mock.override("input.get_mouse_scroll", function() return 0 end)
    mock.override("hud.is_paused", function() return false end)
    mock.override("hud.is_inventory_open", function() return false end)
    mock.override("gui.get_active_frame", function() return "vtt:tactical_frame" end)

    camera.init()

    -- 1. Движение вправо через vtt.cam_right
    camera.target_pos = { 0, 0, 0 }
    mock.override("input.is_active", function(bind) return bind == "vtt.cam_right" end)
    mock.override("input.is_pressed", function(_) return false end)
    camera.update(0.1)
    T.truthy(camera.target_pos[1] > 0, "target_pos X увеличился при vtt.cam_right")

    -- 2. Движение влево через vtt.cam_left
    camera.target_pos = { 0, 0, 0 }
    mock.override("input.is_active", function(bind) return bind == "vtt.cam_left" end)
    camera.update(0.1)
    T.truthy(camera.target_pos[1] < 0, "target_pos X уменьшился при vtt.cam_left")

    -- 3. Движение вперед через vtt.cam_forward
    camera.target_pos = { 0, 0, 0 }
    mock.override("input.is_active", function(bind) return bind == "vtt.cam_forward" end)
    camera.update(0.1)
    T.truthy(camera.target_pos[3] < 0, "target_pos Z уменьшился при vtt.cam_forward")

    -- 4. Движение назад через vtt.cam_back
    camera.target_pos = { 0, 0, 0 }
    mock.override("input.is_active", function(bind) return bind == "vtt.cam_back" end)
    camera.update(0.1)
    T.truthy(camera.target_pos[3] > 0, "target_pos Z увеличился при vtt.cam_back")

    -- 5. Движение через стрелки с клавиатуры (key:right)
    camera.target_pos = { 0, 0, 0 }
    mock.override("input.is_active", function(_) return false end)
    mock.override("input.is_pressed", function(code) return code == "key:right" end)
    camera.update(0.1)
    T.truthy(camera.target_pos[1] > 0, "target_pos X увеличился при key:right")
end)

T.test("camera: update блокирует движение по WASD и зум при hud.is_paused() == true", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("hud.is_paused", function() return true end)
    mock.override("hud.is_inventory_open", function() return false end)
    mock.override("gui.get_active_frame", function() return "vtt:tactical_frame" end)
    mock.override("input.is_active", function(_) return true end)
    mock.override("input.is_pressed", function(_) return true end)
    mock.override("input.get_mouse_delta", function() return { 10, 10 } end)
    mock.override("input.get_mouse_scroll", function() return 1 end)

    camera.init()
    camera.target_pos = { 10, 0, 20 }
    local start_zoom = camera.target_zoom

    camera.update(0.1)

    T.eq(camera.target_pos[1], 10, "target_pos X не изменился в паузе")
    T.eq(camera.target_pos[3], 20, "target_pos Z не изменился в паузе")
    T.eq(camera.target_zoom, start_zoom, "target_zoom не изменился в паузе")
end)

T.test("camera: update блокирует движение по WASD и зум при hud.is_inventory_open() == true", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("hud.is_paused", function() return false end)
    mock.override("hud.is_inventory_open", function() return true end)
    mock.override("gui.get_active_frame", function() return "vtt:tactical_frame" end)
    mock.override("input.is_active", function(_) return true end)
    mock.override("input.is_pressed", function(_) return true end)
    mock.override("input.get_mouse_delta", function() return { 10, 10 } end)
    mock.override("input.get_mouse_scroll", function() return 1 end)

    camera.init()
    camera.target_pos = { 10, 0, 20 }
    local start_zoom = camera.target_zoom

    camera.update(0.1)

    T.eq(camera.target_pos[1], 10, "target_pos X не изменился при открытом инвентаре")
    T.eq(camera.target_pos[3], 20, "target_pos Z не изменился при открытом инвентаре")
    T.eq(camera.target_zoom, start_zoom, "target_zoom не изменился при открытом инвентаре")
end)

T.test("camera: update блокирует ввод и не перетирает фрейм при активном чате (gui.get_active_frame() == 'core:console')", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("hud.is_paused", function() return false end)
    mock.override("hud.is_inventory_open", function() return false end)

    local active_frame = "core:console"
    local set_frame_calls = {}
    mock.override("gui.get_active_frame", function() return active_frame end)
    mock.override("gui.set_active_frame", function(id)
        set_frame_calls[#set_frame_calls + 1] = id
    end)

    mock.override("input.is_active", function(_) return true end)
    mock.override("input.is_pressed", function(_) return true end)
    mock.override("input.get_mouse_delta", function() return { 10, 10 } end)
    mock.override("input.get_mouse_scroll", function() return 1 end)

    camera.init()
    camera.target_pos = { 15, 0, 25 }
    local start_zoom = camera.target_zoom
    set_frame_calls = {}

    camera.update(0.1)

    T.eq(camera.target_pos[1], 15, "target_pos X не изменился при открытом чате")
    T.eq(camera.target_pos[3], 25, "target_pos Z не изменился при открытом чате")
    T.eq(camera.target_zoom, start_zoom, "target_zoom не изменился при открытом чате")
    T.eq(#set_frame_calls, 0, "gui.set_active_frame НЕ вызывается поверх чата")
    mock.override("gui.get_active_frame", function() return "vtt:tactical_frame" end)
end)

T.test("camera: update обрабатывает зум колесом мыши", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("hud.is_paused", function() return false end)
    mock.override("hud.is_inventory_open", function() return false end)
    mock.override("gui.get_active_frame", function() return "vtt:tactical_frame" end)
    mock.override("input.is_pressed", function(_) return false end)
    mock.override("input.get_mouse_delta", function() return { 0, 0 } end)

    camera.init()
    local start_zoom = camera.target_zoom

    -- Скролл вверх (зум внутрь)
    mock.override("input.get_mouse_scroll", function() return 1 end)
    camera.update(0.1)
    T.truthy(camera.target_zoom > start_zoom, "target_zoom увеличился при скролле вверх")

    -- Скролл за пределы MAX_ZOOM должен быть ограничен
    mock.override("input.get_mouse_scroll", function() return 100 end)
    camera.update(0.1)
    T.eq(camera.target_zoom, camera.MAX_ZOOM)
end)

T.test("camera: update игнорируется в режиме first_person", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("input.is_pressed", function(_) return true end)
    mock.override("input.get_mouse_delta", function() return { 0, 0 } end)
    mock.override("input.get_mouse_scroll", function() return 1 end)

    camera.init()
    camera.set_mode("first_person")
    local saved_target_x = camera.target_pos[1]
    local saved_zoom = camera.target_zoom

    camera.update(0.1)

    T.eq(camera.target_pos[1], saved_target_x)
    T.eq(camera.target_zoom, saved_zoom)
end)

T.test("hud: on_hud_open логирует input.get_bindings и передает playerid", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 10, 20, 30 end)
    mock.override("player.set_camera", function() end)
    local bindings_called = false
    mock.override("input.get_bindings", function()
        bindings_called = true
        return { "movement.forward", "movement.back", "hud.inventory" }
    end)
    mock.override("input.add_callback", function() end)
    mock.override("time.delta", function() return 0.016 end)

    dofile("vtt/scripts/hud.lua")

    on_hud_open(4)

    T.eq(camera.player_id, 4)
    T.truthy(bindings_called, "input.get_bindings вызван в on_hud_open")
end)

T.test("camera: init и set_mode переключают биндинги через input.set_enabled", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)

    local enabled_states = {}
    mock.override("input.set_enabled", function(name, flag)
        enabled_states[name] = flag
    end)

    camera.init(1)
    -- В тактическом режиме все биндинги из TACTICAL_DISABLED_BINDINGS отключены (false)
    for _, bind in ipairs(camera.TACTICAL_DISABLED_BINDINGS) do
        T.eq(enabled_states[bind], false, "биндинг " .. bind .. " отключен в tactical")
    end

    -- При переключении в first_person биндинги включаются обратно (true)
    camera.set_mode("first_person")
    for _, bind in ipairs(camera.TACTICAL_DISABLED_BINDINGS) do
        T.eq(enabled_states[bind], true, "биндинг " .. bind .. " включен в first_person")
    end

    -- При возврате в tactical снова отключаются
    camera.set_mode("tactical")
    for _, bind in ipairs(camera.TACTICAL_DISABLED_BINDINGS) do
        T.eq(enabled_states[bind], false, "биндинг " .. bind .. " отключен при повторном tactical")
    end
end)

T.test("camera: управление системным курсором через gui.set_active_frame", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)

    local created_frame_id, created_size
    mock.override("gui.get_viewport", function() return { 1920, 1080 } end)
    mock.override("gui.create_frame", function(id, tex, size)
        created_frame_id = id
        created_size = size
    end)
    local active_frame_id
    mock.override("gui.set_active_frame", function(id)
        active_frame_id = id
    end)

    camera.frame_created = false
    camera.init(1)

    T.eq(created_frame_id, "vtt:tactical_frame")
    T.eq(created_size[1], 1920)
    T.eq(created_size[2], 1080)
    T.eq(active_frame_id, "vtt:tactical_frame", "в tactical активен vtt:tactical_frame")

    camera.set_mode("first_person")
    T.eq(active_frame_id, "", "в first_person активен пустой фрейм (захват курсора)")

    camera.set_mode("tactical")
    T.eq(active_frame_id, "vtt:tactical_frame", "при возврате в tactical активен vtt:tactical_frame")
end)

T.test("camera: фиксирует выбранный слот хотбара во избежание прокрутки колесом мыши", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("input.is_pressed", function(_) return false end)
    mock.override("input.get_mouse_delta", function() return { 0, 0 } end)
    mock.override("input.get_mouse_scroll", function() return 0 end)

    mock.override("player.get_inventory", function(pid)
        return 101, 3
    end)

    local set_slot_pid, set_slot_idx
    mock.override("player.set_selected_slot", function(pid, slotid)
        set_slot_pid = pid
        set_slot_idx = slotid
    end)

    camera.init(5)
    T.eq(camera.locked_slot, 3)

    camera.update(0.016)
    T.eq(set_slot_pid, 5)
    T.eq(set_slot_idx, 3)
end)

T.test("camera: update восстанавливает vtt:tactical_frame при сбросе фрейма вне паузы", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("input.is_pressed", function(_) return false end)
    mock.override("input.get_mouse_delta", function() return { 0, 0 } end)
    mock.override("input.get_mouse_scroll", function() return 0 end)

    local active_frame = ""
    local set_frame_calls = {}
    mock.override("gui.get_active_frame", function() return active_frame end)
    mock.override("gui.set_active_frame", function(id)
        active_frame = id
        set_frame_calls[#set_frame_calls + 1] = id
    end)

    local paused = false
    mock.override("hud.is_paused", function() return paused end)

    camera.init(1)
    T.eq(active_frame, "vtt:tactical_frame")

    -- Симулируем сброс активного фрейма в "" (например, при нажатии Esc)
    active_frame = ""
    set_frame_calls = {}

    camera.update(0.016)
    T.eq(active_frame, "vtt:tactical_frame", "восстановлен vtt:tactical_frame в update")
    T.eq(#set_frame_calls, 1)

    -- Если игра на паузе, update не должен перехватывать фрейм у меню паузы
    active_frame = "engine_pause_menu"
    paused = true
    set_frame_calls = {}

    camera.update(0.016)
    T.eq(active_frame, "engine_pause_menu", "фрейм меню паузы не перезаписывается")
    T.eq(#set_frame_calls, 0)
end)

T.test("hud: on_hud_open регистрирует key:escape для вызова hud.pause", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("input.get_bindings", function() return {} end)

    local callbacks = {}
    mock.override("input.add_callback", function(bind, cb)
        callbacks[bind] = cb
    end)

    local paused = false
    local pause_called = false
    mock.override("hud.is_paused", function() return paused end)
    mock.override("hud.pause", function() pause_called = true end)

    dofile("vtt/scripts/hud.lua")
    on_hud_open(1)

    T.truthy(callbacks["key:escape"] ~= nil, "callback key:escape зарегистрирован")

    camera.set_mode("tactical")
    local res = callbacks["key:escape"]()
    T.truthy(pause_called, "hud.pause вызван при нажатии Esc")
    T.eq(res, true, "callback возвращает true для блокировки дальнейшей обработки")
end)

T.test("hud: on_hud_open регистрирует vtt.camera_toggle для переключения режима камеры", function()
    local fake_cam, _ = make_fake_cam(7)
    mock.override("cameras.get", function(_) return fake_cam end)
    mock.override("player.get_camera", function(_) return 0 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    mock.override("player.set_camera", function() end)
    mock.override("input.get_bindings", function() return {} end)

    local callbacks = {}
    mock.override("input.add_callback", function(bind, cb)
        callbacks[bind] = cb
    end)

    local paused = false
    mock.override("hud.is_paused", function() return paused end)

    dofile("vtt/scripts/hud.lua")
    on_hud_open(1)

    T.truthy(callbacks["vtt.camera_toggle"] ~= nil, "callback vtt.camera_toggle зарегистрирован")

    camera.set_mode("tactical")
    callbacks["vtt.camera_toggle"]()
    T.eq(camera.get_mode(), "first_person", "переключен в first_person")

    callbacks["vtt.camera_toggle"]()
    T.eq(camera.get_mode(), "tactical", "переключен обратно в tactical")

    -- При паузе переключение блокируется
    paused = true
    callbacks["vtt.camera_toggle"]()
    T.eq(camera.get_mode(), "tactical", "в паузе режим не переключается")
end)

T.test("camera: init и set_mode сбрасывают default_cam в core:first-person если мир сохранен в tactical", function()
    local fake_tactical, _ = make_fake_cam(4)
    local fake_fp, _ = make_fake_cam(0)

    mock.override("cameras.get", function(val)
        if val == "vtt:tactical" or val == 4 then return fake_tactical end
        if val == "core:first-person" or val == 0 then return fake_fp end
        return nil
    end)

    -- Игрок загружается в мир, уже находясь в tactical_cam (4)
    mock.override("player.get_camera", function(_) return 4 end)
    mock.override("player.get_pos", function(_) return 0, 0, 0 end)
    local assigned_cam
    mock.override("player.set_camera", function(pid, idx)
        assigned_cam = idx
    end)

    camera.init(0)
    -- default_cam не должен стать 4! Должен быть сброшен в 0 (core:first-person)
    T.eq(camera.default_cam_idx, 0, "default_cam не должен равняться tactical_cam")

    -- Переключаем в first_person
    camera.set_mode("first_person")
    T.eq(assigned_cam, 0, "при переходе в first_person назначена камера 0 (core:first-person)")
end)
