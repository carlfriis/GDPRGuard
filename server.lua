-- GDPRGuard™ med versionstjek og forbedret struktur
-- QBCore-optimeret version

GDPRGuard = {}

-- === VERSIONSTJEK === --
local CURRENT_VERSION = "2.0.0"
CreateThread(function()
    PerformHttpRequest("https://raw.githubusercontent.com/dit-brugernavn/GDPRGuard/main/version.json", function(code, data)
        if code == 200 then
            local ok, versionData = pcall(json.decode, data)
            if ok and versionData.version and versionData.version ~= CURRENT_VERSION then
                print("[GDPRGuard™] ⚠️ NY VERSION TILGÆNGELIG: " .. versionData.version .. " – " .. versionData.changelog)
            else
                print("[GDPRGuard™] ✅ GDPRGuard™ er opdateret (v" .. CURRENT_VERSION .. ")")
            end
        end
    end, "GET", "", {})
end)

-- === CONFIGURATION === --
Config = {}
Config.Framework = "qbcore"
Config.PrivacyLink = "https://discord.gg/dine-rettigheder"
Config.WebhookURL = "https://discord.com/api/webhooks/dit_webhook"
Config.LogRetentionDays = 30

Config.DataTables = {
    { table = "players", id_column = "license", remove = true },
    { table = "player_vehicles", id_column = "citizenid", remove = true },
    { table = "player_outfits", id_column = "citizenid", remove = true },
    { table = "bans", id_column = "license", keep = true }
}

Config.Confirmations = {
    ["Jeg har mappet alle tabeller med persondata"] = true,
    ["Jeg har gjort brugere opmærksom på deres rettigheder"] = true
}

function GDPRGuard:Log(msg)
    print("[GDPRGuard™] " .. msg)
end

function GDPRGuard:SendDiscordWebhook(msg)
    if Config.WebhookURL and Config.WebhookURL ~= "" then
        PerformHttpRequest(Config.WebhookURL, function() end, 'POST', json.encode({
            username = "GDPRGuard",
            content = msg
        }), { ['Content-Type'] = 'application/json' })
    end
end

function GDPRGuard:GetLicenseID(identifiers)
    for _, id in ipairs(identifiers) do
        if string.sub(id, 1, 8) == "license:" then return id end
    end
    return nil
end

-- DATABASE TABELLER
CreateThread(function()
    Wait(2000)
    GDPRGuard:Log("Tjekker og opretter GDPR-tabeller...")
    exports.oxmysql:execute([[CREATE TABLE IF NOT EXISTS gdpr_acceptance (
        license VARCHAR(50) PRIMARY KEY,
        accepted_at DATETIME NOT NULL
    )]])
    exports.oxmysql:execute([[CREATE TABLE IF NOT EXISTS gdpr_deleted (
        license VARCHAR(50) PRIMARY KEY,
        deleted_at DATETIME NOT NULL
    )]])
    exports.oxmysql:execute([[CREATE TABLE IF NOT EXISTS gdpr_logs (
        id INT AUTO_INCREMENT PRIMARY KEY,
        license VARCHAR(50),
        action VARCHAR(50),
        timestamp DATETIME NOT NULL,
        ip VARCHAR(50),
        data LONGTEXT
    )]])
    GDPRGuard:Log("✅ GDPR-tabeller klar.")
end)

-- AUDIT
function GDPRGuard:AuditScan()
    self:Log("Starter GDPR audit...")
    for _, info in pairs(Config.DataTables) do
        if info.remove then
            self:Log("⚠️ Sletning: " .. info.table)
        elseif info.anonymize_column then
            self:Log("⚠️ Anonymisering: " .. info.table .. "." .. info.anonymize_column)
        elseif info.keep then
            self:Log("ℹ️ Bevares: " .. info.table)
        end
    end
    for k, v in pairs(Config.Confirmations) do
        if not v then self:Log("⚠️ Ejeren har ikke bekræftet: " .. k) end
    end
end

RegisterCommand("gdpr_audit", function(src)
    if src == 0 then GDPRGuard:AuditScan() end
end)

-- GDPR-KOMMANDOER
RegisterCommand("gdpr_request", function(src)
    local ids, ip = GetPlayerIdentifiers(src), GetPlayerEndpoint(src)
    local license = GDPRGuard:GetLicenseID(ids)
    GDPRGuard:SendDiscordWebhook("🔍 GDPR-anmodning fra " .. GetPlayerName(src) .. "\nIP: " .. ip .. "\nID'er: " .. table.concat(ids, ", "))
    exports.oxmysql:execute('INSERT INTO gdpr_logs (license, action, timestamp, ip, data) VALUES (?, ?, NOW(), ?, ?)', {
        license, 'request', ip, json.encode({ identifiers = ids })
    })
    TriggerClientEvent('chat:addMessage', src, { args = {"GDPRGuard™", "📦 Du kan se dine data i logs. Brug /gdpr_delete for at slette dem."} })
end)

RegisterCommand("gdpr_delete", function(src)
    local ids = GetPlayerIdentifiers(src)
    local license = GDPRGuard:GetLicenseID(ids)
    local ip = GetPlayerEndpoint(src)
    if not license then return DropPlayer(src, "License ID mangler") end

    GDPRGuard:SendDiscordWebhook("🗑️ GDPR-sletning for " .. license .. " udføres")
    exports.oxmysql:execute('DELETE FROM players WHERE license = ?', { license })
    exports.oxmysql:execute('DELETE FROM player_vehicles WHERE citizenid IN (SELECT citizenid FROM players WHERE license = ?)', { license })
    exports.oxmysql:execute('DELETE FROM player_outfits WHERE citizenid IN (SELECT citizenid FROM players WHERE license = ?)', { license })
    exports.oxmysql:execute('REPLACE INTO gdpr_deleted (license, deleted_at) VALUES (?, NOW())', { license })
    exports.oxmysql:execute('INSERT INTO gdpr_logs (license, action, timestamp, ip, data) VALUES (?, ?, NOW(), ?, ?)', {
        license, 'delete', ip, json.encode({ identifiers = ids })
    })
    DropPlayer(src, "🗑️ Dine data er slettet i henhold til GDPR. Du skal kontakte serverens administrator for at få adgang igen!")
end)

-- GDPR JOIN SAMTYKKE OG BLOKERING
AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
    deferrals.defer()
    Wait(100)
    deferrals.update("🔐 GDPR Samtykke påkrævet...")
    Wait(500)

    local src, ids = source, GetPlayerIdentifiers(source)
    local license = GDPRGuard:GetLicenseID(ids)
    if not license then deferrals.done() CancelEvent() return end

    exports.oxmysql:execute('SELECT license FROM gdpr_deleted WHERE license = ?', { license }, function(result)
        if result and result[1] then
            deferrals.update("Du skal kontakte serverens administrator for at få adgang igen!")
            Wait(2000)
            deferrals.done()
            CancelEvent()
        else
            exports.oxmysql:execute('INSERT IGNORE INTO gdpr_acceptance (license, accepted_at) VALUES (?, NOW())', { license })
            deferrals.done()
            TriggerClientEvent('chat:addMessage', src, {
                args = {"GDPRGuard™", "Ved at spille accepterer du vores datapolitik: " .. Config.PrivacyLink .. " | Brug /gdpr_request /gdpr_delete"}
            })
        end
    end)
end)

-- ANONYMISERING AF GAMLE LOGS
CreateThread(function()
    while true do
        Wait(3600000)
        exports.oxmysql:execute('UPDATE user_logs SET log_text = "[ANONYMISERET]" WHERE timestamp < DATE_SUB(NOW(), INTERVAL ? DAY)', {
            Config.LogRetentionDays
        })
    end
end)

GDPRGuard:Log("GDPRGuard™: QBCore indlæst – GDPRGuard™ med versionstjek aktiv.")
