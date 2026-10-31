-- net/block_interceptor.lua
-- Слой: net (клиентская часть синхронизации токенов до задачи B)
-- Спека: specs/net-split-server.md, specs/server-tokens.md
-- Назначение: Клиентский реестр токенов, приём обновлений сущностей и отправка сетевых сообщений.
-- Публичные функции:
--   register_token_client(api)
--   get_client_token(entity_or_uid)
--   get_client_token_by_cell(cx, cz)
--   send_move_token(token_id, target_cell, from_cell)
--   init_client(api)

local log = require("core/log")
local grid_mod = require("core/grid")

local M = {}

-- Клиентский реестр токенов для интерактивного выбора и отображения
M.client_tokens = {}

-- Регистрация клиентского обработчика синхронизации сущности vtt:token (обход бага Neutron client:controller)
function M.register_token_client(api)
    if not (api and api.entities and api.entities.set_handler) then
        log("neutron_api_missing", { part = "entities" })
        return
    end

    -- docs: docs/neutron/api/libraries/entities.md:284: api.entities.set_handler(entities_tbl, handler)
    api.entities.set_handler({ "vtt:token" }, function(uid, def, dirty)
        if not M.client_tokens[uid] then
            M.client_tokens[uid] = { uid = uid }
        end
        local tok = M.client_tokens[uid]
        tok.uid = uid

        if dirty and dirty.token_id then
            tok.token_id = dirty.token_id
        elseif type(def) == "table" and def.token_id and not tok.token_id then
            tok.token_id = def.token_id
        end

        if dirty and dirty.pos then
            tok.pos = dirty.pos
            tok.cell = grid_mod.make_cell(dirty.pos[1], dirty.pos[3], 0)
            -- docs: docs/engine/scripting/builtins/libentities.md:23: entities.get(uid: int) -> table
            local ent = (entities and entities.get and entities.get(uid)) or (_G.entities and _G.entities.get and _G.entities.get(uid))
            if ent then
                -- docs: docs/engine/scripting/ecs.md:65: local tsf = entity.transform
                local tsf = ent.transform or (ent.get_component and ent:get_component("transform"))
                if tsf and tsf.set_pos then
                    -- docs: docs/engine/scripting/ecs.md:70: tsf:set_pos(pos:vec3)
                    tsf:set_pos(dirty.pos)
                    log("token_client_moved", { uid = uid, pos = dirty.pos })
                end
            end
        elseif type(def) == "table" and def.pos and not tok.pos then
            tok.pos = def.pos
            tok.cell = grid_mod.make_cell(def.pos[1], def.pos[3], 0)
        end
    end)
    log("token_client_handler_registered", { entity = "vtt:token" })
end

-- Получение данных клиента по UID сущности (или таблице сущности)
function M.get_client_token(entity_or_uid)
    if entity_or_uid == nil then return nil end
    local uid = entity_or_uid
    if type(entity_or_uid) == "table" then
        uid = entity_or_uid.uid or (type(entity_or_uid.get_uid) == "function" and entity_or_uid:get_uid())
    end
    if uid == nil then return nil end
    return M.client_tokens[uid]
end

-- Поиск токена на клиенте по клетке (cx, cz)
function M.get_client_token_by_cell(cx, cz)
    for uid, tok in pairs(M.client_tokens) do
        if tok.cell and tok.cell.cx == cx and tok.cell.cz == cz then
            return tok, uid
        elseif tok.pos then
            local tcx, tcz = grid_mod.cell_of(tok.pos[1], tok.pos[3])
            if tcx == cx and tcz == cz then
                return tok, uid
            end
        end
    end
    return nil
end

-- Клиентская отправка намерения MoveToken на сервер
function M.send_move_token(token_id, target_cell, from_cell)
    local channel = package.loaded["net/channel"] or require("net/channel")
    local num_uid = tonumber(token_id)
    if num_uid and M.client_tokens[num_uid] and M.client_tokens[num_uid].token_id then
        token_id = M.client_tokens[num_uid].token_id
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
    channel.send("MoveToken", payload)
    log("token_move_sent", { token_id = payload.token_id, target_cell = payload.target_cell, from_cell = payload.from_cell })
end

-- Инициализация сетевого слоя на клиенте
function M.init_client(api)
    local channel = package.loaded["net/channel"] or require("net/channel")
    if channel and channel.init then
        channel.init(api)
    end
    M.register_token_client(api)
    log("net_client_initialized", { entity = "vtt:token" })
end

return M
