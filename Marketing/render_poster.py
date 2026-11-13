# coding: utf-8
"""Render the WCMigrate feature poster using the existing app icon."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math, json, argparse
parser=argparse.ArgumentParser()
parser.add_argument("--wechat",action="store_true")
args=parser.parse_args()
suffix="-wechat" if args.wechat else ""
ROOT=Path(__file__).resolve().parent.parent
OUT=Path(__file__).resolve().parent
W,H,S=1440,2400,2
BG='#F4F5EE'; DARK='#063F3D'; INK='#123D38'; GREEN='#087E68'; MINT='#89EED0'; MUTED='#536C65'; LINE='#D5DED3'
im=Image.new('RGB',(W*S,H*S),BG);d=ImageDraw.Draw(im)
cn='/System/Library/Fonts/Hiragino Sans GB.ttc'; en='/System/Library/Fonts/Avenir Next.ttc'
checks=[]
def font(n,bold=False,latin=False):return ImageFont.truetype(en if latin else cn,round(n*S),index=(0 if bold else 2) if latin else (2 if bold else 0))
def text(x,y,s,n=30,color=INK,bold=False,latin=False,maxw=None):
 f=font(n,bold,latin);bb=d.textbbox((0,0),s,font=f,anchor='lt');width=(bb[2]-bb[0])/S
 assert maxw is None or width<=maxw+1,(s,width,maxw)
 assert x+width<=W-40,(s,x+width)
 d.text((round(x*S),round(y*S)),s,font=f,fill=color,anchor='lt')
 checks.append({'text':s,'x':x,'y':y,'width':round(width,1)})
def line(coords,color=LINE,width=1):d.line([(int(x*S),int(y*S)) for x,y in coords],fill=color,width=round(width*S))
def box(x,y,w,h,fill,r=0,outline=None,width=1):
 d.rounded_rectangle((int(x*S),int(y*S),int((x+w)*S),int((y+h)*S)),round(r*S),fill=fill,outline=outline,width=round(width*S))
def arrow(x,y,w,color=GREEN,direction=1,lw=6):
 x2=x+w*direction;line([(x,y),(x2,y)],color,lw)
 d.polygon([(round(x2*S),round(y*S)),(round((x2-15*direction)*S),round((y-12)*S)),(round((x2-15*direction)*S),round((y+12)*S))],fill=color)
# Deep green header with a quiet tonal field, no distracting texture.
for y in range(1004*S):
 t=y/(1004*S);c=tuple(round(a+(b-a)*t) for a,b in zip((5,52,51),(8,76,66)))
 d.line((0,y,W*S,y),fill=c)
# Subtle structural rings behind the product mark.
for r in (210,290,370):
 d.ellipse(((1120-r)*S,(485-r)*S,(1120+r)*S,(485+r)*S),outline='#16564D',width=S)
text(88,98,'WCMigrate',70,'#F6FAF2',True,True,maxw=800)
box(1130,99,222,64,'#245D51',32)
text(1164,117,'1.0.0',34,MINT,True,True,maxw=160)
text(91,205,'首个正式版  /  FIRST RELEASE',24,MINT,False,maxw=960)
text(82,326,'应用数据，',112,'#F6FAF2',True,maxw=850)
text(82,474,'按需迁移。',112,'#F6FAF2',True,maxw=850)
text(90,648,'文件与文件夹自由选，迁移到对应位置。',32,'#C9E5D8',maxw=1190)
box(88,746,370,60,'#275F50',30)
text(117,762,'iOS 26–27.3',29,'#EFFAF2',True,True,maxw=310)
text(1042,768,'BY XUEGAO',22,'#BDE2D0',True,True,maxw=280)
icon=Image.open(ROOT/'Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png').convert('RGB').resize((310*S,310*S),Image.Resampling.LANCZOS)
mask=Image.new('L',icon.size);ImageDraw.Draw(mask).rounded_rectangle((0,0,310*S-1,310*S-1),64*S,fill=255)
shadow=Image.new('RGBA',im.size);sd=ImageDraw.Draw(shadow);sd.rounded_rectangle((980*S,343*S,1290*S,653*S),64*S,fill=(0,15,17,80));shadow=shadow.filter(ImageFilter.GaussianBlur(26*S));im=Image.alpha_composite(im.convert('RGBA'),shadow).convert('RGB');im.paste(icon,(964*S,326*S),mask);d=ImageDraw.Draw(im)
if args.wechat:
    # Official App Store artwork; source URL is recorded next to the asset.
    badge=Image.open(OUT/'assets/wechat-appstore.png').convert('RGB').resize((136*S,136*S),Image.Resampling.LANCZOS)
    badge_mask=Image.new('L',badge.size)
    ImageDraw.Draw(badge_mask).rounded_rectangle((0,0,136*S-1,136*S-1),30*S,fill=255)
    box(1184,550,148,148,'#EFFBF1',36)
    im.paste(badge,(1190*S,556*S),badge_mask)
    d=ImageDraw.Draw(im)
    text(963,717,'微信及多开应用迁移',25,'#C9E5D8',maxw=380)
# Three operation definitions sit across the background boundary.
modes=[('01','替换',['来源覆盖目标','清理目标多余内容','来源文件保留']),('02','转换',['两边所选内容互换','目标没有对应内容时','直接移动到目标']),('03','合并',['同名文件直接覆盖','目标独有内容保留','来源文件保留'])]
for i,(num,title,desc) in enumerate(modes):
 x=88+i*432
 box(x,874,400,310,'#FFFFFF',26)
 text(x+28,903,num,24,GREEN,True,True,maxw=110)
 if i==0:arrow(x+286,920,66)
 elif i==1:
  arrow(x+286,912,66,lw=5);arrow(x+352,932,66,direction=-1,lw=5)
 else:
  line([(x+287,903),(x+314,920),(x+350,920)],GREEN,5)
  line([(x+287,937),(x+314,920)],GREEN,5);arrow(x+325,920,27,lw=5)
 text(x+27,964,title,47,INK,True,maxw=340)
 for j,t in enumerate(desc):text(x+28,1043+j*39,t,27,MUTED,maxw=344)
text(88,1275,'不止迁移。',59,INK,True,maxw=700)
text(1008,1298,'更多实用功能',25,MUTED,maxw=345)
line([(88,1372),(1352,1372)],LINE,2)
# Editorial feature grid: consistent alignment, no unnecessary cards.
features=[(88,1430,'01','插件配置备份',['独立保存插件配置','可仅备份 plist，保留目录结构']),
 (772,1430,'02','导入与分享',['支持 plist / ZIP 配置导入','本地备份可打包 ZIP 分享']),
 (88,1708,'03','中断后继续',['先核验已完成的文件','未完成的单个文件重新传输']),
 (772,1708,'04','操作进度可见',['百分比、预计剩余时间','操作期间自动保持屏幕常亮'])]
for x,y,num,title,desc in features:
 box(x,y,52,48,'#DCEBDD',12)
 text(x+10,y+12,num,21,GREEN,True,True,maxw=34)
 text(x+72,y+2,title,37,INK,True,maxw=500)
 for j,t in enumerate(desc):text(x+72,y+82+j*46,t,27,MUTED,maxw=520)
line([(720,1425),(720,1897)],LINE,1)
line([(88,1643),(1352,1643)],LINE,1)
# Clean publishing information; all URLs are real and kept legible.
line([(88,2010),(1352,2010)],'#ACC0B0',2)
text(88,2056,'开源发布',37,INK,True,maxw=500)
box(1035,2049,317,52,'#E3EBDD',26)
text(1060,2065,'GPL-3.0-or-later',23,GREEN,True,True,maxw=270)
text(88,2133,'github.com/yangokok886/WCMigrate',34,INK,True,True,maxw=1264)
text(88,2212,'TG频道  t.me/xxuegao6',28,MUTED,maxw=940)
text(1102,2212,'作者  Xuegao',26,MUTED,maxw=250)
text(88,2312,'操作前退出两边应用；文件迁移不等于聊天数据库行级合并。',21,MUTED,maxw=1264)
im=im.resize((W,H),Image.Resampling.LANCZOS)
im.save(OUT/('WCMigrate-1.0.0-features'+suffix+'.png'),optimize=True,dpi=(144,144))
im.save(OUT/('WCMigrate-1.0.0-features'+suffix+'.jpg'),quality=95,subsampling=0,optimize=True,dpi=(144,144))
(OUT/('poster-text-layout'+suffix+'.json')).write_text(json.dumps(checks,ensure_ascii=False,indent=2))
print('Saved 1440 x 2400 PNG and JPEG')
