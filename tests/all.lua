-- tests/all.lua: список тестовых файлов. Агент добавляет сюда новые.
-- Запуск из корня репозитория: luajit tests/all.lua

package.path = "./?.lua;./tests/?.lua;./tools/?.lua;./vtt/modules/?.lua;" .. package.path

local files = {
    "tests/grid_test.lua",
    "tests/schema_test.lua",
    "tests/gm_rules_test.lua",
    "tests/commands_test.lua",
    "tests/log_test.lua",
    "tests/mock_test.lua",
    "tests/camera_test.lua",
    "tests/block_sync_test.lua",
    "tests/picking_test.lua",
    "tests/overlay_test.lua",
    "tests/hud_test.lua",
    "tests/tokens_test.lua",
    "tests/identity_test.lua",
    "tests/console_commands_test.lua",
    "tests/block_guard_test.lua",
    "tests/world_test.lua",
}

for _, f in ipairs(files) do dofile(f) end

local failed = require("lib").run()
os.exit(failed == 0 and 0 or 1)
