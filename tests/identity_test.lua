-- tests/identity_test.lua
-- Тесты модуля net/identity (получение отправителя, роли, обработка отсутствия API)

local T = require("lib")
local identity = require("net/identity")

T.test("identity: sender_of с пустыми или некорректными данными возвращает nil, nil", function()
    local id1, role1 = identity.sender_of(nil)
    T.eq(id1, nil)
    T.eq(role1, nil)

    local id2, role2 = identity.sender_of({})
    T.eq(id2, nil)
    T.eq(role2, nil)

    local id3, role3 = identity.sender_of({ account = {} })
    T.eq(id3, nil)
    T.eq(role3, nil)

    local id4, role4 = identity.sender_of({ account = { identity = "" } })
    T.eq(id4, nil)
    T.eq(role4, nil)
end)

T.test("identity: sender_of возвращает identity и role из мок-клиента", function()
    local client_gm = {
        account = {
            identity = "master_user",
            role = "master",
        },
    }
    local id_gm, role_gm = identity.sender_of(client_gm)
    T.eq(id_gm, "master_user")
    T.eq(role_gm, "master")

    local client_player = {
        account = {
            identity = "player_bob",
            role = "player",
        },
    }
    local id_p, role_p = identity.sender_of(client_player)
    T.eq(id_p, "player_bob")
    T.eq(role_p, "player")

    local client_no_role = {
        account = {
            identity = "player_charlie",
        },
    }
    local id_nr, role_nr = identity.sender_of(client_no_role)
    T.eq(id_nr, "player_charlie")
    T.eq(role_nr, nil)
end)

T.test("identity: отсутствие api не приводит к ошибке", function()
    -- Вызов init без аргументов или с nil
    local ok1 = pcall(function() identity.init() end)
    T.eq(ok1, true)

    local ok2 = pcall(function() identity.init(nil) end)
    T.eq(ok2, true)

    -- sender_of продолжает работать корректно
    local id, role = identity.sender_of({ account = { identity = "alice", role = "guest" } })
    T.eq(id, "alice")
    T.eq(role, "guest")
end)

T.test("identity: MASTER_ROLE и is_master", function()
    T.eq(identity.MASTER_ROLE, "master")
    T.eq(identity.is_master("master"), true)
    T.eq(identity.is_master("member"), false)
    T.eq(identity.is_master("admin"), false)
    T.eq(identity.is_master(nil), false)
    T.eq(identity.is_master(""), false)
end)

T.test("identity: label возвращает identity, username или unknown", function()
    T.eq(identity.label(nil), "unknown")
    T.eq(identity.label({}), "unknown")
    T.eq(identity.label({ account = {} }), "unknown")
    T.eq(identity.label({ player = { username = "player1" } }), "player1")
    T.eq(identity.label({ account = { identity = "acc1" }, player = { username = "player1" } }), "acc1")
    T.eq(identity.label({ account = { identity = "" }, player = { username = "player1" } }), "player1")
    T.eq(identity.label({ account = { identity = "" }, player = { username = "" } }), "unknown")
end)

T.test("identity: sender_of логирует identity один раз для каждой пары (identity, role)", function()
    local log_mod = require("core/log")
    local logged = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[identity]", 1, true) then
            table.insert(logged, line)
        end
    end

    local client = { account = { identity = "uniq_user", role = "master" } }
    identity.sender_of(client)
    identity.sender_of(client)
    identity.sender_of(client)

    T.eq(#logged, 1, "лог [identity] пишется один раз для пары (identity, role)")

    local client_changed_role = { account = { identity = "uniq_user", role = "member" } }
    identity.sender_of(client_changed_role)
    T.eq(#logged, 2, "новая пара (identity, role) пишется в лог")

    identity.sender_of(client_changed_role)
    T.eq(#logged, 2, "повторный вызов новой пары не дублирует лог")

    log_mod.sink = orig_sink
end)
