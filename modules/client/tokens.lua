-- client/tokens.lua
-- Слой: client
-- Спека: specs/client-tokens.md, specs/net-split-client.md
-- Назначение: Клиентское состояние токенов: реестр сущностей, выбор, превью перемещения и отправка намерения на сервер.
-- Публичные функции:
--   select(token_id, cell)
--   get_selected()
--   preview_move(token_id, target_cell, cell)
--   confirm_move()
--   cancel_preview()
--   on_entity(uid, fresh, initial)
--   get_by_entity(entity_or_uid)
--   get_by_cell(cx, cz)
--   send_move(token_id, target_cell, from_cell)

local log = require("core/log")
local grid = require("core/grid")
local channel = require("net/channel")

local M = {}

M.registry = {}
M.selected_token_id = nil
M.selected_cell = nil
M.preview_target = nil

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
    return M.registry[uid]
end

-- Поиск токена на клиенте по клетке (cx, cz)
function M.get_by_cell(cx, cz)
    for uid, tok in pairs(M.registry) do
        if tok.cell and tok.cell.cx == cx and tok.cell.cz == cz then
            return tok, uid
        elseif tok.pos then
            local tcx, tcz = grid.cell_of(tok.pos[1], tok.pos[3])
            if tcx == cx and tcz == cz then
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
