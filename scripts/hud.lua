-- scripts/hud.lua
-- Скрипт жизненного цикла HUD на клиенте VoxelCore.
-- docs: docs/engine/scripting/events.md:230: Callbacks specified in hud.lua script

local camera = require("client/camera")
local picking = require("client/picking")
local overlay = require("client/overlay")
local grid = require("core/grid")
local tokens = require("client/tokens")
local log = require("core/log")

-- Последняя подсвеченная курсором клетка стола
local hovered_cell = nil

-- Состояние интерактивного выбора токена и зоны перемещения
local selected_token = nil
local reachable_zone = nil
local reachable_map = nil
local current_path_target = nil
local last_click_uptime = -1

-- Проверка занятости интерфейса (пауза, инвентарь или активный фрейм UI)
local function is_busy()
    -- docs: docs/engine/scripting/builtins/libhud.md:73: hud.is_paused() -> bool
    -- docs: docs/engine/scripting/builtins/libhud.md:80: hud.is_inventory_open() -> bool
    -- docs: docs/engine/scripting/builtins/libgui.md:53: gui.get_active_frame() -> str
    local frame = gui.get_active_frame()
    return hud.is_paused() or hud.is_inventory_open() or (frame ~= "" and frame ~= "vtt:tactical_frame" and frame ~= nil)
end

-- Сброс текущего выбора токена и очистка слоёв зоны и пути
local function clear_selection()
    if selected_token ~= nil or reachable_zone ~= nil then
        overlay.clear_zone()
        overlay.clear_path()
        selected_token = nil
        reachable_zone = nil
        reachable_map = nil
        current_path_target = nil
        log("token_deselected", {})
    end
end

-- Обработка интерактивного клика ЛКМ в тактическом режиме
local function handle_tactical_click()
    if camera.get_mode() ~= "tactical" or is_busy() then
        return
    end

    local now = -1
    if type(time) == "table" and type(time.uptime) == "function" then
        -- docs: docs/engine/scripting/builtins/libtime.md:16: time.uptime() -> number
        now = time.uptime()
    end
    if now >= 0 and now == last_click_uptime then
        return
    end
    last_click_uptime = now

    local cursor_cell = picking.get_cursor_cell()

    -- 1. Если токен ещё НЕ выбран: пытаемся выбрать токен под курсором
    if selected_token == nil then
        local token_ent = picking.get_cursor_token()
        local tok_info = nil
        local uid = nil

        if token_ent ~= nil then
            tok_info = tokens.get_by_entity(token_ent)
            uid = type(token_ent) == "table" and (token_ent.uid or (token_ent.get_uid and token_ent:get_uid())) or token_ent
        end

        -- Запасной поиск токена по клетке курсора, если луч рейкаста попал в блок под токеном
        if not tok_info and cursor_cell ~= nil then
            tok_info, uid = tokens.get_by_cell(cursor_cell.cx, cursor_cell.cz)
        end

        if tok_info ~= nil then
            local token_cell = tok_info.cell
            if not token_cell and tok_info.pos then
                token_cell = grid.make_cell(tok_info.pos[1], tok_info.pos[3], 0)
            end
            if not token_cell and cursor_cell ~= nil then
                token_cell = cursor_cell
            end

            if token_cell ~= nil then
                local zone = grid.reachable_cells(token_cell, 5)
                local r_map = {}
                for _, c in ipairs(zone) do
                    r_map[grid.key(c)] = true
                end

                selected_token = {
                    uid = uid,
                    token_id = tok_info.token_id or tostring(uid),
                    cell = token_cell,
                }
                reachable_zone = zone
                reachable_map = r_map
                current_path_target = nil

                overlay.show_zone(zone, 3)
                log("token_selected", {
                    token_id = selected_token.token_id,
                    uid = uid,
                    cell = token_cell,
                    zone_count = #zone,
                })
            end
        end
        return
    end

    -- 2. Если токен УЖЕ выбран
    if cursor_cell == nil then
        clear_selection()
        return
    end

    -- Клик по той же клетке токена -> отмена выбора
    if cursor_cell.cx == selected_token.cell.cx and cursor_cell.cz == selected_token.cell.cz then
        clear_selection()
        return
    end

    local cell_k = grid.key(cursor_cell)
    if reachable_map and reachable_map[cell_k] then
        -- Клик внутри доступной зоны: отправляем MoveToken на сервер
        local target = { cx = cursor_cell.cx, cz = cursor_cell.cz, level = cursor_cell.level or 0 }
        tokens.send_move(selected_token.token_id, target, selected_token.cell)
        log("token_move_intent", {
            token_id = selected_token.token_id,
            from = selected_token.cell,
            target = target,
        })
        clear_selection()
    else
        -- Клик вне зоны: отмена выбора
        clear_selection()
    end
end

-- docs: docs/engine/scripting/events.md:233: function on_hud_open(playerid: int)
function on_hud_open(playerid)
    -- Инициализируем тактическую камеру стола для конкретного игрока
    camera.init(playerid)

    -- Получаем и логируем список доступных биндингов движка
    -- docs: docs/engine/scripting/builtins/libinput.md:74: input.get_bindings() --> strings array
    local bindings = input.get_bindings()
    log("input_bindings", { list = bindings })

    -- Диагностика доступных камер движка
    for i = 0, 3 do
        -- docs: docs/engine/scripting/builtins/libcameras.md:10: cameras.get(index: int) -> table
        local c = cameras.get(i)
        if c and type(c) == "table" then
            -- docs: docs/engine/scripting/builtins/libcameras.md:25: cam:get_name() -> str
            local name = type(c.get_name) == "function" and c:get_name() or "unknown"
            -- docs: docs/engine/scripting/builtins/libcameras.md:22: cam:get_index() -> int
            local cam_idx = type(c.get_index) == "function" and c:get_index() or i
            log("camera_dump", { index = i, cam_idx = cam_idx, name = name })
        end
    end

    -- Переключение тактического режима камеры (vtt.camera_toggle)
    -- docs: docs/engine/scripting/builtins/libinput.md:16: input.add_callback(bindname: str, callback: function)
    input.add_callback("vtt.camera_toggle", function()
        -- docs: docs/engine/scripting/builtins/libhud.md:73: hud.is_paused() -> bool
        if hud.is_paused() then
            return
        end
        if camera.get_mode() == "tactical" then
            camera.set_mode("first_person")
            overlay.clear_all()
            hovered_cell = nil
            clear_selection()
        else
            camera.set_mode("tactical")
        end
    end)

    -- Переключение отображения тактической сетки (vtt.grid_toggle)
    -- docs: docs/engine/scripting/builtins/libinput.md:16: input.add_callback(bindname: str, callback: function)
    input.add_callback("vtt.grid_toggle", function()
        -- docs: docs/engine/scripting/builtins/libhud.md:73: hud.is_paused() -> bool
        if not hud.is_paused() and camera.get_mode() == "tactical" then
            overlay.set_grid_visible(not overlay.grid_visible)
        end
    end)

    -- Интерактивный клик по столу (vtt.tactical_click / mouse:left)
    -- docs: docs/engine/scripting/builtins/libinput.md:16: input.add_callback(bindname: str, callback: function)
    input.add_callback("vtt.tactical_click", handle_tactical_click)
    -- docs: docs/engine/scripting/builtins/libinput.md:16: input.add_callback(bindname: str, callback: function)
    input.add_callback("mouse:left", handle_tactical_click)

    -- Пауза при нажатии Escape в тактическом режиме
    -- docs: docs/engine/scripting/builtins/libinput.md:16: input.add_callback(bindname: str, callback: function)
    input.add_callback("key:escape", function()
        if camera.get_mode() == "tactical" then
            -- docs: docs/engine/scripting/builtins/libhud.md:73: hud.is_paused() -> bool
            if not hud.is_paused() then
                -- docs: docs/engine/scripting/builtins/libhud.md:67: hud.pause()
                hud.pause()
                return true
            end
        end
    end)
end

-- docs: docs/engine/scripting/events.md:239: function on_hud_render()
function on_hud_render()
    -- docs: docs/engine/scripting/builtins/libtime.md:8: time.delta() -> number
    local dt = time.delta()
    camera.update(dt)

    -- Интерактивная подсветка клетки под курсором в тактическом режиме (только если нет активного UI / чата / паузы / инвентаря)
    local is_ui_busy = is_busy()

    if camera.get_mode() == "tactical" and not is_ui_busy then
        local cell = picking.get_cursor_cell()
        local is_changed = false

        if cell == nil and hovered_cell ~= nil then
            is_changed = true
        elseif cell ~= nil and hovered_cell == nil then
            is_changed = true
        elseif cell ~= nil and hovered_cell ~= nil then
            if cell.cx ~= hovered_cell.cx or cell.cz ~= hovered_cell.cz then
                is_changed = true
            end
        end

        if is_changed then
            if hovered_cell ~= nil then
                overlay.clear_highlight(hovered_cell.cx, hovered_cell.cz)
            end
            if cell ~= nil then
                overlay.highlight_cell(cell.cx, cell.cz, 1)
            end
            hovered_cell = cell
        end

        -- Интерактивное превью маршрута движения при выбранном токене
        if selected_token ~= nil then
            if cell ~= nil and reachable_map and reachable_map[grid.key(cell)] then
                if current_path_target == nil or current_path_target.cx ~= cell.cx or current_path_target.cz ~= cell.cz then
                    local path = grid.build_path(selected_token.cell, cell)
                    overlay.preview_path(path)
                    current_path_target = { cx = cell.cx, cz = cell.cz }
                end
            else
                if current_path_target ~= nil then
                    overlay.clear_path()
                    current_path_target = nil
                end
            end
        else
            if current_path_target ~= nil then
                overlay.clear_path()
                current_path_target = nil
            end
        end
    end
end

-- Тестовые и диагностические интерфейсы HUD
if _G then
    _G.__vtt_hud_state = {
        get_selected_token = function() return selected_token end,
        get_reachable_zone = function() return reachable_zone end,
        get_current_path_target = function() return current_path_target end,
        clear_selection = clear_selection,
        handle_tactical_click = handle_tactical_click,
    }
end
