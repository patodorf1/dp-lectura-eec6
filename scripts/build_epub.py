"""Arma el EPUB del Diario de Pato para Kindle/KOReader.
Uso: python3 scripts/build_epub.py ediciones/AAAA-MM-DD.json salida.epub
(también acepta el HTML de la página web con el bloque <script id="edicion">)
"""
import json,re,zipfile,uuid,html,sys,os
E=html.escape
src,out=sys.argv[1],sys.argv[2]
s=open(src,encoding='utf-8').read()
if src.endswith('.json'): ED=json.loads(s)
else: ED=json.loads(re.search(r'<script id="edicion" type="application/json">(.*?)</script>',s,re.S).group(1))
N=ED['notas'];by={n['id']:n for n in N}
CSS='''
body{font-family:serif;line-height:1.4;margin:0 .4em}
.mast{text-align:center;border-top:4px solid #000;border-bottom:1px solid #000;padding:.3em 0;margin:0 0 .2em}
.mast .name{font-size:2em;font-weight:bold;letter-spacing:.02em;margin:0;line-height:1.1}
.mast .date{font-size:.8em;text-transform:uppercase;letter-spacing:.12em;margin:.2em 0 0}
table.tick{width:100%;border-collapse:collapse;font-family:sans-serif;font-size:.7em;margin:.3em 0 1em}
table.tick td{border:1px solid #000;text-align:center;padding:.25em .1em}
table.tick .k{display:block;font-size:.85em;text-transform:uppercase;letter-spacing:.05em}
table.tick .val{display:block;font-weight:bold;font-size:1.15em}
.kicker{font-family:sans-serif;font-size:.68em;font-weight:bold;text-transform:uppercase;letter-spacing:.1em;margin:0}
.lead{border-bottom:2px solid #000;padding-bottom:.7em;margin-bottom:.6em}
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
.go{font-family:sans-serif;font-weight:bold;font-size:1.1em;text-align:center;border:2px solid #000;padding:.45em;margin:1em 0 .6em}
.go a{color:#000;text-decoration:none}
table.back{width:100%;border-collapse:collapse;font-family:sans-serif;font-weight:bold;font-size:.9em;margin-top:1.2em}
table.back td{width:50%;border:2px solid #000;text-align:center;padding:.6em .3em}
table.back a{color:#000;text-decoration:none}
.mast p{text-align:center}
.t,.bajada,.kicker,.lbl,.band,h1,h2,.art-bajada{text-align:left}
'''
def page(t,b):return f'<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="es"><head><title>{E(t)}</title><link rel="stylesheet" href="s.css" type="text/css"/></head><body>{b}</body></html>'
secs=[s_ for s_ in ED['secciones'] if any(n['sec']==s_ for n in N)]
fn=lambda n:f"{n['id']}.xhtml"
mast=f'<div class="mast"><p class="name">Diario de Pato</p><p class="date">{E(ED["fecha"])}</p></div>'
# Del dólar solo el blue; el resto del ticker (riesgo país) se mantiene
TK=[t for t in ED['ticker'] if 'blue' in t[0].lower() or 'riesgo' in t[0].lower()]
tick='<table class="tick"><tr>'+''.join(f'<td><span class="k">{E(k)}</span><span class="val">{E(v)}</span>{E(x)}</td>' for k,v,x in TK)+'</tr></table>'
L=by[ED['lead']]
tapa=mast+tick+f'<div class="lead"><p class="kicker">{E(L["sec"])} · {E(L["v"])}</p><h1><a href="{fn(L)}">{E(L["t"])}</a></h1><p class="bajada">{E(L["b"])}</p></div>'
tapa+='<p class="lbl">También hoy</p>'+''.join(f'<div class="item"><p class="kicker">{E(by[i]["sec"])}</p><p class="t"><a href="{fn(by[i])}">{E(by[i]["t"])}</a></p></div>' for i in ED['side'])
tapa+='<p class="go"><a href="noticias.xhtml">Noticias de hoy →</a></p>'
# Noticias de hoy: lista para leer de corrido (categoría, título, bajada). El id h<id> es el ancla de "← Noticias de hoy"
nots=mast+'<p class="title">Noticias de hoy</p>'
for s_ in secs:
    nots+=''.join(f'<div class="ni"><p class="kicker" id="h{n["id"]}">{E(s_)}</p><p class="nt"><a href="{fn(n)}">{E(n["t"])}</a></p><p class="nb">{E(n["b"])}</p></div>' for n in N if n['sec']==s_)
nots+='<p class="nav"><a href="tapa.xhtml">← Tapa</a></p>'
docs=[("tapa","Tapa",tapa),("noticias","Noticias de hoy",nots)]
for s_ in secs:
    for n in [n for n in N if n['sec']==s_]:
        body=''
        for p in n['body']:
            if p.startswith('Por qué importa'):
                body+=f'<p class="why"><b>Por qué importa</b>{E((lambda x:x[:1].upper()+x[1:])(p.split(":",1)[1].strip() if ":" in p else p))}</p>'
            else: body+=f'<p>{E(p)}</p>'
        docs.append((n['id'],n['t'],f'<p class="band">{E(s_)}</p><p class="kicker">{E(n["v"])}</p><h2 class="art">{E(n["t"])}</h2><p class="art-bajada">{E(n["b"])}</p>{body}<p class="src">Fuente: {E(n["src"])}<br/><a href="{E(n["u"])}">{E(n["u"])}</a></p><table class="back"><tr><td><a href="noticias.xhtml#h{n["id"]}">← Noticias de hoy</a></td><td><a href="tapa.xhtml">Tapa</a></td></tr></table>'))
TITLE=f"Diario de Pato · {ED['fecha']}"
with zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED) as z:
    z.writestr(zipfile.ZipInfo("mimetype"),"application/epub+zip",compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml",'<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="O/c.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    z.writestr("O/s.css",CSS)
    for i,t,b in docs: z.writestr(f"O/{i}.xhtml",page(t,b))
    toc=[('tapa','Tapa'),('noticias','Noticias de hoy')]
    z.writestr("O/nav.xhtml",'<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Índice</title></head><body><nav epub:type="toc"><ol>'+''.join(f'<li><a href="{i}.xhtml">{E(t)}</a></li>' for i,t in toc)+'</ol></nav></body></html>')
    man=''.join(f'<item id="{i}" href="{i}.xhtml" media-type="application/xhtml+xml"/>' for i,_,_ in docs)
    sp=''.join(f'<itemref idref="{i}"/>' for i,_,_ in docs)
    z.writestr("O/c.opf",f'<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:{uuid.uuid4()}</dc:identifier><dc:title>{E(TITLE)}</dc:title><dc:language>es</dc:language><dc:creator>Diario de Pato</dc:creator><meta property="dcterms:modified">2026-10-05T10:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="css" href="s.css" media-type="text/css"/>{man}</manifest><spine>{sp}</spine></package>')
print(ED['fecha'],len(N),'notas',[d[0] for d in docs][:4])
