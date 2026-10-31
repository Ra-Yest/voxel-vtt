-- core/gm_rules.lua
-- Слой: core (чистый Lua, без вызовов движка)
-- Спека: specs/server-move-validation.md, specs/net-block-guard.md
-- Назначение: Игровая логика и правила Мастера: проверка прав (GM vs Player), валидация перемещений и разбор формул дайсов.
-- Публичные функции:
--   can_move_token(token, target_cell, player_id, is_gm, max_steps)
--   can_spawn_token(player_id, is_gm, owner)
--   can_set_token_owner(player_id, is_gm)
--   can_remove_token(token, player_id, is_gm)
--   can_modify_world(player_id, is_gm)
--   parse_roll(formula)
--   is_packet_allowed(packet_name, is_gm)

local grid = require("core/grid")

local M = {}

M.DEFAULT_MOVE_STEPS = 5

M.GUARDED_PACKETS = {
    "BlockUpdate",
    "BlockDestroy",
    "BlockInteract",
    "BlockRegionUpdate",
    "BlockRegionDestroy",
    "BlockRegionInteract",
    "EntitySpawnAttempt",
    "EntityInteract",
}

-- Проверка разрешения клиентского сетевого пакета
function M.is_packet_allowed(packet_name, is_gm)
    local is_guarded = false
    for _, name in ipairs(M.GUARDED_PACKETS) do
        if name == packet_name then
            is_guarded = true
            break
        end
    end
    if not is_guarded then
        return true
    end
    if is_gm == true then
        return true
    end
    return false, "Только Мастер может менять мир"
end

-- Проверка возможности перемещения токена
function M.can_move_token(token, target_cell, player_id, is_gm, max_steps)
    -- 1. token == nil
    if not token then
        return false, "Токен не найден"
    end

    -- 2. target_cell без числовых cx, cz
    if not target_cell or type(target_cell.cx) ~= "number" or type(target_cell.cz) ~= "number" then
        return false, "Некорректная целевая клетка"
    end

    local token_cell = token.cell or { cx = 0, cz = 0, level = 0 }

    -- 3. Ход между уровнями запрещён
    if (target_cell.level or 0) ~= (token_cell.level or 0) then
        return false, "Ход между уровнями запрещён"
    end

    -- 4. target_cell совпадает с token.cell
    if target_cell.cx == token_cell.cx and target_cell.cz == token_cell.cz and (target_cell.level or 0) == (token_cell.level or 0) then
        return false, "Токен уже в этой клетке"
    end

    -- 5. is_gm == true -> разрешено (Мастер без ограничения дальности и владения)
    if is_gm == true then
        return true
    end

    -- 6. player_id == nil
    if player_id == nil then
        return false, "Игрок не определён"
    end

    -- 7. token.owner_id == nil или token.owner_id ~= player_id
    if token.owner_id == nil or token.owner_id ~= player_id then
        return false, "Нет прав на управление данным токеном"
    end

    -- 8. Проверка дальности
    local allowed_steps = max_steps or token.max_steps or M.DEFAULT_MOVE_STEPS
    if grid.distance(token_cell, target_cell) > allowed_steps then
        return false, "Слишком далеко"
    end

    return true
end

-- Проверка права спавна токена (в MVP-0 только GM)
function M.can_spawn_token(player_id, is_gm, owner)
    if not is_gm then
        return false, "Только Мастер (GM) может создавать токены"
    end
    if owner ~= nil then
        if type(owner) ~= "string" or owner == "" then
            return false, "Некорректный владелец"
        end
    end
    return true
end

-- Проверка права смены владельца токена (только GM)
function M.can_set_token_owner(player_id, is_gm)
    if not is_gm then
        return false, "Только Мастер может менять владельца"
    end
    return true
end

-- Проверка права удаления токена (в MVP-0 только GM)
function M.can_remove_token(token, player_id, is_gm)
    if not is_gm then
        return false, "Только Мастер (GM) может удалять токены"
    end
    return true
end

-- Проверка права модификации вокселей (в MVP-0 только GM)
function M.can_modify_world(player_id, is_gm)
    if not is_gm then
        return false, "Только Мастер (GM) может изменять мир"
    end
    return true
end

-- Разбор формулы дайсов (например, "1d20+2", "2d6-1", "d20")
function M.parse_roll(formula)
    if type(formula) ~= "string" then
        return nil, "Формула должна быть строкой"
    end
    local trimmed = formula:gsub("%s+", "")
    local count_str, sides_str, mod_sign, mod_str = trimmed:match("^(%d*)d(%d+)([+-]?)(%d*)$")
    if not sides_str then
        return nil, "Некорректный формат формулы дайса: " .. formula
    end
    local count = tonumber(count_str) or 1
    local sides = tonumber(sides_str)
    local mod = 0
    if mod_str and #mod_str > 0 then
        mod = tonumber(mod_str) or 0
        if mod_sign == "-" then
            mod = -mod
        end
    end
    return {
        count = count,
        sides = sides,
        modifier = mod,
    }
end

return M
