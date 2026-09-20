from pathlib import Path
import re, json, hashlib
from docx import Document
from docx.shared import Mm, Pt, RGBColor
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from PIL import Image

ROOT=Path(__file__).resolve().parents[2]
WORK=ROOT/'export/work'
def read(p): return (ROOT/p).read_text(encoding='utf-8-sig')
def blocks(p): return [x.strip() for x in read(p).splitlines() if x.strip()]
def clean(s): return s.replace('**','').lstrip('# ').removeprefix('- ')
sources=list((ROOT/'resume').glob('*.md'))+list((ROOT/'portfolio').rglob('*'))+[ROOT/'README.md']
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_file()}
(WORK/'issue-3-source-hashes.json').write_text(json.dumps(hashes,indent=2),encoding='utf8')
CFG={'a':dict(font='Arial',size=10.5,title=22,heading=13,color='243746',margin=18,space=4),
     'b':dict(font='Calibri',size=11,title=28,heading=16,color='285B68',margin=20,space=6),
     'c':dict(font='Arial',size=10.5,title=23,heading=13,color='354D59',margin=18,space=5)}
def shade(p,color):
    el=OxmlElement('w:shd'); el.set(qn('w:fill'),color); p._p.get_or_add_pPr().append(el)
def rich(p,s):
    for i,v in enumerate(re.split(r'\*\*(.*?)\*\*',s)):
        r=p.add_run(v); r.bold=bool(i%2)
    return p
def para(d,s,style=None):
    if s.startswith('#'):
        lev=min(len(s)-len(s.lstrip('#')),3)
        p=d.add_paragraph(clean(s),style=f'Heading {lev}')
        if concept=='c': shade(p,'EAF0F2')
        return p
    if s.startswith('- '): return rich(d.add_paragraph(style='List Bullet'),s[2:])
    return rich(d.add_paragraph(style=style),s)
def lines(d,arr):
    for s in arr: para(d,s)
def title(d,s): d.add_paragraph(s,'Title')
def picture(d,path,width):
    p=d.add_paragraph(); p.paragraph_format.space_after=Pt(7)
    p.add_run().add_picture(str(ROOT/path),width=Mm(width))
    return p
def new(kind):
    d=Document(); sec=d.sections[0]
    sec.page_width=Mm(210); sec.page_height=Mm(297)
    sec.top_margin=sec.bottom_margin=Mm(cfg['margin']); sec.left_margin=sec.right_margin=Mm(cfg['margin'])
    sec.header_distance=sec.footer_distance=Mm(9)
    for sty in ['Normal','List Bullet','Title','Heading 1','Heading 2','Heading 3']:
        st=d.styles[sty]; st.font.name=cfg['font']; st.font.size=Pt(cfg['size']); st.font.bold=False; st.font.color.rgb=RGBColor.from_string('202A30')
        st.paragraph_format.space_after=Pt(cfg['space']); st.paragraph_format.line_spacing=1.06
    for n in [1,2,3]:
        st=d.styles[f'Heading {n}']; st.font.size=Pt(cfg['heading']-(n-1)); st.font.bold=True
        st.font.color.rgb=RGBColor.from_string(cfg['color']); st.paragraph_format.space_before=Pt(10); st.paragraph_format.keep_with_next=True
    d.styles['Title'].font.size=Pt(cfg['title']); d.styles['Title'].font.bold=True; d.styles['Title'].font.color.rgb=RGBColor(0,0,0)
    d.styles['Title'].paragraph_format.keep_with_next=True
    st=d.styles['List Bullet'].paragraph_format; st.left_indent=Mm(4); st.first_line_indent=Mm(-3)
    h=sec.header.paragraphs[0]; h.text='Конорезов Владислав Сергеевич'; h.style='Normal'; h.runs[0].font.size=Pt(8); h.runs[0].font.color.rgb=RGBColor.from_string('687780')
    f=sec.footer.paragraphs[0]; f.alignment=2
    field=OxmlElement('w:fldSimple'); field.set(qn('w:instr'),'PAGE'); f._p.append(field)
    d.core_properties.author='Конорезов Владислав Сергеевич'; d.core_properties.title=kind
    return d
def side(d,left,right,width=61):
    t=d.add_table(rows=1,cols=2); t.autofit=False
    total=210-2*cfg['margin']; t.columns[0].width=Mm(width); t.columns[1].width=Mm(total-width)
    for i,w in enumerate([width,total-width]):
        t.cell(0,i).width=Mm(w)
        tcpr=t.cell(0,i)._tc.get_or_add_tcPr(); mar=OxmlElement('w:tcMar')
        for edge in ['top','left','bottom','right']:
            e=OxmlElement('w:'+edge); e.set(qn('w:w'),'80'); e.set(qn('w:type'),'dxa'); mar.append(e)
        tcpr.append(mar)
    left(t.cell(0,0)); right(t.cell(0,1))
    for cell in t.rows[0].cells:
        if not cell.paragraphs[0].text: cell._tc.remove(cell.paragraphs[0]._p)
    return t
def save(d,kind):
    dest=ROOT/f'export/templates/concept-{concept}'; dest.mkdir(parents=True,exist_ok=True)
    d.save(WORK/f'concept-{concept}-{kind}-sample.docx')
    # Filled reference template: semantic styles and source-tagged content blocks.
    # Same concrete layout as sample; XML tags make source replacement discoverable.
    for i,el in enumerate(list(d._element.body)):
        if el.tag==qn('w:sectPr'): continue
        sdt=OxmlElement('w:sdt'); pr=OxmlElement('w:sdtPr'); tag=OxmlElement('w:tag'); tag.set(qn('w:val'),f'{kind}.block.{i:03}'); pr.append(tag); sdt.append(pr)
        content=OxmlElement('w:sdtContent'); el.addprevious(sdt); content.append(el); sdt.append(content)
    d.save(dest/f'{kind}-template.docx')

summary=blocks('resume/summary.md')
experience=[x for x in read('resume/experience.md').split('---')[0].splitlines() if x.strip()]
contacts=blocks('README.md')[1:5]
crystal=blocks('portfolio/crystal-ship/project.md'); lakhta=blocks('portfolio/lakhta-center/project.md')
other=blocks('portfolio/other-projects/project.md'); other=other[:next(i for i,s in enumerate(other) if s=='## Жилой комплекс, г. Кингисепп')]
for concept,cfg in CFG.items():
    width=210-2*cfg['margin']
    d=new('Резюме'); title(d,clean(contacts[0]).split(': ',1)[1]); para(d,'Ведущий инженер-проектировщик ОВиК / Team Leader 2')
    if concept=='c':
        side(d,lambda c:lines(c,[clean(s) for s in contacts[1:3]]),lambda c:para(c,clean(contacts[3])),85)
    else: lines(d,[clean(s) for s in contacts[1:]])
    lines(d,summary)
    lines(d,experience[:11])
    d.add_page_break(); lines(d,['### Достижения']+experience[11:]); save(d,'resume')
    d=new('Портфолио'); title(d,clean(crystal[0])); picture(d,'portfolio/crystal-ship/assets/hero-exterior.jpg',width)
    ix=crystal.index('## Выполнено'); role=crystal.index('## Роль')
    if concept in 'bc': side(d,lambda c:lines(c,crystal[1:role]),lambda c:lines(c,crystal[role:ix]),62)
    else: lines(d,crystal[1:ix])
    lines(d,crystal[ix:ix+5]); d.add_page_break()
    title(d,clean(crystal[0])); lines(d,['## Выполнено']+crystal[ix+5:crystal.index('## Межфасадное пространство и обдув фасада')])
    picture(d,'portfolio/crystal-ship/assets/facade-cfd.png',width)
    lines(d,crystal[crystal.index('## Межфасадное пространство и обдув фасада'):])
    d.add_page_break(); title(d,clean(lakhta[0])); ix=lakhta.index('## Выполнено')
    side(d,lambda c:picture(c,'portfolio/lakhta-center/assets/hero-exterior.jpg',56 if concept!='b' else 60),lambda c:lines(c,lakhta[1:ix]),64 if concept!='b' else 68)
    lines(d,lakhta[ix:ix+9]); d.add_page_break(); title(d,clean(lakhta[0])); lines(d,['## Выполнено']+lakhta[ix+9:])
    picture(d,'portfolio/lakhta-center/assets/technical-sheet.png',145)
    para(d,'## '+clean(other[0]))
    if concept=='c':
        starts=[i for i,s in enumerate(other) if s.startswith('## ')]+[len(other)]
        side(d,lambda c:lines(c,other[starts[0]:starts[1]]),lambda c:lines(c,other[starts[1]:starts[2]]),width/2)
    else: lines(d,other[1:])
    save(d,'portfolio')
    layout={'version':1,'concept':concept,'format':'A4','font':cfg['font'],'body_pt':cfg['size'],'margins_mm':cfg['margin'],'accent':cfg['color'],
    'template_mode':'filled reference DOCX with tagged blocks; rebuild from Markdown, never treat template text as source',
    'builder':'export/work/build_concepts.py','blocks':[
    {'source':'README.md','select':'contacts','document':'resume','order':1},
    {'source':'resume/summary.md','select':'all','document':'resume','order':2},
    {'source':'resume/experience.md','select':'first employer, before first horizontal rule','document':'resume','order':3,'page_break':'after first five achievement bullets; repeat section heading'},
    {'source':'portfolio/crystal-ship/project.md','select':'all','document':'portfolio','order':1,'page_break':'after first four completed-work bullets'},
    {'source':'portfolio/lakhta-center/project.md','select':'all','document':'portfolio','order':2,'page_break':'before project; after first eight completed-work bullets'},
    {'source':'portfolio/other-projects/project.md','select':'first two cases','document':'portfolio','order':3,'page_break':'flow after Lakhta technical image'}],
    'images':[
    {'asset':'portfolio/crystal-ship/assets/hero-exterior.jpg','role':'hero','width_mm':width,'placement':'after title, before metadata','caption':None},
    {'asset':'portfolio/crystal-ship/assets/facade-cfd.png','role':'technical','width_mm':width,'placement':'before facade section, after remaining completed work','caption':None},
    {'asset':'portfolio/lakhta-center/assets/hero-exterior.jpg','role':'hero','width_mm':60 if concept=='b' else 56,'placement':'left column beside metadata and role','caption':None},
    {'asset':'portfolio/lakhta-center/assets/technical-sheet.png','role':'technical','width_mm':145,'placement':'after remaining completed work','caption':None}],
    'rules':{'landscape':'inline; fit content width; preserve aspect ratio','portrait':'inline in left table cell; fit width; preserve aspect ratio','headings':'keep with next','bullets':'hanging indent; automatic continuation','pages':'explicit sample boundaries plus Word pagination; no image-only pages','small_cases':'two columns' if concept=='c' else 'stacked','metadata':'side by side' if concept in 'bc' else 'stacked'}}
    # JSON syntax is valid YAML 1.2 and avoids a build dependency.
    (ROOT/f'export/templates/concept-{concept}/layout.yaml').write_text(json.dumps(layout,ensure_ascii=False,indent=2),encoding='utf8')
print('Created 12 DOCX and 3 layout.yaml files')
