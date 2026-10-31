-- server/tokens.lua
-- Слой: server
-- Спека: specs/server-tokens.md, specs/server-move-validation.md
-- Назначение: Серверный реестр и жизненный цикл токенов (спавн сущностей, перемещение, удаление, привязка к клеткам).
-- Публичные функции:
--   spawn(cell, def) -> token_id
--   set_owner(token_id, owner_id) -> true | false, reason
--   move(token_id, target_cell) -> success
--   remove(token_id) -> success
--   get(token_id) -> table
--   get_all() -> table
--   get_by_entity_id(entity_id) -> table or nil
--   get_by_cell(cx, cz) -> table or nil
--   sync_from_world()
--   find_surface_y(wx, wz, [cell_level]) -> number

local grid = require("core/grid")
local log = require("core/log")

local M = {}

M.registry = {}

-- Поиск высоты верхней поверхности блока под мировыми координатами (wx, wz)
function M.find_surface_y(wx, wz, cell_level)
    local default_y = cell_level or 0
    -- docs: docs/engine/scripting/builtins/libblock.md:140: block.raycast(start: vec3, dir: vec3, max_distance: number, [optional] dest: table, [optional] filter: table) -> table or nil
    local hit = block.raycast({ wx, 255.0, wz }, { 0, -1, 0 }, 255.0)
    if hit and hit.iendpoint then
        local y = hit.iendpoint[2]
        local bx = math.floor(wx)
        local bz = math.floor(wz)
        -- docs: docs/engine/scripting/builtins/libblock.md:55: block.is_solid_at(x: int, y: int, z: int) -> bool
        -- docs: docs/engine/scripting/builtins/libblock.md:59: block.is_replaceable_at(x: int, y: int, z: int) -> bool
        while y > 0 and (block.is_solid_at(bx, y, bz) == false or block.is_replaceable_at(bx, y, bz) == true) do
            y = y - 1
        end
        return y + 1.0
    end
    return default_y
end

-- Создание токена на указанной клетке
function M.spawn(cell, def)
    def = def or {}
    local id = def.id or ("token_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)))
    local asset_id = def.asset_id or "vtt:token"
    local wx, wz = grid.center_of(cell.cx, cell.cz)
    local wy = M.find_surface_y(wx, wz, cell.level)

    -- docs: docs/engine/scripting/builtins/libentities.md:19: entities.spawn(name: str, pos: vec3, [optional] args: table) -> table
    local ent = entities.spawn(asset_id, { wx, wy, wz })
    -- docs: docs/engine/scripting/ecs.md:23: entity:get_uid() -> int
    local entity_id = (ent and ent.get_uid and ent:get_uid()) or nil

    M.registry[id] = {
        id = id,
        name = def.name or "Token",
        asset_id = asset_id,
        cell = { cx = cell.cx, cz = cell.cz, level = cell.level or 0 },
        entity = ent,
        entity_id = entity_id,
        owner_id = def.owner_id,
    }
    log("token_spawn", { id = id, entity_id = entity_id, cell = cell, pos = { wx, wy, wz } })
    return id
end

-- Поиск токена по UID сущности
function M.get_by_entity_id(entity_id)
    if entity_id == nil then return nil end
    for _, token in pairs(M.registry) do
        if token.entity_id == entity_id then
            return token
        end
    end
    return nil
end

-- Поиск токена по координатам клетки
function M.get_by_cell(cx, cz)
    if cx == nil or cz == nil then return nil end
    for _, token in pairs(M.registry) do
        if token.cell and token.cell.cx == cx and token.cell.cz == cz then
            return token
        end
    end
    return nil
end

-- Синхронизация реестра токенов с сущностями vtt:token в мире VoxelCore
function M.sync_from_world()
    if type(entities) ~= "table" or type(entities.get_all) ~= "function" then
        return
    end
    -- docs: docs/engine/scripting/builtins/libentities.md:52: entities.get_all() -> table
    local all_ents = entities.get_all()
    if type(all_ents) ~= "table" then return end

    for k, ent in pairs(all_ents) do
        local uid = type(k) == "number" and k or nil
        if type(ent) == "table" or type(ent) == "userdata" then
            if ent.get_uid and type(ent.get_uid) == "function" then
                -- docs: docs/engine/scripting/ecs.md:23: entity:get_uid() -> int
                local ok_u, u = pcall(function() return ent:get_uid() end)
                if ok_u and type(u) == "number" then uid = u end
            elseif type(ent) == "table" and type(ent.uid) == "number" then
                uid = ent.uid
            end
        elseif type(ent) == "number" then
            uid = ent
            -- docs: docs/engine/scripting/builtins/libentities.md:8: entities.get(uid: int) -> table
            ent = entities.get(uid)
        end

        if ent and uid then
            -- docs: docs/engine/scripting/builtins/libentities.md:21: entities.exists(uid: int) -> bool
            local exists = true
            if type(entities.exists) == "function" then
                exists = entities.exists(uid)
            end

            if exists then
                local def_name = nil
                local ok_def, dname = pcall(function()
                    if ent.def_name then
                        -- docs: docs/engine/scripting/ecs.md:15: entity:def_name() -> str
                        return ent:def_name()
                    end
                    return nil
                end)
                if ok_def and type(dname) == "string" then
                    def_name = dname
                elseif type(entities.get_def) == "function" and type(entities.def_name) == "function" then
                    -- docs: docs/engine/scripting/builtins/libentities.md:25: entities.get_def(uid: int) -> int
                    -- docs: docs/engine/scripting/builtins/libentities.md:31: entities.def_name(id: int) -> str
                    local ok2, d2 = pcall(function() return entities.def_name(entities.get_def(uid)) end)
                    if ok2 and type(d2) == "string" then def_name = d2 end
                end

                if def_name == "vtt:token" then
                    local existing = M.get_by_entity_id(uid)
                    if not existing then
                        -- docs: docs/engine/scripting/ecs.md:65: local tsf = entity.transform
                        -- docs: docs/engine/scripting/ecs.md:26: entity:get_component(name: str) -> component or nil
                        local tsf = ent.transform or (ent.get_component and ent:get_component("transform"))
                        -- docs: docs/engine/scripting/ecs.md:68: tsf:get_pos() -> vec3
                        local pos = tsf and tsf.get_pos and tsf:get_pos()
                        local cx, cz = 0, 0
                        if pos then
                            cx, cz = grid.cell_of(pos[1], pos[3])
                        end
                        local id = "token_ent_" .. tostring(uid)
                        M.registry[id] = {
                            id = id,
                            name = "Token " .. tostring(uid),
                            asset_id = "vtt:token",
                            cell = { cx = cx, cz = cz, level = 0 },
                            entity = ent,
                            entity_id = uid,
                        }
                        log("token_synced_from_world", { id = id, entity_id = uid, cell = { cx = cx, cz = cz, level = 0 } })
                    end
                end
            end
        end
    end
end

-- Смена владельца токена (только строковый ID владельца или nil)
function M.set_owner(token_id, owner_id)
    if token_id == nil or not M.registry[token_id] then
        return false, "Токен не найден"
    end
    if owner_id ~= nil and (type(owner_id) ~= "string" or owner_id == "") then
        return false, "Некорректный владелец"
    end
    M.registry[token_id].owner_id = owner_id
    log("token_set_owner", { token_id = token_id, owner_id = owner_id })
    return true
end

-- Получение данных токена из реестра
function M.get(token_id)
    if token_id == nil then return nil end
    return M.registry[token_id]
end

-- Перемещение токена на новую клетку
function M.move(token_id, target_cell)
    local token = M.get(token_id)
    if not token then
        local available_keys = {}
        for k, v in pairs(M.registry) do
            local ck = v.cell and (v.cell.cx .. "," .. v.cell.cz) or "nil"
            available_keys[#available_keys + 1] = tostring(k) .. "[cell=" .. ck .. ",ent=" .. tostring(v.entity_id) .. "]"
        end
        log("token_move_failed", {
            token_id = tostring(token_id),
            registered_tokens = available_keys,
        })
        return false, "Токен не найден (id=" .. tostring(token_id) .. ")"
    end
    token.cell = { cx = target_cell.cx, cz = target_cell.cz, level = target_cell.level or 0 }
    local wx, wz = grid.center_of(target_cell.cx, target_cell.cz)
    local wy = M.find_surface_y(wx, wz, target_cell.level)

    if token.entity then
        -- docs: docs/engine/scripting/ecs.md:65: local tsf = entity.transform
        -- docs: docs/engine/scripting/ecs.md:26: entity:get_component(name: str) -> component or nil
        local tsf = token.entity.transform or (token.entity.get_component and token.entity:get_component("transform"))
        if tsf and tsf.set_pos then
            -- docs: docs/engine/scripting/ecs.md:70: tsf:set_pos(pos:vec3)
            tsf:set_pos({ wx, wy, wz })
        end
    elseif token.entity_id and type(entities) == "table" and type(entities.get) == "function" then
        -- docs: docs/engine/scripting/builtins/libentities.md:8: entities.get(uid: int) -> table
        local ent = entities.get(token.entity_id)
        if ent then
            token.entity = ent
            -- docs: docs/engine/scripting/ecs.md:65: local tsf = entity.transform
            local tsf = ent.transform or (ent.get_component and ent:get_component("transform"))
            if tsf and tsf.set_pos then
                -- docs: docs/engine/scripting/ecs.md:70: tsf:set_pos(pos:vec3)
                tsf:set_pos({ wx, wy, wz })
            end
        end
    end
    log("token_move", { id = token.id, target_cell = target_cell, pos = { wx, wy, wz } })
    return true
end

-- Удаление токена
function M.remove(token_id)
    local token = M.get(token_id)
    if not token then
        return false, "Токен не найден"
    end
    if token.entity and token.entity.despawn then
        -- docs: docs/engine/scripting/ecs.md:9: entity:despawn()
        token.entity:despawn()
    end
    M.registry[token.id] = nil
    log("token_remove", { id = token.id })
    return true
end

-- Получение всех активных токенов
function M.get_all()
    return M.registry
end

return M
