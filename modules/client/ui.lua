-- client/ui.lua
-- Слой: client
-- Спека: specs/client-ui.md
-- Назначение: Интерфейс стола (HUD): чат, лог бросков, панель инструментов Мастера.
-- Публичные функции:
--   init()
--   show_gm_panel(visible)
--   append_chat(sender, message)
--   append_roll(sender, formula, result)
--   send_chat_message(text)
--   send_roll_command(formula)

local channel = require("net/channel")

local M = {}

M.chat_history = {}
M.roll_history = {}
M.gm_panel_visible = false

-- Инициализация HUD элементов
function M.init()
    -- docs: docs/engine/scripting/builtins/libhud.md:49: hud.open_permanent(layoutid: str)
    hud.open_permanent("vtt:hud/main")
end

-- Переключение видимости панели Мастера
function M.show_gm_panel(visible)
    M.gm_panel_visible = visible
    if visible then
        -- docs: docs/engine/scripting/builtins/libhud.md:49: hud.open_permanent(layoutid: str)
        hud.open_permanent("vtt:hud/gm_panel")
    else
        -- docs: docs/engine/scripting/builtins/libhud.md:52: hud.close(layoutid: str)
        hud.close("vtt:hud/gm_panel")
    end
end

-- Добавление сообщения в историю чата
function M.append_chat(sender, message)
    M.chat_history[#M.chat_history + 1] = {
        sender = sender,
        message = message,
        time = os.time(),
    }
end

-- Добавление записи броска кубика
function M.append_roll(sender, formula, result)
    M.roll_history[#M.roll_history + 1] = {
        sender = sender,
        formula = formula,
        result = result,
        time = os.time(),
    }
end

-- Отправка сообщения чата на сервер
function M.send_chat_message(text)
    channel.send("Chat", { text = text })
end

-- Отправка команды броска кубиков на сервер
function M.send_roll_command(formula)
    channel.send("Roll", { formula = formula })
end

return M
