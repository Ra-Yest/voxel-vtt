-- scripts/hud.lua
-- Скрипт жизненного цикла HUD на клиенте VoxelCore.
-- docs: docs/engine/scripting/events.md:230: Callbacks specified in hud.lua script

local camera = require("client/camera")
local picking = require("client/picking")
local overlay = require("client/overlay")
local tokens = require("client/tokens")
local log = require("core/log")

-- Последняя подсвеченная курсором клетка стола
local hovered_cell = nil

-- Проверка занятости интерфейса (пауза, инвентарь или активный фрейм UI)
local function is_busy()
    -- docs: docs/engine/scripting/builtins/libhud.md:73: hud.is_paused() -> bool
    -- docs: docs/engine/scripting/builtins/libhud.md:80: hud.is_inventory_open() -> bool
    -- docs: docs/engine/scripting/builtins/libgui.md:53: gui.get_active_frame() -> str
    local frame = gui.get_active_frame()
    return hud.is_paused() or hud.is_inventory_open() or (frame ~= "" and frame ~= "vtt:tactical_frame" and frame ~= nil)
end

-- Обработка интерактивного клика ЛКМ в тактическом режиме
local function on_click()
    if camera.get_mode() ~= "tactical" or is_busy() then
        return
    end

    local cell = picking.get_cursor_cell()
    local ref = tokens.has_selection() and nil or picking.get_cursor_token()
    tokens.click(cell, ref)
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
            tokens.clear_selection()
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

    -- Интерактивный клик по столу (vtt.tactical_click)
    -- docs: docs/engine/scripting/builtins/libinput.md:16: input.add_callback(bindname: str, callback: function)
    input.add_callback("vtt.tactical_click", on_click)

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

        tokens.hover(cell)
    end
end
