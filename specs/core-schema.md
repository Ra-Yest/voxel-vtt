# Спека: core/schema

**Файл:** `vtt/modules/core/schema.lua`  
**Слой:** core  
**Исполнитель:** сильная модель  
**Риск:** зелёный  

## Назначение

Реестр схем данных и валидатор команд для MVP-0. Служит единым источником структуры команд между клиентом и сервером.

## Интерфейс

- `schema.define(name, schema_def)`: регистрирует схему команды по имени.
- `schema.get(name)`: возвращает определение схемы для команды `name`.
- `schema.validate(name, payload)`: проверяет соответствие `payload` схеме команды. Возвращает `ok, err_msg`.
- Команды MVP-0:
  - `SpawnToken`: поля `asset_id` (string), `cell` (таблица `cx, cz, level`), `name` (string).
  - `MoveToken`: поля `token_id` (string/number), `target_cell` (таблица `cx, cz, level`).
  - `RemoveToken`: поле `token_id` (string/number).
  - `Roll`: поле `formula` (string, напр. `"1d20+2"`), опционально `comment` (string).
  - `Chat`: поле `text` (string).

## Правила и ограничения

- Без вызовов движка и сети (чистый Lua).
- Строгая проверка обязательных полей и их типов.

## Критерий готовности

- Тесты в `tests/schema_test.lua` проходят на каждую команду и функцию.

## Вне задачи

Сетевая сериализация (BSON/JSON) — ответственность слоя `net`.
