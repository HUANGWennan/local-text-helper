"""Parse explicit dates and relative days locally; ambiguous dates stay unresolved."""
import datetime as dt
import re

MONTHS = {name.lower(): i for i, name in enumerate(['January','February','March','April','May','June','July','August','September','October','November','December'],1)}
MONTHS.update({name[:3]: value for name,value in list(MONTHS.items())})
WEEKDAYS = {'一':0,'二':1,'三':2,'四':3,'五':4,'六':5,'日':6,'天':6}

def today():
    return dt.date.today()

def candidates(text, reference=None):
    reference = reference or today()
    found=[]
    occupied=[]
    def add(start,end,year,month,day):
        if any(start < b and end > a for a,b in occupied):
            return
        occupied.append((start,end))
        try:
            date=dt.date(int(year),int(month),int(day))
        except ValueError:
            return
        found.append((date.isoformat(),text[start:end]))
    # Prefer full dates over month/day fragments inside them.
    for m in re.finditer(r'(?<!\d)(20\d{2})\s*(?:年|[-/.])\s*(\d{1,2})\s*(?:月|[-/.])\s*(\d{1,2})(?:\s*[日号])?(?!\d)',text):
        add(m.start(),m.end(),*m.groups())
    for m in re.finditer(r'(?<!\d)(\d{1,2})/(\d{1,2})/(20\d{2})(?!\d)',text):
        month,day,year=m.groups();add(m.start(),m.end(),year,month,day)
    for m in re.finditer(r'(?<!\d)(\d{1,2})\s*月\s*(\d{1,2})(?:\s*[日号])?(?!\d)|(?<![\d.])(\d{1,2})\s*[-/]\s*(\d{1,2})(?![\d./-])',text):
        a,b,c,d=m.groups();add(m.start(),m.end(),reference.year,a or c,b or d)
    month_names='|'.join(sorted(MONTHS,key=len,reverse=True))
    for m in re.finditer(r'\b('+month_names+r')\.?\s*(\d{1,2})(?:st|nd|rd|th)?(?:,?\s*(20\d{2}))?\b',text,re.I):
        month,day,year=m.groups();add(m.start(),m.end(),year or reference.year,MONTHS[month.lower()],day)
    for m in re.finditer(r'\b(\d{1,2})(?:st|nd|rd|th)?\s+('+month_names+r')(?:\s+(20\d{2}))?\b',text,re.I):
        day,month,year=m.groups();add(m.start(),m.end(),year or reference.year,MONTHS[month.lower()],day)
    for m in re.finditer(r'大后天|后天|明天|今天|\btomorrow\b|\btoday\b',text,re.I):
        offset={'大后天':3,'后天':2,'明天':1,'今天':0,'tomorrow':1,'today':0}[m.group().lower()]
        date=reference+dt.timedelta(days=offset)
        add(m.start(),m.end(),date.year,date.month,date.day)
    for m in re.finditer(r'(下下|下|本|这)?(?:周|星期)([一二三四五六日天])',text):
        prefix,day=m.groups();weekday=WEEKDAYS[day]
        if prefix in ['下','下下','本','这']:
            offset={'下':7,'下下':14,'本':0,'这':0}[prefix]
            date=reference-dt.timedelta(days=reference.weekday())+dt.timedelta(days=offset+weekday)
        else:
            date=reference+dt.timedelta(days=(weekday-reference.weekday())%7)
        add(m.start(),m.end(),date.year,date.month,date.day)
    return found

def resolve(text, reference=None):
    found=candidates(text,reference)
    dates={date for date,_ in found}
    if len(dates)==1:
        return next(iter(dates))
    return None
