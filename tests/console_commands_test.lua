-- tests/console_commands_test.lua
-- Тесты консольных команд через реестр, защита от обхода прав (specs/net-console-commands.md)

local T = require("lib")
local log_mod = require("core/log")
local identity = require("net/identity")
local block_interceptor = require("net/block_interceptor")
local commands = require("server/commands")

-- Вспомогательная функция для сборки мок-API консоли
local function make_mock_console_api()
    local registered_commands = {}
    local told_messages = {}

    local api = {
        console = {
            set_command = function(scheme, perms, handler, unauth)
                local name = scheme:match("^([%w_]+):")
                registered_commands[name] = {
                    scheme = scheme,
                    perms = perms,
                    handler = handler,
                    unauth = unauth,
                }
            end,
            tell = function(text, client)
                told_messages[#told_messages + 1] = { text = text, client = client }
            end,
        },
        interceptors = {
            send = {
                add_interceptor = function() end,
                add_generic_interceptor = function() end,
            },
        },
        entities = {
            register = function() end,
            eval = {
                NotEquals = function() return 0 end,
                VectorNotEquals = function() return 0 end,
            },
        },
    }

    return api, registered_commands, told_messages
end

-- 1. token_spawn от master и от member
T.test("console: token_spawn от master создает токен; от member отказ", function()
    local api, cmds, told = make_mock_console_api()
    local spawned_tokens = {}
    local spawn_calls = 0

    local mock_tokens = {
        spawn = function(cell, def)
            spawn_calls = spawn_calls + 1
            local id = def.id or "tok_1"
            spawned_tokens[id] = { id = id, cell = cell, owner_id = def.owner_id, name = def.name }
            return id
        end,
        get = function(id) return spawned_tokens[id] end,
    }

    commands.init(mock_tokens)
    block_interceptor.register_token_commands(api, commands)

    local cmd = cmds["token_spawn"]
    T.truthy(cmd ~= nil, "команда token_spawn должна быть зарегистрирована")

    -- 1. Вызов от member -> отказ
    local client_member = { account = { identity = "bob", role = "member" } }
    cmd.handler({ cx = 1, cz = 2, id = "t1", owner = "alice" }, client_member)

    T.eq(spawn_calls, 0, "tokens.spawn не должен вызываться для member")
    T.eq(spawned_tokens["t1"], nil, "токен не должен создаваться")
    T.truthy(#told > 0, "клиент должен получить сообщение в чат")
    T.truthy(told[#told].text:find("Только Мастер"), "сообщение об отказе прав Мастера")

    -- 2. Вызов от master -> успех
    local client_master = { account = { identity = "gm", role = "master" } }
    cmd.handler({ cx = 1, cz = 2, id = "t1", owner = "alice" }, client_master)

    T.eq(spawn_calls, 1, "tokens.spawn вызван 1 раз для master")
    T.truthy(spawned_tokens["t1"] ~= nil, "токен t1 создан")
    T.eq(spawned_tokens["t1"].owner_id, "alice", "владелец alice сохранен")
end)

-- 2. token_spawn с уже занятым id -> отказ
T.test("console: token_spawn с уже занятым id дает отказ, исходный токен цел", function()
    local api, cmds, told = make_mock_console_api()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 0, cz = 0, level = 0 }, owner_id = "alice", name = "Old" },
    }
    local spawn_calls = 0

    local mock_tokens = {
        get = function(id) return registry[id] end,
        spawn = function(cell, def)
            spawn_calls = spawn_calls + 1
            return def.id
        end,
    }

    commands.init(mock_tokens)
    block_interceptor.register_token_commands(api, commands)

    local cmd = cmds["token_spawn"]
    local client_master = { account = { identity = "gm", role = "master" } }

    cmd.handler({ cx = 5, cz = 5, id = "t1", owner = "eve" }, client_master)

    T.eq(spawn_calls, 0, "tokens.spawn не должен вызываться при конфликте id")
    T.eq(registry["t1"].owner_id, "alice", "исходный владелец не изменился")
    T.eq(registry["t1"].cell.cx, 0, "исходная клетка не изменилась")
    T.truthy(told[#told].text:find("уже существует"), "сообщение о занятом id")
end)

-- 3. token_move: единая политика перемещения (master/чужой/дальность/владелец)
T.test("console: token_move: единая политика перемещения (master/чужой/дальность/владелец)", function()
    local api, cmds, told = make_mock_console_api()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 0, cz = 0, level = 0 }, owner_id = "alice" },
        ["t2"] = { id = "t2", cell = { cx = 0, cz = 0, level = 0 }, owner_id = nil },
    }
    local move_calls = 0

    local mock_tokens = {
        get = function(id) return registry[id] end,
        move = function(id, target_cell)
            move_calls = move_calls + 1
            registry[id].cell = { cx = target_cell.cx, cz = target_cell.cz, level = target_cell.level or 0 }
            return true
        end,
    }

    commands.init(mock_tokens)
    block_interceptor.register_token_commands(api, commands)
    local cmd = cmds["token_move"]
    T.truthy(cmd ~= nil, "команда token_move зарегистрирована")

    -- А. Master двигает любой токен на любую дистанцию (> 5 клеток: (0,0) -> (10,10))
    local client_master = { account = { identity = "gm", role = "master" } }
    cmd.handler({ id = "t1", cx = 10, cz = 10 }, client_master)
    T.eq(move_calls, 1, "токен сдвинут мастером")
    T.eq(registry["t1"].cell.cx, 10)
    T.eq(registry["t1"].cell.cz, 10)
    -- Возвращаем t1 в (0, 0)
    registry["t1"].cell = { cx = 0, cz = 0, level = 0 }
    move_calls = 0

    -- Б. Member двигает чужой токен (bob пытается двигать токен alice t1) -> отказ по владельцу
    local client_bob = { account = { identity = "bob", role = "member" } }
    cmd.handler({ id = "t1", cx = 1, cz = 1 }, client_bob)
    T.eq(move_calls, 0, "чужой токен не должен сдвинуться")
    T.eq(registry["t1"].cell.cx, 0)
    T.truthy(told[#told].text:find("Нет прав на управление данным токеном", 1, true), "текст отказа: Нет прав на управление данным токеном")

    -- В. Member двигает токен без владельца (bob пытается двигать t2) -> отказ по владельцу
    cmd.handler({ id = "t2", cx = 1, cz = 1 }, client_bob)
    T.eq(move_calls, 0, "токен без владельца не должен сдвинуться")
    T.eq(registry["t2"].cell.cx, 0)
    T.truthy(told[#told].text:find("Нет прав на управление данным токеном", 1, true), "текст отказа: Нет прав на управление данным токеном")

    -- Г. Member-владелец на расстояние > 5 клеток (alice пытается двигать t1 из (0,0) в (10,10)) -> "Слишком далеко"
    local client_alice = { account = { identity = "alice", role = "member" } }
    cmd.handler({ id = "t1", cx = 10, cz = 10 }, client_alice)
    T.eq(move_calls, 0, "токен не должен сдвинуться при превышении дальности")
    T.eq(registry["t1"].cell.cx, 0)
    T.truthy(told[#told].text:find("Слишком далеко", 1, true), "текст отказа: Слишком далеко")

    -- Д. Member-владелец на расстояние <= 5 клеток (alice двигает t1 из (0,0) в (2, 3)) -> успех
    cmd.handler({ id = "t1", cx = 2, cz = 3 }, client_alice)
    T.eq(move_calls, 1, "токен успешно сдвинут владельцем")
    T.eq(registry["t1"].cell.cx, 2)
    T.eq(registry["t1"].cell.cz, 3)
end)

-- 4. token_remove: master удаляет; member отказ
T.test("console: token_remove: master удаляет; member отказ", function()
    local api, cmds, told = make_mock_console_api()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 0, cz = 0, level = 0 }, owner_id = "alice" },
    }
    local remove_calls = 0

    local mock_tokens = {
        get = function(id) return registry[id] end,
        remove = function(id)
            remove_calls = remove_calls + 1
            registry[id] = nil
            return true
        end,
    }

    commands.init(mock_tokens)
    block_interceptor.register_token_commands(api, commands)
    local cmd = cmds["token_remove"]

    -- 1. member -> отказ
    local client_member = { account = { identity = "alice", role = "member" } }
    cmd.handler({ id = "t1" }, client_member)
    T.eq(remove_calls, 0)
    T.truthy(registry["t1"] ~= nil)

    -- 2. master -> успех
    local client_master = { account = { identity = "gm", role = "master" } }
    cmd.handler({ id = "t1" }, client_master)
    T.eq(remove_calls, 1)
    T.eq(registry["t1"], nil)
end)

-- 5. token_owner: master меняет и снимает владельца; member отказ
T.test("console: token_owner: master меняет и снимает владельца; member отказ", function()
    local api, cmds, told = make_mock_console_api()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 0, cz = 0, level = 0 }, owner_id = "alice" },
    }

    local mock_tokens = {
        get = function(id) return registry[id] end,
        set_owner = function(id, owner)
            registry[id].owner_id = owner
            return true
        end,
    }

    commands.init(mock_tokens)
    block_interceptor.register_token_commands(api, commands)
    local cmd = cmds["token_owner"]
    T.truthy(cmd ~= nil, "команда token_owner зарегистрирована")

    -- 1. member -> отказ
    local client_member = { account = { identity = "bob", role = "member" } }
    cmd.handler({ id = "t1", owner = "bob" }, client_member)
    T.eq(registry["t1"].owner_id, "alice")

    -- 2. master меняет на bob
    local client_master = { account = { identity = "gm", role = "master" } }
    cmd.handler({ id = "t1", owner = "bob" }, client_master)
    T.eq(registry["t1"].owner_id, "bob")

    -- 3. master снимает владельца (без owner)
    cmd.handler({ id = "t1" }, client_master)
    T.eq(registry["t1"].owner_id, nil)
end)

-- 6. block_set: master вызывает world.set_block один раз; member отказ
T.test("console: block_set: master вызывает world.set_block; member отказ", function()
    local api, cmds, told = make_mock_console_api()
    local set_block_calls = 0
    local last_set = nil

    local mock_world = {
        set_block = function(x, y, z, id, states)
            set_block_calls = set_block_calls + 1
            last_set = { x = x, y = y, z = z, id = id }
            return true
        end,
    }

    commands.init(nil, mock_world)
    block_interceptor.register_command(api)
    local cmd = cmds["block_set"]
    T.truthy(cmd ~= nil, "команда block_set зарегистрирована")

    -- 1. member -> отказ
    local client_member = { account = { identity = "bob", role = "member" } }
    cmd.handler({ x = 10, y = 20, z = 30, id = 5 }, client_member)
    T.eq(set_block_calls, 0, "world.set_block не должен вызываться для member")

    -- 2. master -> успех
    local client_master = { account = { identity = "gm", role = "master" } }
    cmd.handler({ x = 10, y = 20, z = 30, id = 5 }, client_master)
    T.eq(set_block_calls, 1, "world.set_block вызван ровно 1 раз для master")
    T.eq(last_set.x, 10)
    T.eq(last_set.y, 20)
    T.eq(last_set.z, 30)
    T.eq(last_set.id, 5)
end)

-- 7. Клиент без account.identity для любой команды: нет dispatch, auth_denied sender_unknown
T.test("console: клиент без account.identity: нет dispatch, auth_denied sender_unknown", function()
    local api, cmds, told = make_mock_console_api()
    local mock_tokens = {
        spawn = function() error("не должно вызываться") end,
        get = function() return nil end,
    }
    commands.init(mock_tokens)
    block_interceptor.register_token_commands(api, commands)

    local denied_logged = false
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("auth_denied") and line:find("sender_unknown") then
            denied_logged = true
        end
        orig_sink(line)
    end

    local cmd = cmds["token_spawn"]
    local anon_client = { player = { username = "anon" } }
    cmd.handler({ cx = 1, cz = 1 }, anon_client)

    log_mod.sink = orig_sink

    T.eq(denied_logged, true, "должен быть залогирован auth_denied sender_unknown")
    T.truthy(#told > 0, "клиенту отправлен отказ")
    T.truthy(told[#told].text:find("sender_unknown") or told[#told].text:find("Не удалось определить"), "сообщение клиенту")
end)

-- 8. Клиенту отправляется api.console.tell; при отсутствии api.console.tell ошибки нет
T.test("console: при отсутствии api.console.tell ошибки нет", function()
    local api, cmds, told = make_mock_console_api()
    api.console.tell = nil -- убираем tell

    commands.init()
    block_interceptor.register_token_commands(api, commands)

    local cmd = cmds["token_spawn"]
    local client = { account = { identity = "bob", role = "member" } }

    local ok = pcall(function()
        cmd.handler({ cx = 1, cz = 1 }, client)
    end)
    T.eq(ok, true, "отсутствие api.console.tell не вызывает падения")
end)

-- 9. init(nil) и init({}) не падают, пишут neutron_api_missing
T.test("console: init(nil) и init({}) не падают, пишут neutron_api_missing", function()
    local missing_parts = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        local part = line:match("neutron_api_missing.*part=\"([^\"]+)\"")
        if part then
            missing_parts[part] = true
        end
        orig_sink(line)
    end

    -- 1. init(nil)
    local ok1 = pcall(function()
        block_interceptor.init(nil)
    end)
    T.eq(ok1, true, "init(nil) не должен падать")

    -- 2. init({})
    local ok2 = pcall(function()
        block_interceptor.init({})
    end)
    T.eq(ok2, true, "init({}) не должен падать")

    log_mod.sink = orig_sink

    T.truthy(missing_parts["interceptors"] or missing_parts["api"], "зафиксирован neutron_api_missing для interceptors")
    T.truthy(missing_parts["console"], "зафиксирован neutron_api_missing для console")
end)

-- 10. identity.label, identity.is_master, однократный лог пары (identity, role)
T.test("identity: label, is_master, однократный лог пары", function()
    -- is_master
    T.eq(identity.MASTER_ROLE, "master")
    T.eq(identity.is_master("master"), true)
    T.eq(identity.is_master("member"), false)
    T.eq(identity.is_master(nil), false)

    -- label
    T.eq(identity.label(nil), "unknown")
    T.eq(identity.label({}), "unknown")
    T.eq(identity.label({ player = { username = "hero" } }), "hero")
    T.eq(identity.label({ account = { identity = "alice" }, player = { username = "hero" } }), "alice")

    -- однократный лог
    local identity_logs = 0
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("%[identity%]") and line:find("user_cache_test") then
            identity_logs = identity_logs + 1
        end
        orig_sink(line)
    end

    local test_client = { account = { identity = "user_cache_test", role = "master" } }
    identity.sender_of(test_client)
    identity.sender_of(test_client)
    identity.sender_of(test_client)

    log_mod.sink = orig_sink

    T.eq(identity_logs, 1, "лог [identity] для одной и той же пары должен вызываться ровно 1 раз")
end)

-- 11. Статическая проверка: client.account только в net/identity.lua
T.test("static: client.account встречается только в net/identity.lua", function()
    local win = package.config:sub(1, 1) == "\\"
    local cmd = win and 'dir /b /s "vtt\\*.lua" 2>nul' or 'find vtt -type f -name "*.lua" 2>/dev/null'
    local h = io.popen(cmd)
    local found = {}

    if h then
        for path in h:lines() do
            path = path:gsub("\r", "")
            local norm = path:gsub("\\", "/")
            if not norm:find("net/identity.lua", 1, true) then
                local f = io.open(path, "rb")
                if f then
                    local content = f:read("*a")
                    f:close()
                    -- Удаляем комментарии
                    local stripped = content:gsub("%-%-[^\n]*", "")
                    if stripped:find("client%.account") then
                        found[#found + 1] = norm
                    end
                end
            end
        end
        h:close()
    end

    T.eq(#found, 0, "client.account не должен встречаться вне net/identity.lua, найдено в: " .. table.concat(found, ", "))
end)

-- 12. Статическая проверка: в block_interceptor.lua нет прямых вызовов tokens.* и world.set_block
T.test("static: в block_interceptor.lua нет вызовов tokens_module.* и world_module.set_block", function()
    local f = io.open("vtt/modules/net/block_interceptor.lua", "rb")
    T.truthy(f ~= nil, "block_interceptor.lua должен существовать")
    local content = f:read("*a")
    f:close()

    local stripped = content:gsub("%-%-[^\n]*", "")
    T.eq(stripped:find("tokens_module%.spawn") ~= nil, false, "не должно быть tokens_module.spawn")
    T.eq(stripped:find("tokens_module%.move") ~= nil, false, "не должно быть tokens_module.move")
    T.eq(stripped:find("tokens_module%.remove") ~= nil, false, "не должно быть tokens_module.remove")
    T.eq(stripped:find("world_module%.set_block") ~= nil, false, "не должно быть world_module.set_block")
end)

-- 13. Лог результата: при успехе result/token_id и error=nil; при ошибке error с текстом и result=nil
T.test("console: лог результата команд: единый формат result vs error", function()
    local api, cmds, told = make_mock_console_api()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 0, cz = 0, level = 0 }, owner_id = "alice" },
    }
    local mock_tokens = {
        get = function(id) return registry[id] end,
        spawn = function(cell, def)
            local id = def.id or "tok_spawned"
            registry[id] = { id = id, cell = cell, owner_id = def.owner_id }
            return id
        end,
        move = function(id, target_cell)
            registry[id].cell = { cx = target_cell.cx, cz = target_cell.cz, level = 0 }
            return true
        end,
        remove = function(id)
            registry[id] = nil
            return true
        end,
        set_owner = function(id, owner)
            registry[id].owner_id = owner
            return true
        end,
    }
    local mock_world = {
        set_block = function() return true end,
    }

    commands.init(mock_tokens, mock_world)
    block_interceptor.register_token_commands(api, commands)
    block_interceptor.register_command(api, commands, mock_world)

    local logged_lines = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        logged_lines[#logged_lines + 1] = line
        orig_sink(line)
    end

    local client_master = { account = { identity = "gm", role = "master" } }
    local client_member = { account = { identity = "bob", role = "member" } }

    -- 1. token_move успех (master)
    cmds["token_move"].handler({ id = "t1", cx = 1, cz = 1 }, client_master)
    local move_success_log = logged_lines[#logged_lines]
    T.truthy(move_success_log:find("%[command_result_token_move%]"), "лог command_result_token_move")
    T.truthy(move_success_log:find("success=true"), "success=true")
    T.truthy(move_success_log:find("result="), "поле result присутствует при успехе")
    T.eq(move_success_log:find("error="), nil, "error=nil при успехе")

    -- 2. token_move отказ (member чужой токен)
    cmds["token_move"].handler({ id = "t1", cx = 2, cz = 2 }, client_member)
    local move_fail_log = logged_lines[#logged_lines]
    T.truthy(move_fail_log:find("success=false"), "success=false")
    T.truthy(move_fail_log:find("error="), "поле error присутствует при отказе")
    T.eq(move_fail_log:find("result="), nil, "result=nil при отказе")

    -- 3. token_remove успех (master)
    cmds["token_remove"].handler({ id = "t1" }, client_master)
    local remove_success_log = logged_lines[#logged_lines]
    T.truthy(remove_success_log:find("%[command_result_token_remove%]"))
    T.truthy(remove_success_log:find("success=true"))
    T.truthy(remove_success_log:find("result="))
    T.eq(remove_success_log:find("error="), nil, "error=nil при успехе remove")

    -- 4. token_remove отказ (member)
    cmds["token_remove"].handler({ id = "t1" }, client_member)
    local remove_fail_log = logged_lines[#logged_lines]
    T.truthy(remove_fail_log:find("success=false"))
    T.truthy(remove_fail_log:find("error="))
    T.eq(remove_fail_log:find("result="), nil)

    -- 5. token_spawn отказ (member)
    cmds["token_spawn"].handler({ cx = 1, cz = 1, id = "s1" }, client_member)
    local spawn_fail_log = logged_lines[#logged_lines]
    T.truthy(spawn_fail_log:find("%[command_result_token_spawn%]"))
    T.truthy(spawn_fail_log:find("success=false"))
    T.truthy(spawn_fail_log:find("error="), "error присутствует при отказе spawn")

    -- 6. block_set отказ (member)
    cmds["block_set"].handler({ x = 1, y = 1, z = 1, id = 1 }, client_member)
    local block_fail_log = logged_lines[#logged_lines]
    T.truthy(block_fail_log:find("%[command_result_block_set%]"))
    T.truthy(block_fail_log:find("success=false"), "success=false при отказе block_set")
    T.truthy(block_fail_log:find("error="), "error присутствует при отказе block_set")
    T.eq(block_fail_log:find("result="), nil, "result=nil при отказе block_set")

    log_mod.sink = orig_sink
end)

-- 14. Без Neutron: обнуление _G.Message и _G.Replication, init(nil) status=skipped no_api, без server_messages_registered
T.test("console: без Neutron (_G.Message/_G.Replication nil): init(nil) skipped no_api, без server_messages_registered", function()
    local old_Message = _G.Message
    local old_Replication = _G.Replication
    _G.Message = nil
    _G.Replication = nil

    local logged_lines = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        logged_lines[#logged_lines + 1] = line
        orig_sink(line)
    end

    -- 1. init(nil)
    block_interceptor.init(nil)
    local init_nil_lines = table.concat(logged_lines, "\n")
    T.truthy(init_nil_lines:find("status=\"skipped\""), "init(nil) должен логировать status=skipped")
    T.truthy(init_nil_lines:find("reason=\"no_api\""), "init(nil) должен логировать reason=no_api")
    T.eq(init_nil_lines:find("server_messages_registered"), nil, "init(nil) не должен регистрировать server_messages_registered")

    -- 2. init({})
    logged_lines = {}
    block_interceptor.init({})
    local init_empty_lines = table.concat(logged_lines, "\n")
    T.eq(init_empty_lines:find("server_messages_registered"), nil, "init({}) без messages API не должен логировать server_messages_registered")

    log_mod.sink = orig_sink
    _G.Message = old_Message
    _G.Replication = old_Replication
end)

-- 15. world_module не теряется в init(api, world_module, options)
T.test("console: init(api, world_mock, options): block_set от master вызывает world_mock.set_block", function()
    local api, cmds, told = make_mock_console_api()
    local world_mock_called = false
    local called_args = nil
    local world_mock = {
        set_block = function(x, y, z, id, states)
            world_mock_called = true
            called_args = { x = x, y = y, z = z, id = id }
            return true
        end,
    }

    block_interceptor.init(api, world_mock, { commands_module = commands })
    local cmd = cmds["block_set"]
    T.truthy(cmd ~= nil, "команда block_set зарегистрирована через init")

    local client_master = { account = { identity = "gm", role = "master" } }
    cmd.handler({ x = 7, y = 8, z = 9, id = 2 }, client_master)

    T.truthy(world_mock_called, "world_mock.set_block должен быть вызван (world_module не должен теряться в init)")
    T.eq(called_args.x, 7)
    T.eq(called_args.y, 8)
    T.eq(called_args.z, 9)
    T.eq(called_args.id, 2)
end)
