-- client/tokens.lua
-- Слой: client
-- Спека: specs/client-tokens.md, specs/net-split-client.md, specs/client-tokens-selection.md
-- Назначение: Клиентское состояние токенов: реестр сущностей, выбор, превью перемещения, отправка намерения на сервер.
-- Публичные функции:
--   select(token_id, cell)
--   get_selected()
--   has_selection()
--   get_selection()
--   clear_selection()
--   click(cursor_cell, token_ref)
--   hover(cursor_cell)
--   preview_move(token_id, target_cell, cell)
--   confirm_move()
--   cancel_preview()
--   on_entity(uid, fresh, initial)
--   get_by_entity(entity_or_uid)
--   get_by_cell(cx, cz)
--   send_move(token_id, target_cell, from_cell)

local log = require("core/log")
local grid = require("core/grid")
local gm_rules = require("core/gm_rules")
local overlay = require("client/overlay")
local channel = require("net/channel")

local M = {}

M.registry = {}
M.selected_token_id = nil
M.selected_uid = nil
M.selected_cell = nil
M.preview_target = nil
M.reachable_zone = nil
M.reachable_map = nil
M.current_path_target = nil
M._prune_unavailable_logged = nil

-- Вспомогательная проверка существования сущности и очистка призрака
local function check_and_prune(uid)
    if not uid then return false end
    if type(entities) == "table" and type(entities.exists) == "function" then
        -- docs: docs/engine/scripting/builtins/libentities.md:21: entities.exists(uid: int) -> bool
        local exists = entities.exists(uid)
        if exists == false then
            M.registry[uid] = nil
            log("token_registry_pruned", { uid = uid })
            return false
        elseif exists == nil then
            if not M._prune_unavailable_logged then
                M._prune_unavailable_logged = true
                log("token_registry_prune_unavailable", {})
            end
            return true
        end
        return true
    else
        if not M._prune_unavailable_logged then
            M._prune_unavailable_logged = true
            log("token_registry_prune_unavailable", {})
        end
        return true
    end
end

-- Обработчик обновлений сущности токена от Neutron
function M.on_entity(uid, fresh, initial)
    if not M.registry[uid] then
        M.registry[uid] = { uid = uid }
    end
    local tok = M.registry[uid]
    tok.uid = uid

    fresh = fresh or {}
    initial = initial or {}

    if fresh.token_id then
        tok.token_id = fresh.token_id
    elseif initial.token_id and not tok.token_id then
        tok.token_id = initial.token_id
    end

    if fresh.pos then
        tok.pos = fresh.pos
        tok.cell = grid.make_cell(fresh.pos[1], fresh.pos[3], 0)
    elseif initial.pos and not tok.pos then
        tok.pos = initial.pos
        tok.cell = grid.make_cell(initial.pos[1], initial.pos[3], 0)
    end
end

-- Получение данных клиента по UID сущности (или таблице сущности)
function M.get_by_entity(entity_or_uid)
    if entity_or_uid == nil then return nil end
    local uid = entity_or_uid
    if type(entity_or_uid) == "table" then
        uid = entity_or_uid.uid or (type(entity_or_uid.get_uid) == "function" and entity_or_uid:get_uid())
    end
    if uid == nil then return nil end
    local tok = M.registry[uid]
    if not tok then return nil end
    if not check_and_prune(uid) then
        return nil
    end
    return tok
end

-- Поиск токена на клиенте по клетке (cx, cz)
function M.get_by_cell(cx, cz)
    for uid, tok in pairs(M.registry) do
        local matches = false
        if tok.cell and tok.cell.cx == cx and tok.cell.cz == cz then
            matches = true
        elseif tok.pos then
            local tcx, tcz = grid.cell_of(tok.pos[1], tok.pos[3])
            if tcx == cx and tcz == cz then
                matches = true
            end
        end
        if matches then
            if check_and_prune(uid) then
                return tok, uid
            end
        end
    end
    return nil
end

-- Клиентская отправка намерения MoveToken на сервер
function M.send_move(token_id, target_cell, from_cell)
    local num_uid = tonumber(token_id)
    if num_uid and M.registry[num_uid] and M.registry[num_uid].token_id then
        token_id = M.registry[num_uid].token_id
    end
    local payload = {
        token_id = tostring(token_id),
        target_cell = {
            cx = target_cell.cx,
            cz = target_cell.cz,
            level = target_cell.level or 0,
        },
        from_cell = from_cell and {
            cx = from_cell.cx,
            cz = from_cell.cz,
            level = from_cell.level or 0,
        } or nil,
    }
    local send_ok, res = pcall(channel.send, "MoveToken", payload)
    if not send_ok or res == false then
        log("token_move_send_failed", { token_id = payload.token_id, target_cell = payload.target_cell })
        return false
    end
    log("token_move_sent", { token_id = payload.token_id, target_cell = payload.target_cell, from_cell = payload.from_cell })
    return true
end

-- Выбор токена кликом
function M.select(token_id, cell)
    M.selected_token_id = token_id
    M.selected_cell = cell
    M.preview_target = nil
end

-- Получение текущего выбранного токена
function M.get_selected()
    return M.selected_token_id
end

-- Проверка наличия активного выбора токена
function M.has_selection()
    return M.selected_token_id ~= nil
end

-- Получение структуры активного выбора для тестов и оверлея
function M.get_selection()
    if not M.has_selection() then
        return nil
    end
    return {
        token_id = M.selected_token_id,
        uid = M.selected_uid,
        cell = M.selected_cell,
        zone_count = M.reachable_zone and #M.reachable_zone or 0,
    }
end

-- Сброс текущего выбора токена и очистка слоёв зоны и пути
function M.clear_selection()
    if M.has_selection() or M.reachable_zone ~= nil then
        overlay.clear_zone()
        overlay.clear_path()
        M.selected_token_id = nil
        M.selected_uid = nil
        M.selected_cell = nil
        M.preview_target = nil
        M.reachable_zone = nil
        M.reachable_map = nil
        M.current_path_target = nil
        log("token_deselected", {})
    end
end

-- Обработка клика ЛКМ в тактическом режиме: выбор токена или перемещение
function M.click(cursor_cell, token_ref)
    -- 1. Если токен ещё НЕ выбран
    if not M.has_selection() then
        local tok_info = nil
        local uid = nil

        if token_ref ~= nil then
            tok_info = M.get_by_entity(token_ref)
            uid = type(token_ref) == "table" and (token_ref.uid or (token_ref.get_uid and token_ref:get_uid())) or (type(token_ref) == "number" and token_ref)
        end

        -- Запасной поиск токена по клетке курсора, если луч попал в блок под токеном
        if not tok_info and cursor_cell ~= nil then
            tok_info, uid = M.get_by_cell(cursor_cell.cx, cursor_cell.cz)
        end

        if tok_info ~= nil then
            uid = uid or tok_info.uid
            local token_cell = tok_info.cell
            if not token_cell and tok_info.pos then
                token_cell = grid.make_cell(tok_info.pos[1], tok_info.pos[3], 0)
            end
            if not token_cell and cursor_cell ~= nil then
                token_cell = cursor_cell
            end

            if token_cell ~= nil then
                local steps = gm_rules.DEFAULT_MOVE_STEPS
                local zone = grid.reachable_cells(token_cell, steps)
                local r_map = {}
                for _, c in ipairs(zone) do
                    r_map[grid.key(c)] = true
                end

                local tid = tok_info.token_id or tostring(uid)
                M.select(tid, token_cell)
                M.selected_uid = uid
                M.reachable_zone = zone
                M.reachable_map = r_map
                M.current_path_target = nil

                overlay.show_zone(zone, 3)
                log("token_selected", {
                    token_id = tid,
                    uid = uid,
                    cell = token_cell,
                    zone_count = #zone,
                })
                return "selected"
            end
        end

        return "ignored"
    end

    -- 2. Если токен УЖЕ выбран
    if cursor_cell == nil then
        M.clear_selection()
        return "cleared"
    end

    -- Клик по той же клетке токена -> отмена выбора
    if cursor_cell.cx == M.selected_cell.cx and cursor_cell.cz == M.selected_cell.cz then
        M.clear_selection()
        return "cleared"
    end

    local cell_k = grid.key(cursor_cell)
    if M.reachable_map and M.reachable_map[cell_k] then
        -- Клик внутри доступной зоны: отправляем MoveToken на сервер
        local target = { cx = cursor_cell.cx, cz = cursor_cell.cz, level = cursor_cell.level or 0 }
        local from = M.selected_cell
        local tid = M.selected_token_id
        M.send_move(tid, target, from)
        log("token_move_intent", {
            token_id = tid,
            from = from,
            target = target,
        })
        M.clear_selection()
        return "moved"
    else
        -- Клик вне зоны: отмена выбора
        M.clear_selection()
        return "cleared"
    end
end

-- Интерактивное наведение мыши на клетку: превью маршрута при выбранном токене
function M.hover(cursor_cell)
    if M.has_selection() then
        if cursor_cell ~= nil and M.reachable_map and M.reachable_map[grid.key(cursor_cell)] then
            if M.current_path_target == nil or M.current_path_target.cx ~= cursor_cell.cx or M.current_path_target.cz ~= cursor_cell.cz then
                local path = grid.build_path(M.selected_cell, cursor_cell)
                overlay.preview_path(path)
                local target = { cx = cursor_cell.cx, cz = cursor_cell.cz, level = cursor_cell.level or 0 }
                M.preview_move(M.selected_token_id, target)
                M.current_path_target = { cx = cursor_cell.cx, cz = cursor_cell.cz }
            end
        else
            if M.current_path_target ~= nil or M.preview_target ~= nil then
                overlay.clear_path()
                M.cancel_preview()
                M.current_path_target = nil
            end
        end
    else
        if M.current_path_target ~= nil or M.preview_target ~= nil then
            overlay.clear_path()
            M.cancel_preview()
            M.current_path_target = nil
        end
    end
end

-- Установка целевой клетки для превью перемещения
function M.preview_move(token_id, target_cell, cell)
    M.selected_token_id = token_id
    if cell ~= nil then
        M.selected_cell = cell
    end
    M.preview_target = target_cell
end

-- Подтверждение перемещения и отправка намерения на сервер
function M.confirm_move()
    if M.selected_token_id and M.preview_target then
        local ok = M.send_move(M.selected_token_id, M.preview_target, M.selected_cell)
        M.preview_target = nil
        return ok
    end
    return false
end

-- Отмена предпросмотра перемещения
function M.cancel_preview()
    M.preview_target = nil
end

return M