"""Genera el catálogo OPDS (opds.xml) para KOReader a partir de los EPUB en site/ediciones/.
Uso: python3 scripts/build_opds.py https://USUARIO.github.io/REPO
Deja solo las últimas 7 ediciones listadas (borra las más viejas del catálogo, no del disco).
"""
import os,sys,glob,html,datetime
base=sys.argv[1].rstrip('/')
files=sorted(glob.glob('site/ediciones/*.epub'),reverse=True)[:7]
now=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
E=html.escape
entries=''
for f in files:
    name=os.path.basename(f); fecha=name.replace('.epub','')
    entries+=f'''<entry><title>Diario de Pato · {E(fecha)}</title><id>urn:diario:{E(fecha)}</id><updated>{now}</updated>
<link rel="http://opds-spec.org/acquisition" href="{base}/ediciones/{E(name)}" type="application/epub+zip"/></entry>
'''
xml=f'''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
<id>urn:diario-de-pato</id><title>Diario de Pato</title><updated>{now}</updated>
<link rel="self" href="{base}/opds.xml" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
{entries}</feed>'''
os.makedirs('site',exist_ok=True)
open('site/opds.xml','w',encoding='utf-8').write(xml)
print('opds.xml con',len(files),'ediciones')
