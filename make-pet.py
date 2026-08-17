#!/usr/bin/env python3
# make-pet.py — 程序化生成一只简笔卡通球员宠物的精灵图(petdex 规范)
#
# 输出: 8列×9行 = 72帧, 每帧 192×208, 透明背景 PNG。
# 行 = 动画状态, 顺序与 SpriteSheet.swift 的 PetAnim 对齐:
#   0 idle  1 wave  2 run  3 failed  4 review  5 jump  (6~8 复用 idle)
# 每行前 6 帧是该动作的循环, 后 2 帧留空(app 每态只用前 6 帧)。
#
# 这是"能动起来的简笔卡通", 不是精美插画 —— 先打通自制素材库链路,
# 以后可用同样的目录结构换成更好看的图。改配色/号码只需改下面的参数。
#
# 用法:
#   python3 make-pet.py messi   --shirt 108ACE --stripe FFFFFF --shorts 222 --skin F1C9A5 --num 10
#   python3 make-pet.py rodri   --shirt C60B1E --stripe C60B1E --shorts 1B3A8C --skin E8B48C --num 16
# 生成到 ~/.claude/pets/<name>/spritesheet.png + pet.json

import sys, os, json, math, argparse
from PIL import Image, ImageDraw, ImageFont

COLS, ROWS = 8, 9
FW, FH = 192, 208
FRAMES_PER_STATE = 6

def hex2rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

def load_font(size):
    for p in ["/System/Library/Fonts/SFNSRounded.ttf",
              "/System/Library/Fonts/Helvetica.ttc",
              "/Library/Fonts/Arial Bold.ttf"]:
        if os.path.exists(p):
            try: return ImageFont.truetype(p, size)
            except Exception: pass
    return ImageFont.load_default()

def draw_player(d, cx, top, colors, number, pose):
    """在给定画布上画一个卡通球员。pose 提供各部位的动态偏移。"""
def _cap(d, x0, y0, x1, y1, w, color):
    """一条带圆头的粗线段(胶囊形), 用来画有厚度的四肢。"""
    d.line([x0, y0, x1, y1], fill=color, width=w)
    r = w // 2
    d.ellipse([x0-r, y0-r, x0+r, y0+r], fill=color)
    d.ellipse([x1-r, y1-r, x1+r, y1+r], fill=color)

def limb(d, x0, y0, x1, y1, w, fill, dark):
    """带深色描边的圆润肢体。"""
    _cap(d, x0, y0, x1, y1, w+4, dark)
    _cap(d, x0, y0, x1, y1, w, fill)

def draw_ball(d, cx, cy, r, dark):
    """脚边一颗小足球(白底 + 深色五边形点缀)。"""
    d.ellipse([cx-r, cy-r, cx+r, cy+r], fill=(255,255,255), outline=dark, width=3)
    # 中心一个五边形 + 周围三块, 近似经典足球花纹
    import math as _m
    def poly(ccx, ccy, rr, rot=0):
        pts = [(ccx+rr*_m.cos(rot+_m.radians(72*k-90)),
                ccy+rr*_m.sin(rot+_m.radians(72*k-90))) for k in range(5)]
        d.polygon(pts, fill=dark)
    poly(cx, cy, r*0.42)
    for a in (0, 120, 240):
        px = cx + _m.cos(_m.radians(a-90))*r*0.66
        py = cy + _m.sin(_m.radians(a-90))*r*0.66
        d.ellipse([px-2, py-2, px+2, py+2], fill=dark)

def draw_player(d, cx, top, colors, number, pose):
    """扁平萌系卡通球员。pose 提供各部位动态偏移。"""
    skin, shirt, stripe, shorts, dark, accent = colors
    hair = (58, 40, 30)

    head_r = 30
    hy = top + head_r + pose['head_dy']          # 头心
    body_top = hy + head_r - 6
    body_w, body_h = 60, 50
    bx0, bx1 = cx - body_w//2, cx + body_w//2
    by0, by1 = body_top, body_top + body_h
    hip_y = by1 - 2

    # --- 腿(先画, 在身体后) ---
    leg_len = 34
    foot = {}
    for side, ang in (('l', pose['leg_l']), ('r', pose['leg_r'])):
        lx = cx + (-15 if side == 'l' else 15)
        ex = lx + math.sin(math.radians(ang)) * leg_len
        ey = hip_y + 12 + math.cos(math.radians(ang)) * leg_len
        limb(d, lx, hip_y+8, ex, ey, 13, skin, dark)      # 大腿+小腿一段
        # 球鞋
        d.ellipse([ex-11, ey-5, ex+11, ey+8], fill=dark)
        d.ellipse([ex-11, ey+3, ex+11, ey+8], fill=(255,255,255))  # 鞋底白条
        foot[side] = (ex, ey)

    # --- 短裤 ---
    d.rounded_rectangle([bx0+2, hip_y-10, bx1-2, hip_y+14], radius=10,
                        fill=shorts, outline=dark, width=3)

    # --- 身体(球衣) ---
    d.rounded_rectangle([bx0, by0, bx1, by1], radius=16, fill=shirt, outline=dark, width=3)
    if stripe != shirt:                            # 竖条纹
        sw = 10
        x = bx0 + 7
        while x < bx1 - 5:
            d.rectangle([x, by0+4, x+sw, by1-4], fill=stripe)
            x += sw*2
        d.rounded_rectangle([bx0, by0, bx1, by1], radius=16, outline=dark, width=3)
    # 点缀: 领口 V 形 + 下摆条
    if accent != shirt:
        d.line([cx-12, by0+3, cx, by0+13, ], fill=accent, width=4)
        d.line([cx, by0+13, cx+12, by0+3], fill=accent, width=4)
        d.rectangle([bx0+3, by1-7, bx1-3, by1-3], fill=accent)
    # 号码
    if number:
        f = load_font(24)
        tb = d.textbbox((0,0), number, font=f)
        tw = tb[2]-tb[0]; th = tb[3]-tb[1]
        d.text((cx-tw/2, (by0+by1)/2 - th/2 - tb[1]), number, font=f,
               fill="#ffffff", stroke_width=3, stroke_fill=dark)

    # --- 手臂 ---
    sh_y = by0 + 10
    arm_len = 32
    for side, ang in (('l', pose['arm_l']), ('r', pose['arm_r'])):
        sx = (bx0+4) if side == 'l' else (bx1-4)
        rad = math.radians(ang)
        ex = sx + (-1 if side == 'l' else 1) * math.cos(rad) * arm_len
        ey = sh_y + math.sin(rad) * arm_len
        limb(d, sx, sh_y, ex, ey, 11, shirt, dark)        # 袖子
        if accent != shirt:                                # 袖口点缀
            d.ellipse([ex-8, ey-8, ex+8, ey+8], outline=accent, width=3)
        d.ellipse([ex-8, ey-8, ex+8, ey+8], fill=skin, outline=dark, width=2)  # 手

    # --- 头 ---
    d.ellipse([cx-head_r, hy-head_r, cx+head_r, hy+head_r], fill=skin, outline=dark, width=3)
    # 头发(顶部一圈 + 刘海)
    d.pieslice([cx-head_r, hy-head_r, cx+head_r, hy+head_r], 180, 360, fill=hair)
    d.ellipse([cx-head_r, hy-head_r-3, cx+head_r, hy-head_r+22], fill=hair)
    d.ellipse([cx-head_r+1, hy-head_r+8, cx+head_r-1, hy-head_r+30], fill=skin)  # 露出额头
    # 眼睛(带高光)
    ey0 = hy - 2
    for ex in (cx-10, cx+10):
        d.ellipse([ex-5, ey0-6, ex+5, ey0+6], fill=dark)
        d.ellipse([ex-1, ey0-4, ex+3, ey0], fill=(255,255,255))
    # 腮红
    for ex in (cx-17, cx+17):
        d.ellipse([ex-5, ey0+6, ex+5, ey0+12], fill=(255,170,160))
    # 嘴
    m = pose.get('mouth', 'smile')
    my = hy + 14
    if m == 'smile':
        d.arc([cx-9, my-8, cx+9, my+6], 20, 160, fill=dark, width=3)
    elif m == 'sad':
        d.arc([cx-9, my-2, cx+9, my+12], 200, 340, fill=dark, width=3)
    else:
        d.line([cx-7, my+1, cx+7, my+1], fill=dark, width=3)

    # --- 足球(站立态放脚边) ---
    if pose.get('ball') and foot:
        fx = max(f[0] for f in foot.values()) + 20
        fy = max(f[1] for f in foot.values()) + 2
        draw_ball(d, fx, fy, 13, dark)

def pose_for(state, t):
    """给定状态行与帧内进度 t∈[0,1), 返回各部位姿态。"""
    swing = math.sin(t * 2*math.pi)          # -1..1 循环
    base = dict(head_dy=0, arm_l=90, arm_r=90, leg_l=0, leg_r=0, mouth='smile', ball=False)
    if state == 0:   # idle: 轻微呼吸浮动 + 脚边球
        base['head_dy'] = int(2*swing)
        base['arm_l'] = 105; base['arm_r'] = 105; base['ball'] = True
    elif state == 1: # wave: 右手挥动
        base['arm_r'] = -55 + 35*swing
        base['arm_l'] = 108; base['ball'] = True
    elif state == 2: # run: 手脚大幅交替
        base['arm_l'] = 90 + 60*swing; base['arm_r'] = 90 - 60*swing
        base['leg_l'] = 35*swing; base['leg_r'] = -35*swing
        base['head_dy'] = int(-3*abs(swing))
    elif state == 3: # failed: 沮丧, 手垂头低
        base['arm_l'] = 125; base['arm_r'] = 125
        base['head_dy'] = 5; base['mouth'] = 'sad'
    elif state == 4: # review: 双手上举招呼"过来看/等你"
        base['arm_l'] = -60 + 25*swing; base['arm_r'] = -60 - 25*swing
        base['mouth'] = 'flat'
    elif state == 5: # jump: 跳起, 手脚张开+上移
        base['head_dy'] = int(-8 - 5*abs(swing))
        base['arm_l'] = 20; base['arm_r'] = 20
        base['leg_l'] = 30; base['leg_r'] = -30
    return base

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--shirt", default="108ACE")
    ap.add_argument("--stripe", default="FFFFFF")
    ap.add_argument("--shorts", default="222222")
    ap.add_argument("--skin", default="F1C9A5")
    ap.add_argument("--accent", default="")
    ap.add_argument("--num", default="")
    ap.add_argument("--display", default="")
    args = ap.parse_args()

    accent = hex2rgb(args.accent) if args.accent else hex2rgb(args.shirt)
    colors = (hex2rgb(args.skin), hex2rgb(args.shirt), hex2rgb(args.stripe),
              hex2rgb(args.shorts), (40,40,40), accent)

    sheet = Image.new("RGBA", (COLS*FW, ROWS*FH), (0,0,0,0))
    for row in range(ROWS):
        state = row if row < 6 else 0   # 6~8 复用 idle
        for col in range(FRAMES_PER_STATE):
            cell = Image.new("RGBA", (FW, FH), (0,0,0,0))
            d = ImageDraw.Draw(cell)
            t = col / FRAMES_PER_STATE
            draw_player(d, FW//2, 24, colors, args.num, pose_for(state, t))
            sheet.paste(cell, (col*FW, row*FH), cell)

    dest = os.path.expanduser(f"~/.claude/pets/{args.name}")
    os.makedirs(dest, exist_ok=True)
    sheet.save(os.path.join(dest, "spritesheet.png"))
    with open(os.path.join(dest, "pet.json"), "w") as f:
        json.dump({"id": args.name,
                   "displayName": args.display or args.name.title(),
                   "spritesheetPath": "spritesheet.png",
                   "source": "make-pet.py"}, f, ensure_ascii=False, indent=2)
    print(f"✅ 生成 {dest}/spritesheet.png ({COLS*FW}×{ROWS*FH})")
    print(f"   菜单栏 → 选择宠物形象 → {args.name}")

if __name__ == "__main__":
    main()
