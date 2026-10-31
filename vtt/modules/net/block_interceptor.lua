-- net/block_interceptor.lua
-- Слой: net (единственное место, где вызывается Neutron)
-- Спека: prompts/s0-2-block-sync.md, specs/server-tokens.md, specs/net-console-commands.md
-- Назначение: Диагностический перехватчик пакета BlockChanged, консольные команды через реестр
--   для проверки синхронизации блоков и токенов (S0.2, S0.6, Net-Console-Commands).
-- Публичные функции:
--   handle_packet(client, original_packet, edited_packet, variant)
--   register_interceptors(api, mode)
--   register_command(api, commands_module)
--   register_token_sync(api)
--   register_token_commands(api, commands_module, tokens_module)
--   init_lifecycle()
--   init(api, world_module, options)

local log = require("core/log")
local identity_mod = require("net/identity")

local M = {}

-- Безопасная загрузка серверных модулей с логированием в случае отсутствия
local function safe_require_server(name)
    local ok, mod = pcall(require, name)
    if ok then
        return mod
    else
        log("module_missing", { name = name, error = tostring(mod) })
        return nil
    end
end

-- Единая сборка контекста сессии для commands.dispatch
local function make_session_ctx(sender_id, role, tokens_module, world_module)
    return {
        tokens_module = tokens_module,
        world_module = world_module,
        is_gm = function(id) return id == sender_id and identity_mod.is_master(role) end,
    }
end

-- Единое логирование результатов консольных команд (result vs error)
local function log_command_result(tag, fields, ok, res, fallback_id)
    local data = {}
    for k, v in pairs(fields) do
        data[k] = v
    end
    data.success = ok
    if ok then
        if tag == "command_result_token_spawn" then
            data.token_id = (type(res) == "table" and res.token_id) or fallback_id
        else
            data.result = (res ~= nil) and res or true
        end
    else
        data.error = tostring(res or "unknown_error")
    end
    log(tag, data)
end

-- Обработка пакета перехватчиком: логирует поля и пропускает без изменений
function M.handle_packet(client, original_packet, edited_packet, variant, dump_non_blocks)
    local client_identity = identity_mod.label(client)

    if original_packet and original_packet.block then
        local blk = original_packet.block
        local pos = blk.pos or {}
        log("net_block_changed", {
            variant = variant or "generic",
            pid = original_packet.pid,
            block_id = blk.id,
            block_state = blk.state,
            block_pos = { x = pos.x, y = pos.y, z = pos.z },
            client = client_identity,
        })
    elseif dump_non_blocks then
        -- Опциональное логирование прочих пакетов только по явному флагу отладки
        local scalars = {}
        if type(original_packet) == "table" then
            for k, v in pairs(original_packet) do
                if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
                    scalars[tostring(k)] = v
                end
            end
        end
        log("net_packet_dump", {
            variant = variant or "generic",
            client = client_identity,
            scalars = scalars,
        })
    end

    -- docs: docs/neutron/api/libraries/interceptors.md:46: Возвращаемое значение: true — продолжить обработку/отправку
    return true
end

-- Регистрация перехватчиков по вариантам (а: BlockChanged, б: ServerMsg, в: generic)
function M.register_interceptors(api, mode, dump_non_blocks)
    if not (api and api.interceptors and api.interceptors.send) then
        log("neutron_api_missing", { part = "interceptors" })
        return
    end

    mode = mode or "all"
    dump_non_blocks = dump_non_blocks or false

    -- Вариант а: перехват по имени пакета "BlockChanged"
    if mode == "all" or mode == "a" or mode == "named" then
        -- docs: docs/neutron/api/libraries/interceptors.md:20: api.interceptors.send.add_interceptor(packet_type, interceptor)
        api.interceptors.send.add_interceptor("BlockChanged", function(client, original_packet, edited_packet)
            return M.handle_packet(client, original_packet, edited_packet, "variant_a", dump_non_blocks)
        end)
        log("interceptor_registered", { variant = "a", packet_type = "BlockChanged" })
    end

    -- Вариант б: перехват по категории "ServerMsg"
    if mode == "all" or mode == "b" or mode == "category" then
        -- docs: docs/neutron/api/libraries/interceptors.md:20: api.interceptors.send.add_interceptor(packet_type, interceptor)
        api.interceptors.send.add_interceptor("ServerMsg", function(client, original_packet, edited_packet)
            return M.handle_packet(client, original_packet, edited_packet, "variant_b", dump_non_blocks)
        end)
        log("interceptor_registered", { variant = "b", packet_type = "ServerMsg" })
    end

    -- Вариант в: общий перехватчик send.add_generic_interceptor (рабочий вариант)
    if mode == "all" or mode == "c" or mode == "generic" then
        -- docs: docs/neutron/api/libraries/interceptors.md:53: api.interceptors.send.add_generic_interceptor(interceptor)
        api.interceptors.send.add_generic_interceptor(function(client, original_packet, edited_packet)
            return M.handle_packet(client, original_packet, edited_packet, "variant_c", dump_non_blocks)
        end)
        log("interceptor_registered", { variant = "c", generic = true })
    end
end

-- Внутреннее исполнение намерения через реестр команд commands.dispatch с отправкой ответа клиенту
local function exec_via_registry(api, commands_module, tokens_module, client, name, payload, world_module)
    commands_module = commands_module or package.loaded["server/commands"] or package.loaded["vtt:server/commands"]
    if not commands_module then
        commands_module = safe_require_server("server/commands")
    end
    tokens_module = tokens_module or (commands_module and commands_module.tokens) or package.loaded["server/tokens"] or package.loaded["vtt:server/tokens"]
    if not tokens_module then
        tokens_module = safe_require_server("server/tokens")
    end
    world_module = world_module or (commands_module and commands_module.world) or package.loaded["server/world"] or package.loaded["vtt:server/world"]
    if not world_module then
        world_module = safe_require_server("server/world")
    end

    local sender_id, role = identity_mod.sender_of(client)
    if sender_id == nil then
        log("auth_denied", { name = name, reason = "sender_unknown" })
        if api and api.console and api.console.tell then
            -- docs: docs/neutron/api/libraries/console.md:143: api.console.tell(message: string, client: Client)
            pcall(function() api.console.tell("[Отказ] Не удалось определить отправителя (sender_unknown)", client) end)
        end
        return false, "sender_unknown"
    end

    local session_ctx = make_session_ctx(sender_id, role, tokens_module, world_module)

    if not commands_module or not commands_module.dispatch then
        log("command_error", { name = name, error = "commands_module.dispatch is nil" })
        return false, "commands_module.dispatch is nil"
    end

    local ok, res = commands_module.dispatch(name, sender_id, payload, session_ctx)
    if api and api.console and api.console.tell then
        pcall(function()
            if ok then
                -- docs: docs/neutron/api/libraries/console.md:143: api.console.tell(message: string, client: Client)
                api.console.tell("[Успех] Команда " .. name .. " выполнена", client)
            else
                -- docs: docs/neutron/api/libraries/console.md:143: api.console.tell(message: string, client: Client)
                api.console.tell("[Отказ] " .. tostring(res or "Действие запрещено"), client)
            end
        end)
    end
    return ok, res
end

-- Регистрация команды SetBlock через api.console.set_command
function M.register_command(api, commands_module, world_module)
    if not (api and api.console and api.console.set_command) then
        log("neutron_api_missing", { part = "console" })
        return
    end

    commands_module = commands_module or package.loaded["server/commands"] or package.loaded["vtt:server/commands"]
    if not commands_module then
        commands_module = safe_require_server("server/commands")
    end
    if commands_module and commands_module.init then
        if not commands_module.get or not commands_module.get("SetBlock") then
            commands_module.init(nil, world_module)
        end
    end

    -- Схема: docs/neutron/api/libraries/console.md:48: block_set: x=, y=, z=, id=[number] -> Set Block
    local scheme = "block_set: x=<number>, y=<number>, z=<number>, id=[number] -> Set Block"

    -- Вторая линия защиты: по умолчанию member тоже имеет это право, решение принимает commands.dispatch
    -- docs: docs/neutron/api/libraries/console.md:54: {permissions={"time_management"}}
    -- docs: docs/neutron/core/server-config.md:150: role_management - Управление ролями игроков
    local permissions = { permissions = { "role_management" } }
    local can_use_unauthorized = false

    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local x = tonumber(args.x)
        local y = tonumber(args.y)
        local z = tonumber(args.z)
        local id = tonumber(args.id) or 1

        log("command_exec_block_set", {
            x = x,
            y = y,
            z = z,
            id = id,
            client = client_identity,
        })

        local payload = { x = x, y = y, z = z, id = id }
        local ok, res = exec_via_registry(api, commands_module, nil, client, "SetBlock", payload, world_module)

        log_command_result("command_result_block_set", {
            x = x,
            y = y,
            z = z,
            id = id,
        }, ok, res)
    end, can_use_unauthorized)

    log("test_command_registered", { scheme = scheme, restricted = true })
end

-- Регистрация синхронизации сущности vtt:token в Neutron (серверная сторона)
function M.register_token_sync(api, tokens_mod_param)
    if not (api and api.entities and api.entities.register) then
        log("neutron_api_missing", { part = "entities" })
        return
    end

    local tmod_ref = tokens_mod_param or package.loaded["server/tokens"] or package.loaded["vtt:server/tokens"]
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
                    local tmod = tmod_ref or package.loaded["server/tokens"] or package.loaded["vtt:server/tokens"]
                    if not tmod then
                        tmod = safe_require_server("server/tokens")
                    end
                    if tmod and tmod.get_by_entity_id then
                        local t = tmod.get_by_entity_id(uid)
                        if t then return t.id end
                    end
                    return nil
                end,
            },
        },
    })
    log("token_sync_registered", { entity = "vtt:token" })
end

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
            local grid_mod = package.loaded["core/grid"] or require("core/grid")
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
            local grid_mod = package.loaded["core/grid"] or require("core/grid")
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
    local grid_mod = package.loaded["core/grid"] or require("core/grid")
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
    local channel = require("net/channel")
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

-- Регистрация приёма серверных сообщений (в т.ч. MoveToken)
function M.register_server_messages(commands_module, tokens_module, api)
    if type(_G.Message) ~= "table" and not (api and api.messages) then
        local channel = package.loaded["net/channel"] or require("net/channel")
        if not (channel and channel.api and channel.api.messages) then
            log("neutron_api_missing", { part = "messages" })
            return
        end
    end

    commands_module = commands_module or package.loaded["server/commands"] or package.loaded["vtt:server/commands"]
    if not commands_module then
        commands_module = safe_require_server("server/commands")
    end
    if commands_module and commands_module.init then
        if not commands_module.get or not commands_module.get("MoveToken") then
            commands_module.init(tokens_module)
        end
    end
    tokens_module = tokens_module or (commands_module and commands_module.tokens) or package.loaded["server/tokens"] or package.loaded["vtt:server/tokens"]
    if not tokens_module then
        tokens_module = safe_require_server("server/tokens")
    end
    local channel = require("net/channel")

    local subscribed = false
    local ok_sub, err_sub = pcall(function()
        channel.on("MoveToken", function(payload, client)
            local ok_h, err_h = pcall(function()
                local sender_id, role = identity_mod.sender_of(client)
                if not sender_id then
                    log("auth_denied", { name = "MoveToken", reason = "sender_unknown" })
                    return
                end

                log("token_move_command", {
                    client = sender_id,
                    token_id = payload and payload.token_id,
                    target_cell = payload and payload.target_cell,
                    from_cell = payload and payload.from_cell,
                })

                local session_ctx = make_session_ctx(sender_id, role, tokens_module, nil)

                if commands_module and commands_module.dispatch then
                    local ok, err = commands_module.dispatch("MoveToken", sender_id, payload, session_ctx)
                    return ok, err
                end
            end)
            if not ok_h then
                log("command_error", { name = "MoveToken", error = tostring(err_h) })
            end
        end)
        subscribed = true
    end)

    if ok_sub and subscribed then
        log("server_messages_registered", { list = { "MoveToken" } })
    else
        log("neutron_api_missing", { part = "messages", error = tostring(err_sub) })
    end
end

-- Инициализация сетевого слоя на клиенте
function M.init_client(api)
    local channel = require("net/channel")
    if channel and channel.init then
        channel.init(api)
    end
    M.register_token_client(api)
    log("net_client_initialized", { entity = "vtt:token" })
end

-- Регистрация консольных команд для токенов через реестр команд
function M.register_token_commands(api, commands_module, tokens_module)
    if not (api and api.console and api.console.set_command) then
        log("neutron_api_missing", { part = "console" })
        return
    end

    commands_module = commands_module or package.loaded["server/commands"] or package.loaded["vtt:server/commands"]
    if not commands_module then
        commands_module = safe_require_server("server/commands")
    end
    if commands_module and commands_module.init then
        if not commands_module.get or not commands_module.get("SpawnToken") then
            commands_module.init(tokens_module)
        end
    end
    tokens_module = tokens_module or (commands_module and commands_module.tokens) or package.loaded["server/tokens"] or package.loaded["vtt:server/tokens"]
    if not tokens_module then
        tokens_module = safe_require_server("server/tokens")
    end

    -- Вторая линия защиты: по умолчанию member тоже имеет это право, решение принимает commands.dispatch
    -- docs: docs/neutron/api/libraries/console.md:54: {permissions={"time_management"}}
    -- docs: docs/neutron/core/server-config.md:150: role_management - Управление ролями игроков
    local permissions = { permissions = { "role_management" } }
    local can_use_unauthorized = false

    local scheme_spawn = "token_spawn: cx=<number>, cz=<number>, id=[string], owner=[string] -> Spawn token"
    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme_spawn, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local cx = tonumber(args.cx)
        local cz = tonumber(args.cz)
        local id = (type(args.id) == "string" and args.id ~= "") and args.id or nil
        local owner = (type(args.owner) == "string" and args.owner ~= "") and args.owner or nil

        log("command_exec_token_spawn", {
            cx = cx,
            cz = cz,
            id = id,
            client = client_identity,
        })

        local payload = {
            cell = { cx = cx, cz = cz, level = 0 },
            asset_id = "vtt:token",
            name = id or "Token",
            id = id,
            owner = owner,
        }
        local ok, res = exec_via_registry(api, commands_module, tokens_module, client, "SpawnToken", payload)
        log_command_result("command_result_token_spawn", { cx = cx, cz = cz }, ok, res, id)
    end, can_use_unauthorized)

    local scheme_move = "token_move: id=<string>, cx=<number>, cz=<number> -> Move token"
    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme_move, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local id = tostring(args.id)
        local cx = tonumber(args.cx)
        local cz = tonumber(args.cz)

        log("command_exec_token_move", {
            id = id,
            cx = cx,
            cz = cz,
            client = client_identity,
        })

        local payload = {
            token_id = id,
            target_cell = { cx = cx, cz = cz, level = 0 },
        }
        local ok, res = exec_via_registry(api, commands_module, tokens_module, client, "MoveToken", payload)
        log_command_result("command_result_token_move", { id = id, cx = cx, cz = cz }, ok, res)
    end, can_use_unauthorized)

    local scheme_remove = "token_remove: id=<string> -> Remove token"
    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme_remove, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local id = tostring(args.id)

        log("command_exec_token_remove", {
            id = id,
            client = client_identity,
        })

        local payload = { token_id = id }
        local ok, res = exec_via_registry(api, commands_module, tokens_module, client, "RemoveToken", payload)
        log_command_result("command_result_token_remove", { id = id }, ok, res)
    end, can_use_unauthorized)

    local scheme_owner = "token_owner: id=<string>, owner=[string] -> Set or clear token owner"
    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme_owner, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local id = tostring(args.id)
        local owner = (type(args.owner) == "string" and args.owner ~= "") and args.owner or nil

        log("command_exec_token_owner", {
            id = id,
            owner = owner,
            client = client_identity,
        })

        local payload = { token_id = id, owner = owner }
        local ok, res = exec_via_registry(api, commands_module, tokens_module, client, "SetTokenOwner", payload)
        log_command_result("command_result_token_owner", { id = id, owner = owner }, ok, res)
    end, can_use_unauthorized)

    log("token_commands_registered", { schemes = { "token_spawn", "token_move", "token_remove", "token_owner" } })
end

-- Инициализация логирования жизненного цикла сервера
function M.init_lifecycle()
    if type(events) ~= "table" or type(events.on) ~= "function" then
        log("neutron_api_missing", { part = "events" })
        return
    end

    -- docs: docs/engine/scripting/events.md:180: events.on(event: str, callback: function)
    events.on("server:client_connected", function(client)
        local client_identity = identity_mod.label(client)
        log("server_client_connected", { client = client_identity })
    end)

    log("server_lifecycle_init", { status = "active" })
end

-- Полная инициализация сетевого модуля перехвата и команд
function M.init(api, world_module, options)
    options = options or {}
    if not api or type(api) ~= "table" then
        log("neutron_api_missing", { part = "api" })
        log("block_interceptor_init", { status = "skipped", reason = "no_api" })
        return
    end
    local channel = require("net/channel")
    if channel and channel.init then
        channel.init(api)
    end
    local identity = require("net/identity")
    if identity and identity.init then
        identity.init(api)
    end
    M.init_lifecycle()
    M.register_interceptors(api, options.mode or "all", options.dump_non_blocks)
    local wm = (options and options.world_module) or world_module
    M.register_command(api, options and options.commands_module, wm)
    M.register_token_sync(api, options and options.tokens_module)
    M.register_token_commands(api, options and options.commands_module, options and options.tokens_module)
    M.register_server_messages(options and options.commands_module, options and options.tokens_module, api)
    log("block_interceptor_init", { mode = options.mode or "all" })
end

return M
