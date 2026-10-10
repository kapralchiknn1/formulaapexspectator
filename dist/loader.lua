------------------------------------------------------------
-- Formula Apex Spectator — лоадер для Xeno (v1.3.6 / v1.6+)
-- Вставьте эту одну строку в Xeno и нажмите Execute:
--
loadstring(game:HttpGet("https://raw.githubusercontent.com/kapralchiknn1/formulaapexspectator/main/main.lua"))()
--
-- Скрипт загружается с GitHub, поэтому всегда актуальная версия.
------------------------------------------------------------

local URL = "https://raw.githubusercontent.com/kapralchiknn1/formulaapexspectator/main/main.lua"

local ok, source = pcall(function()
    return game:HttpGet(URL)
end)

if not ok or type(source) ~= "string" or #source == 0 then
    warn("[FormulaApexSpectator] Не удалось загрузить скрипт с GitHub. Попробуйте позже или проверьте интернет.")
    return
end

local chunk, err = loadstring(source)
if not chunk then
    warn("[FormulaApexSpectator] Ошибка компиляции скрипта: " .. tostring(err))
    return
end

chunk()
