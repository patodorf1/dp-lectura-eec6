"""Arma el EPUB del Diario de Pato para Kindle/KOReader.
Uso: python3 scripts/build_epub.py ediciones/AAAA-MM-DD.json salida.epub
(también acepta el HTML de la página web con el bloque <script id="edicion">)
"""
import json,re,zipfile,uuid,html,sys,os,datetime,io,urllib.request,urllib.parse
from concurrent.futures import ThreadPoolExecutor
E=html.escape
src,out=sys.argv[1],sys.argv[2]
s=open(src,encoding='utf-8').read()
if src.endswith('.json'): ED=json.loads(s)
else: ED=json.loads(re.search(r'<script id="edicion" type="application/json">(.*?)</script>',s,re.S).group(1))
N=ED['notas'];by={n['id']:n for n in N}
# Foto de cada nota: la principal de la página original (og:image), en gris y achicada para la Kindle.
# Si el sitio no la da o algo falla, la nota sale sin foto.
def foto(u):
    try:
        from PIL import Image,ImageOps
        get=lambda x,n:urllib.request.urlopen(urllib.request.Request(x,headers={'User-Agent':'Mozilla/5.0'}),timeout=20).read(n)
        h=get(u,600000).decode('utf-8','ignore')
        m=re.search(r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)',h) or re.search(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:image["\']',h)
        if not m: return None
        im=Image.open(io.BytesIO(get(urllib.parse.urljoin(u,html.unescape(m.group(1))),8000000))).convert('L')
        w,hh=im.size
        if hh>w*.75: c=int((hh-w*.75)*.35); im=im.crop((0,c,w,c+int(w*.75)))  # fotos verticales: recorte apaisado
        if im.width>900: im=im.resize((900,round(im.height*900/im.width)),Image.LANCZOS)
        im=ImageOps.autocontrast(im,cutoff=1)
        # Miniatura para "Noticias de hoy": recorte 4:3 al centro, chica para que la lista pese poco
        mi=ImageOps.fit(im,(360,270),Image.LANCZOS,centering=(.5,.35))
        b=io.BytesIO(); im.save(b,'JPEG',quality=72,optimize=True)
        bm=io.BytesIO(); mi.save(bm,'JPEG',quality=70,optimize=True)
        return b.getvalue(),bm.getvalue()
    except Exception as e:
        print('sin foto',u,type(e).__name__,file=sys.stderr); return None
with ThreadPoolExecutor(8) as ex: FOTOS={i:f for i,f in zip(by,ex.map(lambda n:foto(n['u']),N)) if f}
fig=lambda n:f'<div class="foto"><img src="f/{n["id"]}.jpg" alt=""/><p class="cred">Foto: {E(n["src"])}</p></div>' if n['id'] in FOTOS else ''
# Foto de la tapa: recorte apaisado, más bajo cuanto más largos son el título y la bajada,
# para que el botón "Noticias de hoy" entre en la primera pantalla de la Kindle
L=by[ED['lead']];TAPA=None
if L['id'] in FOTOS:
    from PIL import Image,ImageOps
    im=Image.open(io.BytesIO(FOTOS[L['id']][0]))
    # Lugar que queda para la foto (medido en una pantalla de 540 de ancho): cada renglón de más del título o la bajada se lo come
    alto=min(200,170-38*(-(-len(L['t'])//27)-3)-28*(-(-len(L['b'])//48)-3))
    if alto>=100:  # si no entra ni apaisada, la tapa va sin foto
        if im.height/im.width>alto/455: im=ImageOps.fit(im,(im.width,round(im.width*alto/455)),centering=(.5,.25))
        b=io.BytesIO(); im.save(b,'JPEG',quality=72,optimize=True); TAPA=b.getvalue()
CSS='''
a{color:#000;text-decoration:none !important}
body{font-family:serif;line-height:1.4;margin:0 .4em}
.mast{text-align:center;border-top:4px solid #000;border-bottom:1px solid #000;padding:.3em 0;margin:0 0 .2em}
.mast .name{font-size:2em;font-weight:bold;letter-spacing:.02em;margin:0;line-height:1.1}
.mast .date{font-size:.8em;text-transform:uppercase;letter-spacing:.12em;margin:.2em 0 0}
table.tick{width:100%;border-collapse:collapse;font-family:sans-serif;font-size:.7em;margin:.3em 0 .6em}
table.tick td{border:1px solid #000;text-align:center;padding:.25em .1em}
table.tick .k{display:block;font-size:.85em;text-transform:uppercase;letter-spacing:.05em}
table.tick .val{display:block;font-weight:bold;font-size:1.15em}
.kicker{font-family:sans-serif;font-size:.68em;font-weight:bold;text-transform:uppercase;letter-spacing:.1em;margin:0}
.lead{border-bottom:2px solid #000;padding-bottom:.5em;margin-bottom:.4em}
.lead h1{font-size:1.65em;line-height:1.12;margin:.15em 0 .3em}
.lead h1 a,.t a{color:#000;text-decoration:none}
.bajada{font-style:italic;margin:0}
.lbl{font-family:sans-serif;font-size:.7em;font-weight:bold;text-transform:uppercase;letter-spacing:.12em;border-bottom:1px solid #000;margin:.8em 0 .3em}
.item{border-bottom:1px solid #999;padding:.45em 0}
.t{font-weight:bold;font-size:1.05em;line-height:1.2;margin:.1em 0}
.band{background:#000;color:#fff;font-family:sans-serif;font-weight:bold;text-transform:uppercase;letter-spacing:.12em;padding:.3em .5em;margin:0 0 .6em;font-size:.95em}
h2.art{font-size:1.45em;line-height:1.15;margin:.2em 0 .35em}
.art-bajada{font-style:italic;border-bottom:1px solid #000;padding-bottom:.6em;margin:0 0 .8em}
p{margin:0 0 .7em;text-align:justify}
.why{border:2px solid #000;padding:.5em .6em;text-align:left}
.why b{font-family:sans-serif;font-size:.8em;text-transform:uppercase;letter-spacing:.08em;display:block}
.src{font-family:sans-serif;font-size:.75em;border-top:1px solid #000;padding-top:.4em;margin-top:1em;text-align:left;word-wrap:break-word}
.nav{font-family:sans-serif;font-size:.8em;text-align:center;margin-top:1em}
.nav a{color:#000}
.title{font-family:sans-serif;font-weight:bold;font-size:1.2em;text-transform:uppercase;letter-spacing:.1em;text-align:center;margin:.4em 0 .9em}
.band{margin-top:1.1em}
.ni{border-bottom:1px solid #999;padding:1.1em 0 1em}
.nt{font-size:1.15em;line-height:1.2;text-align:left;margin:.15em 0 .25em}
.nt a{color:#000;text-decoration:none}
.nb{font-size:.9em;line-height:1.3;text-align:left;margin:0}
.go{font-family:sans-serif;font-weight:bold;font-size:1.1em;text-align:center;border:2px solid #000;padding:.45em;margin:.6em 0 0}
.go a{color:#000;text-decoration:none}
table.back{width:100%;border-collapse:collapse;font-family:sans-serif;font-weight:bold;font-size:.9em;margin-top:1.2em}
table.back td{width:50%;border:2px solid #000;text-align:center;padding:.6em .3em}
table.back a{color:#000;text-decoration:none}
.mast p{text-align:center}
.t,.bajada,.kicker,.lbl,.band,h1,h2,.art-bajada{text-align:left}
.foto{margin:0 0 .8em;text-align:center}
.foto img{width:100%;height:auto}
.cred{font-family:sans-serif;font-size:.6em;text-align:right;margin:.15em 0 0}
.lead .foto{margin:.5em auto 0;width:90%}
table.nl{width:100%;border-collapse:collapse}
table.nl td{vertical-align:top;padding:0}
table.nl td.mi{width:34%;padding-left:.6em}
table.nl td.mi img{width:100%;height:auto}
'''
def page(t,b):return f'<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="es" xml:lang="es"><head><meta charset="utf-8"/><title>{E(t)}</title><link rel="stylesheet" href="s.css" type="text/css"/></head><body>{b}</body></html>'
secs=[s_ for s_ in ED['secciones'] if any(n['sec']==s_ for n in N)]
# Orden de lectura: "orden" lo arma la tarea (Deportes y F1 primero, después el resto mezclado por interés).
# Las ediciones viejas no lo tienen: ahí van por sección. Una nota que falte en "orden" va al final.
ORDEN=[by[i] for i in dict.fromkeys(ED.get('orden',[])) if i in by]
ORDEN+=[n for s_ in secs for n in N if n['sec']==s_ and n not in ORDEN]
ORDEN+=[n for n in N if n not in ORDEN]
fn=lambda n:f"{n['id']}.xhtml"
mast=f'<div class="mast"><p class="name">Diario de Pato</p><p class="date">{E(ED["fecha"])}</p></div>'
# Del dólar solo el blue; el resto del ticker (riesgo país) se mantiene
TK=[t for t in ED['ticker'] if 'blue' in t[0].lower() or 'riesgo' in t[0].lower()]
tick='<table class="tick"><tr>'+''.join(f'<td><span class="k">{E(k)}</span><span class="val">{E(v)}</span>{E(x)}</td>' for k,v,x in TK)+'</tr></table>'
ftapa=f'<div class="foto"><a href="{fn(L)}"><img src="f/{L["id"]}t.jpg" alt=""/></a></div>' if TAPA else ''
tapa=mast+tick+f'<div class="lead"><p class="kicker">{E(L["sec"])} · {E(L["v"])}</p><h1><a href="{fn(L)}">{E(L["t"])}</a></h1><p class="bajada">{E(L["b"])}</p>{ftapa}</div>'
tapa+='<p class="go"><a href="noticias.xhtml">Noticias de hoy →</a></p>'
# Noticias de hoy: lista para leer de corrido (categoría, título, bajada). El id h<id> es el ancla de "← Noticias de hoy"
# Con foto: dos columnas (texto a la izquierda, miniatura a la derecha). Sin foto: el texto ocupa todo el ancho
txt=lambda n:f'<p class="kicker" id="h{n["id"]}">{E(n["sec"])}</p><p class="nt"><a href="{fn(n)}">{E(n["t"])}</a></p><p class="nb">{E(n["b"])}</p>'
item=lambda n:f'<table class="nl"><tr><td>{txt(n)}</td><td class="mi"><a href="{fn(n)}"><img src="f/{n["id"]}m.jpg" alt=""/></a></td></tr></table>' if n['id'] in FOTOS else txt(n)
nots=mast+''.join(f'<div class="ni">{item(n)}</div>' for n in ORDEN)
nots+='<p class="nav"><a href="tapa.xhtml">← Tapa</a></p>'
docs=[("tapa","Tapa",tapa),("noticias","Noticias de hoy",nots)]
for n in ORDEN:
        body=''
        for p in n['body']:
            if p.startswith('Por qué importa'):
                body+=f'<p class="why"><b>Por qué importa</b>{E((lambda x:x[:1].upper()+x[1:])(p.split(":",1)[1].strip() if ":" in p else p))}</p>'
            else: body+=f'<p>{E(p)}</p>'
        docs.append((n['id'],n['t'],f'<p class="band">{E(n["sec"])}</p><p class="kicker">{E(n["v"])}</p><h2 class="art">{E(n["t"])}</h2><p class="art-bajada">{E(n["b"])}</p>{fig(n)}{body}<p class="src">Fuente: {E(n["src"])}<br/><a href="{E(n["u"])}">{E(n["u"])}</a></p><table class="back"><tr><td><a href="noticias.xhtml#h{n["id"]}">← Noticias de hoy</a></td><td><a href="tapa.xhtml">Tapa</a></td></tr></table>'))
TITLE=f"Diario de Pato · {ED['fecha']}"
# Mismo identificador para la misma edición, aunque se rearme el libro
UID=f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL,'diario-de-pato:'+ED['fecha'])}"
NOW=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
# Tapa con imagen e índice NCX: sin ellos, el envío a la Kindle por mail (Send to Kindle) se trababa al descargar
PORTADA=open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'portada.png'),'rb').read()
with zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED) as z:
    z.writestr(zipfile.ZipInfo("mimetype"),"application/epub+zip",compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml",'<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="O/c.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    z.writestr("O/s.css",CSS)
    z.writestr("O/portada.png",PORTADA)
    for i,(f,m) in FOTOS.items(): z.writestr(f"O/f/{i}.jpg",f); z.writestr(f"O/f/{i}m.jpg",m)
    if TAPA: z.writestr(f"O/f/{L['id']}t.jpg",TAPA)
    for i,t,b in docs: z.writestr(f"O/{i}.xhtml",page(t,b))
    toc=[('tapa','Tapa'),('noticias','Noticias de hoy')]
    z.writestr("O/nav.xhtml",'<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="es" xml:lang="es"><head><meta charset="utf-8"/><title>Índice</title></head><body><nav epub:type="toc"><ol>'+''.join(f'<li><a href="{i}.xhtml">{E(t)}</a></li>' for i,t in toc)+'</ol></nav></body></html>')
    z.writestr("O/toc.ncx",f'<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="es"><head><meta name="dtb:uid" content="{UID}"/><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head><docTitle><text>{E(TITLE)}</text></docTitle><navMap>'+''.join(f'<navPoint id="np{k}" playOrder="{k}"><navLabel><text>{E(t)}</text></navLabel><content src="{i}.xhtml"/></navPoint>' for k,(i,t) in enumerate(toc,1))+'</navMap></ncx>')
    man=''.join(f'<item id="{i}" href="{i}.xhtml" media-type="application/xhtml+xml"/>' for i,_,_ in docs)
    man+=''.join(f'<item id="f_{i}" href="f/{i}.jpg" media-type="image/jpeg"/><item id="m_{i}" href="f/{i}m.jpg" media-type="image/jpeg"/>' for i in FOTOS)
    if TAPA: man+=f'<item id="t_{L["id"]}" href="f/{L["id"]}t.jpg" media-type="image/jpeg"/>'
    sp=''.join(f'<itemref idref="{i}"/>' for i,_,_ in docs)
    z.writestr("O/c.opf",f'<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id" xml:lang="es"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">{UID}</dc:identifier><dc:title>{E(TITLE)}</dc:title><dc:language>es</dc:language><dc:creator>Diario de Pato</dc:creator><meta property="dcterms:modified">{NOW}</meta><meta name="cover" content="portada"/></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="css" href="s.css" media-type="text/css"/><item id="portada" href="portada.png" media-type="image/png" properties="cover-image"/>{man}</manifest><spine toc="ncx">{sp}</spine><guide><reference type="text" title="Tapa" href="tapa.xhtml"/></guide></package>')
print(ED['fecha'],len(N),'notas',[d[0] for d in docs][:4])
