-- client/picking.lua
-- Слой: client
-- Спека: specs/client-picking.md
-- Назначение: Определение клетки и токена под курсором мыши через рейкаст.
-- Публичные функции:
--   get_cursor_cell()
--   get_cursor_token()
--   screen_to_ray(screen_x, screen_y)

local grid = require("core/grid")

local M = {}

-- Вспомогательная функция нормализации трёхмерного вектора
local function normalize(v)
    local len_sq = v[1] * v[1] + v[2] * v[2] + v[3] * v[3]
    if len_sq > 1e-12 then
        local len = math.sqrt(len_sq)
        return { v[1] / len, v[2] / len, v[3] / len }
    end
    return { 0, 0, 0 }
end

-- Преобразование экранных координат в луч в 3D (origin, dir)
function M.screen_to_ray(screen_x, screen_y)
    -- docs: docs/engine/scripting/builtins/libgui.md:17: gui.get_viewport() -> {int, int}
    local vp = gui.get_viewport()
    if not vp or not vp[1] or not vp[2] or vp[1] <= 0 or vp[2] <= 0 then
        return { 0, 0, 0 }, { 0, -1, 0 }
    end

    local cam = nil
    -- docs: docs/engine/scripting/builtins/libhud.md:65: hud.get_player() -> int
    if type(hud) == "table" and type(hud.get_player) == "function" and type(player) == "table" and type(player.get_camera) == "function" then
        local pid = hud.get_player()
        if type(pid) == "number" then
            -- docs: docs/engine/scripting/builtins/libplayer.md:130: player.get_camera(playerid: int) -> int
            local cam_idx = player.get_camera(pid)
            if type(cam_idx) == "number" then
                -- docs: docs/engine/scripting/builtins/libcameras.md:10: cameras.get(index: int) -> table
                cam = cameras.get(cam_idx)
            end
        end
    end
    if not cam then
        -- docs: docs/engine/scripting/builtins/libcameras.md:8: cameras.get(name: str) -> table
        cam = cameras.get("vtt:tactical")
        if not cam then
            -- docs: docs/engine/scripting/builtins/libcameras.md:8: cameras.get(name: str) -> table
            cam = cameras.get("tactical")
        end
    end
    if not cam then
        return { 0, 0, 0 }, { 0, -1, 0 }
    end

    -- Нормализованные экранные координаты (NDC) в диапазоне [-1, 1]
    local ndc_x = (2.0 * screen_x / vp[1]) - 1.0
    local ndc_y = 1.0 - (2.0 * screen_y / vp[2])

    -- docs: docs/engine/scripting/builtins/libcameras.md:48: cam:is_flipped() -> bool
    if cam.is_flipped and cam:is_flipped() then
        ndc_y = -ndc_y
    end

    -- docs: docs/engine/scripting/builtins/libcameras.md:28: cam:get_pos() -> vec3
    local pos = cam:get_pos() or { 0, 0, 0 }
    -- docs: docs/engine/scripting/builtins/libcameras.md:58: cam:get_front() -> vec3
    local front = cam:get_front() or { 0, -1, 0 }
    -- docs: docs/engine/scripting/builtins/libcameras.md:60: cam:get_right() -> vec3
    local right = cam:get_right() or { 1, 0, 0 }
    -- docs: docs/engine/scripting/builtins/libcameras.md:62: cam:get_up() -> vec3
    local up = cam:get_up() or { 0, 1, 0 }

    -- docs: docs/engine/scripting/builtins/libcameras.md:43: cam:get_fov() -> number
    local fov = (cam.get_fov and cam:get_fov()) or 45.0
    -- docs: docs/engine/scripting/builtins/libcameras.md:38: cam:get_zoom() -> number
    local zoom = (cam.get_zoom and cam:get_zoom()) or 1.0
    if zoom <= 0 then zoom = 1.0 end

    -- docs: docs/engine/scripting/builtins/libcameras.md:53: cam:is_perspective() -> bool
    local is_persp = true
    if cam.is_perspective then
        is_persp = cam:is_perspective()
    end

    local aspect = vp[1] / vp[2]
    -- В движке VoxelCore матрица проекции Camera::getProjection вычисляет effective_fov = fov * zoom:
    -- tan_half_fov = tanf((fov * zoom) * 0.5), P[0][0] = 1.0 / (aspect * tan_half_fov), P[1][1] = 1.0 / tan_half_fov
    local effective_fov = fov * zoom
    if effective_fov > 170.0 then effective_fov = 170.0 end
    if effective_fov < 1.0 then effective_fov = 1.0 end
    local tan_half_fov = math.tan(math.rad(effective_fov * 0.5))

    if is_persp then
        local half_h = tan_half_fov
        local half_w = half_h * aspect
        local origin = { pos[1], pos[2], pos[3] }
        local dx = front[1] + right[1] * (ndc_x * half_w) + up[1] * (ndc_y * half_h)
        local dy = front[2] + right[2] * (ndc_x * half_w) + up[2] * (ndc_y * half_h)
        local dz = front[3] + right[3] * (ndc_x * half_w) + up[3] * (ndc_y * half_h)
        local dir = normalize({ dx, dy, dz })
        return origin, dir
    else
        local ortho_half_h = effective_fov * 0.5
        local ortho_half_w = ortho_half_h * aspect
        local origin = {
            pos[1] + right[1] * (ndc_x * ortho_half_w) + up[1] * (ndc_y * ortho_half_h),
            pos[2] + right[2] * (ndc_x * ortho_half_w) + up[2] * (ndc_y * ortho_half_h),
            pos[3] + right[3] * (ndc_x * ortho_half_w) + up[3] * (ndc_y * ortho_half_h),
        }
        local dir = normalize({ front[1], front[2], front[3] })
        return origin, dir
    end
end

-- Получение клетки под курсором мыши
function M.get_cursor_cell()
    -- docs: docs/engine/scripting/builtins/libinput.md:55: input.get_mouse_pos() -> {int, int}
    local pos = input.get_mouse_pos()
    if not pos or not pos[1] or not pos[2] then
        return nil
    end

    local mx, my = pos[1], pos[2]
    local origin, dir = M.screen_to_ray(mx, my)
    if not origin or not dir then
        return nil
    end

    -- docs: docs/engine/scripting/builtins/libblock.md:140: block.raycast(start: vec3, dir: vec3, max_distance: number, [optional] dest: table, [optional] filter: table) -> table or nil
    local hit = block.raycast(origin, dir, 128.0)
    if hit and hit.iendpoint then
        local bx, bz = hit.iendpoint[1], hit.iendpoint[3]
        local cx, cz = grid.cell_of(bx, bz)
        return { cx = cx, cz = cz, level = 0 }
    end
    return nil
end

-- Получение токена под курсором мыши
function M.get_cursor_token()
    -- docs: docs/engine/scripting/builtins/libinput.md:55: input.get_mouse_pos() -> {int, int}
    local pos = input.get_mouse_pos()
    if not pos or not pos[1] or not pos[2] then
        return nil
    end

    local mx, my = pos[1], pos[2]
    local origin, dir = M.screen_to_ray(mx, my)
    if not origin or not dir then
        return nil
    end

    local pid = 0
    if type(hud) == "table" and type(hud.get_player) == "function" then
        -- docs: docs/engine/scripting/builtins/libhud.md:65: hud.get_player() -> int
        pid = hud.get_player() or 0
    end
    local ignore_uid = -1
    if type(player) == "table" and type(player.get_entity) == "function" then
        -- docs: docs/engine/scripting/builtins/libplayer.md:160: player.get_entity(playerid: int) -> int
        ignore_uid = player.get_entity(pid) or -1
    end

    -- docs: docs/engine/scripting/builtins/libentities.md:69: entities.raycast(start: vec3, dir: vec3, max_distance: number, ignore: int, [optional] destination: table, [optional] filter: table, [optional] include_non_selectable = false) -> table or nil
    local hit = entities.raycast(origin, dir, 128.0, ignore_uid)
    if hit and hit.entity ~= nil then
        return hit.entity
    end
    return nil
end

return M
