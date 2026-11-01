-- net/token_entity.lua
-- Слой: net (единственное место, где вызывается Neutron)
-- Спека: specs/net-split-server.md, specs/net-split-client.md
-- Назначение: Регистрация синхронизации сущности vtt:token в Neutron на сервере и клиенте.
-- Публичные функции:
--   register_server(api, token_id_of) -> boolean
--   register_client(api, on_update) -> boolean

local log = require("core/log")

local M = {}

-- Регистрация синхронизации сущности vtt:token в Neutron (серверная сторона)
function M.register_server(api, token_id_of)
    if not (api and api.entities and api.entities.register) then
        log("neutron_api_missing", { part = "entities" })
        return false
    end

    -- docs: docs/neutron/api/libraries/entities.md:24: entities.register(entity_name, config, [spawn_handler])
    api.entities.register("vtt:token", {
        -- docs: docs/neutron/api/libraries/entities.md:50: standard_fields
        standard_fields = {
            tsf_pos = {
                maximum_deviation = 0.01,
                -- docs: docs/neutron/api/libraries/entities.md:240: entities.eval.VectorNotEquals
                evaluate_deviation = (api.entities.eval and api.entities.eval.VectorNotEquals) or nil,
            },
        },
        -- docs: docs/neutron/api/libraries/entities.md:59: custom_fields
        -- docs: docs/neutron/api/libraries/entities.md:126: custom_fields provider
        custom_fields = {
            pos = {
                maximum_deviation = 0.01,
                -- docs: docs/neutron/api/libraries/entities.md:240: entities.eval.VectorNotEquals
                evaluate_deviation = (api.entities.eval and api.entities.eval.VectorNotEquals) or nil,
                -- docs: docs/neutron/api/libraries/entities.md:130: function(uid, field_name)
                provider = function(uid, field_name)
                    -- docs: docs/engine/scripting/builtins/libentities.md:23: entities.get(uid: int) -> table
                    local ent = (entities and entities.get and entities.get(uid)) or (_G.entities and _G.entities.get and _G.entities.get(uid))
                    if ent then
                        -- docs: docs/engine/scripting/ecs.md:65: local tsf = entity.transform
                        local tsf = ent.transform or (ent.get_component and ent:get_component("transform"))
                        if tsf and tsf.get_pos then
                            -- docs: docs/engine/scripting/ecs.md:68: tsf:get_pos() -> vec3
                            return tsf:get_pos()
                        end
                    end
                    return nil
                end,
            },
            token_id = {
                maximum_deviation = 0,
                -- docs: docs/neutron/api/libraries/entities.md:236: entities.eval.NotEquals
                evaluate_deviation = (api.entities.eval and api.entities.eval.NotEquals) or nil,
                -- docs: docs/neutron/api/libraries/entities.md:130: function(uid, field_name)
                provider = function(uid, field_name)
                    if token_id_of then
                        return token_id_of(uid)
                    end
                    return nil
                end,
            },
        },
    })
    log("token_sync_registered", { entity = "vtt:token" })
    return true
end

-- Регистрация клиентского обработчика синхронизации сущности vtt:token
function M.register_client(api, on_update)
    if not (api and api.entities and api.entities.set_handler) then
        log("neutron_api_missing", { part = "entities" })
        return false
    end

    -- docs: docs/neutron/api/libraries/entities.md:284: api.entities.set_handler(entities_tbl, handler)
    api.entities.set_handler({ "vtt:token" }, function(uid, def, dirty)
        local fresh = {}
        if type(dirty) == "table" then
            fresh.token_id = dirty.token_id
            fresh.pos = dirty.pos
        end

        local initial = {}
        if type(def) == "table" then
            initial.token_id = def.token_id
            initial.pos = def.pos
        end

        if on_update then
            local ok, err = pcall(on_update, uid, fresh, initial)
            if not ok then
                log("token_client_update_error", { uid = uid, error = tostring(err) })
            end
        end

        if fresh.pos then
            -- docs: docs/engine/scripting/builtins/libentities.md:23: entities.get(uid: int) -> table
            local ent = (entities and entities.get and entities.get(uid)) or (_G.entities and _G.entities.get and _G.entities.get(uid))
            if ent then
                -- docs: docs/engine/scripting/ecs.md:65: local tsf = entity.transform
                local tsf = ent.transform or (ent.get_component and ent:get_component("transform"))
                if tsf and tsf.set_pos then
                    -- docs: docs/engine/scripting/ecs.md:70: tsf:set_pos(pos:vec3)
                    tsf:set_pos(fresh.pos)
                    log("token_client_moved", { uid = uid, pos = fresh.pos })
                end
            end
        end
    end)

    log("token_client_handler_registered", { entity = "vtt:token" })
    return true
end

return M
