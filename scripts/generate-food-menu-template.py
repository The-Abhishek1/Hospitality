"""Regenerate the public Excel/CSV food-menu import examples using only stdlib."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
from xml.sax.saxutils import escape
import csv

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'apps/web/public/templates'
COLUMNS = ['name','category','price','tax_percent','food_type','served_in','size','description','dietary_notes','prep_minutes','available']
ROWS = [
 ['Paneer tikka','Starters',180,5,'veg','both','Half','Grilled paneer with spices','Contains dairy',15,'FALSE'],
 ['Paneer tikka','Starters',320,5,'veg','both','Full','Grilled paneer with spices','Contains dairy',15,'FALSE'],
 ['Chicken biryani','Main course',280,5,'non_veg','restaurant','','Rice with chicken and spices','',25,'FALSE'],
 ['Fresh lime soda','Drinks',100,5,'vegan','both','','Lime, soda and mint','',5,'FALSE'],
]
GUIDE = [
 ['Food menu import','Replace the sample dishes on the Menu sheet with your hotel menu. Import reads the first worksheet only.'],
 ['Limits','Up to 2 MB, 500 data rows and 200 distinct menu items per file.'],
 ['Required columns','name, category, price'],
 ['name','Item name, 2–120 characters. Repeat a name only for different sizes of the same item.'],
 ['category','Category name, 2–80 characters. New categories are created automatically.'],
 ['price','Number before tax in your hotel currency. No currency symbol. At most two decimal places. Sample prices are illustrative.'],
 ['tax_percent','0–100, up to two decimals. Enter 5 for 5% tax; use plain numbers, not Excel percentage formatting. Blank means 0.'],
 ['food_type','veg, non_veg, egg, vegan, not_specified. Blank means not_specified.'],
 ['served_in','restaurant, room_service, both. Blank means both.'],
 ['size','Optional size such as Half/Full or 250 ml/500 ml. One row per size, at most 12 sizes. Keep every other detail identical across size rows; price may differ.'],
 ['description','Optional, up to 800 characters.'],
 ['dietary_notes','Optional ingredients/allergen notes, up to 200 characters.'],
 ['prep_minutes','Optional whole number, 1–240.'],
 ['available','TRUE or FALSE. Blank means FALSE (unavailable). Set TRUE when ready to serve.'],
 ['Existing items','Imports only add new items. Existing names, including deleted items, can be skipped or stop the batch. Nothing is overwritten.'],
 ['Photos','Add photos through Configure item after importing. Embedded photos and remote image URLs are not imported.'],
 ['CSV','Use the same columns and save as CSV UTF-8. Commas and multiline descriptions must be quoted by your spreadsheet app.'],
 ['Preview','Upload in Orders → Food menu → Import Excel / CSV. Check the preview, then confirm. No items are saved by preview.'],
]
NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
def col(n):
    result = ''
    while n:
        n, rem = divmod(n-1, 26)
        result = chr(65+rem)+result
    return result

def sheet(rows, menu=False):
    xml = [f'<worksheet xmlns="{NS}"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols>']
    for n in range(1,len(rows[0])+1):
        width = (44 if n in (8,9) else 22) if menu else (24 if n == 1 else 115)
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
    if menu:
        xml.append(f'<autoFilter ref="A1:K{len(rows)}"/><dataValidations count="3">')
        for column,values in [('E','veg,non_veg,egg,vegan,not_specified'),('F','restaurant,room_service,both'),('K','TRUE,FALSE')]:
            xml.append(f'<dataValidation type="list" allowBlank="1" showErrorMessage="1" sqref="{column}2:{column}501"><formula1>"{values}"</formula1></dataValidation>')
        xml.append('</dataValidations>')
    xml.append('</worksheet>')
    return ''.join(xml)

OUT.mkdir(parents=True,exist_ok=True)
with (OUT/'food-menu-import.csv').open('w',newline='',encoding='utf-8-sig') as f:
    csv.writer(f,lineterminator='\n').writerows([COLUMNS,*ROWS])
files = {
 '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
 '_rels/.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
 'xl/workbook.xml': f'<workbook xmlns="{NS}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Menu" sheetId="1" r:id="rId1"/><sheet name="Instructions" sheetId="2" r:id="rId2"/></sheets></workbook>',
 'xl/_rels/workbook.xml.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
 'xl/styles.xml': f'<styleSheet xmlns="{NS}"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf fontId="0" fillId="0" borderId="0" xfId="0"/><xf fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>',
 'xl/worksheets/sheet1.xml': sheet([COLUMNS,*ROWS],True),
 'xl/worksheets/sheet2.xml': sheet(GUIDE),
}
with ZipFile(OUT/'food-menu-import.xlsx','w',ZIP_DEFLATED) as z:
    for name,content in files.items():
        z.writestr(name,'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+content)
print('Generated food-menu Excel and CSV templates.')
