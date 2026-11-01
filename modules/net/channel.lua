-- net/channel.lua
-- Слой: net (единственная прослойка над Neutron)
-- Спека: specs/net-channel.md, specs/net-client-server-handle.md
-- Назначение: Изоляция сетевого API Neutron (Message, Replication) для сервера и клиента.
-- Публичные функции:
--   init(api)
--   send(msg_name, payload, target_client)
--   broadcast(msg_name, payload)
--   on(msg_name, callback)
--   replicate(name, id, initial_data, is_server)
--   get_replica(name, id)
--   ensure_client_server()

local log = require("core/log")

local M = {}

M.api = nil

local messages = {}
local replicators = {}
local replicas = {}
local logged_reasons = {}
local logged_send_failures = {}

-- Инициализация ссылок на подсистемы Neutron
function M.init(api)
    M.api = api
    if api then
        if api.messages and (type(_G.Message) ~= "table" or _G.Message == nil) then
            _G.Message = api.messages
        end
        if api.replications and (type(_G.Replication) ~= "table" or _G.Replication == nil) then
            _G.Replication = api.replications
        end
    end
end

-- Автоматическое разрешение api через глобальный дескриптор $Multiplayer
local function resolve_api()
    if M.api then return M.api end
    if _G["$Multiplayer"] then
        local m = _G["$Multiplayer"]
        if m.pack_id and m.api_references and m.api_references.Neutron and m.side then
            local ok, loaded = pcall(require, string.format("%s:api/%s/api", m.pack_id, m.api_references.Neutron[2]))
            if ok and loaded and loaded[m.side] then
                M.init(loaded[m.side])
                return M.api
            end
        end
    end
    return nil
end

local function get_message_class()
    if type(_G.Message) == "table" and type(_G.Message.new) == "function" then
        return _G.Message
    end
    local a = resolve_api()
    if a and a.messages then
        if type(_G.Message) ~= "table" or _G.Message == nil then
            _G.Message = a.messages
        end
        return a.messages
    end
    if type(Message) == "table" then
        return Message
    end
    error("Neutron Message API не найден (ни глобальный Message, ни api.messages)")
end

local function get_replication_class()
    if type(_G.Replication) == "table" and type(_G.Replication.new) == "function" then
        return _G.Replication
    end
    local a = resolve_api()
    if a and a.replications then
        if type(_G.Replication) ~= "table" or _G.Replication == nil then
            _G.Replication = a.replications
        end
        return a.replications
    end
    if type(Replication) == "table" then
        return Replication
    end
    error("Neutron Replication API не найден (ни глобальный Replication, ни api.replications)")
end

-- Получение или создание объекта сообщения Neutron
local function get_or_create_message(msg_name)
    if not messages[msg_name] then
        local msg_cls = get_message_class()
        -- docs: docs/neutron/api/libraries/messages.md:18: Message.new(pack: string, event: string, schema: table) -> Message
        messages[msg_name] = msg_cls.new("vtt", msg_name, { payload = "bson" })
    end
    return messages[msg_name]
end

-- Получение или создание объекта репликатора Neutron
local function get_or_create_replicator(name, schema)
    if not replicators[name] then
        local rep_cls = get_replication_class()
        -- docs: docs/neutron/api/libraries/replications.md:26: Replication.new(pack: string, event: string, schema: table) -> Replicator
        replicators[name] = rep_cls.new("vtt", name, schema or { state = "bson" })
    end
    return replicators[name]
end

-- Диагностика и ленивый обход изоляции SERVER на клиенте Neutron 0.4.0 (specs/net-client-server-handle.md)
-- Допустимо писать в _G.SERVER только здесь; ключ 'neutron-client-env' подтверждён кодом Neutron-Client 0.4.0.
function M.ensure_client_server()
    -- 1. Если rawget(_G, "SERVER") ~= nil: вернуть true, "already" без лога.
    if rawget(_G, "SERVER") ~= nil then
        return true, "already"
    end

    -- 2. Если session не таблица или нет session.has и session.get: log("neutron_client_env_missing", {part = "session"}), вернуть false, "no_session".
    local sess = rawget(_G, "session")
    if type(sess) ~= "table" or type(sess.has) ~= "function" or type(sess.get) ~= "function" then
        if not logged_reasons["no_session"] then
            logged_reasons["no_session"] = true
            log("neutron_client_env_missing", { part = "session" })
        end
        return false, "no_session"
    end

    -- 3. Если not session.has("neutron-client-env"): log("neutron_client_env_missing", {part = "env"}), вернуть false, "no_env".
    -- docs: docs/engine/scripting/builtins/libsession.md:17: session.has(name: str) -> boolean
    local has_ok, has_env = pcall(sess.has, "neutron-client-env")
    if not has_ok or not has_env then
        if not logged_reasons["no_env"] then
            logged_reasons["no_env"] = true
            log("neutron_client_env_missing", { part = "env" })
        end
        return false, "no_env"
    end

    -- 4. env = session.get("neutron-client-env"); если env.SERVER == nil: log("neutron_client_server_unavailable", {g_server = false, env_server = false}), вернуть false, "no_server_in_env".
    -- docs: docs/engine/scripting/builtins/libsession.md:11: session.get(name: str) -> table
    local get_ok, env = pcall(sess.get, "neutron-client-env")
    if not get_ok or type(env) ~= "table" or env.SERVER == nil then
        if not logged_reasons["no_server_in_env"] then
            logged_reasons["no_server_in_env"] = true
            log("neutron_client_server_unavailable", { g_server = false, env_server = false })
        end
        return false, "no_server_in_env"
    end

    -- 5. Иначе _G.SERVER = env.SERVER, log("neutron_client_server_patched", {neutron = "0.4.0"}), вернуть true, "patched".
    _G.SERVER = env.SERVER
    log("neutron_client_server_patched", { neutron = "0.4.0" })
    return true, "patched"
end

-- Отправка сообщения: на клиенте на сервер, на сервере клиенту
function M.send(msg_name, payload, target_client)
    local msg = get_or_create_message(msg_name)
    if target_client then
        -- docs: docs/neutron/api/libraries/messages.md:119: Message:tell(client: Client, data: table)
        msg:tell(target_client, { payload = payload })
        return true
    end

    -- Клиентская ветка отправки на сервер
    local ok, reason = M.ensure_client_server()
    if not ok then
        local err_key = tostring(msg_name) .. ":" .. tostring(reason)
        if not logged_send_failures[err_key] then
            logged_send_failures[err_key] = true
            log("channel_send_failed", { name = msg_name, reason = reason })
        end
        return false
    end

    local send_ok, send_err = pcall(function()
        -- docs: docs/neutron/api/libraries/messages.md:135: Message:send(data: table)
        msg:send({ payload = payload })
    end)

    if not send_ok then
        local err_str = tostring(send_err)
        local err_key = tostring(msg_name) .. ":" .. err_str
        if not logged_send_failures[err_key] then
            logged_send_failures[err_key] = true
            log("channel_send_failed", { name = msg_name, error = err_str })
        end
        return false
    end

    return true
end

-- Рассылка сообщения всем подключённым клиентам (сервер)
function M.broadcast(msg_name, payload)
    local msg = get_or_create_message(msg_name)
    -- docs: docs/neutron/api/libraries/messages.md:123: Message:echo(data: table)
    msg:echo({ payload = payload })
end

-- Подписка на входящее сообщение
function M.on(msg_name, callback)
    local msg = get_or_create_message(msg_name)
    -- docs: docs/neutron/api/libraries/messages.md:144: Message:on(handler: function(client: Client, data: table))
    msg:on(function(client_or_data, maybe_data)
        if maybe_data ~= nil then
            -- Вызов на сервере: (client, data)
            callback(maybe_data.payload or maybe_data, client_or_data)
        else
            -- Вызов на клиенте: (data)
            callback(client_or_data.payload or client_or_data)
        end
    end)
end

-- Регистрация репликации состояния:
-- На сервере: create_public_replica(id, initial_value)
-- На клиенте: create_listener(id, initial_value)
function M.replicate(name, id, initial_data, is_server)
    local rep = get_or_create_replicator(name)
    local key = name .. ":" .. tostring(id)
    if is_server then
        -- docs: docs/neutron/api/libraries/replications.md:81: Replicator:create_public_replica(id: int, initial_value: table, need_send: function(client, dirty): boolean?) -> table
        local replica = rep:create_public_replica(id, initial_data or {})
        replicas[key] = replica
        return replica
    else
        -- docs: docs/neutron/api/libraries/replications.md:144: Replicator:create_listener(id: int, initial_value: table) -> table
        local listener = rep:create_listener(id, initial_data or {})
        replicas[key] = listener
        return listener
    end
end

-- Получение существующей реплики по имени и идентификатору
function M.get_replica(name, id)
    return replicas[name .. ":" .. tostring(id)]
end

return M
