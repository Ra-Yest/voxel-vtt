-- client/overlay.lua
-- Слой: client
-- Спека: specs/client-overlay.md
-- Назначение: Отрисовка тактической сетки клеток и интерактивная подсветка через blockwraps с поддержкой приоритетов слоёв.
-- Публичные функции:
--   highlight_cell(cx, cz, color_id)
--   clear_highlight(cx, cz)
--   set_grid_visible(visible)
--   preview_path(cells)
--   clear_path()
--   show_zone(cells, color_id)
--   clear_zone()
--   clear_all()
--   find_surface_y(bx, bz)
--   get_block_edge_mask(dx, dz, s)
--   get_cell_layer(cx, cz)

local grid = require("core/grid")
local log = require("core/log")

local M = {}

M.RAYCAST_START_Y = 255.0
M.RAYCAST_DIST = 255.0
M.DEFAULT_Y = 0
M.GRID_RADIUS = 8

-- Публичные коллекции активных обёрток по слоям
M.active_wraps = {}
M.path_wraps = {}
M.path_cells = {}
M.zone_wraps = {}
M.zone_cells = {}
M.grid_wraps = {}
M.grid_visible = false

-- Внутреннее состояние слоёв для разрешения приоритетов
M.state_active = {}
M.state_path = {}
M.state_zone = {}
M.state_grid = {}

-- Текущие отрендеренные в движке клетки и обёртки по слоям
M.rendered_cells = {}
M.path_wraps_by_cell = {}
M.zone_wraps_by_cell = {}
M.grid_wraps_by_cell = {}

-- Цветовые профили для окраски обёрток через set_tints
M.TINTS = {
    grid = { 0.85, 0.85, 0.85 }, -- Базовая сетка
    [1]  = { 1.0, 0.85, 0.2 },   -- Жёлтый (курсор / фокус клетки)
    [2]  = { 0.2, 0.95, 0.35 },  -- Зелёный (превью пути)
    [3]  = { 0.25, 0.65, 1.0 },  -- Голубой (зона перемещения токена)
}

local function resolve_tint(color_id, default_id)
    if type(color_id) == "table" and #color_id >= 3 then
        return color_id
    end
    return M.TINTS[color_id] or M.TINTS[default_id or 1]
end

-- Определение битовой маски внешних краёв клетки для блока (dx, dz)
function M.get_block_edge_mask(dx, dz, s)
    local mask = 0
    -- На грани +Y движка VoxelCore текстурные координаты UV развернуты на 180° относительно мировых осей X/Z
    -- (верх текстуры Y=0 рендерится на South +Z, левый край X=0 — на East +X).
    -- Чтобы внешние границы рисовались снаружи клетки, а не образовывали внутренний крест:
    -- - Внешний край North (-Z, dz == 0) соответствует нижней грани текстуры (бит 4)
    -- - Внешний край East (+X, dx == s - 1) соответствует левой грани текстуры (бит 8)
    -- - Внешний край South (+Z, dz == s - 1) соответствует верхней грани текстуры (бит 1)
    -- - Внешний край West (-X, dx == 0) соответствует правой грани текстуры (бит 2)
    if dz == 0 then mask = mask + 4 end     -- North outer edge -> texture bottom (бит 4)
    if dx == s - 1 then mask = mask + 8 end -- East outer edge -> texture left (бит 8)
    if dz == s - 1 then mask = mask + 1 end -- South outer edge -> texture top (бит 1)
    if dx == 0 then mask = mask + 2 end     -- West outer edge -> texture right (бит 2)
    return mask
end

-- Поиск высоты верхнего блока поверхности в колонке (bx, bz)
function M.find_surface_y(bx, bz)
    -- docs: docs/engine/scripting/builtins/libblock.md:140: block.raycast(start: vec3, dir: vec3, max_distance: number, [optional] dest: table, [optional] filter: table) -> table or nil
    local hit = block.raycast({ bx + 0.5, M.RAYCAST_START_Y, bz + 0.5 }, { 0, -1, 0 }, M.RAYCAST_DIST)
    if hit and hit.iendpoint then
        local y = hit.iendpoint[2]
        -- Спускаемся сквозь неполные/проходимые блоки (трава, цветы, факелы и т.д.) к реальному твердому основанию
        -- docs: docs/engine/scripting/builtins/libblock.md:55: block.is_solid_at(x: int, y: int, z: int) -> bool
        -- docs: docs/engine/scripting/builtins/libblock.md:59: block.is_replaceable_at(x: int, y: int, z: int) -> bool
        while y > 0 and (block.is_solid_at(bx, y, bz) == false or block.is_replaceable_at(bx, y, bz) == true) do
            y = y - 1
        end
        return y
    end
    return M.DEFAULT_Y
end

-- Вспомогательная функция оборачивания блоков клетки с маской и окраской (для подсветки курсора, пути и зоны)
local function wrap_cell_blocks(cx, cz, tint, wrap_target, skip_zero_mask)
    local s = grid.CELL_SIZE
    local blocks = grid.blocks_of(cx, cz)
    for _, b in ipairs(blocks) do
        local dx = b[1] - cx * s
        local dz = b[2] - cz * s
        local mask = M.get_block_edge_mask(dx, dz, s)
        if not (skip_zero_mask and mask == 0) then
            local y = M.find_surface_y(b[1], b[2])
            local tex = "blocks:cell_edge_" .. tostring(mask)
            -- docs: docs/engine/scripting/builtins/libgfx-blockwraps.md:10: gfx.blockwraps.wrap(position: vec3, texture: string, [optional] emission: number = 1.0) -> int
            local wid = gfx.blockwraps.wrap({ b[1], y, b[2] }, tex)
            if gfx.blockwraps.set_faces then
                -- docs: docs/engine/scripting/builtins/libgfx-blockwraps.md:29: gfx.blockwraps.set_faces(id: int, face1?: string, face2?: string, face3?: string, face4?: string, face5?: string, face6?: string)
                gfx.blockwraps.set_faces(wid, nil, nil, nil, tex, nil, nil)
            end
            if gfx.blockwraps.set_tints then
                -- docs: docs/engine/scripting/builtins/libgfx-blockwraps.md:45: gfx.blockwraps.set_tints(id: int, face1?: vec3, face2?: vec3, face3?: vec3, face4?: vec3, face5?: vec3, face6?: vec3)
                gfx.blockwraps.set_tints(wid, nil, nil, nil, tint, nil, nil)
            end
            wrap_target[#wrap_target + 1] = wid
        end
    end
end

-- Оборачивание 4 внешних угловых маркеров (corner brackets) клетки
local function wrap_brackets(cx, cz, tint, wrap_target, prefix)
    local s = grid.CELL_SIZE
    local pfx = prefix or "blocks:bracket_"
    local corners = {
        { dx = 0,     dz = 0,     tex = pfx .. "nw" },
        { dx = s - 1, dz = 0,     tex = pfx .. "ne" },
        { dx = 0,     dz = s - 1, tex = pfx .. "sw" },
        { dx = s - 1, dz = s - 1, tex = pfx .. "se" },
    }

    for _, c in ipairs(corners) do
        local bx = cx * s + c.dx
        local bz = cz * s + c.dz
        local y = M.find_surface_y(bx, bz)
        -- docs: docs/engine/scripting/builtins/libgfx-blockwraps.md:10: gfx.blockwraps.wrap(position: vec3, texture: string, [optional] emission: number = 1.0) -> int
        local wid = gfx.blockwraps.wrap({ bx, y, bz }, c.tex)
        if gfx.blockwraps.set_faces then
            -- docs: docs/engine/scripting/builtins/libgfx-blockwraps.md:29: gfx.blockwraps.set_faces(id: int, face1?: string, face2?: string, face3?: string, face4?: string, face5?: string, face6?: string)
            gfx.blockwraps.set_faces(wid, nil, nil, nil, c.tex, nil, nil)
        end
        if gfx.blockwraps.set_tints then
            -- docs: docs/engine/scripting/builtins/libgfx-blockwraps.md:45: gfx.blockwraps.set_tints(id: int, face1?: vec3, face2?: vec3, face3?: vec3, face4?: vec3, face5?: vec3, face6?: vec3)
            gfx.blockwraps.set_tints(wid, nil, nil, nil, tint, nil, nil)
        end
        wrap_target[#wrap_target + 1] = wid
    end
end

-- Оборачивание 4 внешних угловых маркеров клетки для базовой сетки стола (5px маркеры)
local function wrap_grid_brackets(cx, cz, tint, wrap_target)
    wrap_brackets(cx, cz, tint, wrap_target, "blocks:bracket_")
end

-- Оборачивание 4 внешних угловых маркеров клетки для зоны перемещения и пути (удлинённые 6px маркеры)
local function wrap_zone_path_brackets(cx, cz, tint, wrap_target)
    wrap_brackets(cx, cz, tint, wrap_target, "blocks:bracket_long_")
end

M.wrap_brackets = wrap_brackets
M.wrap_grid_brackets = wrap_grid_brackets
M.wrap_zone_path_brackets = wrap_zone_path_brackets

-- Пересчёт плоских массивов обёрток по слоям
local function rebuild_layer_arrays()
    local path_arr = {}
    for _, wrap_ids in pairs(M.path_wraps_by_cell) do
        for _, wid in ipairs(wrap_ids) do
            path_arr[#path_arr + 1] = wid
        end
    end
    M.path_wraps = path_arr

    local zone_arr = {}
    for _, wrap_ids in pairs(M.zone_wraps_by_cell) do
        for _, wid in ipairs(wrap_ids) do
            zone_arr[#zone_arr + 1] = wid
        end
    end
    M.zone_wraps = zone_arr

    local grid_arr = {}
    for _, wrap_ids in pairs(M.grid_wraps_by_cell) do
        for _, wid in ipairs(wrap_ids) do
            grid_arr[#grid_arr + 1] = wid
        end
    end
    M.grid_wraps = grid_arr
end

-- Определение наивысшего активного слоя для клетки по правилу: active > path > zone > grid
local function get_effective_layer(k)
    if M.state_active[k] then
        local entry = M.state_active[k]
        return "active", entry.color_id or 1, false
    elseif M.state_path[k] then
        return "path", 2, false
    elseif M.state_zone[k] then
        local entry = M.state_zone[k]
        return "zone", entry.color_id or 3, false
    elseif M.grid_visible and M.state_grid[k] then
        return "grid", "grid", true
    else
        return nil
    end
end

-- Обновление физических обёрток клетки в соответствии с приоритетом
local function update_cell_rendering(cx, cz)
    local k = grid.key({ cx = cx, cz = cz, level = 0 })
    local target_layer, color_id, skip_zero = get_effective_layer(k)
    local current = M.rendered_cells[k]

    -- Если отображаемый слой и цвет не изменились, ничего не пересоздаём
    if current and current.layer == target_layer and current.color_id == color_id then
        return
    end

    -- Удаляем старые обёртки, если клетка ранее рендерилась
    if current then
        for _, wid in ipairs(current.wrap_ids) do
            if type(gfx.blockwraps) == "table" and gfx.blockwraps.unwrap then
                -- docs: docs/engine/scripting/builtins/libgfx-blockwraps.md:20: gfx.blockwraps.unwrap(id: int)
                gfx.blockwraps.unwrap(wid)
            end
        end
        if current.layer == "active" then
            M.active_wraps[k] = nil
        elseif current.layer == "path" then
            M.path_wraps_by_cell[k] = nil
        elseif current.layer == "zone" then
            M.zone_wraps_by_cell[k] = nil
        elseif current.layer == "grid" then
            M.grid_wraps_by_cell[k] = nil
        end
        M.rendered_cells[k] = nil
    end

    -- Создаём обёртки нового слоя победителя
    if target_layer then
        local tint = resolve_tint(color_id, 1)
        local wrap_ids = {}
        if target_layer == "grid" then
            wrap_grid_brackets(cx, cz, tint, wrap_ids)
            M.grid_wraps_by_cell[k] = wrap_ids
        elseif target_layer == "path" or target_layer == "zone" then
            wrap_zone_path_brackets(cx, cz, tint, wrap_ids)
            if target_layer == "path" then
                M.path_wraps_by_cell[k] = wrap_ids
            elseif target_layer == "zone" then
                M.zone_wraps_by_cell[k] = wrap_ids
            end
        else -- target_layer == "active"
            wrap_cell_blocks(cx, cz, tint, wrap_ids, false)
            M.active_wraps[k] = wrap_ids
        end
        M.rendered_cells[k] = { layer = target_layer, color_id = color_id, wrap_ids = wrap_ids }
    end
end

-- Запрос текущего отображаемого слоя клетки
function M.get_cell_layer(cx, cz)
    local k = grid.key({ cx = cx, cz = cz, level = 0 })
    local cell = M.rendered_cells[k]
    return cell and cell.layer or nil
end

-- Подсветка отдельной клетки (слой active, наивысший приоритет)
function M.highlight_cell(cx, cz, color_id)
    local k = grid.key({ cx = cx, cz = cz, level = 0 })
    M.state_active[k] = { cx = cx, cz = cz, color_id = color_id }
    update_cell_rendering(cx, cz)
    rebuild_layer_arrays()
end

-- Снятие подсветки с клетки (слой active, восстановление нижележащего слоя)
function M.clear_highlight(cx, cz)
    local k = grid.key({ cx = cx, cz = cz, level = 0 })
    if M.state_active[k] then
        M.state_active[k] = nil
        update_cell_rendering(cx, cz)
        rebuild_layer_arrays()
    end
end

-- Отображение превью пути перемещения (слой path, приоритет 2)
function M.preview_path(cells)
    local old_path = M.state_path
    M.state_path = {}
    M.path_cells = {}
    local affected = {}
    for k, c in pairs(old_path) do
        affected[k] = c
    end

    if type(cells) == "table" then
        for _, c in ipairs(cells) do
            if type(c) == "table" and c.cx and c.cz then
                local k = grid.key({ cx = c.cx, cz = c.cz, level = 0 })
                local entry = { cx = c.cx, cz = c.cz }
                M.state_path[k] = entry
                M.path_cells[#M.path_cells + 1] = entry
                affected[k] = entry
            end
        end
    end

    for _, c in pairs(affected) do
        update_cell_rendering(c.cx, c.cz)
    end
    rebuild_layer_arrays()
end

-- Очистка слоя превью пути
function M.clear_path()
    M.preview_path(nil)
end

-- Отображение зоны доступного перемещения токена (слой zone, приоритет 3)
function M.show_zone(cells, color_id)
    local old_zone = M.state_zone
    M.state_zone = {}
    M.zone_cells = {}
    local affected = {}
    for k, c in pairs(old_zone) do
        affected[k] = c
    end

    local resolved_color = color_id or 3
    if type(cells) == "table" then
        for _, c in ipairs(cells) do
            if type(c) == "table" and c.cx and c.cz then
                local k = grid.key({ cx = c.cx, cz = c.cz, level = 0 })
                local entry = { cx = c.cx, cz = c.cz, color_id = resolved_color }
                M.state_zone[k] = entry
                M.zone_cells[#M.zone_cells + 1] = entry
                affected[k] = entry
            end
        end
    end

    for _, c in pairs(affected) do
        update_cell_rendering(c.cx, c.cz)
    end
    rebuild_layer_arrays()
end

-- Очистка слоя зоны перемещения токена
function M.clear_zone()
    M.show_zone(nil)
end

-- Включение/выключение отображения базовой сетки стола (слой grid, приоритет 4 / низший)
function M.set_grid_visible(visible)
    if not visible then
        if not M.grid_visible then return end
        M.grid_visible = false
        local old_grid = M.state_grid
        M.state_grid = {}
        for _, c in pairs(old_grid) do
            update_cell_rendering(c.cx, c.cz)
        end
        rebuild_layer_arrays()
        log("overlay_grid", { visible = false, wraps = 0 })
        return
    end

    -- visible == true
    local old_grid = M.state_grid
    M.state_grid = {}
    local affected = {}
    for k, c in pairs(old_grid) do
        affected[k] = c
    end

    -- Определение центра построения сетки по фокусу взгляда камеры
    local center_pos = { 0, 0, 0 }
    -- docs: docs/engine/scripting/builtins/libcameras.md:8: cameras.get(name: str) -> table
    local cam = cameras.get("vtt:tactical")
    if not cam then
        -- docs: docs/engine/scripting/builtins/libcameras.md:8: cameras.get(name: str) -> table
        cam = cameras.get("tactical")
    end
    if cam then
        -- docs: docs/engine/scripting/builtins/libcameras.md:28: cam:get_pos() -> vec3
        local pos = (cam.get_pos and cam:get_pos()) or { 0, 0, 0 }
        -- docs: docs/engine/scripting/builtins/libcameras.md:58: cam:get_front() -> vec3
        local front = (cam.get_front and cam:get_front()) or { 0, -1, 0 }

        -- Рейкаст из камеры вдоль направления взгляда для центрирования сетки на видимом рельефе
        -- docs: docs/engine/scripting/builtins/libblock.md:140: block.raycast(start: vec3, dir: vec3, max_distance: number, [optional] dest: table, [optional] filter: table) -> table or nil
        local hit = block.raycast(pos, front, 256.0)
        if hit and hit.iendpoint then
            center_pos = { hit.iendpoint[1], hit.iendpoint[2], hit.iendpoint[3] }
        else
            -- Аналитическое пересечение луча с плоскостью Y = DEFAULT_Y при отсутствии блоков
            if front[2] and front[2] < -1e-4 then
                local t = (M.DEFAULT_Y - pos[2]) / front[2]
                center_pos = { pos[1] + t * front[1], M.DEFAULT_Y, pos[3] + t * front[3] }
            else
                center_pos = pos
            end
        end
    end

    local center_cx, center_cz = grid.cell_of(center_pos[1], center_pos[3])
    local r = M.GRID_RADIUS
    local r_sq = r * r
    for cx = center_cx - r, center_cx + r do
        local dcx = cx - center_cx
        for cz = center_cz - r, center_cz + r do
            local dcz = cz - center_cz
            -- Круговой фильтр сетки: dcx^2 + dcz^2 <= r^2
            if dcx * dcx + dcz * dcz <= r_sq then
                local k = grid.key({ cx = cx, cz = cz, level = 0 })
                local entry = { cx = cx, cz = cz }
                M.state_grid[k] = entry
                affected[k] = entry
            end
        end
    end

    M.grid_visible = true
    for _, c in pairs(affected) do
        update_cell_rendering(c.cx, c.cz)
    end
    rebuild_layer_arrays()
    log("overlay_grid", { visible = true, wraps = #M.grid_wraps, cell_size = grid.CELL_SIZE, radius = r })
end

-- Полная очистка всех активных обёрток всех 4 слоёв
function M.clear_all()
    M.state_path = {}
    M.path_cells = {}
    M.state_zone = {}
    M.zone_cells = {}
    M.state_active = {}
    M.state_grid = {}
    M.grid_visible = false

    for _, cell in pairs(M.rendered_cells) do
        for _, wid in ipairs(cell.wrap_ids) do
            if type(gfx.blockwraps) == "table" and gfx.blockwraps.unwrap then
                -- docs: docs/engine/scripting/builtins/libgfx-blockwraps.md:20: gfx.blockwraps.unwrap(id: int)
                gfx.blockwraps.unwrap(wid)
            end
        end
    end
    M.rendered_cells = {}
    M.active_wraps = {}
    M.path_wraps_by_cell = {}
    M.zone_wraps_by_cell = {}
    M.grid_wraps_by_cell = {}
    M.path_wraps = {}
    M.zone_wraps = {}
    M.grid_wraps = {}
end

return M
