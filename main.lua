--[[
    Formula Apex — Spectator / Crash Monitor Injector Script
    Совместимо с Xeno v1.3.6 (а также новее: v1.6+)

    Назначение:
    Автоматическое наблюдение за пилотами в игре Formula Apex (Roblox).
    Скрипт отслеживает состояние болидов всех пилотов, фиксирует аварии
    (краши), кто и когда разбил машину, и выводит информацию в удобный
    HUD-интерфейс прямо в игре. Полезно для лиг и стримов.

    Как использовать с Xeno v1.3.6:
    1. Запустите Roblox и зайдите в Formula Apex.
    2. Откройте Xeno v1.3.6, нажмите Inject/Attach к процессу Roblox.
    3. Вставьте содержимое этого файла в редактор скриптов Xeno.
    4. Нажмите Execute.
    Примечание: в v1.3.6 функция gethui() может отсутствовать — скрипт
    автоматически использует фолбэк на CoreGui, затем PlayerGui.
]]

------------------------------------------------------------
-- Совместимость с Xeno v1.3.6: gethui() -> CoreGui -> PlayerGui
------------------------------------------------------------
local function getParentForGui()
    -- gethui() есть не во всех сборках Xeno — проверяем аккуратно
    local gethuiFn = (type(gethui) == "function") and gethui
        or (type(getgenv) == "function" and type(getgenv().gethui) == "function" and getgenv().gethui)
    if gethuiFn then
        local ok, hui = pcall(gethuiFn)
        if ok and hui then return hui end
    end
    local ok, coreGui = pcall(function() return game:GetService("CoreGui") end)
    if ok and coreGui then return coreGui end
    return game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
end

------------------------------------------------------------
-- Фолбэки task.* для старых исполнителей (Xeno v1.3.6)
------------------------------------------------------------
local wait  = (type(task) == "table" and task.wait)  or wait
local spawn = (type(task) == "table" and task.spawn) or spawn

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

------------------------------------------------------------
-- Настройки
------------------------------------------------------------
local CONFIG = {
    REFRESH_INTERVAL = 0.5,        -- как часто обновлять список пилотов
    CRASH_SPEED_THRESHOLD = 5,     -- порог скорости (stud/s), ниже которого считаем что машина стоит после удара
    CRASH_DAMAGE_THRESHOLD = 70,   -- если здоровье машины ниже этого % — считаем её разбитой
    STALLED_AFTER_SECONDS = 12,    -- машина стоит слишком долго без здоровья -> DNF
    SHOW_LOCAL_PLAYER = true,      -- показывать и себя тоже
    DEBUG_LOG = false,             -- печатать в консоль найденные машины/ошибки поиска
    MAX_LOG_ENTRIES = 50,          -- сколько записей об авариях хранить
    WEBHOOK_ENABLED = false,       -- включить отправку логов на Discord Webhook (нужен включённый HTTP в Xeno)
    WEBHOOK_URL = "",              -- вставьте URL вашего Discord webhook сюда
}

------------------------------------------------------------
-- Хранилище данных о пилотах
------------------------------------------------------------
local PilotData = {}      -- [userId] = { Name, Speed, Health, LastSpeed, Crashed, CrashTime, Position }
local CrashLog = {}       -- массив событий аварий
local StartedAt = os.time()

------------------------------------------------------------
-- Утилиты
------------------------------------------------------------
------------------------------------------------------------
-- Глобальный поиск машин (нужен, чтобы видеть пилотов даже
-- когда они не загрузились в стриминг-буфер вокруг вас)
------------------------------------------------------------
local DESCENDANTS_CACHE = nil
local DESCENDANTS_CACHE_TIME = 0
local DESCENDANTS_CACHE_TTL = 5 -- секунд; GetDescendants() дорогая операция

local function getAllModels()
    local now = os.clock()
    if DESCENDANTS_CACHE and (now - DESCENDANTS_CACHE_TIME) < DESCENDANTS_CACHE_TTL then
        return DESCENDANTS_CACHE
    end
    local ok, list = pcall(function() return workspace:GetDescendants() end)
    if not ok then
        warn("[Spectator] Не удалось получить список объектов workspace:", list)
        return {}
    end
    local models = {}
    for _, obj in ipairs(list) do
        if obj:IsA("Model") then
            table.insert(models, obj)
        end
    end
    DESCENDANTS_CACHE = models
    DESCENDANTS_CACHE_TIME = now
    return models
end

local function modelBelongsTo(model, plr)
    -- 1. Атрибуты владельца (частый способ в гоночных играх Roblox)
    local attrs = { "OwnerUserId", "PlayerUserId", "UserId", "Owner", "Player", "Driver" }
    for _, key in ipairs(attrs) do
        local v = model:GetAttribute(key)
        if v ~= nil then
            if type(v) == "number" and v == plr.UserId then return true end
            if type(v) == "string" and (v == plr.Name or tonumber(v) == plr.UserId) then return true end
            if typeof(v) == "Instance" and v:IsA("Player") and v.UserId == plr.UserId then return true end
        end
    end
    -- 2. Имя модели == имя игрока
    if model.Name == plr.Name then return true end
    -- 3. Внутри модели есть часть/значение с именем игрока (например Seat "PlayerName_Sit")
    local ok, parts = pcall(function() return model:GetChildren() end)
    if ok then
        for _, ch in ipairs(parts) do
            if ch.Name == plr.Name or ch.Name:find(plr.Name, 1, true) then
                return true
            end
        end
    end
    return false
end

local carCache = {} -- [userId] = {model = ..., time = ...}

local function getCarForPlayer(plr)
    local cached = carCache[plr.UserId]
    if cached and cached.model and cached.model.Parent and (os.clock() - cached.time < 3) then
        return cached.model
    end

    local foundModel = nil

    -- Быстрые проверки сначала: персонаж / стандартные контейнеры
    local char = plr.Character
    if char then
        local carModel = char:FindFirstChild("Car") or char:FindFirstChild("Vehicle")
        if carModel then foundModel = carModel end
        if not foundModel and modelBelongsTo(char, plr) then foundModel = char end
    end

    if not foundModel then
        for _, containerName in ipairs({ "Cars", "Vehicles", "Racing", "Race", "Grid" }) do
            local container = workspace:FindFirstChild(containerName)
            if container then
                for _, obj in ipairs(container:GetChildren()) do
                    if obj:IsA("Model") and modelBelongsTo(obj, plr) then
                        foundModel = obj
                        break
                    end
                end
            end
            if foundModel then break end
        end
    end

    if not foundModel then
        local direct = workspace:FindFirstChild(plr.Name)
        if direct and direct:IsA("Model") then foundModel = direct end
    end

    -- Медленная проверка: глобальный обход всех моделей (стриминг-далёкие машины)
    if not foundModel then
        for _, model in ipairs(getAllModels()) do
            if modelBelongsTo(model, plr) then
                foundModel = model
                break
            end
        end
    end

    if CONFIG.DEBUG_LOG then
        print(("[Spectator] %s -> машина: %s"):format(plr.Name, foundModel and foundModel:GetFullName() or "НЕ НАЙДЕНА"))
    end

    if foundModel then
        carCache[plr.UserId] = { model = foundModel, time = os.clock() }
    else
        carCache[plr.UserId] = nil
    end
    return foundModel
end

local function getCarHealth(carModel)
    if not carModel then return 100 end
    -- Здоровье может быть в атрибуте, в Value, или в Humanoid (если есть)
    local attrNames = { "Health", "HP", "Integrity", "Damage", "BodyHealth" }
    for _, key in ipairs(attrNames) do
        local h = carModel:GetAttribute(key)
        if type(h) == "number" then
            if key == "Damage" then
                return math.clamp(100 - h, 0, 100)
            end
            -- нормализуем в проценты, если максимум больше 100
            if h > 100 then return math.clamp(h / 10, 0, 100) end
            return math.clamp(h, 0, 100)
        end
    end

    local ok, descendants = pcall(function() return carModel:GetDescendants() end)
    if ok then
        for _, ch in ipairs(descendants) do
            if (ch:IsA("NumberValue") or ch:IsA("IntValue")) and (ch.Name == "Health" or ch.Name == "CarHealth" or ch.Name == "HP") then
                local v = ch.Value
                if v > 100 then return math.clamp(v / 10, 0, 100) end
                return math.clamp(v, 0, 100)
            end
        end
    end

    local hum = carModel:FindFirstChildOfClass("Humanoid")
    if hum then
        return (hum.Health / hum.MaxHealth) * 100
    end

    return 100
end

local function getCarVelocity(carModel)
    if not carModel then return 0 end
    local part = carModel.PrimaryPart
        or carModel:FindFirstChild("HumanoidRootPart")
        or carModel:FindFirstChild("Body")
        or carModel:FindFirstChildWhichIsA("BasePart")
    if not part then
        -- ищем любую BasePart среди потомков (машина может быть глубоко вложенной)
        local ok, descendants = pcall(function() return carModel:GetDescendants() end)
        if ok then
            for _, ch in ipairs(descendants) do
                if ch:IsA("BasePart") then part = ch break end
            end
        end
    end
    if part and part:IsA("BasePart") then
        local v = part.AssemblyLinearVelocity
        if typeof(v) == "Vector3" then
            return v.Magnitude
        end
        return part.Velocity.Magnitude
    end
    return 0
end

local function formatTime(ts)
    local dt = os.date("*t", ts)
    return string.format("%02d:%02d:%02d", dt.hour, dt.min, dt.sec)
end

local function addCrashEvent(userId, name)
    local now = os.time()
    table.insert(CrashLog, 1, {
        Time = now,
        Uid = userId,
        Name = name,
    })
    -- обрезаем лог до лимита
    while #CrashLog > CONFIG.MAX_LOG_ENTRIES do
        table.remove(CrashLog)
    end

    -- Отправка на вебхук при необходимости
    if CONFIG.WEBHOOK_ENABLED and CONFIG.WEBHOOK_URL ~= "" then
        spawn(function()
            local ok, err = pcall(function()
                local payload = HttpService:JSONEncode({
                    username = "Formula Apex Crash Bot",
                    content = ("**%s** crashed at %s"):format(name, formatTime(now)),
                })
                HttpService:PostRequest(CONFIG.WEBHOOK_URL, {
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = payload,
                })
            end)
            if not ok then
                warn("[Spectator] Webhook error:", err)
            end
        end)
    end
end

------------------------------------------------------------
-- Основной цикл наблюдения
------------------------------------------------------------
local function updatePilotData()
    local seen = {}

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer or CONFIG.SHOW_LOCAL_PLAYER then
            local uid = plr.UserId
            seen[uid] = true

            local car = getCarForPlayer(plr)
            local speed = getCarVelocity(car)
            local health = getCarHealth(car)

            local data = PilotData[uid]
            if not data then
                data = {
                    Name = plr.Name,
                    Speed = speed,
                    Health = health,
                    LastSpeed = speed,
                    Crashed = false,
                    DNF = false,
                    CrashTime = nil,
                    StalledSince = nil,
                    CarFound = car ~= nil,
                    Car = car,
                }
                PilotData[uid] = data
            else
                data.Name = plr.Name
                data.LastSpeed = data.Speed
                data.Speed = speed
                data.Health = health
                data.CarFound = car ~= nil
                data.Car = car

                -- Заводим "таймер простоя": машина стоит (или не найдена/исчезла)
                local isStopped = (not car) or (speed < CONFIG.CRASH_SPEED_THRESHOLD)
                if isStopped then
                    if not data.StalledSince then data.StalledSince = os.time() end
                else
                    data.StalledSince = nil
                end

                -- Детектор краша: был быстрый, резко встал + здоровье просело
                local wasFast = data.LastSpeed > CONFIG.CRASH_SPEED_THRESHOLD * 3
                local lowHealth = data.Health < CONFIG.CRASH_DAMAGE_THRESHOLD

                if not data.Crashed and wasFast and isStopped and lowHealth then
                    data.Crashed = true
                    data.CrashTime = os.time()
                    addCrashEvent(uid, data.Name)
                end

                -- DNF: долго стоит без возможности уехать (машина разбита/исчезла)
                if not data.DNF and data.StalledSince
                   and (os.time() - data.StalledSince) >= CONFIG.STALLED_AFTER_SECONDS
                   and (lowHealth or not car) then
                    data.DNF = true
                    table.insert(CrashLog, 1, { Time = os.time(), Uid = uid, Name = data.Name, Type = "DNF" })
                    while #CrashLog > CONFIG.MAX_LOG_ENTRIES do table.remove(CrashLog) end
                end

                -- Если пилот починился / снова поехал — снимаем статусы
                if (data.Crashed or data.DNF) and data.Speed > CONFIG.CRASH_SPEED_THRESHOLD * 2 and data.Health >= CONFIG.CRASH_DAMAGE_THRESHOLD then
                    data.Crashed = false
                    data.DNF = false
                    data.StalledSince = nil
                end
            end
        end
    end

    -- Удаляем данные покинувших сервер игроков
    for uid in pairs(PilotData) do
        if not seen[uid] then
            PilotData[uid] = nil
            carCache[uid] = nil
        end
    end
end

------------------------------------------------------------
-- GUI (HUD) — интерфейс наблюдения
------------------------------------------------------------
local gui, mainFrame, pilotsLabel, crashLogLabel

local function createGui()
    gui = Instance.new("ScreenGui")
    gui.Name = "ApexSpectatorHUD"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = getParentForGui() -- gethui()/CoreGui для Xeno v1.3.6

    mainFrame = Instance.new("Frame")
    mainFrame.Name = "MainFrame"
    mainFrame.Size = UDim2.new(0, 380, 0, 420)
    mainFrame.Position = UDim2.new(0, 20, 0.5, -210)
    mainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    mainFrame.BackgroundTransparency = 0.15
    mainFrame.BorderSizePixel = 0
    mainFrame.Parent = gui

    Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 10)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(220, 40, 40)
    stroke.Thickness = 2
    stroke.Transparency = 0.4
    stroke.Parent = mainFrame

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, 0, 0, 40)
    title.Position = UDim2.new(0, 0, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 20
    title.TextColor3 = Color3.fromRGB(255, 70, 70)
    title.Text = "FORMULA APEX | SPECTATOR"
    title.Parent = mainFrame

    pilotsLabel = Instance.new("TextLabel")
    pilotsLabel.Name = "PilotsList"
    pilotsLabel.Size = UDim2.new(1, -20, 0, 220)
    pilotsLabel.Position = UDim2.new(0, 10, 0, 50)
    pilotsLabel.BackgroundTransparency = 1
    pilotsLabel.Font = Enum.Font.Code
    pilotsLabel.TextSize = 14
    pilotsLabel.TextXAlignment = Enum.TextXAlignment.Left
    pilotsLabel.TextYAlignment = Enum.TextYAlignment.Top
    pilotsLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
    pilotsLabel.TextWrapped = true
    pilotsLabel.Text = "Ожидание данных..."
    pilotsLabel.Parent = mainFrame

    crashLogLabel = Instance.new("TextLabel")
    crashLogLabel.Name = "CrashLog"
    crashLogLabel.Size = UDim2.new(1, -20, 0, 130)
    crashLogLabel.Position = UDim2.new(0, 10, 0, 280)
    crashLogLabel.BackgroundTransparency = 1
    crashLogLabel.Font = Enum.Font.Code
    crashLogLabel.TextSize = 13
    crashLogLabel.TextXAlignment = Enum.TextXAlignment.Left
    crashLogLabel.TextYAlignment = Enum.TextYAlignment.Top
    crashLogLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
    crashLogLabel.TextWrapped = true
    crashLogLabel.Text = "-- Лог аварий пуст --"
    crashLogLabel.Parent = mainFrame

    -- Кнопка скрытия/показа HUD
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Name = "ToggleBtn"
    toggleBtn.Size = UDim2.new(0, 120, 0, 30)
    toggleBtn.Position = UDim2.new(0, 10, 1, -40)
    toggleBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 14
    toggleBtn.TextColor3 = Color3.new(1, 1, 1)
    toggleBtn.Text = "Скрыть HUD"
    toggleBtn.Parent = mainFrame
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 6)

    toggleBtn.MouseButton1Click:Connect(function()
        mainFrame.Visible = not mainFrame.Visible
        if mainFrame.Visible then
            toggleBtn.Text = "Скрыть HUD"
        else
            toggleBtn.Text = "Показать HUD"
        end
    end)
end

local function updateHud()
    if not gui then return end

    -- Список пилотов (RichText для цветных статусов)
    local lines = {}
    local count = 0
    for _ in pairs(PilotData) do count = count + 1 end
    table.insert(lines, string.format("Пилотов на треке: %d\n", count))

    if count == 0 then
        table.insert(lines, "<font color='#888888'>Нет данных о пилотах...</font>")
    else
        for _, d in pairs(PilotData) do
            local statusIcon, colorTag
            if d.DNF then
                statusIcon, colorTag = "[DNF]", "#ff2222"
            elseif d.Crashed then
                statusIcon, colorTag = "[АВАРИЯ]", "#ff4444"
            elseif not d.CarFound then
                statusIcon, colorTag = "[НЕТ МАШИНЫ]", "#888888"
            else
                statusIcon, colorTag = "[ON TRACK]", "#44ff88"
            end
            table.insert(lines, string.format(
                "<font color='%s'>%s</font> %s | Speed: %.0f | HP: %.0f%%\n",
                colorTag, statusIcon, d.Name, d.Speed, d.Health
            ))
        end
    end
    pilotsLabel.Text = table.concat(lines, "")

    -- Лог аварий / DNF
    if #CrashLog == 0 then
        crashLogLabel.Text = "-- Лог аварий пуст --"
    else
        local logLines = {}
        for i, ev in ipairs(CrashLog) do
            if i > 8 then break end
            table.insert(logLines, string.format(
                "[%s] %s — %s\n",
                formatTime(ev.Time), ev.Name, ev.Type or "crash"
            ))
        end
        crashLogLabel.Text = "Лог событий:\n" .. table.concat(logLines, "")
    end
end

------------------------------------------------------------
-- Запуск
------------------------------------------------------------
local function main()
    print("[Formula Apex Spectator] Загрузка... (Xeno v1.3.6 compatible)")
    createGui()

    spawn(function()
        while wait(CONFIG.REFRESH_INTERVAL) do
            local ok, err = pcall(updatePilotData)
            if not ok then warn("[Spectator] Update error:", err) end

            local ok2, err2 = pcall(updateHud)
            if not ok2 then warn("[Spectator] HUD error:", err2) end
        end
    end)

    print("[Formula Apex Spectator] Активен. Наблюдение за пилотами начато.")
end

main()

return {
    State = {
        Pilots = PilotData,
        CrashLog = CrashLog,
        StartedAt = StartedAt,
    },
    Config = CONFIG,
}
