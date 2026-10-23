"""Векторная геометрия оригинального знака: три истории на полке и звезда."""
from PIL import Image, ImageDraw
from pathlib import Path
import json
import math

root = Path(__file__).resolve().parents[1]
out = root / 'App/Assets.xcassets/AppIcon.appiconset'
out.mkdir(parents=True,exist_ok=True)
im = Image.new('RGB',(1024,1024))
p = im.load()
for y in range(1024):
    for x in range(1024):
        glow = max(0,1-math.hypot(x-760,y-180)/1200)
        p[x,y] = (int(8+glow*9), int(18+glow*27), int(40+glow*52))
d = ImageDraw.Draw(im)
# Large, simple marks remain legible at home-screen size.
d.rounded_rectangle((200,315,344,695),radius=32,fill=(74,157,255))
d.rounded_rectangle((381,245,525,695),radius=32,fill=(111,184,255))
d.polygon([(580,345),(710,305),(820,663),(689,703)],fill=(206,232,255))
d.rounded_rectangle((170,736,858,782),radius=23,fill=(242,248,255))
d.line((230,365,309,365),fill=(206,232,255),width=15)
d.line((411,300,494,300),fill=(235,248,255),width=15)
star=[]
for i in range(8):
    a=-math.pi/2+i*math.pi/4
    r=66 if i%2==0 else 20
    star.append((742+math.cos(a)*r,205+math.sin(a)*r))
d.polygon(star,fill=(120,194,255))
im.save(out/'AppIcon.png')
(out/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2))
(out.parent/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}}))
