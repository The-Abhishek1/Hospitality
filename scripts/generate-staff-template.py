"""Regenerate the public Excel/CSV staff import examples using only stdlib."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
from xml.sax.saxutils import escape
import csv

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'apps/web/public/templates'
COLUMNS = ['code','full_name','department','phone','email','joined_on','monthly_salary']
ROWS = [['EMP001','Example Employee','Housekeeping','','','26-11-2026',18000]]
GUIDE = [['Staff import','Replace the example with staff records. First worksheet only; 200 employees maximum.'],['Required','code and full_name and joined_on. Keep all column headings.'],['Dates','DD-MM-YYYY; use text cells for dates.'],['Salary','Optional monthly salary in hotel currency, numbers only. Blank leaves salary unset.'],['Privacy','Do not include bank details, identity documents or passwords.'],['Existing staff','New employees only. Existing codes stop the import; use Staff records to edit them.']]

NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
def col(n):
    result = ''
    while n:
        n, rem = divmod(n-1, 26)
        result = chr(65+rem)+result
    return result

def sheet(rows):
    xml = [f'<worksheet xmlns="{NS}"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols>']
    for n in range(1,len(rows[0])+1):
        width = 24 if len(rows[0]) == 7 else (24 if n == 1 else 115)
        xml.append(f'<col min="{n}" max="{n}" width="{width}" customWidth="1"/>')
    xml.append('</cols><sheetData>')
    for i,row in enumerate(rows,1):
        xml.append(f'<row r="{i}">')
        for j,value in enumerate(row,1):
            ref = f'{col(j)}{i}'
            if isinstance(value,(int,float)):
                xml.append(f'<c r="{ref}"><v>{value}</v></c>')
            else:
                style = ' s="1"' if i == 1 else ''
                xml.append(f'<c r="{ref}"{style} t="inlineStr"><is><t xml:space="preserve">{escape(str(value))}</t></is></c>')
        xml.append('</row>')
    xml.append('</sheetData>')
    xml.append('</worksheet>')
    return ''.join(xml)

OUT.mkdir(parents=True,exist_ok=True)
with (OUT/'staff-import.csv').open('w',newline='',encoding='utf-8-sig') as f:
    csv.writer(f,lineterminator='\n').writerows([COLUMNS,*ROWS])
files = {
 '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
 '_rels/.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
 'xl/workbook.xml': f'<workbook xmlns="{NS}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Staff" sheetId="1" r:id="rId1"/><sheet name="Instructions" sheetId="2" r:id="rId2"/></sheets></workbook>',
 'xl/_rels/workbook.xml.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
 'xl/styles.xml': f'<styleSheet xmlns="{NS}"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf fontId="0" fillId="0" borderId="0" xfId="0"/><xf fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>',
 'xl/worksheets/sheet1.xml': sheet([COLUMNS,*ROWS]),
 'xl/worksheets/sheet2.xml': sheet(GUIDE),
}
with ZipFile(OUT/'staff-import.xlsx','w',ZIP_DEFLATED) as z:
    for name,content in files.items():
        z.writestr(name,'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+content)
print('Generated staff Excel and CSV templates.')
