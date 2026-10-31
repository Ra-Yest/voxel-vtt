-- tests/identity_test.lua
-- Тесты модуля net/identity (получение отправителя, роли, region_of, проверка входа)

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

    local id4, role4 = identity.sender_of({ account = { identity = "", is_logged = true } })
    T.eq(id4, nil)
    T.eq(role4, nil)
end)

T.test("identity: sender_of возвращает identity и role из мок-клиента при is_logged = true", function()
    local client_gm = {
        account = {
            identity = "master_user",
            role = "master",
            is_logged = true,
        },
    }
    local id_gm, role_gm = identity.sender_of(client_gm)
    T.eq(id_gm, "master_user")
    T.eq(role_gm, "master")

    local client_player = {
        account = {
            identity = "player_bob",
            role = "player",
            is_logged = true,
        },
    }
    local id_p, role_p = identity.sender_of(client_player)
    T.eq(id_p, "player_bob")
    T.eq(role_p, "player")

    local client_no_role = {
        account = {
            identity = "player_charlie",
            is_logged = true,
        },
    }
    local id_nr, role_nr = identity.sender_of(client_no_role)
    T.eq(id_nr, "player_charlie")
    T.eq(role_nr, nil)
end)

T.test("identity: sender_of возвращает nil, nil для клиента с is_logged = false или nil, логирует auth_denied not_logged", function()
    local log_mod = require("core/log")
    local logged_auth_denied = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[auth_denied]", 1, true) and line:find("not_logged_user", 1, true) then
            table.insert(logged_auth_denied, line)
        end
    end

    local client_unlogged = {
        account = {
            identity = "not_logged_user",
            role = "player",
            is_logged = false,
        },
    }
    local id1, r1 = identity.sender_of(client_unlogged)
    T.eq(id1, nil, "клиент с is_logged = false должен вернуть nil")
    T.eq(r1, nil, "клиент с is_logged = false должен вернуть nil")

    -- Повторный вызов не должен дублировать auth_denied для того же identity
    identity.sender_of(client_unlogged)
    T.eq(#logged_auth_denied, 1, "auth_denied с reason=not_logged пишется ровно 1 раз для identity")
    T.truthy(logged_auth_denied[1]:find("not_logged", 1, true), "в логе должна быть причина not_logged")

    local client_nil_logged = {
        account = {
            identity = "not_logged_user2",
            role = "master",
            -- is_logged отсутствует (nil)
        },
    }
    local id2, r2 = identity.sender_of(client_nil_logged)
    T.eq(id2, nil, "клиент без is_logged должен вернуть nil")
    T.eq(r2, nil, "клиент без is_logged должен вернуть nil")

    log_mod.sink = orig_sink
end)

T.test("identity: отсутствие api не приводит к ошибке", function()
    -- Вызов init без аргументов или с nil
    local ok1 = pcall(function() identity.init() end)
    T.eq(ok1, true)

    local ok2 = pcall(function() identity.init(nil) end)
    T.eq(ok2, true)

    -- sender_of продолжает работать корректно
    local id, role = identity.sender_of({ account = { identity = "alice", role = "guest", is_logged = true } })
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

T.test("identity: region_of возвращает {x, y, z} только при корректных числовых данных", function()
    T.truthy(type(identity.region_of) == "function", "region_of должна быть функцией")

    T.eq(identity.region_of(nil), nil)
    T.eq(identity.region_of({}), nil)
    T.eq(identity.region_of({ player = {} }), nil)
    T.eq(identity.region_of({ player = { region_pos = {} } }), nil)
    T.eq(identity.region_of({ player = { region_pos = { x = "0", y = 0, z = 0 } } }), nil)
    T.eq(identity.region_of({ player = { region_pos = { x = 0, y = nil, z = 0 } } }), nil)

    local res = identity.region_of({ player = { region_pos = { x = 2, y = 1, z = -3 } } })
    T.truthy(type(res) == "table")
    T.eq(res.x, 2)
    T.eq(res.y, 1)
    T.eq(res.z, -3)
end)

T.test("identity: client.player читается только в net/identity.lua (статическая проверка по vtt/**.lua)", function()
    local win = package.config:sub(1, 1) == "\\"
    local cmd = win and 'dir /b /s "vtt\\*.lua" 2>nul' or 'find vtt -name "*.lua" 2>/dev/null'
    local h = io.popen(cmd)
    T.truthy(h ~= nil)
    local violations = {}
    for line in h:lines() do
        local file_path = line:gsub("\r", "")
        if file_path ~= "" and not file_path:find("identity.lua", 1, true) then
            local f = io.open(file_path, "r")
            if f then
                local content = f:read("*a")
                f:close()
                if content:find("client%.player") then
                    table.insert(violations, file_path)
                end
            end
        end
    end
    h:close()
    T.eq(#violations, 0, "client.player читается вне identity.lua: " .. table.concat(violations, ", "))
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

    local client = { account = { identity = "uniq_user", role = "master", is_logged = true } }
    identity.sender_of(client)
    identity.sender_of(client)
    identity.sender_of(client)

    T.eq(#logged, 1, "лог [identity] пишется один раз для пары (identity, role)")

    local client_changed_role = { account = { identity = "uniq_user", role = "member", is_logged = true } }
    identity.sender_of(client_changed_role)
    T.eq(#logged, 2, "новая пара (identity, role) пишется в лог")

    identity.sender_of(client_changed_role)
    T.eq(#logged, 2, "повторный вызов новой пары не дублирует лог")

    log_mod.sink = orig_sink
end)
