local T = require("lib")
local gm_rules = require("core/gm_rules")

T.test("gm_rules: Мастер двигает чужой токен и токен без владельца на любую дистанцию на том же уровне", function()
    local token_other = { id = "t1", owner_id = "bob", cell = { cx = 0, cz = 0, level = 0 } }
    local cell_far = { cx = 100, cz = 100, level = 0 }
    local ok1, reason1 = gm_rules.can_move_token(token_other, cell_far, "master", true)
    T.eq(ok1, true)
    T.eq(reason1, nil)

    local token_no_owner = { id = "t2", owner_id = nil, cell = { cx = 0, cz = 0, level = 0 } }
    local ok2, reason2 = gm_rules.can_move_token(token_no_owner, cell_far, "master", true)
    T.eq(ok2, true)
    T.eq(reason2, nil)
end)

T.test("gm_rules: Игрок двигает свой токен на расстояние <= 5; на 6 -> 'Слишком далеко'", function()
    local token_mine = { id = "t1", owner_id = "alice", cell = { cx = 0, cz = 0, level = 0 } }
    -- dist = |2 - 0| + |3 - 0| = 5 <= 5
    local ok1, reason1 = gm_rules.can_move_token(token_mine, { cx = 2, cz = 3, level = 0 }, "alice", false)
    T.eq(ok1, true)
    T.eq(reason1, nil)

    -- dist = |3 - 0| + |3 - 0| = 6 > 5
    local ok2, reason2 = gm_rules.can_move_token(token_mine, { cx = 3, cz = 3, level = 0 }, "alice", false)
    T.eq(ok2, false)
    T.eq(reason2, "Слишком далеко")
end)

T.test("gm_rules: Игрок двигает чужой токен или токен без владельца -> отказ", function()
    local token_other = { id = "t1", owner_id = "bob", cell = { cx = 0, cz = 0, level = 0 } }
    local ok1, reason1 = gm_rules.can_move_token(token_other, { cx = 1, cz = 0, level = 0 }, "alice", false)
    T.eq(ok1, false)
    T.eq(reason1, "Нет прав на управление данным токеном")

    local token_no_owner = { id = "t2", owner_id = nil, cell = { cx = 0, cz = 0, level = 0 } }
    local ok2, reason2 = gm_rules.can_move_token(token_no_owner, { cx = 1, cz = 0, level = 0 }, "alice", false)
    T.eq(ok2, false)
    T.eq(reason2, "Нет прав на управление данным токеном")
end)

T.test("gm_rules: player_id == nil у не-мастера -> отказ", function()
    local token = { id = "t1", owner_id = "alice", cell = { cx = 0, cz = 0, level = 0 } }
    local ok, reason = gm_rules.can_move_token(token, { cx = 1, cz = 0, level = 0 }, nil, false)
    T.eq(ok, false)
    T.eq(reason, "Игрок не определён")
end)

T.test("gm_rules: Цель = текущая клетка, другой level, token == nil, цель без cx -> отказ", function()
    local token = { id = "t1", owner_id = "alice", cell = { cx = 2, cz = 2, level = 0 } }

    -- 1. token == nil
    local ok1, r1 = gm_rules.can_move_token(nil, { cx = 2, cz = 3, level = 0 }, "alice", false)
    T.eq(ok1, false)
    T.eq(r1, "Токен не найден")

    -- 2. target_cell без cx/cz
    local ok2, r2 = gm_rules.can_move_token(token, { cz = 3, level = 0 }, "alice", false)
    T.eq(ok2, false)
    T.eq(r2, "Некорректная целевая клетка")

    -- 3. Другой level
    local ok3, r3 = gm_rules.can_move_token(token, { cx = 2, cz = 3, level = 1 }, "alice", false)
    T.eq(ok3, false)
    T.eq(r3, "Ход между уровнями запрещён")

    -- 3b. Другой level даже для Мастера
    local ok3b, r3b = gm_rules.can_move_token(token, { cx = 2, cz = 3, level = 1 }, "master", true)
    T.eq(ok3b, false)
    T.eq(r3b, "Ход между уровнями запрещён")

    -- 4. Цель совпадает с текущей клеткой
    local ok4, r4 = gm_rules.can_move_token(token, { cx = 2, cz = 2, level = 0 }, "alice", false)
    T.eq(ok4, false)
    T.eq(r4, "Токен уже в этой клетке")

    -- 4b. Цель совпадает даже для Мастера
    local ok4b, r4b = gm_rules.can_move_token(token, { cx = 2, cz = 2, level = 0 }, "master", true)
    T.eq(ok4b, false)
    T.eq(r4b, "Токен уже в этой клетке")
end)

T.test("gm_rules: max_steps токена учитывается; аргумент max_steps его перекрывает", function()
    local token = { id = "t1", owner_id = "alice", cell = { cx = 0, cz = 0, level = 0 }, max_steps = 3 }

    -- token.max_steps = 3, цель на 4 шага -> отказ
    local ok1, r1 = gm_rules.can_move_token(token, { cx = 4, cz = 0, level = 0 }, "alice", false)
    T.eq(ok1, false)
    T.eq(r1, "Слишком далеко")

    -- token.max_steps = 3, цель на 3 шага -> разрешено
    local ok2, r2 = gm_rules.can_move_token(token, { cx = 3, cz = 0, level = 0 }, "alice", false)
    T.eq(ok2, true)
    T.eq(r2, nil)

    -- аргумент max_steps = 4 перекрывает token.max_steps (3) -> разрешено
    local ok3, r3 = gm_rules.can_move_token(token, { cx = 4, cz = 0, level = 0 }, "alice", false, 4)
    T.eq(ok3, true)
    T.eq(r3, nil)

    -- аргумент max_steps = 1 строже token.max_steps (3) -> отказ на 2 шагах
    local ok4, r4 = gm_rules.can_move_token(token, { cx = 2, cz = 0, level = 0 }, "alice", false, 1)
    T.eq(ok4, false)
    T.eq(r4, "Слишком далеко")
end)

T.test("gm_rules: can_spawn_token: игрок без роли -> отказ; мастер с owner = '' -> отказ", function()
    local ok1, r1 = gm_rules.can_spawn_token("bob", false, "bob")
    T.eq(ok1, false)
    T.truthy(tostring(r1):find("Только Мастер", 1, true))

    local ok2, r2 = gm_rules.can_spawn_token("master", true, "")
    T.eq(ok2, false)
    T.eq(r2, "Некорректный владелец")

    local ok3, r3 = gm_rules.can_spawn_token("master", true, "alice")
    T.eq(ok3, true)
    T.eq(r3, nil)

    local ok4, r4 = gm_rules.can_spawn_token("master", true, nil)
    T.eq(ok4, true)
    T.eq(r4, nil)
end)

T.test("gm_rules: can_set_token_owner: игрок -> отказ, мастер -> разрешено", function()
    local ok1, r1 = gm_rules.can_set_token_owner("bob", false)
    T.eq(ok1, false)
    T.eq(r1, "Только Мастер может менять владельца")

    local ok2, r2 = gm_rules.can_set_token_owner("master", true)
    T.eq(ok2, true)
    T.eq(r2, nil)
end)

T.test("gm_rules: can_remove_token только для GM", function()
    local token = { id = "t1" }
    local ok_gm = gm_rules.can_remove_token(token, 1, true)
    T.eq(ok_gm, true)

    local ok_player, reason = gm_rules.can_remove_token(token, 2, false)
    T.eq(ok_player, false)
    T.truthy(tostring(reason):find("Только Мастер", 1, true))
end)

T.test("gm_rules: can_modify_world только для GM", function()
    local ok_gm = gm_rules.can_modify_world(1, true)
    T.eq(ok_gm, true)

    local ok_player, reason = gm_rules.can_modify_world(2, false)
    T.eq(ok_player, false)
    T.truthy(tostring(reason):find("Только Мастер", 1, true))
end)

T.test("gm_rules: parse_roll разбирает формулы дайсов", function()
    local r1 = gm_rules.parse_roll("1d20+5")
    T.truthy(r1 ~= nil)
    T.eq(r1.count, 1)
    T.eq(r1.sides, 20)
    T.eq(r1.modifier, 5)

    local r2 = gm_rules.parse_roll("3d6-2")
    T.truthy(r2 ~= nil)
    T.eq(r2.count, 3)
    T.eq(r2.sides, 6)
    T.eq(r2.modifier, -2)

    local r3 = gm_rules.parse_roll("d100")
    T.truthy(r3 ~= nil)
    T.eq(r3.count, 1)
    T.eq(r3.sides, 100)
    T.eq(r3.modifier, 0)

    local r4, err = gm_rules.parse_roll("invalid")
    T.eq(r4, nil)
    T.truthy(err ~= nil)
end)

T.test("gm_rules: GUARDED_PACKETS и is_packet_allowed", function()
    T.truthy(type(gm_rules.GUARDED_PACKETS) == "table")
    local expected = {
        "BlockUpdate",
        "BlockDestroy",
        "BlockInteract",
        "BlockRegionUpdate",
        "BlockRegionDestroy",
        "BlockRegionInteract",
        "EntitySpawnAttempt",
        "EntityInteract",
    }
    T.eq(#gm_rules.GUARDED_PACKETS, #expected)
    for _, name in ipairs(expected) do
        -- для Мастера -> true
        local ok_gm, reason_gm = gm_rules.is_packet_allowed(name, true)
        T.eq(ok_gm, true)
        T.eq(reason_gm, nil)

        -- для не-Мастера -> false, "Только Мастер может менять мир"
        local ok_player, reason_player = gm_rules.is_packet_allowed(name, false)
        T.eq(ok_player, false)
        T.eq(reason_player, "Только Мастер может менять мир")
    end

    -- имя вне списка -> true для всех
    local non_guarded = { "ChatMessage", "PlayerPosition", "EntityDespawn", "InventoryInteract" }
    for _, name in ipairs(non_guarded) do
        local ok_gm, r_gm = gm_rules.is_packet_allowed(name, true)
        T.eq(ok_gm, true)
        T.eq(r_gm, nil)

        local ok_player, r_player = gm_rules.is_packet_allowed(name, false)
        T.eq(ok_player, true)
        T.eq(r_player, nil)
    end
end)
