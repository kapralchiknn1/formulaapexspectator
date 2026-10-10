--[[
    Formula Apex — DIAGNOSTIC (Xeno v1.3.6)
    Запустите этот скрипт ПЕРЕД основным, чтобы узнать, как игра хранит
    машины/пилотов и есть ли у вас доступ к нужным данным.
    Вывод идёт в консоль Xeno (F9 / вкладка Console).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("================ APEX DIAG ================")
print("Игра:", game.Name, "| PlaceId:", game.PlaceId)
print("Локальный игрок:", Players.LocalPlayer.Name)

-- 1. Сколько игроков на сервере
print("--- Игроки ---")
for _, p in ipairs(Players:GetPlayers()) do
    print(string.format("%s (UserId=%d), Character: %s", p.Name, p.UserId, tostring(p.Character)))
end

-- 2. Что лежит в Workspace (имена верхнеуровневых объектов)
print("--- Workspace children ---")
for _, obj in ipairs(workspace:GetChildren()) do
    print(obj.ClassName .. " | " .. obj.Name)
end

-- 3. Ищем модели машин и их атрибуты (Formula Apex обычно вешает атрибуты на машины)
print("--- Поиск моделей с атрибутами (первые 40) ---")
local found = 0
local ok, list = pcall(function() return workspace:GetDescendants() end)
if ok and list then
    for _, obj in ipairs(list) do
        if found >= 40 then break end
        if obj:IsA("Model") then
            local attrs = obj:GetAttributes()
            local hasAttr = false
            for k, v in pairs(attrs) do
                hasAttr = true
                print(string.format("Model '%s' attr [%s]=%s", obj.Name, k, tostring(v)))
            end
            if not hasAttr and obj.PrimaryPart then
                -- печатаем только модели с PrimaryPart — вероятно это машины
                if found < 15 then
                    print(string.format("Model '%s' (PrimaryPart=%s, Path=%s)", obj.Name, obj.PrimaryPart.Name, obj:GetFullName()))
                end
                found = found + 1
            end
        end
    end
end

-- 4. РепlicatedStorage — структура верхнего уровня (там могут быть данные гонки/DNF)
print("--- ReplicatedStorage top-level ---")
for _, obj in ipairs(ReplicatedStorage:GetChildren()) do
    print(obj.ClassName .. " | " .. obj.Name)
end

-- 5. Проверяем, читаются ли атрибуты вообще (ограничение игры может блокировать)
print("--- Проверка чтения атрибутов ---")
local testAttrs = 0
for _, obj in ipairs(workspace:GetChildren()) do
    local a = obj:GetAttributes()
    for _ in pairs(a) do testAttrs = testAttrs + 1 end
end
print("Атрибутов найдено в корне Workspace:", testAttrs)

print("============= DIAG END ==============")
print("Скопируйте вывод консоли и пришлите — по нему подгоню основной скрипт.")
