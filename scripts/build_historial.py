"""Genera site/historial.txt: lo publicado en las últimas 10 ediciones, para que la tarea no repita notas.
Uso: python3 scripts/build_historial.py
Una línea por nota: fecha | sección | título | link. Las ediciones más nuevas, primero.
"""
import os,glob,json
lineas=[]
for f in sorted(glob.glob('ediciones/*.json'),reverse=True)[:10]:
    fecha=os.path.basename(f).replace('.json','')
    for n in json.load(open(f,encoding='utf-8'))['notas']:
        lineas.append(' | '.join([fecha,n['sec'],' '.join(n['t'].split()),n['u']]))
os.makedirs('site',exist_ok=True)
open('site/historial.txt','w',encoding='utf-8').write('Diario de Pato: notas publicadas (fecha | sección | título | link)\n'+'\n'.join(lineas)+'\n')
print('historial.txt con',len(lineas),'notas')
