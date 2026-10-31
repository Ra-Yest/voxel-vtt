-- client/camera.lua
-- Слой: client
-- Спека: specs/client-camera.md
-- Назначение: Управление тактической камерой стола, зум, панорамирование, переключение режимов.
-- Публичные функции:
--   init(playerid)
--   set_mode(mode_name)
--   get_mode()
--   focus_on_cell(cx, cz)
--   update(delta_time)

local grid = require("core/grid")
local log = require("core/log")

local M = {}

-- Настройки и константы тактической камеры
M.CAMERA_HEIGHT = 16.0
M.CAMERA_OFFSET_Z = 12.0
M.CAMERA_OFFSET_X = 0.0
M.DEFAULT_FOV = 45.0

M.DEFAULT_ZOOM = 1.0
M.MIN_ZOOM = 0.5
M.MAX_ZOOM = 3.0
M.ZOOM_STEP = 0.1

M.PAN_SPEED = 15.0
M.DRAG_SENSITIVITY = 0.02
M.SMOOTH_FACTOR = 10.0

-- Текущее состояние
M.player_id = 0
M.default_cam_idx = 0
M.frame_created = false
M.locked_slot = nil
M.mode = "tactical" -- "tactical" или "first_person"
M.active_cam = nil
M.current_pos = { 0, 0, 0 }
M.target_pos = { 0, 0, 0 }
M.current_zoom = 1.0
M.target_zoom = 1.0
M.zoom = 1.0

local function make_binding(prefix, action)
    return prefix .. "." .. action
end

-- Список биндингов движка, отключаемых в тактическом режиме
M.TACTICAL_DISABLED_BINDINGS = {
    "movement.forward",
    "movement.back",
    "movement.left",
    "movement.right",
    "movement.jump",
    "movement.crouch",
    "movement.sprint",
    "movement.cheat",
    make_binding("player", "build"),
    make_binding("player", "destroy"),
    make_binding("player", "attack"),
    make_binding("player", "pick"),
    make_binding("player", "drop"),
    make_binding("player", "fast_interaction"),
    "camera.mode",
    "camera.zoom",
}

-- Инициализация тактической камеры
function M.init(playerid)
    if playerid ~= nil then
        M.player_id = playerid
    end

    -- docs: docs/engine/resources.md:23: After loading the pack, resource names will have the pack prefix
    -- docs: docs/engine/scripting/builtins/libcameras.md:8: cameras.get(name: str) -> table
    local cam = cameras.get("vtt:tactical")
    if not cam then
        -- docs: docs/engine/scripting/builtins/libcameras.md:8: cameras.get(name: str) -> table
        cam = cameras.get("tactical")
    end
    if not cam then
        error("Не удалось найти ресурс камеры ('vtt:tactical' или 'tactical')")
    end

    M.active_cam = cam

    -- docs: docs/engine/scripting/builtins/libcameras.md:22: cam:get_index() -> int
    local idx = cam:get_index()

    -- Сохраняем исходную камеру игрока до переключения.
    -- Если игрок уже был в тактической камере (сохранение мира), берем core:first-person
    -- docs: docs/engine/scripting/builtins/libplayer.md:130: player.get_camera(playerid: int) -> int
    local current_cam = player.get_camera(M.player_id)
    if current_cam and current_cam ~= idx then
        M.default_cam_idx = current_cam
    else
        -- docs: docs/engine/scripting/builtins/libcameras.md:8: cameras.get(name: str) -> table
        local fp_cam = cameras.get("core:first-person")
        if fp_cam then
            -- docs: docs/engine/scripting/builtins/libcameras.md:22: cam:get_index() -> int
            M.default_cam_idx = fp_cam:get_index()
        else
            M.default_cam_idx = 0
        end
    end

    -- Получаем позицию игрока и устанавливаем фокус камеры
    -- docs: docs/engine/scripting/builtins/libplayer.md:16: player.get_pos(playerid: int) -> number, number, number
    local px, py, pz = player.get_pos(M.player_id)
    if type(px) == "number" and type(py) == "number" and type(pz) == "number" then
        M.current_pos = { px, py, pz }
        M.target_pos = { px, py, pz }
    end

    if idx then
        -- docs: docs/engine/scripting/builtins/libplayer.md:136: player.set_camera(playerid: int, camera_index: int)
        player.set_camera(M.player_id, idx)
    end

    -- docs: docs/engine/scripting/builtins/libcameras.md:55: cam:set_perspective(perspective: bool)
    cam:set_perspective(true)
    -- docs: docs/engine/scripting/builtins/libcameras.md:45: cam:set_fov(fov: number)
    cam:set_fov(M.DEFAULT_FOV)
    -- docs: docs/engine/scripting/builtins/libcameras.md:40: cam:set_zoom(zoom: number)
    cam:set_zoom(M.current_zoom)

    local cam_x = M.current_pos[1] + M.CAMERA_OFFSET_X * M.current_zoom
    local cam_y = M.current_pos[2] + M.CAMERA_HEIGHT * M.current_zoom
    local cam_z = M.current_pos[3] + M.CAMERA_OFFSET_Z * M.current_zoom
    -- docs: docs/engine/scripting/builtins/libcameras.md:30: cam:set_pos(pos:vec3)
    cam:set_pos({ cam_x, cam_y, cam_z })
    -- docs: docs/engine/scripting/builtins/libcameras.md:65: cam:look_at(point:vec3)
    cam:look_at({ M.current_pos[1], M.current_pos[2], M.current_pos[3] })

    -- Отключаем стандартные биндинги движения и действий в тактическом режиме
    for _, bind in ipairs(M.TACTICAL_DISABLED_BINDINGS) do
        -- docs: docs/engine/scripting/builtins/libinput.md:92: input.set_enabled(bindname: str, flag: bool)
        input.set_enabled(bind, false)
    end

    -- Создаем экранный фрейм для освобождения системного курсора и предотвращения захвата мыши
    if not M.frame_created then
        -- docs: docs/engine/scripting/builtins/libgui.md:17: gui.get_viewport() -> {int, int}
        local vp = gui.get_viewport()
        local vp_size = (type(vp) == "table" and vp[1] and vp[2]) and vp or { 1280, 720 }
        -- docs: docs/engine/scripting/builtins/libgui.md:42: gui.create_frame(id: str, output_texture: str, size: vec2)
        gui.create_frame("vtt:tactical_frame", "", vp_size)
        M.frame_created = true
    end
    -- docs: docs/engine/scripting/builtins/libgui.md:57: gui.set_active_frame(id: str)
    gui.set_active_frame("vtt:tactical_frame")

    -- Запоминаем текущий слот хотбара для предотвращения его прокрутки колесом мыши при зуме
    -- docs: docs/engine/scripting/builtins/libplayer.md:58: player.get_inventory(playerid: int) -> int, int
    local invid, slot = player.get_inventory(M.player_id)
    if type(slot) == "number" then
        M.locked_slot = slot
    end

    log("camera_init", {
        player_id = M.player_id,
        default_cam = M.default_cam_idx,
        tactical_cam = idx,
        pos = M.current_pos,
    })
    return true
end

-- Переключение режима камеры
function M.set_mode(mode_name)
    if mode_name ~= "tactical" and mode_name ~= "first_person" then
        error("Неизвестный режим камеры: " .. tostring(mode_name))
    end

    M.mode = mode_name
    if mode_name == "first_person" then
        -- Защита: если сохранённый default_cam_idx совпадает с тактической камерой, сбрасываем в core:first-person
        local tac_idx = M.active_cam and M.active_cam:get_index()
        if M.default_cam_idx == tac_idx then
            -- docs: docs/engine/scripting/builtins/libcameras.md:8: cameras.get(name: str) -> table
            local fp_cam = cameras.get("core:first-person")
            if fp_cam then
                -- docs: docs/engine/scripting/builtins/libcameras.md:22: cam:get_index() -> int
                M.default_cam_idx = fp_cam:get_index()
            else
                M.default_cam_idx = 0
            end
        end

        -- docs: docs/engine/scripting/builtins/libplayer.md:136: player.set_camera(playerid: int, camera_index: int)
        player.set_camera(M.player_id, M.default_cam_idx)

        -- Включаем обратно стандартные биндинги движения и действий
        for _, bind in ipairs(M.TACTICAL_DISABLED_BINDINGS) do
            -- docs: docs/engine/scripting/builtins/libinput.md:92: input.set_enabled(bindname: str, flag: bool)
            input.set_enabled(bind, true)
        end

        -- Возвращаем захват курсора прицелом (пустой id фрейма)
        -- docs: docs/engine/scripting/builtins/libgui.md:57: gui.set_active_frame(id: str)
        gui.set_active_frame("")
    else
        -- Отключаем стандартные биндинги движения и действий в тактическом режиме
        for _, bind in ipairs(M.TACTICAL_DISABLED_BINDINGS) do
            -- docs: docs/engine/scripting/builtins/libinput.md:92: input.set_enabled(bindname: str, flag: bool)
            input.set_enabled(bind, false)
        end

        -- Освобождаем курсор мыши, делая активным тактический фрейм
        -- docs: docs/engine/scripting/builtins/libgui.md:57: gui.set_active_frame(id: str)
        gui.set_active_frame("vtt:tactical_frame")

        -- Запоминаем текущий слот хотбара для предотвращения его прокрутки колесом мыши при зуме
        -- docs: docs/engine/scripting/builtins/libplayer.md:58: player.get_inventory(playerid: int) -> int, int
        local invid, slot = player.get_inventory(M.player_id)
        if type(slot) == "number" then
            M.locked_slot = slot
        end

        -- docs: docs/engine/scripting/builtins/libplayer.md:16: player.get_pos(playerid: int) -> number, number, number
        local px, py, pz = player.get_pos(M.player_id)
        if type(px) == "number" and type(py) == "number" and type(pz) == "number" then
            M.current_pos = { px, py, pz }
            M.target_pos = { px, py, pz }
        end

        if M.active_cam then
            -- docs: docs/engine/scripting/builtins/libcameras.md:22: cam:get_index() -> int
            local idx = M.active_cam:get_index()
            if idx then
                -- docs: docs/engine/scripting/builtins/libplayer.md:136: player.set_camera(playerid: int, camera_index: int)
                player.set_camera(M.player_id, idx)
            end
        else
            M.init(M.player_id)
        end
    end
    -- docs: docs/engine/scripting/builtins/libplayer.md:130: player.get_camera(playerid: int) -> int
    local current_cam_now = player.get_camera(M.player_id)
    log("camera_mode", {
        mode = mode_name,
        target_cam = (mode_name == "first_person" and M.default_cam_idx or (M.active_cam and M.active_cam:get_index())),
        active_cam_now = current_cam_now,
    })
end

-- Получение текущего режима камеры
function M.get_mode()
    return M.mode
end

-- Центрирование камеры на клетке
function M.focus_on_cell(cx, cz)
    local wx, wz = grid.center_of(cx, cz)
    M.target_pos[1] = wx
    M.target_pos[2] = M.current_pos[2]
    M.target_pos[3] = wz
end

-- Покадровое обновление позиции и интерполяции камеры
function M.update(delta_time)
    if M.mode ~= "tactical" then
        return
    end

    -- Фиксируем выбранный слот хотбара во избежание его прокрутки колесом мыши при зуме
    if type(M.locked_slot) == "number" then
        -- docs: docs/engine/scripting/builtins/libplayer.md:142: player.set_selected_slot(playerid: int, slotid: int)
        player.set_selected_slot(M.player_id, M.locked_slot)
    end

    -- Проверка состояния UI и HUD
    -- docs: docs/engine/scripting/builtins/libhud.md:73: hud.is_paused() -> bool
    -- docs: docs/engine/scripting/builtins/libhud.md:80: hud.is_inventory_open() -> bool
    local ui_active = hud.is_paused() or hud.is_inventory_open()
    -- docs: docs/engine/scripting/builtins/libgui.md:53: gui.get_active_frame() -> str
    local active_frame = gui.get_active_frame()
    local chat_active = (active_frame ~= "" and active_frame ~= "vtt:tactical_frame" and active_frame ~= nil)

    -- Поддерживаем свободный системный курсор в тактическом режиме, если не активен чат/меню
    if not ui_active and not chat_active then
        if active_frame == "" or active_frame == nil then
            -- docs: docs/engine/scripting/builtins/libgui.md:57: gui.set_active_frame(id: str)
            gui.set_active_frame("vtt:tactical_frame")
        end
    end

    local dt = delta_time or 0.016

    -- Панорамирование и зум (только если нет активного UI / чата / паузы / инвентаря)
    if not ui_active and not chat_active then
        local move_x, move_z = 0, 0
        -- docs: docs/engine/scripting/builtins/libinput.md:83: input.is_active(bindname: str) --> bool
        -- docs: docs/engine/scripting/builtins/libinput.md:98: input.is_pressed(code: str) --> bool
        if input.is_active("vtt.cam_forward") or input.is_pressed("key:up") then
            move_z = move_z - 1
        end
        -- docs: docs/engine/scripting/builtins/libinput.md:83: input.is_active(bindname: str) --> bool
        -- docs: docs/engine/scripting/builtins/libinput.md:98: input.is_pressed(code: str) --> bool
        if input.is_active("vtt.cam_back") or input.is_pressed("key:down") then
            move_z = move_z + 1
        end
        -- docs: docs/engine/scripting/builtins/libinput.md:83: input.is_active(bindname: str) --> bool
        -- docs: docs/engine/scripting/builtins/libinput.md:98: input.is_pressed(code: str) --> bool
        if input.is_active("vtt.cam_left") or input.is_pressed("key:left") then
            move_x = move_x - 1
        end
        -- docs: docs/engine/scripting/builtins/libinput.md:83: input.is_active(bindname: str) --> bool
        -- docs: docs/engine/scripting/builtins/libinput.md:98: input.is_pressed(code: str) --> bool
        if input.is_active("vtt.cam_right") or input.is_pressed("key:right") then
            move_x = move_x + 1
        end

        if move_x ~= 0 or move_z ~= 0 then
            if move_x ~= 0 and move_z ~= 0 then
                local inv = 0.70710678
                move_x = move_x * inv
                move_z = move_z * inv
            end
            local speed = M.PAN_SPEED * dt
            M.target_pos[1] = M.target_pos[1] + move_x * speed
            M.target_pos[3] = M.target_pos[3] + move_z * speed
        end

        -- Панорамирование перетаскиванием мыши (средняя или правая кнопка)
        -- docs: docs/engine/scripting/builtins/libinput.md:98: input.is_pressed(code: str) --> bool
        if input.is_pressed("mouse:right") or input.is_pressed("mouse:middle") then
            -- docs: docs/engine/scripting/builtins/libinput.md:61: input.get_mouse_delta() --> {int, int}
            local delta = input.get_mouse_delta()
            if type(delta) == "table" then
                local dx = delta[1] or 0
                local dy = delta[2] or 0
                if dx ~= 0 or dy ~= 0 then
                    M.target_pos[1] = M.target_pos[1] - dx * M.DRAG_SENSITIVITY
                    M.target_pos[3] = M.target_pos[3] - dy * M.DRAG_SENSITIVITY
                end
            end
        end

        -- Зум колесом мыши
        -- docs: docs/engine/scripting/builtins/libinput.md:67: input.get_mouse_scroll() --> int
        local scroll = input.get_mouse_scroll()
        if type(scroll) == "number" and scroll ~= 0 then
            M.target_zoom = math.max(M.MIN_ZOOM, math.min(M.MAX_ZOOM, M.target_zoom + scroll * M.ZOOM_STEP))
        end
    end

    -- Плавная интерполяция позиции и зума
    local t = math.min(1.0, dt * M.SMOOTH_FACTOR)
    M.current_pos[1] = M.current_pos[1] + (M.target_pos[1] - M.current_pos[1]) * t
    M.current_pos[2] = M.current_pos[2] + (M.target_pos[2] - M.current_pos[2]) * t
    M.current_pos[3] = M.current_pos[3] + (M.target_pos[3] - M.current_pos[3]) * t

    M.current_zoom = M.current_zoom + (M.target_zoom - M.current_zoom) * t
    M.zoom = M.current_zoom

    -- Применение параметров к активной камере
    if M.active_cam then
        local cam_x = M.current_pos[1] + M.CAMERA_OFFSET_X * M.current_zoom
        local cam_y = M.current_pos[2] + M.CAMERA_HEIGHT * M.current_zoom
        local cam_z = M.current_pos[3] + M.CAMERA_OFFSET_Z * M.current_zoom
        -- docs: docs/engine/scripting/builtins/libcameras.md:30: cam:set_pos(pos:vec3)
        M.active_cam:set_pos({ cam_x, cam_y, cam_z })
        -- docs: docs/engine/scripting/builtins/libcameras.md:65: cam:look_at(point:vec3)
        M.active_cam:look_at({ M.current_pos[1], M.current_pos[2], M.current_pos[3] })
        -- docs: docs/engine/scripting/builtins/libcameras.md:40: cam:set_zoom(zoom: number)
        M.active_cam:set_zoom(M.current_zoom)
    end
end

return M
