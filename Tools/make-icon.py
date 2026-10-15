from PIL import Image, ImageDraw
from pathlib import Path
import json

root = Path(__file__).resolve().parents[1]
output = root / 'App/Assets.xcassets/AppIcon.appiconset'
output.mkdir(parents=True, exist_ok=True)
scale = 3
image = Image.new('RGB', (1024 * scale, 1024 * scale), (14, 15, 14))
draw = ImageDraw.Draw(image)
colors = [(250, 125, 94), (209, 237, 112), (125, 204, 245), (196, 163, 240)]
def rect(box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(tuple(int(x * scale) for x in box), radius=int(radius * scale), fill=fill, outline=outline, width=width*scale)
for index, color in enumerate(colors):
    x = 172 + index * 178
    rect((x, 210, x + 140, 814), 70, (27, 29, 27), tuple(int(c*.28) for c in color), 2)
    y = [360, 560, 440, 290][index]
    rect((x+52, y, x+88, 743), 18, color)
    rect((x+12, y-18, x+128, y+32), 14, color)
image.resize((1024, 1024), Image.Resampling.LANCZOS).save(output/'AppIcon.png')
(output/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2))
(output.parent/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}},indent=2))
