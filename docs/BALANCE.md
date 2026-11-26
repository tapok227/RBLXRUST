# Баланс, пострелизные механики и QA-стенды (`MyRobloxGame`)

> Подробные таблицы баланса, описания пострелизных систем и тестовых стендов `QA_TestArena`, вынесенные из [`docs/ARCHITECTURE.md`](ARCHITECTURE.md). Нагрузочные замеры хранятся в [`docs/BENCHMARKS.md`](BENCHMARKS.md).

---

## 1. Справочная таблица математического баланса

### Взрывчатка vs Конструкции (Raid Cost Table)
Урон взрывчатки по постройкам: `satchel_charge = 125`, `rocket = 250`, `c4_charge = 500`, `landmine = 100`. Для дверей в проёмах (`doorway` с `HasDoor = true`) действует `Config.Explosion.DoorDamageMultiplier = 1.6` (`50%` эффективного HP стены).

| Объект / Тир | HP (Стена / Дверь) | Сачели | Ракеты | C4 |
|---|---:|---:|---:|---:|
| `wood` | `250` / `200` | `2` / `1` | `1` / `1` | `1` / `1` |
| `stone` | `500` / `400` | `4` / `2` | `2` / `1` | `1` / `1` |
| `metal` | `1000` / `800` | `8` / `4` | `4` / `2` | `2` / `1` |
| `armored` | `2000` / `1600` | `16` / `8` | `8` / `4` | `4` / `2` |
| `shotgun_trap` / `auto_turret` | `200` / `500` | `2` / `4` | `1` / `2` | `1` / `1` |

### Содержание (Upkeep), Гниение (Decay) и Прогрессия базы (`BaseTier`)
| Тир | `HourlyCostPerPiece` (24ч расход) | `HourlyDamageByTier` (пустой TC) | Порог `BaseProgression` |
|---|---|---|---|
| `wood` | `0.25 wood/ч` (`6/24ч`, `~14–17%`) | `84 HP/ч` (`~3.0 ч`) | **Tier 1:** TC + `4` блока (`wood+`) |
| `stone` | `0.45 stone/ч` (`10.8/24ч`, `14.4%`) | `100 HP/ч` (`5.0 ч`) | **Tier 1** |
| `metal` | `0.35 metal_ore/ч` (`8.4/24ч`, `14.0%`) | `125 HP/ч` (`8.0 ч`) | **Tier 2:** TC + `6` блоков (`metal+`) |
| `armored` | `0.08 high_quality_metal/ч` (`1.92/24ч`, `12.8%`) | `167 HP/ч` (`~12.0 ч`) | **Tier 3:** TC + `8` блоков (`armored`) |

### Экономика торговцев, рейдов и лута (`Tier 1–3`)
- **Торговцы (`recycler` vs `weaponsmith`/`quartermaster`):** курс скупки `30.0–33.3%` от стоимости покупки (`<= 35%`), скупка `10 high_quality_metal -> 14 scrap` ниже цены крафта (`40 metal_ore + 20 scrap`), исключая арбитраж.
- **Масштабирование карт (`Config.MapLootScaling`):** `MainMap_Tier1 = 1.0x`, `MainMap_Tier2 = 1.35x`, `MainMap_Tier3 = 1.75x`; таблицы ящиков прогрессируют от `wooden_crate` (Tier 1) к `military_crate` (Tier 2) и `elite_crate` (Tier 3).
- **Рейд-терминал (`Config.Raid.Tiers`):**
  - `Tier 1`: вход `30 scrap` -> пресет приносит `250 wood, 150 stone, 180 scrap, 120 metal_ore, 3 tech_parts, 24 pistol_ammo, 5 cooked_meat`.
  - `Tier 2`: вход `75 scrap + 40 metal_ore` -> пресет приносит `320 scrap, 320 metal_ore, 8 tech_parts, 2 satchel_charge, 48 pistol_ammo`.
  - `Tier 3`: вход `140 scrap + 2 tech_parts` -> пресет приносит `500 scrap, 75 high_quality_metal, 16 tech_parts, 2 c4_charge, 3 rocket`.

---

## 2. Тестовые стенды в Studio (`Workspace.QA_TestArena`)
- `Workbench_Vendor_Stand`: `QA_WB_Tier1..3` (разнесены на 35 studs, кольца радиуса `16` studs) и `QA_VendorHubZone` (`NoBuild` + `VendorHubZone`, 3 NPC-торговца с `ProximityPrompt`).
- `Recycler_Blueprint_Stand`: `QA_RT_Recycler` (`1.2` -> 60%), `QA_Safe_Recycler` (`0.8` -> 40%), `QA_Research_Table` и `QA_Elite_Blueprint_Crate` (`elite_crate`, респавн `10` с).
- `Sector4_BuildingAndRaid.QA_MixedBunker`: смешанный квадратно-треугольный бункер из примитивов (`F1/F2`, `T1/T2`, `doorway` всех 4 тиров, перегородка окклюзии, `F1_SquareStairs`/`T1_TriangleStairs`).
- `Sector5_CombatRange.BowRangeTargets`: `BowTarget_20s/50s/100s` (20/50/100 studs от `FiringLine`) с `Humanoid` + `Head`.
- `Sector5_CombatRange.CombatHitboxRange`: манекены `HitboxDummy_15s/40s/80s` (`Head` 2.0x / `Torso` 1.0x / `Limbs` 0.75x) и `CoverTestWall` + `CoverTestDummy`.
- `Workspace.NPCSpawns`, `Workspace.Campfires` и `QA_NPC_TestArenaZone`: 10 маркеров на `MainMap` и 6 тестовых на `QA_NPC_TestPad` (`rt_guard`, `rt_scientist`, `deer`, `boar`, `wolf`, `bear`), костры `StationType = "campfire"`.
- `TacticalGadgetsStand`: `QA_Tactical_AutoTurret` (`InitialAmmo = 64`), `QA_Tactical_SmartDoor`, `EmpRadiusRing_18`, `CoverWall`, `FiringLine` (`26` studs).
- `LogicWearTestStand`: `QA_HbhfSensor` + `QA_SmartDoor` + `QA_HiddenShotgunTrap`, повреждённая стена `QA_DamagedWall` (`120 / 500` HP, `IsQaRepairTarget = true`).

---

## 3. История пострелизных систем и миграций

### Переработчик (`Recycler`) и Чертежи (`Blueprints` / `DataVersion = 5`)
- **Переработчик (`Recycling.luau`, `RecyclerService.luau`, `RecyclerController.luau`):** `6` входных -> `6` выходных слотов, тик `3.0` с (`~50%` базы; РТ `1.2` -> `60%`, Safe Hub `0.8` -> `40%`).
- **Чертежи и Стол исследований (`BlueprintService.luau`, `BlueprintController.luau`):** физические свитки `bp_<itemId>` (`military_crate`, `elite_crate`, `airdrop`, NPC, награды рейдов) или исследование на `research_table` (`Tier 1 = 75`, `Tier 2 = 250`, `Tier 3 = 500` Scrap). Двойная проверка крафта (`WorkbenchTier` + `UnlockedBlueprints`).

### Замыкание геймлупа (`DataVersion = 6`)
- **Anti-Softlock:** `ExtractionService.CanAccessMap` и `RaidService` допускают вход на карты/базы своего тира и ниже (`playerBaseTier >= RequiredBaseTier`); `quartermaster` выдаёт `StarterRecoveryKit` безоружным раз в `600` с.
- **Разведка 3 целей (`RaidIntel`):** пул из 3 карточек (`DominantTier`, `UsedDefenseCapacity / MaxDefenseCapacity`, `TurretCount`, `TrapCount`, `LootCategory`), бесплатный реролл раз в `600` с или мгновенно за `25` Scrap.
- **Журнал обороны, `DeathGhost` и `Self-Raid`:** при провале рейда защитник получает `25%` стоимости взрывчатки/запуска в `Scrap` в TC и до `5` записей `DefenseLogs`; при входе на `PlayerBase` спавнятся призраки `DeathGhost` (`BaseGhosts`). Кнопка **«Тест защиты (Self-Raid)»** в TC запускает тренировочный рейд по копии своей базы с `SelfRaidKit` и сохранением реального инвентаря.
- **Кулинария и `Well Fed`:** `meat_stew` / `mushroom_stew` (`BuffDuration = 900`, `MaxStaminaBonus = 1.1`), `cooked_meat` (`300`, `1.0`). При `Hunger >= 70` и `Thirst >= 70` вне боя (`>= 8` с) — реген `+1 HP / 3 с`.

### Тактические гаджеты, Stash-эвакуация и Онлайн-сигнализация
- **`emp_grenade`:** отключает `auto_turret` и `smart_door` в радиусе `18` studs на `10` с (принудительно открывая двери) без урона.
- **`smoke_grenade`:** спавнит `8` сфер `SmokeVolume` на `15` с; снаряды `Ballistics` пролетают, но hitscan и LoS турелей (`DefenseService`) обрываются.
- **Эвакуация `ExtractionStash`:** после захвата TC запускается `18`-секундный отсчёт с сиреной и записью маршрута в `DeathPoints` (`"Extraction Route"`).
- **Онлайн-сигнализация:** уведомление владельца (`MessagingService` + локально) с `15` с на ответ и `6` с подготовки перед телепортом к TC (отключена в `Self-Raid`).

### Беспроводная логика, визуальный износ и планировки (`DataVersion = 7`)
- **`hbhf_sensor` + `smart_door`:** сенсор (`10` очков, радиус `16` studs) подаёт сигнал умным дверям (`5` очков, `800` HP) в радиусе `24` studs на `5` с.
- **Износ и `repair_hammer`:** `< 60%` HP — `Concrete`/`CorrodedMetal`; `< 30%` HP — трещины `WearCrack_*` и дым `WearSmoke`. `repair_hammer` чинит `25%` MaxHP за удар за ресурсы из TC вне `30`-секундного рейд-блока.
- **Планировки (`BaseBlueprints`):** встроенный `builtin_2x2` (18 блоков) и `2` слота игрока (без лута, с возвратом `80%` стоимости старых не-TC блоков при перестройке).

### Креатив/QA-команды, новые блоки и аудит эксплоитов (`DataVersion = 9`)
- **`CreativeService`:** чат-команды `/creative` и `/giveall` (только в Studio или для `CreatorId`). Авторитарные проверки опираются только на `CreativeService.IsCreative(player)`, неуязвимость с порогом `HP >= 1`.
- **Блоки (`half_wall`, `quarter_wall`, `sloped_roof`):** добавлены в `BuildingConfig.PieceOrder` (`24–26`) с сохранением совместимости `BaseSerializer`.
- **Аудит эксплоитов:** проверка вертикальных интервалов в `CheckParallelWallStacking`, `WedgePart` probe (`GetPartsInPart`) для `sloped_roof`, серверный запрет надстройки на `quarter_wall`, учёт `half_wall`/`sloped_roof` в `CheckMaxWallsToTC` и `FindUnsupportedPieces`, 5-лучевая окклюзия в `RaidExplosives`.
