--[[
Diario de Pato para KOReader.

Al arrancar KOReader o al despertar la Kindle: si todavía no está la edición
de hoy (hora Argentina), la baja y la abre en la tapa. Si ya está, no hace
nada. Guarda las últimas 7 ediciones y borra las más viejas.

Primero prueba el libro con clave de p.thepulso.com, que trae el texto original
de los autores. La clave va en clave.txt, al lado de este archivo (no está en el
repo). Si a las 7:30 ese libro no está, o el server falla, baja el de GitHub
Pages, que es público y trae los resúmenes.

El Wi-Fi queda siempre prendido. Al despertar, la Kindle se reconecta sola en
unos segundos: el agregado espera hasta un minuto y medio a que lo haga. Si el
Wi-Fi está apagado, lo prende como lo hace la Kindle (sin buscar redes, que es
lo que fallaba) y espera a que se conecte sola a la red guardada.

Además, en la Kindle, KOReader apagaba el Wi-Fi cada vez que un intento de
conexión fallaba, y fallaba seguido porque busca redes en el mismo segundo en
que lo prende, antes de que la Kindle esté lista. Este agregado evita ese
apagado: un intento fallido deja el Wi-Fi prendido y la Kindle se conecta sola.

"Mi día" (primera en el menú de herramientas): muestra las tareas de hoy del
Daily de Airtable para ordenarlas, marcarlas como resueltas o pasarlas al
siguiente día hábil. Habla con el buzón de n8n
"Kindle - Mi día", con la clave de clave_dia.txt (tampoco está en el repo).
Ordenar, resolver y pasar a mañana son instantáneos: se guardan en Airtable
por detrás.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local ReadHistory = require("readhistory")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local mime = require("mime")
local socket = require("socket")
local socketutil = require("socketutil")

local BASE = "https://patodorf1.github.io/dp-lectura-eec6/ediciones/"
local PRIVADO = "https://p.thepulso.com/diario/"  -- libro con clave, con el texto original de los autores
local SIN_PRIVADO = 7 * 60 + 30  -- si a las 7:30 el libro con clave no está, baja el público
local BUZON = "https://n8n2.connectingpeople.io/webhook/kindle-mi-dia"  -- Mi día: lee y guarda el Daily
local GUARDAR = 7           -- ediciones que quedan en la Kindle
local DESDE = 6 * 60 + 30   -- antes de las 6:30 (hora Argentina) no busca
local REINTENTO = 15 * 60   -- después de un intento fallido, vuelve a probar solo a los 15 minutos
local ESPERA_WIFI = 90      -- segundos que espera a que la Kindle se conecte al Wi-Fi
local PASO = 3              -- cada cuántos segundos se fija si ya se conectó
local INTENTOS_RED = 6      -- si falla la red (no un 404), prueba de nuevo hasta 6 veces...
local PAUSA_RED = 10        -- ...cada 10 segundos
local CALMA = 3             -- Mi día: segundos sin tocar tareas antes de mandar los cambios
local INTENTOS_ENVIO = 3    -- si falla el envío de un cambio, prueba hasta 3 veces...
local PAUSA_ENVIO = 15      -- ...cada 15 segundos

local carpeta = Device:isKindle() and "/mnt/us/documents/Diario de Pato"
    or DataStorage:getFullDataDir() .. "/Diario de Pato"

-- Las claves van en archivos de una línea, en la carpeta de este agregado.
-- Sin clave.txt baja directo el libro público; sin clave_dia.txt no anda Mi día.
local function leerClave(nombre)
    local aca = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[^/]*$", "")
    local f = io.open(aca .. nombre, "r")
    if not f then
        return nil
    end
    local clave = (f:read("*l") or ""):match("^%s*(.-)%s*$")
    f:close()
    return clave ~= "" and clave or nil
end
local CLAVE = leerClave("clave.txt")
local CLAVE_DIA = leerClave("clave_dia.txt")

-- El módulo se carga una sola vez, así que esto se comparte entre la
-- biblioteca y el lector.
local arranco = false
local ultimo_intento = 0
local turno = 0  -- cada revisión nueva deja sin efecto la espera de la anterior

-- En la Kindle, un intento fallido de conexión ya no apaga el Wi-Fi (ver arriba).
-- KOReader lo apaga desde NetworkMgr:_abortWifiConnection; acá lo envolvemos para
-- que haga todo lo demás igual, menos apagar el Wi-Fi.
if Device:isKindle() and NetworkMgr._abortWifiConnection and not NetworkMgr.diario_no_apagar_wifi then
    NetworkMgr.diario_no_apagar_wifi = true
    local abortar = NetworkMgr._abortWifiConnection
    NetworkMgr._abortWifiConnection = function(self)
        local apagar = self.turnOffWifi
        self.turnOffWifi = function() end
        local ok, err = pcall(abortar, self)
        self.turnOffWifi = apagar
        if not ok then
            logger.warn("Diario de Pato: no se pudo cancelar la conexión", err)
        end
    end
end

-- Prende el Wi-Fi como la Kindle: solo lo habilita y la Kindle se conecta sola a
-- la red guardada. (KOReader además busca redes enseguida, y eso es lo que fallaba.)
local function prenderWifi()
    if Device:isKindle() and NetworkMgr.restoreWifiAsync then
        NetworkMgr:restoreWifiAsync()
        return true
    end
    return false
end

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

local function pedir(url, fecha, clave)
    local destino = rutaDe(fecha)
    local parcial = destino .. ".part"
    local archivo = io.open(parcial, "wb")
    if not archivo then
        return false, "no se pudo escribir en " .. carpeta
    end
    local headers = { ["Accept-Encoding"] = "identity" }
    if clave then
        headers["Authorization"] = "Basic " .. mime.b64("diario:" .. clave)
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url = url,
        headers = headers,
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

-- Primero el libro con clave. Si todavía no salió (404) se espera hasta las 7:30;
-- después de esa hora, o si el server falla o rechaza la clave, va el público.
local function bajar(fecha)
    if CLAVE then
        local ok, code = pedir(PRIVADO .. fecha .. ".epub", fecha, CLAVE)
        if ok then
            return true
        end
        local _, minutos = ahoraArgentina()
        if code == 404 and minutos < SIN_PRIVADO then
            return false, 404
        end
        logger.info("Diario de Pato: no se pudo bajar el libro con clave, va el público", fecha, code)
    end
    return pedir(BASE .. fecha .. ".epub", fecha)
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

local function revisar()
    local fecha, minutos = ahoraArgentina()
    if minutos < DESDE or existe(rutaDe(fecha)) then
        return
    end
    if os.time() - ultimo_intento < REINTENTO then
        return
    end
    if lfs.attributes(carpeta, "mode") ~= "directory" then
        lfs.mkdir(carpeta)
    end
    turno = turno + 1
    local mio = turno

    local function seguir(intento)
        intento = intento or 1
        if mio ~= turno or existe(rutaDe(fecha)) then
            return
        end
        ultimo_intento = os.time()
        local aviso = InfoMessage:new{ text = "Bajando el diario de hoy…" }
        UIManager:show(aviso)
        UIManager:forceRePaint()
        local ok, motivo = bajar(fecha)
        UIManager:close(aviso)
        if ok then
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(rutaDe(fecha))
            UIManager:scheduleIn(5, function() pcall(limpiar) end)
        elseif motivo ~= 404 and intento < INTENTOS_RED then
            -- Error de red: recién despierta, la Kindle puede figurar conectada
            -- antes de que internet ande (pasó el 21-oct). Se prueba de nuevo en unos segundos.
            logger.info("Diario de Pato: falló la red, intento", intento, fecha, motivo)
            UIManager:scheduleIn(PAUSA_RED, function() seguir(intento + 1) end)
        else
            -- 404 = todavía no salió, o la red siguió fallando: vuelve a probar solo
            -- a los 15 minutos, aunque la Kindle siga prendida.
            logger.info("Diario de Pato: no se pudo bajar", fecha, motivo)
            UIManager:scheduleIn(REINTENTO + 5, revisar)
        end
    end

    if NetworkMgr:isConnected() then
        seguir()
    elseif NetworkMgr:isWifiOn() or prenderWifi() then
        -- Recién despierta o recién prendido: la Kindle se está conectando sola. Esperamos.
        UIManager:show(InfoMessage:new{ text = "Esperando el Wi-Fi para bajar el diario…", timeout = 3 })
        local limite = os.time() + ESPERA_WIFI
        local function esperar()
            if mio ~= turno then
                return
            elseif NetworkMgr:isConnected() then
                seguir()
            elseif os.time() < limite then
                UIManager:scheduleIn(PASO, esperar)
            else
                logger.info("Diario de Pato: el Wi-Fi no se conectó en", ESPERA_WIFI, "segundos")
            end
        end
        UIManager:scheduleIn(PASO, esperar)
    else
        -- Fuera de la Kindle: lo prende KOReader y queda prendido.
        ultimo_intento = os.time()
        NetworkMgr:turnOnWifiAndWaitForConnection(seguir)
    end
end

-- Mi día ---------------------------------------------------------------------
-- Tocar una tarea es instantáneo: la lista cambia en la Kindle y el cambio se
-- manda a Airtable por detrás, unos segundos después del último toque. Abrir la
-- lista es lo único que espera al buzón: primero manda lo pendiente y después
-- muestra la lista que devuelve Airtable.

local function aviso(texto, segundos)
    UIManager:show(InfoMessage:new{ text = texto, timeout = segundos })
end

-- Corre fn con internet. En la Kindle no usa el "conectar" de KOReader (ver
-- arriba): prende el Wi-Fi si hace falta y espera a que la Kindle se conecte sola.
local function conWifi(fn)
    if NetworkMgr:isConnected() then
        return fn()
    end
    if not (NetworkMgr:isWifiOn() or prenderWifi()) then
        return NetworkMgr:runWhenOnline(fn)
    end
    aviso("Esperando el Wi-Fi…", 3)
    local limite = os.time() + ESPERA_WIFI
    local function esperar()
        if NetworkMgr:isConnected() then
            fn()
        elseif os.time() < limite then
            UIManager:scheduleIn(PASO, esperar)
        else
            aviso("No hay Wi-Fi. Probá de nuevo en un rato.")
        end
    end
    UIManager:scheduleIn(PASO, esperar)
end

-- Manda un pedido al buzón. Devuelve el código de respuesta y el texto.
-- No toca la pantalla, así también puede correr por detrás.
local function pedirAlBuzon(pedido)
    local cuerpo = JSON.encode(pedido)
    local respuesta = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url = BUZON,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#cuerpo),
            ["X-Clave"] = CLAVE_DIA,
        },
        source = ltn12.source.string(cuerpo),
        sink = ltn12.sink.table(respuesta),
    })
    socketutil:reset_timeout()
    return code, table.concat(respuesta)
end

-- Manda un pedido al buzón con un cartel de espera. Devuelve la lista nueva, o
-- nil y el código de respuesta (un texto si ni siquiera hubo respuesta).
local function consultar(pedido, espera)
    local cartel = InfoMessage:new{ text = espera }
    UIManager:show(cartel)
    UIManager:forceRePaint()
    local code, texto = pedirAlBuzon(pedido)
    UIManager:close(cartel)
    if code ~= 200 then
        logger.warn("Diario de Pato: el buzón de Mi día respondió", pedido.accion, code)
        return nil, code
    end
    local ok, datos = pcall(JSON.decode, texto)
    if ok and type(datos) == "table" and type(datos.tareas) == "table" then
        return datos
    end
    logger.warn("Diario de Pato: respuesta rara del buzón de Mi día", pedido.accion)
    return nil, code
end

local pantalla  -- la lista abierta, si hay una
local mostrar

-- Lo que falta mandar a Airtable, en orden, y el pedido que corre por detrás.
-- Corre en otro proceso para que la pantalla no se trabe mientras espera al
-- buzón. Del orden de la lista solo importa el último.
local cola = {}
local enviando
local fallas = 0
local pasadas, para = 0, nil  -- cuántas quedaron para otro día y cuál: se avisa al terminar
local revisarEnvio

local function enviarCola()
    local pedido = cola[1]
    if enviando or not pedido then
        return  -- si hay uno corriendo, al terminar sigue con el próximo
    end
    local ok, pid, fd = pcall(ffiutil.runInSubProcess, function(_, salida)
        local code, texto = pedirAlBuzon(pedido)
        local respuesta = tostring(code)
        if code == 200 then
            local leido, datos = pcall(JSON.decode, texto)
            local dia = leido and type(datos) == "table" and datos.para
            respuesta = "ok " .. (type(dia) == "string" and dia or "")
        end
        ffiutil.writeToFD(salida, respuesta, true)
    end, true)
    if not (ok and pid) then
        -- Queda en la cola: se manda la próxima vez que se abra la lista.
        logger.warn("Diario de Pato: no se pudo mandar el cambio por detrás", pid, fd)
        return
    end
    table.remove(cola, 1)
    enviando = { pid = pid, fd = fd, pedido = pedido }
    UIManager:scheduleIn(1, revisarEnvio)
end

local function ordenEnCola()
    for i, pedido in ipairs(cola) do
        if pedido.accion == "orden" then
            return pedido, i
        end
    end
end

-- Cierra el envío que corría por detrás. Devuelve nil si todavía no terminó,
-- true si llegó a Airtable y false si falló. Si falló, el pedido vuelve a la
-- cola, salvo que sea un orden y ya haya uno más nuevo.
local function cerrarEnvio(esperar)
    if not ffiutil.isSubProcessDone(enviando.pid, esperar) then
        return nil
    end
    local pedido = enviando.pedido
    local dia = ffiutil.readAllFromFD(enviando.fd):match("^ok ?(.*)$")
    enviando = nil
    if dia then
        if dia ~= "" then
            pasadas, para = pasadas + 1, dia
        end
        return true
    end
    if not (pedido.accion == "orden" and ordenEnCola()) then
        table.insert(cola, 1, pedido)
    end
    return false
end

revisarEnvio = function()
    if not enviando then
        return
    end
    local llego = cerrarEnvio(false)
    if llego == nil then
        UIManager:scheduleIn(1, revisarEnvio)
    elseif llego then
        fallas = 0
        if cola[1] then
            enviarCola()
        elseif pasadas > 0 then
            aviso((pasadas == 1 and "Queda" or "Quedan") .. " para el " .. para, 3)
            pasadas = 0
        end
    else
        fallas = fallas + 1
        logger.warn("Diario de Pato: falló el envío de un cambio, intento", fallas)
        if fallas == 1 then
            aviso("No se pudieron guardar tus cambios. Lo intento de nuevo.", 3)
        end
        if fallas < INTENTOS_ENVIO then
            UIManager:scheduleIn(PAUSA_ENVIO, enviarCola)
        else
            fallas = 0
            aviso("No se pudieron guardar tus cambios en Airtable. Se guardan la próxima vez que abras Mi día.")
        end
    end
end

-- Trae la lista, pero antes manda lo que haya quedado en la cola: si no, Airtable
-- devolvería la lista vieja. Un cambio que el buzón rechaza se descarta para que
-- no trabe lo demás (por ejemplo, si la tarea se borró en Airtable). Si no hay
-- red o el buzón no responde, queda en la cola para la próxima.
local function traerLista()
    UIManager:unschedule(enviarCola)
    if enviando then
        local cartel = InfoMessage:new{ text = "Guardando tus cambios…" }
        UIManager:show(cartel)
        UIManager:forceRePaint()
        cerrarEnvio(true)
        UIManager:close(cartel)
    end
    fallas, pasadas = 0, 0
    local datos
    local perdidos = 0
    while cola[1] do
        local code
        datos, code = consultar(cola[1], "Guardando tus cambios…")
        if not datos then
            if not (type(code) == "number" and code < 502) then
                return nil
            end
            perdidos = perdidos + 1
        end
        table.remove(cola, 1)
    end
    if perdidos > 0 then
        aviso("No se pudo guardar un cambio en Airtable. Revisá la lista.", 3)
    end
    return datos or consultar({ accion = "lista" }, "Trayendo tus tareas…")
end

local function idsDe(datos)
    local ids = {}
    for _, t in ipairs(datos.tareas) do
        table.insert(ids, t.id)
    end
    return ids
end

local function programarEnvio()
    UIManager:unschedule(enviarCola)
    UIManager:scheduleIn(CALMA, enviarCola)
end

-- Lleva la tarea i al lugar destino.
local function mover(datos, i, destino)
    table.insert(datos.tareas, destino, table.remove(datos.tareas, i))
    mostrar(datos, destino)
    local pedido = ordenEnCola()
    if pedido then
        pedido.orden = idsDe(datos)
    else
        table.insert(cola, { accion = "orden", orden = idsDe(datos) })
    end
    programarEnvio()
end

-- Saca la tarea i de la lista: la marca como resuelta o la pasa al siguiente día
-- hábil (el buzón saltea fines de semana, feriados y vacaciones).
local function sacar(datos, i, accion)
    local id = table.remove(datos.tareas, i).id
    mostrar(datos, i)
    local pedido, lugar = ordenEnCola()
    if pedido and #datos.tareas == 0 then
        table.remove(cola, lugar)
    elseif pedido then
        pedido.orden = idsDe(datos)
    end
    table.insert(cola, { accion = accion, id = id })
    programarEnvio()
end

local function opciones(datos, i)
    local n = #datos.tareas
    local dialogo
    local function boton(texto, accion)
        return { {
            text = texto,
            callback = function()
                UIManager:close(dialogo)
                if accion then
                    accion()
                end
            end,
        } }
    end
    local botones = { boton("Marcarla como resuelta", function() sacar(datos, i, "resuelta") end) }
    if i > 1 then
        table.insert(botones, boton("Ponerla primera", function() mover(datos, i, 1) end))
        table.insert(botones, boton("Subir", function() mover(datos, i, i - 1) end))
    end
    if i < n then
        table.insert(botones, boton("Bajar", function() mover(datos, i, i + 1) end))
        table.insert(botones, boton("Mandarla al final", function() mover(datos, i, n) end))
    end
    table.insert(botones, boton("Moverla a mañana", function() sacar(datos, i, "manana") end))
    table.insert(botones, boton("Cancelar"))
    dialogo = ButtonDialog:new{
        title = datos.tareas[i].t,
        title_align = "center",
        buttons = botones,
    }
    UIManager:show(dialogo)
end

-- Letra de la lista: un 25% más grande que la de las listas de KOReader.
local function letraLista()
    local base = G_reader_settings:readSetting("items_font_size")
        or Menu.getItemFontSize(G_reader_settings:readSetting("items_per_page") or Menu.items_per_page_default)
    return math.floor(base * 1.25 + 0.5)
end

-- foco: la tarea cuya página queda a la vista (sin foco, la primera página).
mostrar = function(datos, foco)
    local filas = {}
    for i, t in ipairs(datos.tareas) do
        table.insert(filas, {
            text = i .. ". " .. (t.c == true and "★ " or "") .. tostring(t.t),
            callback = function() opciones(datos, i) end,
        })
    end
    if #filas == 0 then
        table.insert(filas, { text = "No quedan tareas para hoy", select_enabled = false })
    end
    local titulo = "Mi día · " .. tostring(datos.titulo or "")
    -- La lista se actualiza solo si es lo que está arriba de todo. Si quedó
    -- abierta de otro día, el diario que se abre al despertar la tapa y se
    -- actualizaba sin verse (pasó el 3-nov): se cierra y se arma una nueva.
    -- No alcanza con el aviso de cierre de Menu, que no siempre llega (2-nov).
    if pantalla and UIManager:isWidgetShown(pantalla) then
        if UIManager:getTopmostVisibleWidget() == pantalla then
            pantalla:switchItemTable(titulo, filas, foco)
            return
        end
        UIManager:close(pantalla)
    end
    pantalla = Menu:new{
        title = titulo,
        item_table = filas,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        items_max_lines = 3,  -- con la letra grande, las tareas largas ocupan más
        items_font_size = letraLista(),
    }
    UIManager:show(pantalla)
end

local function abrirMiDia()
    if not CLAVE_DIA then
        return aviso("Falta la clave de Mi día (clave_dia.txt).")
    end
    conWifi(function()
        local datos = traerLista()
        if datos then
            mostrar(datos)
        else
            aviso("No se pudieron traer las tareas. Probá de nuevo.")
        end
    end)
end

-- Pone "Mi día" primera en la pestaña de herramientas, en el lector y en la
-- lista de libros. KOReader arma el menú recién al abrirlo, así que alcanza
-- con anotarla en su orden al arrancar.
local function ponerArriba()
    for _, nombre in ipairs({ "ui/elements/reader_menu_order", "ui/elements/filemanager_menu_order" }) do
        local ok, orden = pcall(require, nombre)
        if ok and type(orden) == "table" and type(orden.tools) == "table" then
            local esta = false
            for _, id in ipairs(orden.tools) do
                if id == "diariodepato_midia" then
                    esta = true
                end
            end
            if not esta then
                table.insert(orden.tools, 1, "diariodepato_midia")
            end
        end
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
    if self.ui and self.ui.menu then
        ponerArriba()
        self.ui.menu:registerToMainMenu(self)
    end
end

function DiarioDePato:addToMainMenu(menu_items)
    menu_items.diariodepato_midia = {
        text = "Mi día",
        sorting_hint = "tools",
        callback = abrirMiDia,
    }
end

function DiarioDePato:onResume()
    UIManager:scheduleIn(2, revisar)
    UIManager:scheduleIn(PAUSA_RED, enviarCola)  -- por si quedó algo sin mandar al dormirse
end

return DiarioDePato
