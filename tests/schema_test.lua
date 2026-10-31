local T = require("lib")
local schema = require("core/schema")

T.test("schema: define и get", function()
    schema.define("TestCmd", {
        fields = {
            id = { type = "number", required = true },
        },
    })
    local def = schema.get("TestCmd")
    T.truthy(def ~= nil, "схема найдена")
    T.eq(def.fields.id.type, "number")
end)

T.test("schema: валидация успешна для валидных данных", function()
    local ok, err = schema.validate("SpawnToken", {
        asset_id = "token_goblin",
        cell = { cx = 1, cz = 2, level = 0 },
        name = "Goblin 1",
    })
    T.eq(ok, true)
    T.eq(err, nil)
end)

T.test("schema: отказ при отсутствии обязательного поля", function()
    local ok, err = schema.validate("SpawnToken", {
        asset_id = "token_goblin",
        name = "Goblin 1",
    })
    T.eq(ok, false)
    T.truthy(tostring(err):find("Отсутствует обязательное поле", 1, true))
end)

T.test("schema: отказ при некорректном типе поля", function()
    local ok, err = schema.validate("Chat", {
        text = 12345,
    })
    T.eq(ok, false)
    T.truthy(tostring(err):find("должно иметь тип string", 1, true))
end)

T.test("schema: валидация всех команд MVP-0", function()
    T.truthy(schema.get("SpawnToken") ~= nil)
    T.truthy(schema.get("MoveToken") ~= nil)
    T.truthy(schema.get("RemoveToken") ~= nil)
    T.truthy(schema.get("Roll") ~= nil)
    T.truthy(schema.get("Chat") ~= nil)

    local ok1 = schema.validate("MoveToken", { token_id = "t1", target_cell = { cx = 0, cz = 0, level = 0 } })
    T.eq(ok1, true)

    local ok2 = schema.validate("RemoveToken", { token_id = "t1" })
    T.eq(ok2, true)

    local ok3 = schema.validate("Roll", { formula = "1d20+5" })
    T.eq(ok3, true)

    local ok4 = schema.validate("Chat", { text = "Hello" })
    T.eq(ok4, true)
end)
