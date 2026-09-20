from pathlib import Path
from PIL import Image,ImageOps,ImageDraw
from docx import Document
import json,hashlib,zipfile
root=Path(__file__).resolve().parents[2]; work=root/'export/work'
for folder in sorted(work.glob('concept-*-sample')):
    counts={x['file']:x['pages'] for x in json.loads((work/'issue-3-word-qa.json').read_text(encoding='utf-8-sig'))}
    pages=[folder/f'page-{i}.png' for i in range(1,counts[folder.name+'.docx']+1)]
    sheet=Image.new('RGB',(620*len(pages),907),'#dddddd'); draw=ImageDraw.Draw(sheet)
    for i,p in enumerate(pages):
        im=Image.open(p); im.thumbnail((620,877)); sheet.paste(im,(620*i,30)); draw.text((620*i+10,8),folder.name+' / '+p.stem,fill='black')
    sheet.save(folder/'overview.png')
for kind in ['resume','portfolio']:
    texts=[]
    for concept in 'abc':
        d=Document(work/f'concept-{concept}-{kind}-sample.docx')
        text=[t.text for t in d._element.body.iter() if t.tag.endswith('}t')]
        texts.append(sorted(text))
    assert texts[0]==texts[1]==texts[2],kind+' content differs'
hashes={k.replace('\\','/'):v for k,v in json.loads((work/'issue-3-source-hashes.json').read_text()).items()}
assert all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in hashes.items())
for path in work.glob('concept-*-portfolio-sample.docx'):
    with zipfile.ZipFile(path) as z:
        embedded={hashlib.sha256(z.read(n)).hexdigest() for n in z.namelist() if n.startswith('word/media/')}
    expected={hashes[p] for p in ['portfolio/crystal-ship/assets/hero-exterior.jpg','portfolio/crystal-ship/assets/facade-cfd.png','portfolio/lakhta-center/assets/hero-exterior.jpg','portfolio/lakhta-center/assets/technical-sheet.png']}
    assert embedded==expected, 'Images changed: '+path.name
print('PASS: same text in all concepts; all source hashes unchanged')
