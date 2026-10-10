--[[
    Formula Apex — Spectator / Crash Monitor Injector Script
    Совместимо с Xeno v1.6 (XenoInjector)

    Назначение:
    Автоматическое наблюдение за пилотами в игре Formula Apex (Roblox).
    Скрипт отслеживает состояние болидов всех пилотов, фиксирует аварии
    (краши), кто и когда разбил машину, и выводит информацию в удобный
    HUD-интерфейс прямо в игре. Полезно для лиг и стримов.

    Как использовать с Xeno v1.6:
    1. Запустите Roblox и зайдите в Formula Apex.
    2. Откройте Xeno v1.6, нажмите Attach к процессу Roblox.
    3. Вставьте содержимое этого файла в редактор скриптов Xeno.
    4. Нажмите Execute (Play).
]]

------------------------------------------------------------
-- Безопасное получение сервисов (workaround для некоторых инжекторов)
------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

------------------------------------------------------------
-- Настройки
------------------------------------------------------------
local CONFIG = {
    REFRESH_INTERVAL = 0.5,        -- как часто обновлять список пилотов
    CRASH_SPEED_THRESHOLD = 5,     -- порог скорости (stud/s), ниже которого считаем что машина стоит после удара
    CRASH_DAMAGE_THRESHOLD = 70,   -- если здоровье машины ниже этого % — считаем её разбитой
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
local function getCarForPlayer(plr)
    -- Formula Apex обычно хранит болиды игрока в Workspace/Cars или под Character
    local char = plr.Character
    if not char then return nil end

    -- Вариант 1: модель машины внутри персонажа
    local carModel = char:FindFirstChild("Car") or char:FindFirstChild("Vehicle")
    if carModel then return carModel end

    -- Вариант 2: ищем PrimaryPart / HumanoidRootPart у модели машины в Workspace
    local workspaceCars = workspace:FindFirstChild("Cars") or workspace:FindFirstChild("Vehicles")
    if workspaceCars then
        for _, obj in ipairs(workspaceCars:GetChildren()) do
            if obj:GetAttribute("OwnerUserId") == plr.UserId
               or obj.Name == plr.Name
               or obj:GetAttribute("Player") == plr.Name then
                return obj
            end
        end
    end

    -- Вариант 3: имя модели машины совпадает с именем игрока где-то в workspace
    local found = workspace:FindFirstChild(plr.Name)
    if found and found:IsA("Model") then return found end

    return nil
end

local function getCarHealth(carModel)
    if not carModel then return 100 end
    -- Здоровье может быть в атрибуте, в Value, или в Humanoid (если есть)
    local h = carModel:GetAttribute("Health")
         or carModel:GetAttribute("Damage")
    if type(h) == "number" then
        return math.clamp(100 - (h or 0), 0, 100)
    end

    local healthValue = carModel:FindFirstChild("Health") or carModel:FindFirstChild("CarHealth")
    if healthValue and healthValue:IsA("NumberValue") then
        return math.clamp(healthValue.Value, 0, 100)
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
    if part and part:IsA("BasePart") then
        return part.AssemblyLinearVelocity.Magnitude
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
        task.spawn(function()
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
        if plr ~= LocalPlayer then
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
                    CrashTime = nil,
                    Car = car,
                }
                PilotData[uid] = data
            else
                data.Name = plr.Name
                data.LastSpeed = data.Speed
                data.Speed = speed
                data.Health = health
                data.Car = car

                -- Детектор краша: был быстрый, резко встал + здоровье просело
                local wasFast = data.LastSpeed > CONFIG.CRASH_SPEED_THRESHOLD * 3
                local isSlowNow = data.Speed < CONFIG.CRASH_SPEED_THRESHOLD
                local lowHealth = data.Health < CONFIG.CRASH_DAMAGE_THRESHOLD

                if not data.Crashed and wasFast and isSlowNow and lowHealth then
                    data.Crashed = true
                    data.CrashTime = os.time()
                    addCrashEvent(uid, data.Name)
                end

                -- Если пилот починился / снова поехал — снимаем статус краша
                if data.Crashed and (data.Speed > CONFIG.CRASH_SPEED_THRESHOLD * 2 or data.Health >= CONFIG.CRASH_DAMAGE_THRESHOLD) then
                    data.Crashed = false
                end
            end
        end
    end

    -- Удаляем данные покинувших сервер игроков
    for uid in pairs(PilotData) do
        if not seen[uid] then
            PilotData[uid] = nil
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
    gui.Parent = game:GetService("CoreGui") -- Xeno позволяет это делать

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
            local statusIcon = d.Crashed and "[АВАРИЯ]" or "[ON TRACK]"
            local colorTag = d.Crashed and "<font color='#ff4444'>" or "<font color='#44ff88'>"
            table.insert(lines, string.format(
                "%s%s</font> %s | Speed: %.0f | HP: %.0f%%\n",
                colorTag, statusIcon, d.Name, d.Speed, d.Health
            ))
        end
    end
    pilotsLabel.Text = table.concat(lines, "")

    -- Лог аварий
    if #CrashLog == 0 then
        crashLogLabel.Text = "-- Лог аварий пуст --"
    else
        local logLines = {}
        for i, ev in ipairs(CrashLog) do
            if i > 8 then break end
            table.insert(logLines, string.format(
                "[%s] %s — crash\n",
                formatTime(ev.Time), ev.Name
            ))
        end
        crashLogLabel.Text = "Лог аварий:\n" .. table.concat(logLines, "")
    end
end

------------------------------------------------------------
-- Запуск
------------------------------------------------------------
local function main()
    print("[Formula Apex Spectator] Загрузка... (Xeno v1.6 compatible)")
    createGui()

    task.spawn(function()
        while task.wait(CONFIG.REFRESH_INTERVAL) do
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
