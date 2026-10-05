--[[
Diario de Pato para KOReader.

Al arrancar KOReader o al despertar la Kindle: si todavía no está la edición
de hoy (hora Argentina), prende el Wi-Fi, la baja de GitHub Pages, apaga el
Wi-Fi si lo prendió y la abre en la tapa. Si ya está, no hace nada y deja
todo como estaba. Guarda las últimas 7 ediciones y borra las más viejas.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local ReadHistory = require("readhistory")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local BASE = "https://patodorf1.github.io/dp-lectura-eec6/ediciones/"
local GUARDAR = 7           -- ediciones que quedan en la Kindle
local DESDE = 6 * 60 + 30   -- antes de las 6:30 (hora Argentina) no busca
local REINTENTO = 15 * 60   -- después de un intento, no vuelve a buscar por 15 minutos

local carpeta = Device:isKindle() and "/mnt/us/documents/Diario de Pato"
    or DataStorage:getFullDataDir() .. "/Diario de Pato"

-- El módulo se carga una sola vez, así que esto se comparte entre la
-- biblioteca y el lector.
local arranco = false
local ultimo_intento = 0

-- Fecha y minutos del día en Argentina (UTC-3 todo el año), sin depender de
-- la zona horaria que tenga configurada la Kindle.
local function ahoraArgentina()
    local t = os.time() - 3 * 3600
    local minutos = tonumber(os.date("!%H", t)) * 60 + tonumber(os.date("!%M", t))
    return os.date("!%Y-%m-%d", t), minutos
end

local function rutaDe(fecha)
    return carpeta .. "/" .. fecha .. ".epub"
end

local function existe(ruta)
    return lfs.attributes(ruta, "mode") == "file"
end

local function bajar(fecha)
    local destino = rutaDe(fecha)
    local parcial = destino .. ".part"
    local archivo = io.open(parcial, "wb")
    if not archivo then
        return false, "no se pudo escribir en " .. carpeta
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url = BASE .. fecha .. ".epub",
        headers = { ["Accept-Encoding"] = "identity" },
        sink = ltn12.sink.file(archivo),
    })
    socketutil:reset_timeout()
    if code == 200 and (lfs.attributes(parcial, "size") or 0) > 0 then
        os.rename(parcial, destino)
        return true
    end
    os.remove(parcial)
    return false, code
end

local function documentoAbierto()
    local ReaderUI = require("apps/reader/readerui")
    local lector = ReaderUI.instance
    return lector and lector.document and lector.document.file
end

-- Deja las GUARDAR ediciones más nuevas y borra el resto, con sus notas de
-- lectura y su lugar en el historial. Nunca borra el libro abierto.
local function limpiar()
    local abierto = documentoAbierto()
    local fechas = {}
    for nombre in lfs.dir(carpeta) do
        local fecha = nombre:match("^(%d%d%d%d%-%d%d%-%d%d)%.epub$")
        if fecha then
            table.insert(fechas, fecha)
        end
    end
    table.sort(fechas, function(a, b) return a > b end)
    for i = GUARDAR + 1, #fechas do
        local ruta = rutaDe(fechas[i])
        if ruta ~= abierto and os.remove(ruta) then
            pcall(DocSettings.updateLocation, ruta)
            pcall(ReadHistory.fileDeleted, ReadHistory, ruta)
        end
    end
end

local function apagarWifi()
    if NetworkMgr.disableWifi then
        NetworkMgr:disableWifi()
    else
        NetworkMgr:turnOffWifi()
    end
end

local function revisar()
    local fecha, minutos = ahoraArgentina()
    if minutos < DESDE or existe(rutaDe(fecha)) then
        return
    end
    if os.time() - ultimo_intento < REINTENTO then
        return
    end
    ultimo_intento = os.time()
    if lfs.attributes(carpeta, "mode") ~= "directory" then
        lfs.mkdir(carpeta)
    end

    local prendio_wifi = not NetworkMgr:isWifiOn()
    local function seguir()
        local aviso = InfoMessage:new{ text = "Bajando el diario de hoy…" }
        UIManager:show(aviso)
        UIManager:forceRePaint()
        local ok, motivo = bajar(fecha)
        UIManager:close(aviso)
        if prendio_wifi then
            apagarWifi()
        end
        if ok then
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(rutaDe(fecha))
            UIManager:scheduleIn(5, function() pcall(limpiar) end)
        else
            -- 404 = todavía no salió: se vuelve a probar en 15 minutos.
            logger.info("Diario de Pato: no se pudo bajar", fecha, motivo)
        end
    end

    if NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then
        seguir()
    elseif NetworkMgr:turnOnWifiAndWaitForConnection(seguir) == false and prendio_wifi then
        apagarWifi()
    end
end

local DiarioDePato = WidgetContainer:extend{
    name = "diariodepato",
}

function DiarioDePato:init()
    if not arranco then
        arranco = true
        UIManager:scheduleIn(3, revisar)
    end
end

function DiarioDePato:onResume()
    UIManager:scheduleIn(2, revisar)
end

return DiarioDePato
