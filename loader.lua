------------------------------------------------------------
-- Formula Apex Spectator — лоадер v3 для Xeno (1.3.6 / 1.6+)
--
-- Вставьте в Xeno ОДНУ строку и нажмите Execute:
--
loadstring(game:HttpGet("https://raw.githubusercontent.com/kapralchiknn1/formulaapexspectator/main/loader.lua"))()
--
-- Что делает этот лоадер:
--   1. Проверяет, что вы находитесь в игре Formula Apex (не в лобби Roblox).
--   2. Скачивает актуальный main.lua с GitHub (с повторными попытками).
--      К ссылке добавляется cache-buster (?v=...), чтобы всегда получать
--      свежую версию сразу после push, минуя кэш raw-CDN GitHub.
--   3. Показывает статус загрузки через onnotify (Xeno) / чат / warn.
--   4. Защищает от пустого/ битого ответа raw-ссылки.
------------------------------------------------------------

local REPO_RAW = "https://raw.githubusercontent.com/kapralchiknn1/formulaapexspectator/main/"
local LOADER_BUILD = "2026-10-10-6" -- обновляется вместе с main.lua
local SCRIPT_URL = REPO_RAW .. "main.lua?cb=" .. LOADER_BUILD .. "-" .. tostring(math.random(100000, 999999))
local VERSION = "loader-v6"

------------------------------------------------------------
-- Уведомления (Xeno-совместимые)
------------------------------------------------------------
local function notify(text, duration)
    duration = duration or 5
    -- onnotify — встроенный хук Xeno (есть в 1.3.x и 1.6.x)
    local okNotify = pcall(function()
        if typeof(onnotify) == "function" then
            onnotify("Formula Apex Spectator", text, duration, 1)
        elseif typeof(onnotify) == "Instance" and onnotify:IsA("BindableFunction") then
            task.spawn(onnotify.Invoke, onnotify, "Formula Apex Spectator", text, duration, 1)
        else
            error("no onnotify")
        end
    end)
    if not okNotify then
        -- фолбэк в чат
        pcall(function()
            local Chat = game:GetService("Chat")
            local speaker = game.Players.LocalPlayer
            if speaker and speaker.Character then
                Chat:Chat(speaker.Character:FindFirstChildWhichIsA("Head"),
                    "[FAS] " .. text, 1)
            end
        end)
        warn("[FormulaApexSpectator] " .. text)
    end
end

------------------------------------------------------------
-- Проверка, что запущена именно Formula Apex
------------------------------------------------------------
local function isFormulaApex()
    local placeId = game.PlaceId
    -- Официальные placeId Formula Apex (FA Racing / Formula Apex)
    local known = { 7811790856, 8407672520 }
    for _, id in ipairs(known) do
        if placeId == id then return true end
    end
    -- эвристически: ищем признаки игры в Workspace
    local ws = game:GetService("Workspace")
    if ws:FindFirstChild("RaceTrack") or ws:FindFirstChild("Tracks")
        or ws:FindFirstChild("PitLane") or ws:FindFirstChild("StartLine") then
        return true
    end
    return false
end

if not isFormulaApex() then
    notify("Вы не в Formula Apex! Зайдите на сервер игры и выполните скрипт снова.", 8)
    warn("[FormulaApexSpectator][" .. VERSION .. "] PlaceId = " .. tostring(game.PlaceId)
        .. " — игра не распознана как Formula Apex.")
end

------------------------------------------------------------
-- Загрузка main.lua с повторами
------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local source

for attempt = 1, 3 do
    local ok, result = pcall(function()
        return game:HttpGet(SCRIPT_URL, true)
    end)
    if ok and type(result) == "string" and #result > 100 then
        source = result
        break
    end
    notify("Попытка " .. attempt .. "/3: загрузка скрипта не удалась, повторяю...", 3)
    task.wait(2)
end

if not source then
    notify("Не удалось скачать main.lua с GitHub. Проверьте интернет или попробуйте позже.", 8)
    return
end

-- грубая проверка, что скачался именно скрипт, а не страница 404
if source:find("404: Not Found", 1, true) or source:find("<!DOCTYPE", 1, true) then
    notify("GitHub вернул ошибку 404 — файл main.lua не найден в репозитории.", 8)
    return
end

local chunk, compileErr = loadstring(source)
if not chunk then
    notify("Ошибка компиляции скрипта: " .. tostring(compileErr), 8)
    return
end

notify("Скрипт загружен (" .. math.floor(#source / 1024) .. " KB, " .. VERSION .. "), запуск...", 3)

local runOk, runErr = pcall(chunk)
if not runOk then
    notify("Ошибка при запуске скрипта: " .. tostring(runErr), 8)
else
    notify("Formula Apex Spectator активен. HUD должен появиться на экране.", 4)
    notify("Далее: нажмите START MONITORING в окне — до этого DNF не начисляются. Кнопки шапки слева направо: – скрыть, P/U закреп чёрным, p лёгкая прозрачность, A сильная прозрачность, ? справка.", 8)
end
