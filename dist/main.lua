--[[
    Formula Apex — Spectator / Crash Monitor Injector Script
    Совместимо с Xeno v1.3.6 (а также новее: v1.6+)

    ВАЖНО про DNF: Formula Apex хранит настоящие машины на СЕРВЕРЕ
    (клиент их не видит из соображений анти-чита), поэтому скорость
    берётся из игрока (Character/HumanoidRootPart), а "машина" используется
    только как дополнительный источник здоровья. Если машина не найдена —
    это НЕ считается признаком DNF; статус ставится по здоровью или после
    долгой остановки.

    Настройки под вашим сервером: если DNF не появляется или появляется
    зря — подкрутите STALLED_AFTER_SECONDS и CRASH_DAMAGE_THRESHOLD ниже.
]]

------------------------------------------------------------
-- Совместимость с Xeno v1.3.6: перебор всех UI-родителей
-- (gethui -> CoreGui -> PlayerGui -> Topbar). Если ScreenGui
-- не создался ни в одном — пробуем NextInstance ("clone"-метод),
-- который обходит большинство анти-detector'ов.
------------------------------------------------------------
local function guiParents()
    local list = {}
    local function tryPush(name, fn)
        local ok, obj = pcall(fn)
        if ok and obj and typeof(obj) == "Instance" then
            list[#list + 1] = { name = name, obj = obj }
        end
    end
    tryPush("gethui", function()
        local f = (type(gethui) == "function" and gethui)
            or (type(getgenv) == "function" and type(getgenv().gethui) == "function" and getgenv().gethui)
        assert(f, "no gethui")
        return f()
    end)
    tryPush("CoreGui", function() return game:GetService("CoreGui") end)
    tryPush("PlayerGui", function() return game.Players.LocalPlayer:FindFirstChildOfClass("PlayerGui") end)
    tryPush("StarterPlayerScripts-gui", function()
        local g = Instance.new("ScreenGui") -- просто чтобы не вернуть nil
        g.Name = "__probe__"; g.Parent = game:GetService("Players").LocalPlayer
        local pg = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui", 3)
        g:Destroy()
        return pg
    end)
    return list
end

local createdGui = nil
local createdVia = nil

local function buildScreenGui(parent)
    local g
    local okNext, ni = pcall(function() return Instance.NextInstance end)
    if okNext and ni then
        -- "clone"-метод: берём существующий ScreenGui и меняем свойства
        local proto = parent and parent:FindFirstChildOfClass("ScreenGui")
        if proto then
            local okC, c = pcall(function() return proto:NextInstance() end)
            if okC and c then g = c else g = Instance.new("ScreenGui") end
        else
            g = Instance.new("ScreenGui")
        end
    else
        g = Instance.new("ScreenGui")
    end
    g.Name = "ApexSpectatorHUD"
    g.ResetOnSpawn = false
    g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    g.IgnoreGuiInset = true
    g.DisplayOrder = 999999
    g.Parent = parent
    -- проверка: действительно ли GUI виден
    local okCheck, shown = pcall(function() return g.Parent ~= nil end)
    if not (okCheck and shown) then error("gui not attached") end
    return g
end

local function createGuiSafe()
    for _, entry in ipairs(guiParents()) do
        local ok, g = pcall(buildScreenGui, entry.obj)
        if ok and g then
            createdGui, createdVia = g, entry.name
            return g
        end
    end
    error("Все UI-родители недоступны (gethui/CoreGui/PlayerGui)")
end

------------------------------------------------------------
-- Фолбэки task.* для старых исполнителей (Xeno v1.3.6)
------------------------------------------------------------
local wait  = (type(task) == "table" and task.wait)  or wait
local spawn = (type(task) == "table" and task.spawn) or spawn

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

------------------------------------------------------------
-- Настройки
------------------------------------------------------------
local CONFIG = {
    REFRESH_INTERVAL = 0.5,        -- как часто обновлять данные пилотов
    CRASH_SPEED_THRESHOLD = 5,     -- stud/s; ниже этой скорости считаем что пилот стоит
    CRASH_DAMAGE_THRESHOLD = 70,   -- если здоровье машины ниже этого % — считаем её разбитой
    STALLED_AFTER_SECONDS = 25,    -- сколько секунд пилот стоит на месте -> [DNF]
    SHOW_LOCAL_PLAYER = true,      -- показывать и себя тоже
    DEBUG_LOG = false,             -- печатать в консоль найденные машины (для отладки)
    MAX_LOG_ENTRIES = 50,          -- сколько записей об авариях хранить
    WEBHOOK_ENABLED = false,       -- включить отправку логов на Discord Webhook
    WEBHOOK_URL = "",              -- вставьте URL вашего Discord webhook сюда
}

------------------------------------------------------------
-- Хранилище данных о пилотах
------------------------------------------------------------
local PilotData = {}      -- [userId] = таблица состояния
local CrashLog = {}       -- массив событий аварий/DNF
local CarCache = {}       -- [userId] = {model, time}
local DescendantsCache = nil
local DescendantsCacheTime = 0
local DescendantsCacheTTL = 5

------------------------------------------------------------
-- Поиск машин (стриминг-осознанный)
------------------------------------------------------------
local function getAllModels()
    local now = os.clock()
    if DescendantsCache and (now - DescendantsCacheTime) < DescendantsCacheTTL then
        return DescendantsCache
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
    DescendantsCache = models
    DescendantsCacheTime = now
    return models
end

local function modelBelongsTo(model, plr)
    local attrs = { "OwnerUserId", "PlayerUserId", "UserId", "Owner", "Player", "Driver" }
    for _, key in ipairs(attrs) do
        local ok, v = pcall(function() return model:GetAttribute(key) end)
        if ok and v ~= nil then
            if type(v) == "number" and v == plr.UserId then return true end
            if type(v) == "string" and (v == plr.Name or tonumber(v) == plr.UserId) then return true end
            if typeof(v) == "Instance" and v:IsA("Player") and v.UserId == plr.UserId then return true end
        end
    end
    if model.Name == plr.Name then return true end
    local ok, parts = pcall(function() return model:GetChildren() end)
    if ok then
        for _, ch in ipairs(parts) do
            if ch.Name == plr.Name or (ch.Name:find(plr.Name, 1, true)) then
                return true
            end
        end
    end
    return false
end

local function getCarForPlayer(plr)
    local cached = CarCache[plr.UserId]
    if cached and cached.model and cached.model.Parent and (os.clock() - cached.time < 3) then
        return cached.model
    end

    local foundModel = nil

    local char = plr.Character
    if char then
        foundModel = char:FindFirstChild("Car") or char:FindFirstChild("Vehicle")
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
        if direct and direct:IsA("Model") and direct ~= plr.Character then foundModel = direct end
    end

    if not foundModel then
        for _, model in ipairs(getAllModels()) do
            if model ~= plr.Character and modelBelongsTo(model, plr) then
                foundModel = model
                break
            end
        end
    end

    if CONFIG.DEBUG_LOG then
        print(("[Spectator] %s -> машина: %s"):format(plr.Name, foundModel and foundModel:GetFullName() or "НЕ НАЙДЕНА"))
    end

    if foundModel then
        CarCache[plr.UserId] = { model = foundModel, time = os.clock() }
    else
        CarCache[plr.UserId] = nil
    end
    return foundModel
end

------------------------------------------------------------
-- Чтение показателей
------------------------------------------------------------
local function getModelVelocity(carModel)
    if not carModel then return 0 end
    local part = carModel.PrimaryPart
        or carModel:FindFirstChild("HumanoidRootPart")
        or carModel:FindFirstChild("Body")
        or carModel:FindFirstChildWhichIsA("BasePart")
    if not part then
        local ok, descendants = pcall(function() return carModel:GetDescendants() end)
        if ok then
            for _, ch in ipairs(descendants) do
                if ch:IsA("BasePart") then part = ch break end
            end
        end
    end
    if part and part:IsA("BasePart") then
        local v = part.AssemblyLinearVelocity
        if typeof(v) == "Vector3" then return v.Magnitude end
    end
    return 0
end

-- Скорость: сначала по машине (если найдена и движется), иначе по персонажу
local function getPilotSpeed(plr, car)
    if car and car.Parent then
        local s = getModelVelocity(car)
        if s > 0.1 then return s end
    end
    local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
    if hrp then
        local v = hrp.AssemblyLinearVelocity
        if typeof(v) == "Vector3" then return v.Magnitude end
    end
    return 0
end

local function getCarHealth(carModel)
    if not carModel then return nil end -- нет машины -> неизвестно (не считать разбитой!)
    local attrNames = { "Health", "HP", "Integrity", "Damage", "BodyHealth" }
    for _, key in ipairs(attrNames) do
        local ok, h = pcall(function() return carModel:GetAttribute(key) end)
        if ok and type(h) == "number" then
            if key == "Damage" then
                return math.clamp(100 - h, 0, 100)
            end
            if h > 100 then return math.clamp(h / 10, 0, 100) end
            return math.clamp(h, 0, 100)
        end
    end
    local ok, descendants = pcall(function() return carModel:GetDescendants() end)
    if ok then
        for _, ch in ipairs(descendants) do
            if (ch:IsA("NumberValue") or ch:IsA("IntValue"))
               and (ch.Name == "Health" or ch.Name == "CarHealth" or ch.Name == "HP") then
                local v = ch.Value
                if v > 100 then return math.clamp(v / 10, 0, 100) end
                return math.clamp(v, 0, 100)
            end
        end
    end
    local hum = carModel:FindFirstChildOfClass("Humanoid")
    if hum and hum.MaxHealth > 0 then
        return (hum.Health / hum.MaxHealth) * 100
    end
    return nil
end

local function formatTime(ts)
    local dt = os.date("*t", ts)
    return string.format("%02d:%02d:%02d", dt.hour, dt.min, dt.sec)
end

local function pushEvent(evt)
    table.insert(CrashLog, 1, evt)
    while #CrashLog > CONFIG.MAX_LOG_ENTRIES do
        table.remove(CrashLog)
    end
    if CONFIG.WEBHOOK_ENABLED and CONFIG.WEBHOOK_URL ~= "" then
        spawn(function()
            local ok, err = pcall(function()
                local payload = HttpService:JSONEncode({
                    username = "Formula Apex Crash Bot",
                    content = ("**%s** %s at %s"):format(evt.Name, evt.Type or "crashed", formatTime(evt.Time)),
                })
                HttpService:PostRequest(CONFIG.WEBHOOK_URL, {
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = payload,
                })
            end)
            if not ok then warn("[Spectator] Webhook error:", err) end
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
            local speed = getPilotSpeed(plr, car)
            local health = getCarHealth(car) -- может быть nil (машина не найдена)

            local data = PilotData[uid]
            if not data then
                data = {
                    Name = plr.Name,
                    Speed = speed,
                    LastSpeed = speed,
                    Health = health,
                    Crashed = false,
                    DNF = false,
                    StalledSince = nil,
                    CarFound = car ~= nil,
                }
                PilotData[uid] = data
            else
                data.Name = plr.Name
                data.LastSpeed = data.Speed
                data.Speed = speed
                data.Health = health
                data.CarFound = car ~= nil

                local isStopped = speed < CONFIG.CRASH_SPEED_THRESHOLD
                if isStopped then
                    if not data.StalledSince then data.StalledSince = os.time() end
                else
                    data.StalledSince = nil
                end

                local lowHealth = health ~= nil and health < CONFIG.CRASH_DAMAGE_THRESHOLD

                -- Краш: был быстрый -> резко встал + здоровье просело
                local wasFast = data.LastSpeed > CONFIG.CRASH_SPEED_THRESHOLD * 3
                if not data.Crashed and wasFast and isStopped and lowHealth then
                    data.Crashed = true
                    pushEvent({ Time = os.time(), Uid = uid, Name = data.Name, Type = "CRASH" })
                end

                -- DNF: (разбитая машина ИЛИ очень долгая остановка)
                if not data.DNF then
                    local stalledTooLong = data.StalledSince
                        and (os.time() - data.StalledSince) >= CONFIG.STALLED_AFTER_SECONDS
                    if lowHealth or stalledTooLong then
                        data.DNF = true
                        pushEvent({ Time = os.time(), Uid = uid, Name = data.Name, Type = "DNF" })
                    end
                end

                -- Починился / снова поехал — снимаем статусы
                if (data.Crashed or data.DNF)
                   and speed > CONFIG.CRASH_SPEED_THRESHOLD * 2
                   and (health == nil or health >= CONFIG.CRASH_DAMAGE_THRESHOLD) then
                    data.Crashed = false
                    data.DNF = false
                    data.StalledSince = nil
                end
            end
        end
    end

    for uid in pairs(PilotData) do
        if not seen[uid] then
            PilotData[uid] = nil
            CarCache[uid] = nil
        end
    end
end

------------------------------------------------------------
-- GUI (HUD)
------------------------------------------------------------
local gui, mainFrame, pilotsLabel, crashLogLabel, hideBtn, collapsed = nil, nil, nil, nil, nil, false
local pinBtn, clearBtn, pinned = nil, nil, false
local titleLbl = nil

-- Срез списка подключений у объекта (совместимость со старыми движками)
local function getConnsOf(obj, signalName)
    local ok, conns = pcall(function()
        local sig = obj[signalName]
        if sig and sig.GetConnections then
            return sig:GetConnections()
        end
    end)
    return (ok and type(conns) == "table") and conns or nil
end

-- В закреплённом режиме окно перестаёт реагировать на ввод:
-- обрываем все подключения кликов по фрейму и его потомкам, снимаем Active/Draggable.
-- Через несколько кадров дополнительно включаем TranslucentHitbox (если поддерживается),
-- чтобы клики проходили сквозь HUD к игре.
local function setInputPassThrough(enabled)
    if not mainFrame then return end
    if enabled then
        pcall(function()
            mainFrame.Active = false
            mainFrame.Draggable = false
        end)
        pcall(function()
            local targets = { mainFrame }
            for _, d in ipairs(mainFrame:GetDescendants()) do
                table.insert(targets, d)
            end
            for _, obj in ipairs(targets) do
                for _, sigName in ipairs({ "InputBegan", "InputChanged", "InputEnded",
                    "MouseButton1Click", "MouseButton1Down", "MouseButton1Up",
                    "MouseEnter", "MouseLeave" }) do
                    local conns = getConnsOf(obj, sigName)
                    if conns then
                        for _, c in ipairs(conns) do
                            pcall(function() c:Disconnect() end)
                        end
                    end
                end
            end
        end)
        -- Фолбэк-метод для старых движков: глобальный сигнал UserInputService
        pcall(function()
            local UIS = game:GetService("UserInputService")
            local conns = getConnsOf(UIS, "InputBegan")
            if conns then
                for _, c in ipairs(conns) do
                    pcall(function() c:Disconnect() end)
                end
            end
        end)
        spawn(function()
            wait(0.35)
            pcall(function() mainFrame.TranslucentHitbox = true end)
            pcall(function() gui.TranslucentHitbox = true end)
        end)
    else
        pcall(function()
            mainFrame.Active = true
            mainFrame.Draggable = true
        end)
        pcall(function() mainFrame.TranslucentHitbox = false end)
        pcall(function() gui.TranslucentHitbox = false end)
    end
end

-- Безопасная установка RichText: если исполнитель не поддерживает HTML-теги,
-- включаем обычный текст (иначе <font color="..."> показывается как код).
local function setRich(label, htmlText, plainText)
    if not label then return end
    local okSet = pcall(function() label.RichText = true end)
    if okSet and label.RichText == true then
        local okT = pcall(function() label.Text = htmlText end)
        if okT then return end
    end
    pcall(function() label.RichText = false end)
    local stripped = htmlText:gsub("</?[^>]+>", "")
    pcall(function() label.Text = plainText or stripped end)
end

-- Принудительно включаем RichText на label при создании
local function enableRich(label)
    pcall(function() label.RichText = true end)
end

-- Всё содержимое окна HUD (создаётся/пересобирается целиком)
local buildGuiContents
buildGuiContents = function()
    mainFrame = Instance.new("Frame")
    mainFrame.Name = "MainFrame"
    mainFrame.Size = UDim2.new(0, 380, 0, 420)
    mainFrame.Position = UDim2.new(0, 20, 0.5, -210)
    mainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    mainFrame.BackgroundTransparency = 0.15
    mainFrame.BorderSizePixel = 0
    mainFrame.Active = true
    mainFrame.Draggable = true
    mainFrame.Parent = gui

    Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 10)

    local stroke = Instance.new("UIStroke")
    stroke.Name = "Border"
    stroke.Color = Color3.fromRGB(220, 40, 40)
    stroke.Thickness = 2
    stroke.Transparency = 0.4
    stroke.Parent = mainFrame

    titleLbl = Instance.new("TextLabel")
    titleLbl.Name = "Title"
    titleLbl.Size = UDim2.new(1, -50, 0, 40)
    titleLbl.Position = UDim2.new(0, 0, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 20
    titleLbl.TextColor3 = Color3.fromRGB(255, 70, 70)
    titleLbl.Text = "FORMULA APEX | SPECTATOR"
    titleLbl.Parent = mainFrame

    -- Кнопка скрытия/показа HUD
    hideBtn = Instance.new("TextButton")
    hideBtn.Name = "HideToggle"
    hideBtn.Size = UDim2.new(0, 34, 0, 34)
    hideBtn.Position = UDim2.new(1, -40, 0, 3)
    hideBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    hideBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    hideBtn.Font = Enum.Font.GothamBold
    hideBtn.TextSize = 18
    hideBtn.Text = "–"
    hideBtn.AutoButtonColor = true
    hideBtn.Parent = mainFrame
    Instance.new("UICorner", hideBtn).CornerRadius = UDim.new(0, 8)

    -- Кнопка закрепления (pin): в закреплённом режиме окно не двигается,
    -- фон становится чёрным и непрозрачным, клики проходят сквозь HUD.
    pinBtn = Instance.new("TextButton")
    pinBtn.Name = "PinToggle"
    pinBtn.Size = UDim2.new(0, 34, 0, 34)
    pinBtn.Position = UDim2.new(1, -78, 0, 3)
    pinBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    pinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    pinBtn.Font = Enum.Font.GothamBold
    pinBtn.TextSize = 16
    pinBtn.Text = pinned and "U" or "P"
    pinBtn.AutoButtonColor = true
    pinBtn.Parent = mainFrame
    Instance.new("UICorner", pinBtn).CornerRadius = UDim.new(0, 8)

    local function applyPinMode()
        if pinned then
            mainFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            mainFrame.BackgroundTransparency = 0
            local strokeInst = mainFrame:FindFirstChild("Border")
            if strokeInst then pcall(function() strokeInst.Color = Color3.fromRGB(90, 90, 90) end) end
            if titleLbl then pcall(function() titleLbl.TextTransparency = 0 end) end
            setInputPassThrough(true)
            pinBtn.Text = "U"
            print("[Spectator] HUD закреплён: окно неподвижно, фон чёрный, клики сквозь HUD.")
        else
            mainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
            mainFrame.BackgroundTransparency = 0.15
            local strokeInst = mainFrame:FindFirstChild("Border")
            if strokeInst then pcall(function() strokeInst.Color = Color3.fromRGB(220, 40, 40) end) end
            if titleLbl then pcall(function() titleLbl.TextTransparency = 0 end) end
            setInputPassThrough(false)
            pinBtn.Text = "P"
            print("[Spectator] HUD откреплён: окно снова перемещаемое.")
        end
    end

    pinBtn.MouseButton1Click:Connect(function()
        pinned = not pinned
        local ok, err = pcall(applyPinMode)
        if not ok then warn("[Spectator] Pin mode error:", err) end
    end)

    hideBtn.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        if collapsed then
            mainFrame.Size = UDim2.new(0, 380, 0, 40)
            pilotsLabel.Visible = false
            crashLogLabel.Visible = false
            local lt = mainFrame:FindFirstChild("LogTitle")
            if lt then lt.Visible = false end
            local cb = mainFrame:FindFirstChild("ClearLog")
            if cb then cb.Visible = false end
            hideBtn.Text = "+"
        else
            mainFrame.Size = UDim2.new(0, 380, 0, 420)
            pilotsLabel.Visible = true
            crashLogLabel.Visible = true
            local lt = mainFrame:FindFirstChild("LogTitle")
            if lt then lt.Visible = true end
            local cb = mainFrame:FindFirstChild("ClearLog")
            if cb then cb.Visible = true end
            hideBtn.Text = "-"
        end
    end)

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
    enableRich(pilotsLabel)
    pilotsLabel.Parent = mainFrame

    local logTitle = Instance.new("TextLabel")
    logTitle.Name = "LogTitle"
    logTitle.Size = UDim2.new(1, -20, 0, 24)
    logTitle.Position = UDim2.new(0, 10, 0, 280)
    logTitle.BackgroundTransparency = 1
    logTitle.Font = Enum.Font.GothamBold
    logTitle.TextSize = 15
    logTitle.TextColor3 = Color3.fromRGB(255, 180, 60)
    logTitle.TextXAlignment = Enum.TextXAlignment.Left
    logTitle.Text = "Crash / DNF Log:"
    logTitle.Parent = mainFrame

    -- Кнопка очистки логов аварий
    clearBtn = Instance.new("TextButton")
    clearBtn.Name = "ClearLog"
    clearBtn.Size = UDim2.new(0, 74, 0, 22)
    clearBtn.Position = UDim2.new(1, -86, 0, 281)
    clearBtn.BackgroundColor3 = Color3.fromRGB(60, 40, 40)
    clearBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
    clearBtn.Font = Enum.Font.GothamBold
    clearBtn.TextSize = 12
    clearBtn.Text = "CLEAR"
    clearBtn.AutoButtonColor = true
    clearBtn.Parent = mainFrame
    Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

    clearBtn.MouseButton1Click:Connect(function()
        for i = #CrashLog, 1, -1 do CrashLog[i] = nil end
        pcall(function() crashLogLabel.Text = "Логи очищены" end)
        print("[Spectator] Crash/DNF логи очищены.")
    end)

    crashLogLabel = Instance.new("TextLabel")
    crashLogLabel.Name = "CrashLog"
    crashLogLabel.Size = UDim2.new(1, -20, 0, 110)
    crashLogLabel.Position = UDim2.new(0, 10, 0, 305)
    crashLogLabel.BackgroundTransparency = 1
    crashLogLabel.Font = Enum.Font.Code
    crashLogLabel.TextSize = 13
    crashLogLabel.TextXAlignment = Enum.TextXAlignment.Left
    crashLogLabel.TextYAlignment = Enum.TextYAlignment.Top
    crashLogLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
    crashLogLabel.TextWrapped = true
    crashLogLabel.Text = ""
    crashLogLabel.Parent = mainFrame
end

local function refreshGui()
    if not pilotsLabel then return end

    local htmlLines = { ("Pilots online: %d"):format(#Players:GetPlayers()), "" }
    local plainLines = { ("Pilots online: %d"):format(#Players:GetPlayers()), "" }

    local entries = {}
    for uid, d in pairs(PilotData) do
        table.insert(entries, { uid = uid, name = d.Name, speed = d.Speed, dnf = d.DNF, crashed = d.Crashed, found = d.CarFound })
    end
    table.sort(entries, function(a, b) return a.speed > b.speed end)

    for i, e in ipairs(entries) do
        local statusIcon, colorTag
        if e.dnf then
            statusIcon, colorTag = "[DNF]", "#ff2222"
        elseif e.crashed then
            statusIcon, colorTag = "[CRASH]", "#ff6600"
        elseif e.speed < CONFIG.CRASH_SPEED_THRESHOLD then
            statusIcon, colorTag = "[STOP]", "#ffcc00"
        else
            statusIcon, colorTag = "[OK]", "#44dd66"
        end
        local carText = e.found and "" or " (car hidden)"
        table.insert(htmlLines, ('<font color="%s">%s</font> %s%s — %d m/s'):format(
            colorTag, statusIcon, e.name, carText, math.floor(e.speed * 0.44704 + 0.5)))
        table.insert(plainLines, ("%s %s%s — %d m/s"):format(
            statusIcon, e.name, carText, math.floor(e.speed * 0.44704 + 0.5)))
        if i >= 20 then
            table.insert(htmlLines, "...")
            table.insert(plainLines, "...")
            break
        end
    end

    setRich(pilotsLabel, table.concat(htmlLines, "\n"), table.concat(plainLines, "\n"))

    local logLines = {}
    for i = 1, math.min(6, #CrashLog) do
        local ev = CrashLog[i]
        table.insert(logLines, ("%s | %s [%s]"):format(formatTime(ev.Time), ev.Name, ev.Type or "CRASH"))
    end
    crashLogLabel.Text = (#logLines > 0) and table.concat(logLines, "\n") or "Нет событий"
end

------------------------------------------------------------
-- Запуск
------------------------------------------------------------
------------------------------------------------------------
-- Страж HUD: если через 5 секунд GUI не виден — пересоздаём во всех доступных родителях
------------------------------------------------------------
spawn(function()
    wait(5)
    local ok, visible = pcall(function()
        return gui and gui.Parent ~= nil
    end)
    if ok and visible then
        print("[Spectator] HUD активен (родитель: " .. tostring(createdVia) .. ")")
        return
    end
    warn("[Spectator] HUD не виден — пробую все UI-родители заново...")
    for _, entry in ipairs(guiParents()) do
        local ok2, g = pcall(buildScreenGui, entry.obj)
        if ok2 and g then
            gui = g
            pcall(buildGuiContents) -- пересобрать содержимое окна
            print("[Spectator] HUD пересоздан через: " .. entry.name)
            break
        end
    end
end)

local function createGui()
    gui = createGuiSafe()
    buildGuiContents()
end

local okGui, errGui = pcall(createGui)
if not okGui then
    warn("[Spectator] Не удалось создать HUD:", errGui)
else
    print(("[Spectator] HUD создан через: %s"):format(tostring(createdVia)))
end

spawn(function()
    while wait(CONFIG.REFRESH_INTERVAL) do
        local ok, err = pcall(updatePilotData)
        if not ok then warn("[Spectator] update error:", err) end
        local ok2, err2 = pcall(refreshGui)
        if not ok2 then warn("[Spectator] gui error:", err2) end
    end
end)

print("[Spectator] Formula Apex observer loaded. HUD draggable. Config: STALLED_AFTER_SECONDS="
    .. CONFIG.STALLED_AFTER_SECONDS .. ", CRASH_DAMAGE_THRESHOLD=" .. CONFIG.CRASH_DAMAGE_THRESHOLD)
