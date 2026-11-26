import asyncio
import json
import random
import aiosqlite
from dataclasses import dataclass, field
from typing import Optional, Dict, List

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.types import Message, CallbackQuery, ReplyKeyboardMarkup, KeyboardButton, InlineKeyboardButton
from aiogram.utils.keyboard import InlineKeyboardBuilder, ReplyKeyboardBuilder
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage

# ====================== НАСТРОЙКИ ======================
BOT_TOKEN = "9147193514:AAG1bfuMNGHd3RdkHgRroJOr_buQvWo3WcM"
ADMIN_IDS =  6208939931         # <-- свой Telegram ID

DB_PATH = "gta6.db"

# ====================== ДАННЫЕ ИГРЫ ======================
LOCATIONS = {
    "Vice Beach": {"danger": 2, "money_mod": 1.0},
    "Downtown": {"danger": 3, "money_mod": 1.2},
    "Port Gellhorn": {"danger": 4, "money_mod": 1.4},
    "Leonida Keys": {"danger": 1, "money_mod": 0.8},
    "Suburbs": {"danger": 2, "money_mod": 1.0},
    "Industrial": {"danger": 5, "money_mod": 1.6},
}

VEHICLES_DB = {
    "Sultan": {"speed": 7, "armor": 4},
    "Infernus": {"speed": 9, "armor": 3},
    "Adder": {"speed": 10, "armor": 5},
    "Police Cruiser": {"speed": 8, "armor": 7},
    "Sanchez": {"speed": 6, "armor": 2},
    "Stretch": {"speed": 5, "armor": 6},
}

MISSIONS = {
    "1": {
        "name": "Угон спорткара",
        "desc": "Угони Infernus с парковки у клуба",
        "reward": 8500,
        "wanted": 1,
        "xp": 40,
        "risk": 35
    },
    "2": {
        "name": "Доставка товара",
        "desc": "Перевези пакет через город",
        "reward": 5200,
        "wanted": 0,
        "xp": 25,
        "risk": 15
    },
    "3": {
        "name": "Ограбление 24/7",
        "desc": "Зайди в магазин и забери кассу",
        "reward": 14000,
        "wanted": 2,
        "xp": 70,
        "risk": 50
    },
    "4": {
        "name": "Контракт киллера",
        "desc": "Убери цель в Downtown",
        "reward": 22000,
        "wanted": 3,
        "xp": 120,
        "risk": 65
    },
}

# ====================== МОДЕЛЬ ======================
@dataclass
class Player:
    user_id: int
    username: Optional[str] = None
    language: str = "ru"
    character: str = "lucia"
    money: int = 4000
    health: int = 100
    armor: int = 0
    wanted: int = 0
    reputation: int = 0
    level: int = 1
    xp: int = 0
    kills: int = 0
    location: str = "Vice Beach"
    skills: Dict[str, int] = field(default_factory=lambda: {"shooting": 1, "driving": 1, "stealth": 1, "charisma": 1})
    inventory: Dict[str, int] = field(default_factory=lambda: {"pistol": 1, "medkit": 3})
    vehicles: List[str] = field(default_factory=lambda: ["Sultan"])
    current_vehicle: str = "Sultan"
    godmode: bool = False

    def to_dict(self):
        return {
            "user_id": self.user_id, "username": self.username, "language": self.language,
            "character": self.character, "money": self.money, "health": self.health,
            "armor": self.armor, "wanted": self.wanted, "reputation": self.reputation,
            "level": self.level, "xp": self.xp, "kills": self.kills, "location": self.location,
            "skills": json.dumps(self.skills), "inventory": json.dumps(self.inventory),
            "vehicles": json.dumps(self.vehicles), "current_vehicle": self.current_vehicle,
            "godmode": int(self.godmode)
        }

    @classmethod
    def from_row(cls, row):
        return cls(
            user_id=row["user_id"], username=row["username"], language=row["language"] or "ru",
            character=row["character"] or "lucia", money=row["money"], health=row["health"],
            armor=row["armor"], wanted=row["wanted"], reputation=row["reputation"],
            level=row["level"], xp=row["xp"], kills=row["kills"], location=row["location"] or "Vice Beach",
            skills=json.loads(row["skills"]) if row["skills"] else {"shooting":1,"driving":1,"stealth":1,"charisma":1},
            inventory=json.loads(row["inventory"]) if row["inventory"] else {"pistol":1,"medkit":3},
            vehicles=json.loads(row["vehicles"]) if row["vehicles"] else ["Sultan"],
            current_vehicle=row["current_vehicle"] or "Sultan", godmode=bool(row["godmode"])
        )

# ====================== БАЗА ======================
async def init_db():
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS players (
                user_id INTEGER PRIMARY KEY,
                username TEXT, language TEXT, character TEXT,
                money INTEGER, health INTEGER, armor INTEGER, wanted INTEGER,
                reputation INTEGER, level INTEGER, xp INTEGER, kills INTEGER,
                location TEXT, skills TEXT, inventory TEXT, vehicles TEXT,
                current_vehicle TEXT, godmode INTEGER
            )
        """)
        await db.commit()

async def get_player(uid: int) -> Optional[Player]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM players WHERE user_id = ?", (uid,)) as c:
            row = await c.fetchone()
            return Player.from_row(dict(row)) if row else None

async def save_player(p: Player):
    d = p.to_dict()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("""
            INSERT INTO players VALUES (
                :user_id,:username,:language,:character,:money,:health,:armor,:wanted,
                :reputation,:level,:xp,:kills,:location,:skills,:inventory,:vehicles,
                :current_vehicle,:godmode
            ) ON CONFLICT(user_id) DO UPDATE SET
                username=excluded.username, language=excluded.language, character=excluded.character,
                money=excluded.money, health=excluded.health, armor=excluded.armor,
                wanted=excluded.wanted, reputation=excluded.reputation, level=excluded.level,
                xp=excluded.xp, kills=excluded.kills, location=excluded.location,
                skills=excluded.skills, inventory=excluded.inventory, vehicles=excluded.vehicles,
                current_vehicle=excluded.current_vehicle, godmode=excluded.godmode
        """, d)
        await db.commit()

async def get_top(by="money", limit=10):
    if by not in ("money", "reputation", "kills", "level"):
        by = "money"
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(f"SELECT username, character, {by}, level FROM players ORDER BY {by} DESC LIMIT ?", (limit,)) as c:
            return [dict(r) for r in await c.fetchall()]

# ====================== КЛАВИАТУРЫ ======================
def lang_kb():
    b = InlineKeyboardBuilder()
    b.button(text="🇷🇺 Русский", callback_data="lang_ru")
    b.button(text="🇬🇧 English", callback_data="lang_en")
    return b.as_markup()

def char_kb():
    b = InlineKeyboardBuilder()
    b.button(text="Jason 🔫", callback_data="char_jason")
    b.button(text="Lucia 💃", callback_data="char_lucia")
    return b.as_markup()

def main_kb(lang="ru"):
    if lang == "ru":
        rows = [["👤 Профиль", "🚗 Гараж"], ["💼 Миссии", "🎒 Инвентарь"], ["🌍 Карта", "🏆 Рейтинг"], ["🎲 Событие"]]
    else:
        rows = [["👤 Profile", "🚗 Garage"], ["💼 Missions", "🎒 Inventory"], ["🌍 Map", "🏆 Ranking"], ["🎲 Event"]]
    return ReplyKeyboardMarkup(keyboard=[[KeyboardButton(text=x) for x in row] for row in rows], resize_keyboard=True)

def locations_kb():
    b = InlineKeyboardBuilder()
    for loc in LOCATIONS:
        b.button(text=loc, callback_data=f"goto_{loc}")
    b.adjust(2)
    return b.as_markup()

def missions_kb():
    b = InlineKeyboardBuilder()
    for mid, m in MISSIONS.items():
        b.button(text=f"{mid}. {m['name']}", callback_data=f"mission_{mid}")
    b.adjust(1)
    return b.as_markup()

# ====================== РОУТЕР ======================
router = Router()

class Form(StatesGroup):
    language = State()

# ---------- СТАРТ ----------
@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext):
    p = await get_player(message.from_user.id)
    if p:
        await message.answer(f"С возвращением, {p.character.title()}!", reply_markup=main_kb(p.language))
        return
    await message.answer("Выбери язык / Choose language:", reply_markup=lang_kb())
    await state.set_state(Form.language)

@router.callback_query(F.data.startswith("lang_"))
async def set_lang(cb: CallbackQuery, state: FSMContext):
    lang = cb.data.split("_")[1]
    await state.update_data(language=lang)
    text = "Добро пожаловать в <b>GTA VI</b>\n\nВыбери персонажа:" if lang == "ru" else "Welcome to <b>GTA VI</b>\n\nChoose character:"
    await cb.message.edit_text(text, reply_markup=char_kb())
    await cb.answer()

@router.callback_query(F.data.startswith("char_"))
async def set_char(cb: CallbackQuery, state: FSMContext):
    data = await state.get_data()
    lang = data.get("language", "ru")
    char = cb.data.split("_")[1]

    p = Player(
        user_id=cb.from_user.id,
        username=cb.from_user.username,
        language=lang,
        character=char,
        money=6000 if char == "jason" else 4500,
        skills={
            "shooting": 3 if char == "jason" else 1,
            "driving": 3 if char == "jason" else 2,
            "stealth": 1 if char == "jason" else 3,
            "charisma": 2 if char == "jason" else 3
        }
    )
    await save_player(p)
    await state.clear()
    await cb.message.delete()
    await cb.message.answer(
        f"{'Персонаж выбран' if lang=='ru' else 'Character selected'}: <b>{char.title()}</b>\nДобро пожаловать в Леониду!",
        reply_markup=main_kb(lang)
    )
    await cb.answer()

# ---------- ПРОФИЛЬ ----------
@router.message(F.text.in_(["👤 Профиль", "👤 Profile"]))
async def profile(message: Message):
    p = await get_player(message.from_user.id)
    if not p:
        return await message.answer("Сначала /start")

    stars = "★" * p.wanted + "☆" * (5 - p.wanted)
    skills = " | ".join([f"{k[:4]}:{v}" for k, v in p.skills.items()])
    text = (
        f"🌴 <b>Профиль — {p.character.title()}</b>\n\n"
        f"💰 {p.money:,}$\n"
        f"❤️ {p.health}/100   🛡️ {p.armor}\n"
        f"🚨 Розыск: {stars}\n"
        f"⭐ Репутация: {p.reputation}\n"
        f"📊 Уровень {p.level}  (XP {p.xp})\n"
        f"🔫 Убийств: {p.kills}\n"
        f"📍 {p.location}\n"
        f"🚗 {p.current_vehicle}\n"
        f"🎯 Навыки: {skills}\n"
        f"{'🟢 <b>GODMODE</b>' if p.godmode else ''}"
    )
    await message.answer(text)

# ---------- ГАРАЖ ----------
@router.message(F.text.in_(["🚗 Гараж", "🚗 Garage"]))
async def garage(message: Message):
    p = await get_player(message.from_user.id)
    if not p:
        return
    text = "🚗 <b>Гараж</b>\n\n"
    for car in p.vehicles:
        mark = "✅" if car == p.current_vehicle else "▫️"
        stats = VEHICLES_DB.get(car, {"speed": 5, "armor": 3})
        text += f"{mark} <b>{car}</b>  (скорость {stats['speed']}/10, броня {stats['armor']}/10)\n"
    text += "\nНапиши название машины, чтобы сесть в неё"
    await message.answer(text)

@router.message(F.text.in_(list(VEHICLES_DB.keys())))
async def switch_car(message: Message):
    p = await get_player(message.from_user.id)
    if not p:
        return
    car = message.text
    if car in p.vehicles:
        p.current_vehicle = car
        await save_player(p)
        await message.answer(f"Ты сел в <b>{car}</b>")
    else:
        await message.answer("У тебя нет этой машины")

# ---------- ИНВЕНТАРЬ ----------
@router.message(F.text.in_(["🎒 Инвентарь", "🎒 Inventory"]))
async def inventory(message: Message):
    p = await get_player(message.from_user.id)
    if not p:
        return
    text = "🎒 <b>Инвентарь</b>\n\n"
    for item, count in p.inventory.items():
        text += f"• {item} × {count}\n"
    text += "\nНапиши <code>use medkit</code> чтобы использовать аптечку"
    await message.answer(text)

@router.message(F.text.lower().startswith("use "))
async def use_item(message: Message):
    p = await get_player(message.from_user.id)
    if not p:
        return
    item = message.text.lower().split(maxsplit=1)[1]
    if item in p.inventory and p.inventory[item] > 0:
        if item == "medkit":
            p.health = min(100, p.health + 40)
            p.inventory[item] -= 1
            await save_player(p)
            await message.answer(f"Использована аптечка. Здоровье: {p.health}")
        else:
            await message.answer("Этот предмет пока нельзя использовать")
    else:
        await message.answer("Нет такого предмета")

# ---------- КАРТА / ПЕРЕМЕЩЕНИЕ ----------
@router.message(F.text.in_(["🌍 Карта", "🌍 Map"]))
async def show_map(message: Message):
    p = await get_player(message.from_user.id)
    if not p:
        return
    await message.answer(f"📍 Ты сейчас в: <b>{p.location}</b>\n\nКуда поехать?", reply_markup=locations_kb())

@router.callback_query(F.data.startswith("goto_"))
async def go_to(cb: CallbackQuery):
    p = await get_player(cb.from_user.id)
    if not p:
        return
    loc = cb.data.replace("goto_", "")
    if loc == p.location:
        await cb.answer("Ты уже здесь", show_alert=True)
        return

    # Шанс случайного события
    danger = LOCATIONS[loc]["danger"]
    if random.randint(1, 10) <= danger and not p.godmode:
        event = random.choice(["police", "bandits", "nothing", "nothing"])
        if event == "police":
            p.wanted = min(5, p.wanted + 1)
            p.health -= random.randint(10, 25)
            await cb.message.answer(f"🚨 Полиция! Розыск повысился. Здоровье: {p.health}")
        elif event == "bandits":
            loss = random.randint(800, 2500)
            p.money = max(0, p.money - loss)
            await cb.message.answer(f"🔫 На тебя напали! Потерял {loss}$")

    p.location = loc
    if p.health <= 0 and not p.godmode:
        p.health = 20
        p.money = max(0, p.money - 1500)
        p.wanted = 0
        await cb.message.answer("💀 Тебя подняли медики... Потерял деньги и розыск сброшен.")
    await save_player(p)
    await cb.message.edit_text(f"Ты приехал в <b>{loc}</b>")
    await cb.answer()

# ---------- МИССИИ ----------
@router.message(F.text.in_(["💼 Миссии", "💼 Missions"]))
async def missions_menu(message: Message):
    p = await get_player(message.from_user.id)
    if not p:
        return
    await message.answer("💼 <b>Доступные миссии</b>\nВыбери:", reply_markup=missions_kb())

@router.callback_query(F.data.startswith("mission_"))
async def do_mission(cb: CallbackQuery):
    p = await get_player(cb.from_user.id)
    if not p:
        return
    mid = cb.data.split("_")[1]
    m = MISSIONS.get(mid)
    if not m:
        return

    # Расчёт успеха
    skill_bonus = (p.skills["shooting"] + p.skills["stealth"] + p.skills["driving"]) * 3
    success_chance = 100 - m["risk"] + skill_bonus
    success_chance = max(15, min(95, success_chance))

    if random.randint(1, 100) <= success_chance or p.godmode:
        reward = int(m["reward"] * LOCATIONS[p.location]["money_mod"])
        p.money += reward
        p.xp += m["xp"]
        p.reputation += random.randint(5, 15)
        p.wanted = min(5, p.wanted + m["wanted"])
        if "киллер" in m["name"].lower() or "контракт" in m["name"].lower():
            p.kills += 1
        # Прокачка уровня
        while p.xp >= p.level * 100:
            p.xp -= p.level * 100
            p.level += 1
            await cb.message.answer(f"🎉 Новый уровень! Теперь {p.level}")
        result = f"✅ <b>Успех!</b>\n+{reward:,}$\n+{m['xp']} XP\nРозыск: {p.wanted}★"
    else:
        p.health -= random.randint(15, 40)
        p.wanted = min(5, p.wanted + 1)
        result = f"❌ <b>Провал...</b>\nПотерял здоровье. Розыск вырос."

    if p.health <= 0 and not p.godmode:
        p.health = 15
        p.money = int(p.money * 0.7)
        result += "\n💀 Почти погиб. Медики спасли."

    await save_player(p)
    await cb.message.edit_text(result)
    await cb.answer()

# ---------- СЛУЧАЙНОЕ СОБЫТИЕ ----------
@router.message(F.text.in_(["🎲 Событие", "🎲 Event"]))
async def random_event(message: Message):
    p = await get_player(message.from_user.id)
    if not p:
        return
    events = [
        ("Ты нашёл кейс с деньгами", +random.randint(2000, 7000), 0),
        ("Тебя подрезали и избили", -random.randint(10, 30), 0),
        ("Полиция устроила облаву", 0, +2),
        ("Удачная сделка на чёрном рынке", +random.randint(3000, 9000), 0),
        ("Поднял ствол после перестрелки", 0, 0),
    ]
    text, money_change, wanted_change = random.choice(events)
    if money_change > 0:
        p.money += money_change
        text += f"\n+{money_change}$"
    elif money_change < 0:
        p.health = max(5, p.health + money_change)
        text += f"\nЗдоровье: {p.health}"
    p.wanted = min(5, max(0, p.wanted + wanted_change))
    await save_player(p)
    await message.answer(f"🎲 {text}")

# ---------- РЕЙТИНГ ----------
@router.message(F.text.in_(["🏆 Рейтинг", "🏆 Ranking"]))
async def ranking(message: Message):
    top = await get_top("money", 10)
    text = "🏆 <b>Топ богачей Леониды</b>\n\n"
    for i, row in enumerate(top, 1):
        name = row["username"] or "Unknown"
        text += f"{i}. {name} ({row['character']}) — {row['money']:,}$\n"
    await message.answer(text)

# ====================== АДМИНКА ======================
@router.message(Command("admin"))
async def admin(message: Message):
    if message.from_user.id not in ADMIN_IDS:
        return
    await message.answer(
        "🛠 <b>Админ-панель</b>\n\n"
        "/money 999999\n"
        "/heal\n"
        "/wanted 0-5\n"
        "/god\n"
        "/level 50\n"
        "/rep 5000\n"
        "/car Adder\n"
        "/item medkit 10\n"
        "/tp Downtown\n"
        "/kill\n"
        "/reset"
    )

@router.message(Command("money"))
async def c_money(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if not p: return
    try: amount = int(m.text.split()[1])
    except: amount = 999999
    p.money = amount
    await save_player(p)
    await m.answer(f"✅ {amount:,}$")

@router.message(Command("heal"))
async def c_heal(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        p.health = 100
        p.armor = 100
        await save_player(p)
        await m.answer("✅ Полный хил")

@router.message(Command("wanted"))
async def c_wanted(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        try: stars = max(0, min(5, int(m.text.split()[1])))
        except: stars = 0
        p.wanted = stars
        await save_player(p)
        await m.answer(f"✅ Розыск {stars}★")

@router.message(Command("god"))
async def c_god(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        p.godmode = not p.godmode
        await save_player(p)
        await m.answer("🟢 GOD ON" if p.godmode else "🔴 GOD OFF")

@router.message(Command("level"))
async def c_level(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        try: p.level = int(m.text.split()[1])
        except: p.level = 50
        await save_player(p)
        await m.answer(f"✅ Уровень {p.level}")

@router.message(Command("rep"))
async def c_rep(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        try: p.reputation = int(m.text.split()[1])
        except: p.reputation = 9999
        await save_player(p)
        await m.answer(f"✅ Репутация {p.reputation}")

@router.message(Command("car"))
async def c_car(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        try: car = m.text.split(maxsplit=1)[1]
        except: car = "Adder"
        if car not in p.vehicles:
            p.vehicles.append(car)
        p.current_vehicle = car
        await save_player(p)
        await m.answer(f"✅ Выдана {car}")

@router.message(Command("item"))
async def c_item(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        parts = m.text.split()
        item = parts[1] if len(parts) > 1 else "medkit"
        count = int(parts[2]) if len(parts) > 2 else 5
        p.inventory[item] = p.inventory.get(item, 0) + count
        await save_player(p)
        await m.answer(f"✅ +{count} {item}")

@router.message(Command("tp"))
async def c_tp(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        try: loc = m.text.split(maxsplit=1)[1]
        except: loc = "Downtown"
        p.location = loc
        await save_player(p)
        await m.answer(f"✅ Телепорт: {loc}")

@router.message(Command("kill"))
async def c_kill(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        p.kills += 1
        await save_player(p)
        await m.answer(f"✅ Убийств: {p.kills}")

@router.message(Command("reset"))
async def c_reset(m: Message):
    if m.from_user.id not in ADMIN_IDS: return
    p = await get_player(m.from_user.id)
    if p:
        p.money = 5000
        p.health = 100
        p.armor = 0
        p.wanted = 0
        p.level = 1
        p.xp = 0
        await save_player(p)
        await m.answer("✅ Персонаж сброшен")

# ====================== ЗАПУСК ======================
async def main():
    await init_db()
    bot = Bot(token=BOT_TOKEN)
    dp = Dispatcher(storage=MemoryStorage())
    dp.include_router(router)
    print("GTA VI Bot запущен...")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
