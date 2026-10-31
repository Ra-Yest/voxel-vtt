# Спека: net/block-guard (защита мира: игрок не меняет блоки и не создаёт сущности)

**Файлы (закрытый список, правило 11 ослаблено только для этой задачи):**
- `vtt/modules/net/block_guard.lua` (новый)
- `vtt/modules/core/gm_rules.lua` (только новый список и функция пакетов)
- `vtt/scripts/world.lua` (только одна строка подключения в серверной ветке)
- `tools/api_allowlist.lua` (добавить `api.interceptors.packets.ClientMsg`)
- тесты: новый `tests/block_guard_test.lua` (+ строка в `tests/all.lua`), дополнение `tests/gm_rules_test.lua`

**Слой:** net (+ core: только данные и чистая функция)
**Исполнитель:** сильная модель
**Риск:** красный (права и безопасность)

## Назначение

Закрыть пункт S0.3: ядро Neutron не проверяет права на блоки (`can_interact_with_block` всегда `true`, правило `allow-destroy` на сервере ничего не делает, см. `reports/2026-10-29-neutron-audit.md`). Поставить серверный receive-перехватчик, который отбрасывает пакеты изменения мира и спавна сущностей от всех, кроме Мастера.

## Решение человека

Блокируется всё, включая взаимодействие с блоками (`BlockInteract`, `BlockRegionInteract`): на настольной карте интерактивных блоков нет.

## Факты из аудита, на которые опирается спека

- Пакеты адресуются числовым ID из таблицы `api.interceptors.packets.ClientMsg.<Имя>`, строковые имена не работают (`modules/api/v2/interceptors.lua:48-49, 79-84`). Числа в код не зашивать: брать по имени из таблицы во время запуска.
- Если receive-перехватчик вернул `false`, пакет отбрасывается, клиент ничего не получает (`modules/net/pipelines/main.lua:60-65`).
- Перехватчик получает `(client, original_packet, edited_packet)`, возвращает `true` (пропустить) или `false`/`nil` (отбросить) (`docs/neutron/api/libraries/interceptors.md`).
- Роль клиента: `client.account.role`, читается только в `net/identity.lua`.

## Интерфейс

### core/gm_rules.lua

- `M.GUARDED_PACKETS`: список имён клиентских пакетов, закрытых для не-Мастеров:
  `BlockUpdate`, `BlockDestroy`, `BlockInteract`, `BlockRegionUpdate`, `BlockRegionDestroy`, `BlockRegionInteract`, `EntitySpawnAttempt`, `EntityInteract`.
- `M.is_packet_allowed(packet_name, is_gm) -> true | false, reason`:
  - имя не из `GUARDED_PACKETS` -> `true`;
  - `is_gm == true` -> `true`;
  - иначе `false, "Только Мастер может менять мир"`.
- Функции модуля, кроме этих, не менять. В `core` вызовов движка нет.

### net/block_guard.lua (новый)

- `M.init(api) -> ok, missing`:
  1. Если нет `api`, `api.interceptors.receive.add_interceptor` или `api.interceptors.packets.ClientMsg`: `log("block_guard_unprotected", {part = "<что отсутствует>"})`, вернуть `false`. Падения нет.
  2. Для каждого имени из `gm_rules.GUARDED_PACKETS` взять `packet_id = api.interceptors.packets.ClientMsg[name]`. Если `nil`: добавить имя в `missing`, `log("block_guard_packet_missing", {name = name})`, продолжить с остальными.
  3. Для найденных зарегистрировать `api.interceptors.receive.add_interceptor(packet_id, function(client, original, edited) ... end)`.
  4. В конце, если `missing` не пуст: `log("block_guard_unprotected", {missing = missing})`, вернуть `false, missing`. Иначе `log("block_guard_active", {count = N})`, вернуть `true`.
- Обработчик перехватчика (`make_guard(name)`):
  - `sender_id, role = identity.sender_of(client)`;
  - `is_gm = sender_id ~= nil and identity.is_master(role)`;
  - `allowed, reason = gm_rules.is_packet_allowed(name, is_gm)`;
  - если `allowed`, вернуть `true`;
  - иначе записать отказ (см. ниже) и вернуть `false`.
  - Если `sender_id == nil` (клиент не определён), это отказ (`is_gm = false`).
  - Ошибка внутри обработчика не должна пропускать пакет: обернуть в `pcall`, при ошибке `log("block_guard_error", {...})` и вернуть `false`.
- Журнал отказов: `log("auth_denied", {name = <пакет>, sender_id = <identity или "unknown">, reason = reason, count = N})`. Чтобы не засорять лог повторяющимися `BlockDestroy`, писать первый отказ для пары `(identity, пакет)` и затем каждый 20-й, поле `count` показывает общее число.
- Требует только `core/log`, `core/gm_rules`, `net/identity`. `require("server/*")` в этом файле запрещён.
- Ссылки `-- docs:` на `interceptors.md` у каждого вызова API. Уточнение, что адресация числовая, записать в `UNVERIFIED.md` как «подтверждено кодом Neutron» со ссылкой на аудит.

### scripts/world.lua

- В серверной ветке после `block_interceptor.init(...)` добавить вызов `require("net/block_guard").init(api)`. Больше ничего в файле не менять.

### tools/api_allowlist.lua

- Добавить `api.interceptors.packets.ClientMsg` со ссылкой на `docs/neutron/api/libraries/interceptors.md` (раздел «Типы пакетов»).

## Правила и ограничения

- Новых API Neutron и движка, кроме `api.interceptors.packets.ClientMsg`, не использовать.
- Мастер определяется только по `identity.is_master(role)`. Имя роли в `block_guard.lua` не писать.
- Не блокировать: `EntityDespawn` (выгрузка сущности на клиенте игрока), `InventoryInteract`/`InventoryClose`/`PlayerHandSlot`, `PlayerPosition`/`PlayerRotation`/`PlayerCheats`, `ChatMessage`, `PackEvent`, `PackEnv`. Список `GUARDED_PACKETS` минимален и расширяется отдельной задачей.
- Ответ клиенту и откат отображения блока на его экране в этой задаче не делаются (см. «Вне задачи»).
- Серверные правки блоков из `server/world.lua` (`block.set`) через receive-перехватчик не проходят, поэтому не затрагиваются.
- Разделение `block_interceptor.lua` и автоинициализацию реестра команд не трогать.

## Критерий готовности

`tests/gm_rules_test.lua`:
- каждый пакет из `GUARDED_PACKETS` для не-Мастера -> `false` и текст причины; для Мастера -> `true`;
- имя вне списка (`ChatMessage`, `PlayerPosition`, `EntityDespawn`, `InventoryInteract`) -> `true` для всех.

`tests/block_guard_test.lua` (мок `api` с таблицей `interceptors.packets.ClientMsg` из имён и числовых ID, `receive.add_interceptor` запоминает пары `(id, функция)`):
- `init(api)` регистрирует перехватчик ровно для 8 пакетов из списка и не регистрирует остальные;
- ID берутся из мока по имени (в тесте дай им произвольные значения, например 100+, чтобы не совпадали с реальными);
- мок-клиент с ролью `master`: все 8 перехватчиков возвращают `true`;
- клиент с ролью `member`, с пустой ролью, с `role = nil`, без `account.identity`, `client = nil`: все возвращают `false`;
- отказ пишет `auth_denied` с именем пакета; для 30 подряд отказов одного клиента и пакета в лог попадает первый и 20-й, `count` растёт;
- в таблице пакетов нет `BlockDestroy`: `init` возвращает `false, {"BlockDestroy"}`, остальные 7 зарегистрированы, в логе `block_guard_packet_missing` и `block_guard_unprotected`;
- `init(nil)`, `init({})`, `init({interceptors = {}})`: не падают, возвращают `false`, пишут `block_guard_unprotected`;
- ошибка внутри обработчика (мок `identity.sender_of`, который кидает ошибку): перехватчик возвращает `false`, пишет `block_guard_error`;
- статическая проверка: в `net/block_guard.lua` нет `require("server/` и нет строки `client.account`.

`run_tests` и `luajit tools/verify_allowlist.lua` проходят.

Как проверить человеку (шаги в отчёте, прислать лог сервера и описание или скриншоты клиента):
1. Игрок с ролью `member` в режиме первого лица ставит блок и ломает блок. На сервере блок не меняется (проверить из клиента Мастера), в логе `[auth_denied] name=BlockUpdate` и `name=BlockDestroy`.
2. На экране этого игрока смотреть: остался ли поставленный блок или вернулся сломанный (клиент не получает отката, это гипотеза из `UNVERIFIED.md`). Затем переподключить игрока и проверить, исчезла ли рассинхронизация.
3. Попытка взаимодействия с блоком (ПКМ по блоку) от `member`: `[auth_denied] name=BlockInteract`.
4. Мастер ставит и ломает блоки: проходит, `block_guard_active` в логе при старте сервера.
5. Регрессия у `member`: ходьба, чат, смена камеры, выбор и перемещение собственного токена работают.
6. Прислать: строку `[block_guard_active]` или `[block_guard_unprotected]` при старте, строки `[auth_denied]`, описание того, что видит игрок на экране после отказа.

## Вне задачи

- Откат отображения блока на клиенте и ответ игроку (нужен серверный пакет-коррекция и изучение формата `BlockChanged`). Решается отдельной задачей после проверки пункта 2 выше.
- Защита `EntityDespawn`, инвентаря, `PlayerCheats`, `PackEvent`.
- Разделение `block_interceptor.lua`, единая инициализация реестра команд.
- Права ролей `allow-*`: на сервере они ничего не блокируют (см. аудит), полагаться на них нельзя.
