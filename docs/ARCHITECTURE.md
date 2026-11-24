# Архитектура проекта MyRobloxGame

## 1. Структура Rojo и точка входа
- `src/shared` -> `ReplicatedStorage.Shared`
- `src/server` -> `ServerScriptService.Server` (`init.server.luau` вызывает `service.Init()` для модулей в `Services/`)
- `src/client` -> `StarterPlayer.StarterPlayerScripts.Client` (`init.client.luau` вызывает `controller.Init()` для модулей в `Controllers/`)
- Нагрузочные замеры и бенчмарки вынесены в [`docs/BENCHMARKS.md`](BENCHMARKS.md).

---

## 2. Shared-модули (`ReplicatedStorage.Shared`)

### `Config` (`src/shared/Config.luau`)
- `Game = { Name: string, MaxPlayers: number }`
- `Places = { MainMap, MainMap_Tier1, MainMap_Tier2, MainMap_Tier3, PlayerBase }`
- `Maps` & `MapOrder` — привязка PvP-карт (`MainMap_Tier1/2/3`) к минимальному требуемому `RequiredBaseTier` (`1 / 2 / 3`).
- `BaseProgression` — пороги структурных блоков и минимального ранга тира с активным TC (`Tier1`: `4` блока `wood+`; `Tier2`: `6` блоков `metal+`; `Tier3`: `8` блоков `armored`).
- `Upkeep` — разрешённые ресурсы содержания TC (`wood`, `stone`, `metal_ore`, `high_quality_metal`), часовой расход на блок (`wood = 0.25`, `stone = 0.45`, `metal = 0.35`, `armored = 0.08`, ~`12.8–15%` за 24 ч), `TcStorageSlots = 12`.
- `Decay` — интервал тика (`60` с), лимит оффлайн-пересчёта (`24` ч), урон гниения в час по тирам (`wood = 84` ~`3` ч, `stone = 100` `5` ч, `metal = 125` `8` ч, `armored = 167` ~`12` ч) и множитель `NoTcMultiplier = 1.5`.
- `Extraction = { Duration: number, CooldownAfterDamage: number }`
- `Explosion = { UpgradeRaidBlockSeconds: number, DoorDamageMultiplier: number, DefenseDamageMultiplier: number, TierDamageMultiplier: { wood: number, stone: number, metal: number, armored: number } }` — единый конфиг взрывного урона (`UpgradeRaidBlockSeconds = 30`, `DoorDamageMultiplier = 1.6` для проёмов `doorway` с дверью, `DefenseDamageMultiplier = 1.0`, `TierDamageMultiplier = 1.0` для всех 4 тиров).
- `MapLootScaling = { [1] = 1.0, [2] = 1.35, [3] = 1.75 }` — множители количества ресурсного лута по тиру карты `MainMap_Tier1/2/3`.
- `MAX_TC_WALL_LAYERS = 2`, `MIN_TURRET_DISTANCE = 14`, `MIN_TRAP_DISTANCE = 6`, `WORKBENCH_RADIUS = 16` — баланс-ограничения защиты базы (максимум 2 слоя стен/перекрытий до TC, анти-киллбокс дистанция между турелями/ловушками) и радиус действия верстаков при крафте (`16` studs).
- Спринт, выносливость и бафф сытости: `BASE_WALK_SPEED = 16`, `SPRINT_WALK_SPEED = 24`, `MAX_STAMINA = 100`, `STAMINA_DRAIN_PER_SEC = 18`, `STAMINA_REGEN_BASE = 12`, `STAMINA_REGEN_WELL_FED = 20`, `STAMINA_REGEN_STARVING = 6`, `STAMINA_MIN_TO_SPRINT = 20`, `WELL_FED_THRESHOLD = 70`, `WELL_FED_HP_REGEN = 1`, `WELL_FED_HP_INTERVAL = 3`, `COMBAT_REGEN_COOLDOWN = 8`.
- `VendorHub` — параметры безопасной зоны торговцев на `PlayerBase`: `Origin = Vector3.new(0, 0, -68)` (вне зоны застройки и на противоположной стороне от `RaidOutpostZone`), `ZoneSize = Vector3.new(44, 32, 34)`, `InteractDistance = 14`, `MaxTradeQuantity = 10`, `StarterKitCooldown = 600`, `StarterKitItems` (`spear`, `hunting_bow`, `arrow` x12, `bandage` x2).
- `Raid` — параметры рейда: `MaxLives = 3`, `RespawnDelay = 0.8` (быстрое возрождение `< 1.5` с), `SpawnInvulnerabilityDuration = 2.0` (`ForceField` на 2 с), `TcHackDuration = 10`, `TcHackMaxDistance = 14`, `OutpostRadius = 28`, `OutpostOffsetZ = 46`, `OutpostGhostBufferMargin = 8`, `IntelCardsCount = 3`, `IntelFreeRefreshCooldown = 600`, `IntelPaidRefreshScrap = 25`, `DefenseRewardRatio = 0.25`, `ExplosiveScrapValues`, `SelfRaidKit`, `ExtractionStashSlots = 18`, `SupplyCrateSlots = 6`, `StarterSupplyItems` (`bandage` x6, `cooked_meat` x2), `Tiers[1..3]`.
- `DefenseCapacity` — лимит очков защиты по тирам базы (`MaxByBaseTier`: `[0]=30`, `[1]=60`, `[2]=100`, `[3]=150`) и стоимость защитных установок (`Costs`: `floor_spikes = 5`, `landmine = 10`, `shotgun_trap = 15`, `auto_turret = 25`).

### `Types` (`src/shared/Types.luau`)
- Инвентарь и предметы: `ItemId`, `ItemType`, `ItemConfig`, `Slot`, `InventorySlot`, `Inventory`, `EquipmentMap`, `ContainerData`, `SurvivalStats` (`WellFedEndTime?`, `WellFedStaminaMult?`), `ConsumableConfig` (`BuffDuration?`, `MaxStaminaBonus?`), `LootContainerState`, `PlayerData` (`SchemaVersion = 9`, `DataVersion = 9`, `Equipment`, `DefenseLogs`, `BaseBlueprints`, `LastStarterKitAt?`), `DeathGhostPoint`, `DefenseLogEntry`, `ItemBatchEntry`.
- Постройки и база: `BuildPieceType` / `ModuleType`, `BuildTier` / `BuildingTier`, `SavedBuildPiece` / `BuildingBlockData` (`HasCodeLock?`, `IsDoorOpen?`, `LinkedHbhfSensor?`, `HasDoor?`), `QuantizedBlock`, `BaseBlueprintSlot` (`EncodedBlocks?`, `PieceCount?`, `Cost?`, legacy `Pieces?`), `BaseSnapshot`, `BaseData` (`SerializedBlocks?`, `ContainerSidecar?`), `BaseTier`, `ToolCupboardStatus`, `ToolCupboardState` / `TCState` (`DefenseUsed?`, `DefenseMax?`, `DefenseLogs?`), `DefenseMountSurface`, `DefenseAllowedMount`, `DefenseConfig`, `DefenseUiState`.
- Рейды, телепорт, боёвка и сеть: `RaidTargetInfo` / `RaidIntelCard`, `RaidIntelPool`, `RaidSessionState`, `RaidHudState`, `RaidDefenseReport`, `ExtractionState`, `TransferReason`, `TransferPayload`, `TransferReceipt`, `BallisticShotRequest`, `BallisticHitResult`, `ExplosionRequest`, `NetResult<T>`, `WeaponCategory`, `HitZone`, `WeaponConfig`, `ExplosiveConfig`, `ProjectileConfig`, `ExplosionParams`, `ExplosionResult`, `WorldEventPayload`, `ToolCategory`, `ToolConfig`, `NodeType`, `NodeConfig`, `NodeClientState`, `Ingredient`, `RecipeConfig`, `CraftingState`, `VendorId`, `VendorOfferMode`, `VendorOffer`, `VendorConfig`, `VendorTradeFeedback`, `LootDropEntry`, `LootTableConfig`, `NPCKind`, `NPCBehavior`, `NPCState`, `NPCConfig`.
- Runtime type-guards: `Types.IsFiniteNumber(val)`, `Types.IsValidInteger(val, min?, max?)`, `Types.IsValidString(val, minLen?, maxLen?)`, `Types.IsValidVector3(val, maxAbs?)`, `Types.IsValidInventorySlot(val)`, `Types.IsValidModuleType(val)`, `Types.IsValidBuildingTier(val)`, `Types.IsValidShotRequest(val)`, `Types.IsValidExplosionRequest(val)`, `Types.IsValidTransferPayload(val)`, `Types.IsValidBuildPlaceArgs(pieceType, position, rotY)` -> Валидация входящих сетевых аргументов и защита от `NaN`/`inf`.
- Константы: `INVENTORY_SIZE = 30`, `HOTBAR_SIZE = 6`, `MAX_GATHER_DISTANCE_SERVER = 14`, `MAX_GATHER_DISTANCE_CLIENT = 12`, `MAX_LOOT_DISTANCE = 14`, `MAX_BUILD_DISTANCE = 20`, `PING_DISTANCE_TOLERANCE = 2`, `MAX_ACTIVE_PROJECTILES_PER_PLAYER = 6`, `CURRENT_SCHEMA_VERSION = 9`, `CURRENT_DATA_VERSION = 9`.

### `Signal` (`src/shared/Signal.luau`) & `Janitor` (`src/shared/Janitor.luau`)
- `Signal.new<T...>(): Signal<T...>` -> Создание типизированного сигнала (`:Connect`, `:Once`, `:Fire`, `:Destroy`).
- `Janitor.new(): Janitor` -> Менеджер очистки ресурсов (`:Add`, `:Cleanup`, `:Destroy`).

### `Ballistics` (`src/shared/Ballistics.luau`)
- `Ballistics.IsIgnoredCharacterPart(inst: Instance): boolean` -> Пропускает аксессуары (`Accessory`), визуал оружия (`EquippedWeaponVisual`, `GunBody`/`GunBarrel`/`Muzzle`) и `HpBillboard`, исключая ложные и двойные попадания.
- `Ballistics.ClassifyHitZone(hitPart: BasePart): HitZone` -> Классифицирует часть тела (`"Head"`, `"Torso"`, `"Limb"`).
- `Ballistics.ComputePosition(origin, initialVelocity, gravity, elapsed): Vector3` -> Позиция снаряда по времени.
- `Ballistics.ComputeVelocity(initialVelocity, gravity, elapsed): Vector3` -> Мгновенная скорость снаряда.
- `Ballistics.ComputeCFrame(position, velocity): CFrame` -> Ориентация снаряда по вектору скорости.
- `Ballistics.Spawn(options: SpawnOptions): string` -> Запуск пошаговой симуляции снаряда на `Heartbeat` (с фильтрацией аксессуаров и пропов).
- `Ballistics.Cancel(projectileId: string): boolean` -> Досрочная отмена симуляции снаряда.
- `Ballistics.GetActiveCount(): number` -> Количество активных снарядов.

### `Net` (`src/shared/Net.luau`)
- `Net.Events`: включает базовые события и `RaidListRequest`, `RaidRefreshRequest`, `RaidListSync`, `StartRaidRequest`, `PlaceExplosiveRequest`, `RaidHudSync`, `RaidExtractRequest`, `RaidTcHackRequest`, `RaidAbandonRequest`, `RaidReportNotify`, `ProjectileSpawn`, `ExplosionEffect`, `VendorOpen`, `VendorTradeRequest`, `VendorStarterKitRequest`, `VendorTradeFeedback`, `RecyclerOpen`, `RecyclerClose`, `RecyclerAction`, `RecyclerStateSync`, `BlueprintSync`, `ResearchTableOpen`, `ResearchItemRequest`, `LearnBlueprintRequest`, `ResearchFeedback`.
- `Net.InitServer()` -> Создаёт папку `Remotes` и кэширует все `RemoteEvent`.
- `Net.GetEvent(eventName: string): RemoteEvent` -> Возвращает кэшированный `RemoteEvent`.

### Конфиги (`src/shared/configs/`)
- `Items.luau`, `Consumables.luau` (`ConsumableConfig` с опциональным полем `Stamina`: `cooked_meat` даёт `+25`, `water_bottle` даёт `+20`), `Tools.luau`, `Nodes.luau`, `Recipes.luau` (27 рецептов: Tier 0 — базовые инструменты/лук/стрелы/WB1 + `cook_meat` на станции `"campfire"`; Tier 1 — TC/пистолет/`pistol_ammo` x12/шипы/HQM/`satchel_charge`/WB2; Tier 2 — `shotgun_shell` x6/мина/`shotgun_trap`/`rocket`/WB3; Tier 3 — C4/ракетница/`auto_turret`), `Vendors.luau` (3 торговца Safe Hub: `recycler` со скупкой `<= 33.3%` от цены покупки/крафта, `weaponsmith`, `quartermaster` за `scrap`), `Weapons.luau` (`hunting_bow` с `ProjectileId = "arrow"`, `DrawMinTime = 0.25`, `DrawFullTime = 1.0`, `MinDamage = 18`, `Damage = 55`), `Projectiles.luau` (`rocket` с `StructureDamage = 250`, `PlayerDamage = 110` и `arrow` с `MinSpeed = 65`, `MaxSpeed = 145`, `Gravity = 48`), `Explosives.luau` (`satchel_charge = 125`, `c4_charge = 500`), `LootTables.luau` (`wooden_crate` Tier 1, `military_crate` Tier 2, `elite_crate` Tier 3, `airdrop`, `npc_rt_guard`, `npc_rt_scientist`, `animal_deer`, `animal_boar`, `animal_wolf`, `animal_bear`).
- `NPCs.luau`: конфиги боевых NPC РТ и диких животных (`rt_guard`, `rt_scientist`, `deer`, `boar`, `wolf`, `bear` — здоровье, скорости, радиусы обнаружения `45`/`25` и преследования `75`/`55..60`, параметры очередей/разброса/кровотечения, палитры, `LootTableId`, дефолтные `DefaultPatrolRadius` и `DefaultRespawnTime`).
- `Defenses.luau`: параметры защит (`floor_spikes = 100 HP`, `landmine = 40 HP / ExplosionStructureDamage = 100`, `shotgun_trap = 200 HP`, `auto_turret = 500 HP` — стоимость в очках, поверхность крепления, радиус, урон, время наведения, кулдаун, боеприпасы, `Defenses.Get`, `Defenses.GetCapacityLimit`).
- `BuildingConfig.luau`: `GridSize = 12`, `WallHeight = 10`, `WallBodyHeight = 9.2`, `Thickness = 0.8`, `FoundationThickness = 1.0`, `UpgradeRaidBlockSeconds = Config.Explosion.UpgradeRaidBlockSeconds` (`30` с), `Pieces` (20 модулей: структурные блоки, `storage_box`, `tool_cupboard` с `MaxPerBase = 1` и `StorageSlots = 12`, `workbench_1`/`workbench_2`/`workbench_3` с `RequiredBaseTier = 1/2/3`, штурмовые `assault_ladder`/`barricade`, защитные `floor_spikes`/`landmine`/`shotgun_trap = 200 HP`/`auto_turret = 500 HP`), `Tiers` (`wood`/`stone`/`metal`/`armored` с `HpMultiplier = 1/2/4/8`, `ExplosionResistance = 0.0`, апгрейд `armored` = `15 HQM + 40 metal_ore`).
- `BuildingConfig.ComputeExplosionDamage(rawDamage, pieceType, tier, hasDoor?): number` -> Единый расчёт взрывного сплэш-урона с учётом `Config.Explosion` (множитель тира, дверного проёма с установленной дверью и защитных конструкций).

### `BaseSerializer` (`src/shared/BaseSerializer.luau`)
- Формат бинарного буфера построек (`FORMAT_VERSION = 1`, `HEADER_SIZE = 7` байт, `BLOCK_STRIDE = 12` байт/блок, `MAX_BLOCKS = 200`):
  - Заголовок (`0..6`): `Version: u8` (`+0`), `BlockCount: u16` (`+1`), `CRC32: u32` (`+3`, IEEE `0xEDB88320` по всему буферу с нулями в `+3..+6`).
  - Запись блока (`12` байт): `QX: i16` (`+0`), `QY: i16` (`+2`), `QZ: i16` (`+4`) — локальные координаты относительно `originCFrame`, квантованные с шагом `0.25` studs; `RotStep: u8` (`+6`, `0..23`, шаг `15°`); `ModuleId: u8` (`+7`, таблица `BuildingConfig.PieceOrder`); `TierId: u8` (`+8`, `1..4`); `Hp: u16` (`+9`, `0..65535`); `StateMask: u8` (`+11`: `0x01` `HasCodeLock`, `0x02` `IsDoorOpen`, `0x04` `LinkedHbhfSensor`, `0x08` `HasDoor`, биты `4..5` `0x30` — `MountSurface` `0=nil, 1=Floor, 2=Wall, 3=Ceiling`).
- `BaseSerializer.PackBuffer(blocks, originCFrame?)` / `UnpackBuffer(buf, originCFrame?)` -> Прямая упаковка и распаковка `buffer` с проверкой длины, версии, лимита и `CRC32`.
- `BaseSerializer.EncodeBase64(buf)` / `DecodeBase64(encoded)` / `ComputeCRC32(buf)` -> Base64-кодирование/декодирование и контрольная сумма.
- `BaseSerializer.SerializeBase(blocks, originCFrame?) -> string` / `DeserializeBase(encoded, originCFrame?) -> (boolean, { BuildingBlockData } | string)` -> Сериализация/десериализация базы и чертежей в компактную Base64-строку.

### `BuildingGeometry` (`src/shared/BuildingGeometry.luau`)
- `BuildingGeometry.CanonicalPieceType(pieceType: string): BuildPieceType` -> Приводит алиасы типа модуля к каноническому `snake_case`.
- `BuildingGeometry.ComposeWorldCFrame(posX, posY, posZ, rotYDeg): CFrame` -> Собирает мировой `CFrame` с опорой на центре нижней плоскости (`Y = 0` локального этажа).
- `BuildingGeometry.GetPieceWorldCFrame(piece: SavedBuildPiece, originOffset: Vector3?): CFrame` -> Возвращает мировой `CFrame` постройки (с поддержкой legacy-координат).
- `BuildingGeometry.ComputeMaxHp(pieceType, tier): number` -> Вычисляет максимальный HP модуля с учётом множителя тира.
- `BuildingGeometry.CreateModel(pieceType, worldCF, isGhost, nameOverride?, mountSurface?): Model` (алиас `CreatePieceModel`) -> Создаёт примитивную модель (`Part`/`WedgePart`, включая `square_stairs`/`triangle_stairs` с плавным подъёмом `0 -> 5.0 -> 10.0` вровень с `WallHeight = 10`, `floor_spikes`, `landmine`, настенный/потолочный `shotgun_trap` и `auto_turret`) с `PrimaryPart` и `Pivot`.
- `BuildingGeometry.ApplyTierVisuals(model, pieceType, tier)` -> Применяет материал и цвет тира ко всем деталям модели (включая створку `DoorPanel`).
- `BuildingGeometry.SetDoorOpen(model, isOpen)` -> Открывает/закрывает примитивную створку `DoorPanel` в дверном проёме с обновлением CFrame и коллизий.
- `BuildingGeometry.AttachDoorPanel(model, worldCF, tier, isOpen?)` -> Создаёт или обновляет створку `DoorPanel` в `doorway` с материалом и цветом тира.
- `BuildingGeometry.SetGhostColor(model, color)` -> Окрашивает полупрозрачный фантом (`Green` / `Blue` / `Red`).
- `BuildingGeometry.GetPieceSockets(pieceType): { BuildSocketDef }` -> Список сокетов модуля (`Edge_1..N`, `Top`, `Center`, `WallTop`).
- `BuildingGeometry.IsSocketCompatible(parentType, socket, childType): boolean` -> Проверяет совместимость родительского сокета и дочернего модуля.
- `BuildingGeometry.GetSocketSlotKey(socket, childType, rotStep?): string` -> Ключ канала сокета для разделения стен и перекрытий.
- `BuildingGeometry.ComputeSnappedCFrame(parentType, parentWorldCF, socket, childType, rotStep?): CFrame` -> Вычисляет точный мировой `CFrame` дочернего модуля на сокете.
- `BuildingGeometry.GetOverlapBoxes(pieceType, worldCF, expandXZ?, mountSurface?): { BuildOverlapBox }` -> Возвращает уменьшенные (`0.85`) OBB-боксы модуля для проверки коллизий.
- `BuildingGeometry.IsNoBuildInstance(inst, allowRaidOutpostZone?)` / `CheckWorldOverlap(pieceType, targetCF, excludeInstances?, isDetachedFoundation, allowRaidOutpostZone?, mountSurface?)` -> Проверяет запрещённые зоны и коллизии с поддержкой строительства внутри `RaidOutpostZone` в рейде, блокировкой зон торговцев (`VendorHubZone`, `QA_VendorHubZone`) и учётом `RaidOutpostStructures`.

---

## 3. Серверные сервисы (`ServerScriptService.Server.Services`)

### `SecurityService` (`src/server/Services/SecurityService.luau`)
- `SecurityService.CheckRateLimit(player, remoteName, cost?): boolean` -> Token Bucket лимитер входящих пакетов.
- `SecurityService.IsFiniteNumber(val)` / `IsValidInteger(val, min?, max?)` / `IsValidString(val, min?, max?)` / `IsValidVector3(val, max?)` / `IsValidCFrame(val, max?)` -> Валидация типов и `NaN`/`inf`.
- `SecurityService.GetAliveCharacterRoot(player): (Model?, BasePart?, Humanoid?)` -> Проверка живого персонажа.
- `SecurityService.IsWithinDistance(player, targetPos, maxDist, pingTolerance?): boolean` -> Авторитетная проверка дистанции от `HumanoidRootPart`.
- `SecurityService.RunLocked(player, reason, fn): boolean` -> Выполнение транзакции под per-player мьютексом.
- `SecurityService.SetTeleportLock(player, locked)` / `IsTeleportLocked(player): boolean` -> Блокировка игрока на время телепортации.
- `SecurityService.SetActiveContainer(player, id, part)` / `ClearActiveContainer(player, id?)` / `IsActiveContainerOutOfRange(player, maxDist, tol?): boolean` -> Контроль дистанции открытого контейнера.
- `SecurityService.Init()` -> Инициализация лимитеров и очистки при выходе игрока.

### `DataService` (`src/server/Services/DataService.luau`)
- `DataService.CURRENT_SCHEMA_VERSION` (`9`) & `DataService.Migrations: { [number]: (data) -> () }` -> Цепочка чистых функций миграции `v1..v9` (`Base`/`BaseBlueprints` в бинарном формате `BaseSerializer` + `ContainerSidecar`, `SchemaVersion`, `Equipment`, `DefenseLogs`, `UnlockedBlueprints`, `MountSurface`, `BaseTier`/`LastUpkeepTimestamp`, `(PosX, PosY, PosZ)`).
- `DataService.MigrateProfileData(rawData): { [string]: any }` -> Последовательно обновляет профиль с версии `N` до `CURRENT_SCHEMA_VERSION` до вызова `Profile:Reconcile()`.
- `DataService.IsTransferring(player)` / `SetTransferring(player, locked)` / `IsTeleporting(player)` -> Управление флагом блокировки трансфера (блокирует мутации через `GetData`, `SetInventorySlot`, `SetField`, `UpdateProfile` на время межплейсового перехода).
- `DataService.GetData(player): PlayerData?` / `GetProfileSnapshot(player): PlayerData?` / `GetInventorySlot(player, slotIndex)` / `SetInventorySlot(player, slotIndex, slot): NetResult<InventorySlot?>` / `GetField(player, fieldName)` / `SetField(player, fieldName, value): NetResult<boolean>` / `UpdateProfile(player, mutator): NetResult<boolean>` -> Безопасные геттеры/сеттеры профиля с проверкой `IsTransferring` и валидацией полей.
- `DataService.OnDataLoaded(callback): Signal.Connection` -> Подписка на загрузку профиля.
- `DataService.OnBeforeUnload(callback)` -> Хук перед сохранением/выгрузкой профиля.
- `DataService.ReleaseForTeleport(player): boolean` / `RestoreAfterFailedTeleport(player): boolean` -> Безопасное освобождение и восстановление сессии `ProfileStore`.
- `DataService.RegisterRaidableBase(player)` / `GetRaidTargets(excludeUserId, limit)` / `GetPresetTier(targetUserId)` / `LoadBaseSnapshot(targetUserId)` -> Индексация и загрузка снимков баз для рейдов (включая `BaseTier`, пресеты `Tier 1/2/3`, `DangerLabel`, `RewardLabel`, `LaunchCost`).
- `DataService.RecordRaidDefenseReport(targetUserId, report)` / `ConsumeDefenseReports(player)` -> Запись и выдача отчётов о защите базы (без удаления реальной базы защитника).
- `DataService.Init()` -> Управление жизненным циклом профилей `ProfileStore`.

### `InventoryService` (`src/server/Services/InventoryService.luau`)
- `InventoryService.GetEquippedSlot(player): number` / `GetEquippedItem(player): Slot?` / `GetSlot(player, slotIndex): Slot?` -> Чтение слотов и активного предмета хотбара.
- `InventoryService.GetItemCount(player, id): number` / `HasItems(player, items): boolean` -> Подсчёт и проверка ресурсов.
- `InventoryService.CanCraftTransaction(player, ingredients, resultId, resultCount): boolean` -> Проверка вместимости инвентаря перед крафтом.
- `InventoryService.AddItem(player, id, count): number` / `AddItemToSlot(player, id, count, slot): number` / `AddItems(player, items)` -> Начисление предметов + `InventorySync`.
- `InventoryService.RemoveItem(player, id, count): boolean` / `RemoveItems(player, items): boolean` / `ConsumeSlot(player, slot, count): boolean` -> Атомарное списание предметов.
- `InventoryService.ClearInventory(player): Inventory` -> Полная очистка инвентаря (при смерти).
- `InventoryService.Init()` -> Обработка `InventoryMove` / `HotbarSelect`, репликация `EquippedItemId` и стартовый кит Studio (`building_plan`, `hammer`, ресурсы и оружие).

### `ResourceService` (`src/server/Services/ResourceService.luau`)
- `ResourceService.Init()` -> Обработка добычи `HitNode`, кулдауны, рассылка `NodeUpdated` и респавн нод.

### `CraftingService` (`src/server/Services/CraftingService.luau`)
- `CraftingService.RegisterStation(stationId, stationType, position, ownerUserId?)` / `UnregisterStation(stationId)` -> Учёт динамических и статических верстаков (`workbench_1`, `workbench_2`, `workbench_3` с иерархической совместимостью по тирам и проверкой владельца `OwnerUserId`) и костров (`campfire` из `Workspace.Campfires` и `QA_TestArena`).
- `CraftingService.GetPlayerWorkbenchTier(player, includePingTolerance?): number` -> Вычисляет максимальный уровень доступного игроку верстака в радиусе `Config.WORKBENCH_RADIUS` (`16` studs).
- `CraftingService.GetActiveCraft(player): CraftingState?` / `CancelCraftForPlayer(player, syncClient, bypassLock?)` -> Управление очередью крафта игрока.
- `CraftingService.Init()` -> Обработка `CraftRequest` (авторитетная проверка `GetPlayerWorkbenchTier(player, true) >= recipe.RequiredWorkbench` и близости к `Station`, включая `"campfire"`) / `CraftCancel`, отмена и возврат ингредиентов при выходе, смерти, телепорте или переполнении инвентаря на момент завершения, а также фоновая синхронизация атрибутов `WorkbenchTier` и `NearCampfire` игрока.

### `VendorService` (`src/server/Services/VendorService.luau`)
- `VendorService.SpawnBaseVendorHub()` / `DespawnBaseVendorHub()` -> Процедурный спавн безопасной зоны `VendorHubZone` (примитивы `Part`/`WedgePart`, теги `NoBuild` + `VendorHubZone`, 3 NPC-торговца с `ProximityPrompt`) в режиме `PlayerBase` (`BaseService.IsBaseMode()`) и скрытие/удаление при активном рейде (`RaidServerMode`).
- `VendorService.BindStaticVendorHub(container)` -> Регистрация статических NPC-торговцев из сцены (`QA_TestArena/Workbench_Vendor_Stand/QA_VendorHubZone`).
- `VendorService.Init()` -> Обработка `VendorOpen` и авторитетный обмен `VendorTradeRequest` (rate-limit, проверка дистанции, блокировка в рейде, `SecurityService.RunLocked`, проверка наличия предметов `HasItems` и свободного места `CanCraftTransaction`, атомарное списание/выдача с откатом частичного добавления при нехватке слотов и ответ `VendorTradeFeedback`).

### `SurvivalService` (`src/server/Services/SurvivalService.luau`)
- `SurvivalService.GetStats(player): SurvivalStats?` / `GetContainerState(containerId): LootContainerState?` -> Чтение статов выживания.
- `SurvivalService.GetStamina(player): number` / `AddStamina(player, amount)` / `ResetSprintState(player, refillStamina)` -> Управление выносливостью и сброс спринта/скорости при смерти, респавне и телепорте.
- `SurvivalService.ApplyBleeding(player, duration, dps)` / `ClearBleeding(player)` -> Наложение и снятие статуса кровотечения (периодический урон в цикле выживания, атрибут `Bleeding`, снятие бинтом `bandage` и при респавне).
- `SurvivalService.Init()` -> Тик выживания (`2.0` с: расход голода/жажды заморожен на `PlayerBase` вне рейда, смертельный урон при `0%` отключён; при `Hunger >= 70` и `Thirst >= 70` и отсутствии урона `>= 8` с — пассивный реген `+1 HP` каждые `3` с и атрибут `WellFed`), обработка `UseConsumable` (с бонусом стамины), серверный цикл `Heartbeat` спринта/стамины (`SprintStateRequest`, переключение `WalkSpeed` `16 <-> 24` с учётом `SlowMultiplier`, репликация `Stamina` / `IsSprinting` / `StaminaExhausted`, восстановление `20` / `12` / `6` в сек, порог выхода из истощения `20%`) и спавн рюкзака лута при смерти.

### `LootService` (`src/server/Services/LootService.luau`)
- `LootService.RollLootTable(tableId, mapTierOverride?): Inventory` -> Генерация лута по весам `LootTables` с масштабированием количества ресурсных предметов через `Config.MapLootScaling` (`Workspace:GetAttribute("MapTier")` = `1.0 / 1.35 / 1.75`) и поддержкой `elite_crate`.
- `LootService.RegisterSlotsContainer(...)` / `RegisterStorageContainer(...)` / `SpawnTemporaryContainer(...)` -> Регистрация временных и постоянных контейнеров с `ProximityPrompt`.
- `LootService.UnregisterContainer(containerId)` / `DestroyContainer(containerId)` -> Удаление контейнера.
- `LootService.OpenContainerForPlayer(player, containerId): boolean` / `CloseContainerForPlayer(player, notifyClient)` -> Открытие/закрытие контейнера с проверкой дистанции.
- `LootService.GetContainerState(containerId)` / `IsContainerDepleted(containerId): boolean` / `DepositToStorageContainer(containerId, itemId, count): number` / `ClearContainerSlots(containerId)` -> Чтение состояния, пополнение и очистка хранилищ.
- `LootService.Init()` -> Наполнение POI-ящиков, обработка `LootTakeSlot` / `ContainerDepositSlot`.

### `WorldEventService` (`src/server/Services/WorldEventService.luau`)
- `WorldEventService.TriggerAirdropNow(descentTimeOverride?): Model` -> Немедленный запуск Supply Drop.
- `WorldEventService.GetActiveAirdropModel(): Model?` / `GetActiveAirdropContainerId(): string?` -> Состояние активного аирдропа.
- `WorldEventService.Init()` -> Цикл Supply Drop раз в `420` с.

### `CombatService` (`src/server/Services/CombatService.luau`)
- `CombatService.GetEquippedWeapon(player): (string, WeaponConfig)` -> Активное оружие игрока.
- `CombatService.Init()` -> Обработка `AttackRequest` с унифицированной серверной проверкой точки атаки (`validateAttackOrigin`), дистанции и anti-rapidfire (`SecurityService.LogSuspicious`), зональными множителями урона (`Head` = `HeadshotMultiplier`, `Torso` = `1.0x`, `Limb` = `0.75x`), защитой от двойной регистрации (`hitTargets` + пропуск аксессуаров), секторной проверкой ближнего боя с отсечкой через стены/двери (`performServerMeleeSweep`), баллистическими снарядами (`Ballistics.Spawn`) и уроном по постройкам `BaseService`/`RaidService.DamageRaidPiece`.

### `NPCService` (`src/server/Services/NPCService.luau`)
- `NPCService.GetActiveCount(): number` -> Количество активных NPC и животных на карте.
- `NPCService.SpawnFromMarker(marker: BasePart): Model?` -> Спавн примитивной (`Part`/`WedgePart`) модели NPC/животного с `Humanoid`, `Janitor` и скрытой до первого урона полоской HP (`HpBillboard`) по маркеру из `Workspace.NPCSpawns`.
- `NPCService.DespawnAll()` -> Принудительная очистка всех активных NPC, потоков очередей (`ActiveBurstThread`) и таймеров респавна (вызывается при выходе последнего игрока или при `RaidServerMode == true`).
- `NPCService.Init()` -> Работает только на `MainMap` при наличии активных игроков; управляет ИИ охранников/учёных РТ (задержка реакции `0.4–0.6` с, сужающийся разброс очереди `FirstShotSpreadMultiplier`, магазин и перезарядка `MagazineSize`/`ReloadDuration`, проверка LOS перед каждым выстрелом), мирных животных (`deer`, `boar` со скорингом безопасных векторов побега от игрока) и хищников (`wolf`, `bear` с детектором застревания, обходом препятствий и `SurvivalService.ApplyBleeding`), а также спавном лут-мешка через `LootService.RegisterSlotsContainer` и респавном по `RespawnTime`.

### `ExtractionService` (`src/server/Services/ExtractionService.luau`)
- `ExtractionService.CanAccessMap(player, mapKey, playerBaseTier): (boolean, string?)` -> Проверка допуска к PvP-карте (`MainMap_Tier1/2/3`) по `BaseTier` игрока.
- `ExtractionService.GetExtractionState(player): ExtractionState?` / `IsInCombatCooldown(player): boolean` -> Статус эвакуации игрока.
- `ExtractionService.RecordDamage(player)` -> Сброс таймера эвакуации при получении урона.
- `ExtractionService.Init()` -> Проверка зон эвакуации и телепорт на `PlayerBase`.

### `BuildingValidator` (`src/server/Services/BuildingValidator.luau`)
- `BuildingValidator.ComputeDefenseCapacity(pieces, baseTier): (number, number)` -> Подсчёт использованного и максимального бюджета `DefenseCapacity`.
- `BuildingValidator.QuantizeSocketWorldKey(worldPos: Vector3, slotCategory: string): string` -> Квантованный мировой ключ сокета для защиты от двойного занятия общей грани.
- `BuildingValidator.GetWorldSocketKeyForPiece(pieceType, worldCF): string` -> Возвращает мировой ключ слота для размещённого модуля.
- `BuildingValidator.RegisterOccupationsForRecord(record, playerRecords, occupiedSockets, occupiedWorldKeys)` / `UnregisterSocketsForPiece(uid, occupiedSockets, occupiedWorldKeys)` -> Регистрация и освобождение занятых сокетов (включая смежные грани и квантованные мировые ключи).
- `BuildingValidator.HasSupportingWallOnEdges(anchorEntry, playerRecords, occupiedSockets): boolean` -> Проверяет наличие несущей стены на гранях перед установкой перекрытия.
- `BuildingValidator.CheckParallelWallStacking(targetType, targetCF, allRecordsByUid): (boolean, string?)` -> Блокирует установку параллельных стен (угол между нормалями `< 15°`, радиус `6` studs, расстояние `< 3.5` studs).
- `BuildingValidator.IsInRaidOutpostZone(pieceType, targetCF): boolean` -> Проверяет попадание постройки в зону рейд-кибитки (`RaidOutpostZone`).
- `BuildingValidator.CheckMaxWallsToTC(playerRecords, occupiedSockets, candidatePiece?, excludeUid?): (boolean, string?, number?)` (и совместимая обёртка `CanReachToolCupboard`) -> Взвешенный 0-1 BFS по графу сокетов `BuildingGeometry` от внешнего периметра и открытого неба до блока с `tool_cupboard`: открытые грани, проёмы `doorway` без двери и открытые лестничные переходы на смежный верхний этаж имеют вес `0`; глухие стены (`wall`, `window_wall`), двери (`HasDoor == true`) и сплошные вертикальные перекрытия (`hasImmediateCeiling` и верхняя крыша `hasAnyOverheadRoof` для многоэтажных шахт) дают `+1` слой (сплошной потолок над лестницей не обходится, смежный переход учитывает стены на обоих уровнях, `excludeUid` используется для проверки сноса лестниц). Разрешает глухие Rust-бункеры при условии `minLayers <= Config.MAX_TC_WALL_LAYERS` (`2`).
- `BuildingValidator.FindUnsupportedPieces(pieces, removedUids?): { string }` -> BFS-проверка конструктивной устойчивости от фундаментов (`foundation`, `triangle_foundation`), штурмовых/дворовых установок и независимых пресетных объектов (включая опору на стены, перекрытия с лимитом консоли `floorDepth <= 1` без прямой опоры перекрытия на фундамент, лестницы и навесные/напольные модули); возвращает список потерявших опору `Uid`.
- `BuildingValidator.CheckWorldOverlap(pieceType, targetCF, excludeInstances?, isDetachedFoundation, allowRaidOutpostZone?, mountSurface?)` -> Проверяет `Workspace:GetPartBoundsInBox` с хитбоксом `0.85` против построек, игроков и запрещённых зон (`POI`, `ExtractionZones`, `AirdropZones`, `ResourceNodes`, `Workbenches`, `RaidTerminal`, `RaidOutpostZone`, `VendorHubZone`, `QA_VendorHubZone`).
- `BuildingValidator.ValidatePlacement(input)` -> Полная серверная валидация размещения блока и защитных установок (`IsDefense`: бюджет `DefenseCapacity` только для ловушек/турелей, запрет в рейде и `RaidOutpostZone`, проверка поверхности крепления `Floor`/`Wall`/`Ceiling`, анти-киллбокс дистанция `MIN_TURRET_DISTANCE = 14` между `auto_turret`, `MIN_TRAP_DISTANCE = 6` для `shotgun_trap` и коллизии).

### `DefenseService` (`src/server/Services/DefenseService.luau`)
- `DefenseService.BindRaidHooks(hooks)` -> Привязка `RaidService.TriggerExplosion` и `RaidService.NotifyRaiderDamaged` без циклических зависимостей.
- `DefenseService.RegisterDefense(options)` / `UnregisterDefense(uid)` / `UpdateDefenseHp(uid, hp, maxHp?)` / `DisableTurretsInRadius(origin, radius, duration)` -> Реестр активных ловушек и турелей для `PlayerBase`, рейд-инстансов и `Workspace.QA_TestArena`, включая ЭМИ-отключение (`DisabledUntil`, `EmpDisabled`, эффект `TurretEmp`).
- `DefenseService.GetActiveCount(): number` -> Количество активных защитных установок.
- `DefenseService.Init()` -> Управление `ProximityPrompt` загрузки/выгрузки патронов (`DefenseSync` / `DefenseAction`), цикл `Heartbeat` сканирования целей с проверкой иммунитета владельца на `PlayerBase` и временной спавн-неуязвимости рейдера (`ForceField` / `RaidInvulnerable`), повторная проверка `RaycastParams` LoS прямо перед списанием патрона у `auto_turret` и `shotgun_trap` (отсечка очереди при уходе за укрытие/дверь или при пересечении дыма `SmokeVolume`), проверка `pivot -> muzzle` и LoS сквозь стены у `floor_spikes` и `landmine`, а также установка атрибута `SlowMultiplier` на `Humanoid` при замедлении для корректной работы со скоростью спринта.

### `BaseService` (`src/server/Services/BaseService.luau` + `src/server/Services/Base/`)
- Декомпозиция подмодулей:
  - `Base/BaseUpkeep.luau` -> Расчёт `BaseTier`, часового содержания, `ProcessUpkeepAndDecay`, начисление `Scrap` в TC (`DepositScrapToToolCupboard`), эвакуированного лута (`DepositItemsToPlayerBase`), синхронизация флагов моделей (`SyncPieceStatesFromModels`), обёртки `PackBaseSnapshot`/`UnpackBaseSnapshot` и валидация загруженных блоков `ValidateLoadedBasePieces` (`MaxBlocks`, `MaxPerBase`, `IsInRaidOutpostZone`, `CheckParallelWallStacking`, `CheckWorldOverlap`, `FindUnsupportedPieces`).
  - `Base/BaseBlueprints.luau` -> Сохранение/загрузка `BaseBlueprints` через бинарный формат `BaseSerializer` (`EncodedBlocks`) с автомиграцией legacy-слотов.
  - `Base/BaseGhosts.luau` -> Спавн и сессионная очистка призраков павших рейдеров (`SpawnSessionDeathGhosts`, `ClearSessionGhosts`, `SessionGhostsJanitor`).
- `BaseService.GetBaseOrigin(player?)` / `SerializePlayerBase(player)` / `LoadSerializedBase(player, encoded)` -> Получение центра участка, упаковка и валидированная загрузка бинарного снимка базы.
- `BaseService.ComputeHourlyUpkeep(pieces): { [string]: number }` -> Расчёт часового расхода ресурсов на содержание базы по тирам блоков.
- `BaseService.ComputeBaseTier(pieces, hasActiveTc): number` -> Серверный расчёт `BaseTier` (`0..3`) по наличию TC и количеству/тиру несущих конструкций.
- `BaseService.GetPlayerBaseTier(player): number` -> Текущий `BaseTier` игрока.
- `BaseService.BuildToolCupboardState(player): ToolCupboardState?` -> Сборка состояния шкафа (слоты, статус `Protected`/`Decaying`, `ProtectedHours`, статус слоёв защиты TC по `CheckMaxWallsToTC`, бюджет `DefenseUsed`/`DefenseMax`).
- `BaseService.ProcessUpkeepAndDecay(player, elapsedSeconds): boolean` -> Делегирует в `BaseUpkeep`: списание ресурсов из TC или нанесение периодического урона гниения по внешним блокам (с оффлайн-пересчётом по `os.time()` при входе и тиком каждые `60` с) с каскадным обрушением потерявших опору конструкций (`BuildingValidator.FindUnsupportedPieces`) и пересчётом `BaseTier`.
- `BaseService.IsBaseMode(): boolean` / `CanBuild(player): boolean` -> Проверка разрешения на строительство.
- `BaseService.DamagePiece(uid, rawDamage, damageKind, attacker?): (boolean, boolean)` -> Нанесение урона постройке (для `"Explosion"` — через `BuildingConfig.ComputeExplosionDamage`) с записью `LastDamagedAt = os.clock()`, каскадным обрушением зависимых блоков и пересчётом `BaseTier` при разрушении.
- `BaseService.GetLivePieceModelsInRadius(origin, radius)` / `GetPlayerPieces(player)` / `GetStorageContainerId(player, uid)` / `DepositItemsToPlayerBase(player, items)` -> Доступ к постройкам игрока и перенос эвакуированного лута в инвентарь и `storage_box` профиля.
- `BaseService.Init()` -> Спавн базы (включая `ProximityPrompt` для TC, регистрацию верстаков `workbench_1/2/3` и активных защит в `DefenseService`), обработка `BuildPlaceRequest` (из `BuildingPlan` и предметов `workbench_1/2/3`, `tool_cupboard`, `IsDefense` в хотбаре; проверка требуемого верстака при постройке защиты из сырых ресурсов; игнорируется при `InRaid == true`), `BuildUpgradeRequest`, `BuildRepairRequest` (ремонт киянкой), `BuildDemolishRequest` (с проверкой `CheckMaxWallsToTC` при сносе лестниц, запретом сноса несущих опор при непустом `BuildingValidator.FindUnsupportedPieces`, проверкой свободного слота инвентаря и возвратом снятой защиты и её боезапаса), `ToolCupboardAction`, `RequestReturnToMap`, `BuildFeedback` и фоновый цикл Upkeep/Decay.

### `RaidService` (`src/server/Services/RaidService.luau` + `src/server/Services/Raid/`)
- Декомпозиция подмодулей:
  - `Raid/RaidIntel.luau` -> Телеметрия баз (`ComputeBaseIntel`), генерация пресет-баз (`BuildPresetBaseForTarget`), пул 3 карточек разведки и бесплатный/платный реролл (`GetIntelPool`, `RefreshIntelPool`).
  - `Raid/RaidExplosives.luau` -> Визуал взрывчатки (`CreateExplosiveVisual`), окклюзия (`HasExplosionLineOfSight`), расчёт AoE-взрыва (`TriggerExplosion`), детонация (`DetonateExplosive`), а также тактические гаджеты (`TriggerEmpPulse`, `TriggerSmokeCloud`).
  - `Raid/RaidOutpost.luau` -> Спавн рейд-кибитки (`SpawnRaidOutpost`), `ExtractionStash` (с `StashExtractPrompt` запуска экстракции на `F`), `RaidSupplyCrate`, терминал эвакуации и сбор лута (`CollectStashBatch`, `SpawnDroppedLootBag`).
- `RaidService.HasExplosionLineOfSight(blastOrigin, targetModel, excludeInstances?, isCharacterTarget?): boolean` -> Прокси в `RaidExplosives`: многоточечная проверка окклюзии взрыва (9 точек для стен/квадратов с косяками и створкой `DoorPanel`, 7 точек для треугольников).
- `RaidService.TriggerExplosion(params: ExplosionParams): ExplosionResult` / `TriggerEmpPulse` / `TriggerSmokeCloud` -> Прокси в `RaidExplosives`: расчёт AoE-взрыва с единой формулой `BuildingConfig.ComputeExplosionDamage`, игнорированием целей с активной спавн-неуязвимостью (`ForceField` / `RaidInvulnerable`), обновлением 30с таймера блок-апгрейда (`LastDamagedServerTime = Workspace:GetServerTimeNow()`), каскадным разрушением потерявших опору блоков рейд-базы (`BuildingValidator.FindUnsupportedPieces`), `NotifyRaiderDamaged`, ЭМИ-импульсом (`18` studs, `10` сек по турелям и умным дверям без урона) и дымовым облаком (`15` сек, `CanCollide = false`, `CanQuery = true`, `SmokeVolume`).
- `RaidService.DamageRaidPiece(uid, rawDamage, damageKind, attacker?)` / `NotifyRaiderDamaged(player)` -> Урон оружием по рейд-постройкам (с резервным триггером сигнализации) и срыв взлома TC при получении урона.
- `RaidService.EnterStudioMockRaid(player, targetUserId): boolean` / `IsPlayerInRaid(player): boolean` / `GetActiveSessionInfo(player): RaidHudState?` -> Управление рейд-сессией: спавн базы цели (снепшот или пресет Tier 1/2/3 с лутом из `Config.Raid.Tiers[tier].PresetTcLoot`/`PresetBoxLoot` и активными ловушками/турелями с `BaseHp` из `BuildingConfig`), спавн префаба рейд-кибитки в `RaidOutpostZone` (`RaidOutpostStructures`: каркас, `workbench_1`, `OutpostRespawnPad` с 3 жизнями, быстрым респавном `<= 1.5` с через `LoadCharacter()` и 2-секундной неуязвимостью `ForceField`, `ExtractionStash`, стартовый мед-контейнер `RaidSupplyCrate`, `ExtractionTerminal`), временная стройка рейдера, захват/уничтожение вражеского TC (`TcHackPrompt` 10 сек), 18-секундный отсчёт эвакуации у `ExtractionStash` с базовой сиреной и логированием маршрута для `BaseGhosts` (лут остаётся в `ExtractionStash` и уходит защитнику при гибели/провале рейдера), а также онлайн-сигнализация владельцу базы (`MessagingService` + локальная проверка, 15с вызов, 6с подготовка, телепорт к TC и выдача боекомплекта; отключена в `Self-Raid`).
- `RaidService.Init()` -> Обработка `RaidListRequest`, `StartRaidRequest` (доступ с `PlayerBase`/`MainMap`/Studio, проверка `attackerBaseTier >= targetBaseTier`, списание/возврат `LaunchCost`), `BuildPlaceRequest` (в рейде), `PlaceExplosiveRequest`, `RaidTcHackRequest`, `RaidExtractRequest`, `RaidAbandonRequest`, `RaidAlarmResponse`, подписка `MessagingService` и выдача `RaidReportNotify`.

---

## 4. Клиентские контроллеры (`StarterPlayer.StarterPlayerScripts.Client.Controllers`)

- `InventoryController`: `.Changed`, `.GetInventory()`, `.GetSlot(slotIndex)`, `.OnChanged(cb)`, `.RequestMove(from, to)`, `.Init()`.
- `HotbarController`: `.SelectionChanged`, `.SelectSlot(slotIndex)`, `.GetSelectedSlot()`, `.Init()`.
- `InventoryUIController`: `.OpenChanged`, `.IsOpen()`, `.SetOpen(open)`, `.Toggle()`, `.Init()`.
- `CraftingController`: `.OpenChanged`, `.IsOpen()`, `.SetOpen(open)`, `.Toggle()`, `.GetActiveCraft()`, `.GetWorkbenchTier()`, `.Init()` — отслеживает атрибуты `WorkbenchTier` и `NearCampfire` игрока, отображает HUD-плашку `Workbench Level 1 / 2 / 3`, фильтрует рецепты (`All`, `Avail`, `T0..T3`), поддерживает рецепты со станцией `"campfire"` (`[Requires Campfire]`) и блокирует недоступные крафты (`WB X` / `Campfire`).
- `VendorController`: `.OpenChanged`, `.IsOpen()`, `.GetActiveVendorId()`, `.SetOpen(open)`, `.Init()` — окно торговли `VendorGui` по `VendorOpen` (отображение баланса `Scrap`, офферов `BUY`/`SELL` с кнопками `x1`/`x5`, баннер `VendorTradeFeedback`, автозакрытие при отходе или открытии других меню).
- `GatheringController`: `.GetNodeState(nodeId)`, `.IsCursorOnActiveNode()`, `.Init()`.
- `SurvivalHudController`: `.Init()` — отображает полосы HP (с индикацией `(Well Fed)`), голода, жажды, выносливости (`StaminaBar` с цветом истощения `StaminaExhausted`) и пульсирующий бейдж кровотечения (`BLEEDING - Use Bandage`) по атрибуту `Bleeding`.
- `MovementController`: `.Init()` — управление запросом спринта (`LeftShift` на ПК + сенсорная кнопка-переключатель `SPRINT` при `TouchEnabled`), очистка состояния персонажа через `Janitor` и отправка `SprintStateRequest` при движении (`MoveDirection.Magnitude > 0.1`) и достаточной стамине.
- `ConsumableController`: `.Init()`.
- `LootController`: `.OpenChanged`, `.IsOpen()`, `.GetActiveContainerId()`, `.CanDeposit()`, `.RequestDeposit(playerSlot)`, `.Close()`, `.Init()`.
- `CombatController`: `.Init()` — динамический прицел, хитмаркер, отдача камеры с плавным возвратом (`BindToRenderStep` после камеры), динамический разброс (движение / прыжок / присед на `LeftControl`), натяжение лука (ЛКМ hold/release, порог `DrawMinTime`, индикатор под прицелом) и блокировка выстрелов при открытых меню (`VendorController`, `ToolCupboardController`, инвентарь, крафт, лут, турель, рейд).
- `ProjectileController`: `.SpawnLocalProjectile(id, origin, dir, char, speedOverride?): string`, `.GetActiveVisualCount(): number`, `.Init()` — параболический рендер и визуальный шлейф (`Trail`) для ракет (`Rocket`), примитивных стрел (`Arrow` — застревание с плавным затуханием в статичных стенах и скрытие корпуса при попадании в живых персонажей/NPC) и тактических гранат (`emp_grenade`, `smoke_grenade` с ЭМИ-волной и вспышкой дыма).
- `WorldEventController`: `.IsBannerVisible(): boolean`, `.GetActiveBeaconCount(): number`, `.Init()`.
- `ExtractionController`: `.IsVisible(): boolean`, `.GetState(): ExtractionState?`, `.Init()`.
- `BuildingController`: `.IsBaseMode()`, `.CanBuild()`, `.IsBuildMode()`, `.SetBuildMode(enabled)`, `.GetPieces()`, `.Init()` — активация по экипировке `building_plan` (превью размещения), `hammer` (апгрейд/ремонт повреждённых объектов и снятие/демонтаж по ЛКМ/ПКМ и клавишам) или ловушек/турелей из хотбара; кэшированный `RaycastParams`; фантом через `BuildingGeometry.CreateModel` с подсветкой **зелёный** / **синий** / **красный**, поддержкой крепления `Floor`/`Wall`/`Ceiling` и клиентской проверкой анти-киллбокс дистанции (`14` / `6` studs); панель `BaseActionBar` с индикатором `DefenseCapacity` и палитра из 20 модулей.
- `ToolCupboardController`: `.IsOpen()`, `.Close()`, `.GetState()`, `.Init()` — окно Tool Cupboard (12 слотов содержания, быстрый депозит ресурсов `wood`/`stone`/`metal_ore`/`high_quality_metal`, отображение `BaseTier`, статуса `Protected`/`Decaying`, расхода в час, количества слоёв защиты TC (`<= 2`) и текущего бюджета `DefenseCapacity`).
- `DefenseController`: `.IsOpen()`, `.Close()`, `.Init()` — окно загрузки/выгрузки боезапаса для `auto_turret` и `shotgun_trap` (`DefenseSync` / `DefenseAction`), отображение прочности и `DefenseCapacity`, рендер трассеров, лазера наведения, ЭМИ-искр (`TurretEmp`) и звуковых эффектов по `DefenseEffect`.
- `RaidController`: `.IsInRaid()`, `.IsSelectionOpen()`, `.GetHudState()`, `.OpenTargetList()`, `.CloseTargetList()`, `.Init()` — интерфейс Рейд-терминала (фильтры `Tier 1/2/3`, отображение опасности, награды, стоимости запуска, блокировка при недостаточном `BaseTier`), расширенный рейд-HUD (таймер, жизни, `ExtractionStash`, прогресс захвата TC, 18с обратный отсчёт экстракции, кнопки `Extract`/`Abandon`), баннер тревоги `RaidAlarmFrame` (`15`с) + экран подготовки `DefensePrepOverlay` (`6`с) по `RaidAlarmNotify` и уведомления `RaidReportNotify`.

---

## 5. Тестовые стенды в Studio (`Workspace.QA_TestArena`)
- `Workbench_Vendor_Stand` — стенд проверки радиуса верстаков (`16` studs) и безопасной зоны торговцев (`Part`/`WedgePart`):
  - `Workspace.Workbenches`: `QA_WB_Tier1` (`workbench_1`), `QA_WB_Tier2` (`workbench_2`), `QA_WB_Tier3` (`workbench_3`), разнесённые на 35 studs друг от друга с визуальными неоновыми кольцами радиуса `16` studs (включая обновлённое `StationRing_Workbench_16` в `Sector3_CraftingAndSurvival`).
  - `QA_VendorHubZone` (теги `NoBuild` + `VendorHubZone`): 3 примитивных NPC-торговца (`Vendor_recycler`, `Vendor_weaponsmith`, `Vendor_quartermaster`) с `ProximityPrompt`.
- `Sector4_BuildingAndRaid.QA_MixedBunker` — смешанный квадратно-треугольный тестовый бункер в `QA_TestArena` (примитивы `Part`/`WedgePart`, без `MeshPart`/`UnionOperation`): фундаменты `F1`/`F2` (`foundation`) + `T1`/`T2` (`triangle_foundation`), стены и проёмы `doorway` с открытой/закрытой створкой `DoorPanel` всех 4 тиров (`wood`/`stone`/`metal`/`armored`), внутренняя перегородка для теста окклюзии взрыва, лестницы `F1_SquareStairs` и `T1_TriangleStairs` (вровень с 2-м этажом `F2_UpperFloor`/`T2_UpperTriangleFloor`/`F2_UpperRoofCap`) и табличка `Sign_MixedBunker`.
- `Sector5_CombatRange.BowRangeTargets` — стенд для проверки баллистики лука (примитивы `Part`, без `MeshPart`/`UnionOperation`): 3 мишени `BowTarget_20s`, `BowTarget_50s`, `BowTarget_100s` (20 / 50 / 100 studs от `FiringLine`) с `Humanoid` + `Head` (центр мишени для проверки хедшота и падения траектории) и информационная табличка `BowRange_Sign`.
- `Sector5_CombatRange.CombatHitboxRange` — тир для проверки хитбоксов, отдачи/разброса и отсечки сквозь укрытия (примитивы `Part`, без `MeshPart`/`UnionOperation`): 3 анатомических манекена `HitboxDummy_15s`, `HitboxDummy_40s`, `HitboxDummy_80s` (`Head` 2.0x / `UpperTorso`+`LowerTorso` 1.0x / `LeftArm`+`RightArm`+`LeftLeg`+`RightLeg` 0.75x) на 15 / 40 / 80 studs от `FiringLine`, стенд `CoverTestWall` + `CoverTestDummy` (для теста отсечки ближнего боя и турелей) и табличка `HitboxRange_Sign`.
- `Workspace.NPCSpawns`, `Workspace.Campfires` и `Sector5_CombatRange.QA_NPC_TestArenaZone`:
  - 10 маркеров спавна на `MainMap` (охранники и учёные у `RadioTower`/`Warehouse`, олени/кабаны/волки/медведь в открытых зонах) и 6 тестовых маркеров на площадке `QA_NPC_TestPad` в `QA_TestArena` (`rt_guard`, `rt_scientist`, `deer`, `boar`, `wolf`, `bear`).
  - Костры с атрибутом `StationType = "campfire"` (`Workspace.Campfires.MainMap_Campfire_1` и `Sector3_CraftingAndSurvival.QA_Campfire`) для жарки `raw_meat` -> `cooked_meat`.
- `Workspace.QA_TestArena.TacticalGadgetsStand` (примитивы `Part`/`WedgePart`, рядом с `DefenseTestStand`, `1810, 0.4, 2187`) — стенд проверки тактических гаджетов против активной турели: `QA_Tactical_AutoTurret` (`IsQaDefense = true`, `PieceType = "auto_turret"`, `DefenseUid = "qa_tactical_turret"`, `InitialAmmo = 64`), `QA_Tactical_SmartDoor` (`HasDoor = true`, `IsSmartDoor = true`, створка `DoorPanel` + `DoorIndicator`), неоновое кольцо `EmpRadiusRing_18` радиуса `18` studs, укрытие `CoverWall`/`CoverButtress`, линия броска `FiringLine` (`26` studs от турели) и табличка `SignBoard`.

---

## 6. Справочная таблица математического баланса

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
- **Торговцы (`recycler` vs `weaponsmith`/`quartermaster`):** курс скупки равен `30.0–33.3%` от стоимости покупки (`<= 35%`), скупка `10 high_quality_metal -> 14 scrap` ниже цены крафта (`40 metal_ore + 20 scrap`), исключая бесконечный фарм/арбитраж.
- **Масштабирование карт (`Config.MapLootScaling`):** `MainMap_Tier1 = 1.0x`, `MainMap_Tier2 = 1.35x`, `MainMap_Tier3 = 1.75x` (применяется к ресурсам в `LootService.RollLootTable`), таблицы ящиков прогрессируют от `wooden_crate` (Tier 1) к `military_crate` (Tier 2) и `elite_crate` (Tier 3).
- **Рейд-терминал (`Config.Raid.Tiers`):**
  - `Tier 1`: вход `30 scrap` -> пресетная база приносит `250 wood, 150 stone, 180 scrap, 120 metal_ore, 3 tech_parts, 24 pistol_ammo, 5 cooked_meat`.
  - `Tier 2`: вход `75 scrap + 40 metal_ore` -> пресетная база приносит `320 scrap, 320 metal_ore, 8 tech_parts, 2 satchel_charge, 48 pistol_ammo`.
  - `Tier 3`: вход `140 scrap + 2 tech_parts` -> пресетная база приносит `500 scrap, 75 high_quality_metal, 16 tech_parts, 2 c4_charge, 3 rocket`.

---

## 7. Переработчик (Recycler) и Система чертежей (Blueprints / Research Table)

### Переработчик (`RecyclerService` + `Recycling` + `RecyclerController`)
- **Конфигурация (`src/shared/configs/Recycling.luau`, `Config.Recycler`):**
  - Базовая таблица выходов (`~50%` от стоимости крафта) для компонентов (`tech_parts`), оружия, взрывчатки, боеприпасов (с `BatchSize`), ловушек, инструментов и деплойаблов.
  - Коэффициент эффективности задаётся атрибутом `EfficiencyMultiplier`:
    - **РТ на `MainMap` (`1.2` -> `60%` выхода):** `Workspace.POI.RadioTower.RT_Recycler_RadioTower` и `Workspace.POI.Warehouse.RT_Recycler_Warehouse`.
    - **Безопасная зона `PlayerBase` (`0.8` -> `40%` выхода):** `SafeRecycler` внутри динамического `VendorHubZone` (спавнится `VendorService.SpawnBaseVendorHub`).
- **Серверная очередь (`src/server/Services/RecyclerService.luau`):**
  - `6` входных слотов (`InputSlots`) -> `6` выходных слотов (`OutputSlots`), переработка по `1` предмету (или `BatchSize`) каждые `3.0` сек (`Config.Recycler.TickInterval`).
  - Авто-остановка при опустошении входа или заполнении всех слотов выхода (проверка `canFitAllOutputs` до списания).
  - На РТ переработчик общий для всех игроков; при работе (`IsRunning = true`) активируются `Neon`-индикатор + `PointLight` и пространственный звук (`action_falling.ogg` в цикле, `impact_explosion_03.mp3` на тике завершения).
- **Клиент (`src/client/Controllers/RecyclerController.luau`):** окно `RecyclerGui` с отображением эффективности (`RT 60% Yield` / `Safe 40% Yield`), перехватом кликов инвентаря (`InventoryUIController.RegisterSlotInterceptor`) для депозита, кнопкой `Turn On / Turn Off` и `Take All Output`.

### Чертежи и Стол исследований (`BlueprintService` + `BlueprintController`)
- **Профиль и миграция (`Types.luau`, `DataService.luau`):**
  - `CURRENT_DATA_VERSION` повышен с `4` до `5`; добавлено поле `PlayerData.UnlockedBlueprints: { [string]: boolean }` и шаг миграции `v4 -> v5` (`deserializeBlueprints`).
- **Рецепты и предметы (`Recipes.luau`, `Items.luau`, `LootTables.luau`):**
  - В `RecipeConfig` добавлены `RequiresBlueprint: boolean` и `ResearchCost: number`.
  - Базовые рецепты (Tier 0, `tool_cupboard`, `high_quality_metal`, `workbench_1..3`, `research_table`) открыты по умолчанию (`RequiresBlueprint = false`).
  - Tier 1 (`75` Scrap), Tier 2 (`250` Scrap) и Tier 3 (`500` Scrap) рецепты требуют изученного чертежа (`RequiresBlueprint = true`).
  - Физические свитки `bp_<itemId>` (`Type = "Blueprint"`) добавлены в `military_crate`, `elite_crate`, `airdrop`, `npc_rt_guard`, `npc_rt_scientist` и награды пресетных рейдов (`Config.Raid.Tiers`); их можно изучить прямо из инвентаря (`Use / Learn BP`) или с хотбара (`ConsumableController`).
- **Стол исследований (`research_table`):**
  - Добавлен как деплойабл в `BuildingConfig.luau` / `BuildingGeometry.luau` (из примитивов `Part`, крафтится на WB Lv.1, регистрируется в `BaseService.luau`) и установлен в безопасной зоне `VendorHubZone` (`SafeResearchTable`).
  - В `BlueprintService.luau`: `ResearchItemRequest` забирает `1x` оригинал предмета и `ResearchCost` единиц `scrap` (с откатом при сбое), добавляет `recipe.Id` в `UnlockedBlueprints` и синхронизирует клиент через `Net.Events.BlueprintSync`.
- **Двойная проверка крафта:** `CraftingService.luau` и `CraftingController.luau` одновременно проверяют `WorkbenchTier >= recipe.RequiredWorkbench` (или `Station`) и `BlueprintService.CanCraftRecipe` / `BlueprintController.HasBlueprint`.

### Сцена Studio (`QA_TestArena`)
- В `Workspace.QA_TestArena.Recycler_Blueprint_Stand` (рядом с `Workbench_Vendor_Stand`) размещены примитивные стенды `QA_RT_Recycler` (`1.2`), `QA_Safe_Recycler` (`0.8`) и `QA_Research_Table`, а также `Workspace.POI.QA_TestArena.QA_Elite_Blueprint_Crate` (`elite_crate` с респавном `10` сек).

---

## 8. Замыкание геймлупа (Anti-Softlock, 3 Intel Cards, Defense Logs/Death Ghosts, Self-Raid, Well Fed Buffs)

### Профиль и миграция (`DataVersion = 6`)
- `Types.CURRENT_DATA_VERSION` повышен с `5` до `6` (`DataService.MigrateProfileData` шаг `v5 -> v6`).
- В `PlayerData` добавлены `DefenseLogs: { DefenseLogEntry }` (последние `5` записей через `DataService.AppendDefenseLog`) и `LastStarterKitAt: number?`, а в `SurvivalStats` — `WellFedEndTime: number?` и `WellFedStaminaMult: number?`.

### Защита от софтлока (`ExtractionService` + `VendorService` + `VendorController`)
- `ExtractionService.CanAccessMap` и `RaidService` допускают вход на карты/базы своего тира **и ниже** (`playerBaseTier >= RequiredBaseTier`: игрок Tier 3 свободно заходит на Tier 1, 2 и 3).
- У NPC-снабженца `quartermaster` в `VendorHubZone` добавлен бесплатный `StarterRecoveryKit` (`VendorStarterKitRequest` / кнопка в `VendorController`): выдаёт `spear`, `hunting_bow`, `arrow` x12, `bandage` x2 только безоружным игрокам (нет оружия из `Weapons`) с серверным кулдауном `600` сек (`LastStarterKitAt` и атрибут `StarterKitReadyAt`).

### Разведка 3 целей в Рейд-терминале (`RaidService` + `RaidController`)
- Для выбранного тира `1..3` генерируется пул `RaidIntelPool` из `3` карточек целей (`RaidService.GetIntelPool` / `computeBaseIntel`) с телеметрией снепшота: основной материал стен (`DominantTier`), бюджет защиты (`UsedDefenseCapacity / MaxDefenseCapacity`), количество турелей/ловушек (`TurretCount`, `TrapCount`) и категория лута (`LootCategory`). При нехватке реальных баз пул дополняется вариативными пресетами (`DataService.GetPresetTargets`: 3 пресета на тир).
- `RaidRefreshRequest` (`RaidService.RefreshIntelPool`) обновляет 3 карточки выбранного тира бесплатно раз в `600` сек (`FreeRefreshAt`) либо мгновенно за `25` Scrap (`Config.Raid.IntelPaidRefreshScrap`).

### Журнал обороны, Призраки рейдеров (`DeathGhost`) и Self-Raid (`RaidService` + `BaseService` + `DefenseService` + `ToolCupboardController`)
- **Журнал и награда:** при провале рейдера владельцу базы начисляется `25%` от стоимости потраченной взрывчатки и запуска в `Scrap` (складывается напрямую в TC через `BaseService.DepositScrapToToolCupboard`), а лог с точками смертей записывается в `DefenseLogs` (макс. `5`, флаг `GhostsShown = false`).
- **Фильтрация зоны и Призраки:** при гибели рейдера (`RaidService`) координаты фиксируются только вне `RaidOutpostZone` и буферной зоны (`BuildingValidator.IsPointInRaidOutpostOrBuffer`), с причиной смерти `LastDamageSource` (например, `"Killed by Shotgun Trap"`, `"Killed by Auto Turret"`, `"Killed by Landmine"`). При загрузке `PlayerBase` (`BaseService.SpawnSessionDeathGhosts`) для всех логов с `GhostsShown == false` спавнятся примитивные полупрозрачные маркеры `DeathGhost` (`Part`, `Anchored = true`, `CanCollide = false`, `ForceField`/`Neon` + `BillboardGui`) в отдельный `SessionGhostsJanitor`, после чего флаг сразу меняется на `true`. При уходе игрока с `PlayerBase`, запуске рейда/`Self-Raid` или выходе из игры вызывается `BaseService.ClearSessionGhosts(player)` (`SessionGhostsJanitor:Destroy()`).
- **Тест своей базы (`Self-Raid`):** кнопка **«Тест защиты (Self-Raid)»** в окне TC (`ToolCupboardAction:FireServer("StartSelfRaid")`) вызывает `RaidService.StartSelfRaid` через `BaseService.BindRaidHooks` (без циклической зависимости): создаётся изолированный тренировочный инстанс копии базы игрока с выдачей `SelfRaidKit`, реальный инвентарь сохраняется в `SavedInventorySnapshot` и восстанавливается во всех путях выхода (включая `OnBeforeUnload` и `PlayerRemoving`), смерть в Self-Raid не сбрасывает лут-рюкзак (`InSelfRaid`), а защиты работают с флагами `InfiniteAmmo = true` и `AllowOwnerTarget = true` без расхода реального боезапаса.

### Кулинария и таймер баффа еды (`Well Fed`)
- В `Items.luau` / `Consumables.luau` / `Recipes.luau` / `Vendors.luau` / `LootTables.luau` добавлены ингредиенты `wild_berries`, `mushrooms` и сложные блюда на костёр (`Station = "campfire"`): `meat_stew` (`BuffDuration = 900`, `MaxStaminaBonus = 1.1`) и `mushroom_stew` (`BuffDuration = 900`, `MaxStaminaBonus = 1.1`); для `cooked_meat` задано `BuffDuration = 300`, `MaxStaminaBonus = 1.0`.
- В `SurvivalService` статус `WellFed` привязан к таймеру `WellFedEndTime > os.time()`, давая пассивный реген `+1 HP / 3 сек` вне боя, ускоренный реген стамины и динамический `MaxStamina` (`100` или `110` при `+10%`); на клиенте `SurvivalHudController` отображает `WellFedBadge` с обратным отсчётом и актуальный максимум стамины.

---

## 9. Тактические гаджеты рейдера, активная эвакуация Stash и онлайн-сигнализация (Этап 1)

### Тактические гранаты (`emp_grenade`, `smoke_grenade`)
- **Предметы, рецепты и баллистика:** добавлены в `Items.luau`, `Recipes.luau` (крафт на `workbench_2` без чертежа), `Weapons.luau`, `Projectiles.luau` (`ImpactKind = "Emp" | "Smoke"`) и `Config.Raid.SelfRaidKit`. Метание проходит через `CombatController` -> `CombatService` -> `Ballistics.Spawn` со списанием 1 единицы из инвентаря.
- **ЭМИ-граната (`emp_grenade`):** в `RaidExplosives.TriggerEmpPulse` (без урона постройкам и игрокам) отключает все `auto_turret` через `DefenseService.DisableTurretsInRadius` и умные двери (`HasDoor` / `IsSmartDoor`) в радиусе `18` studs на `10` сек (`DisabledUntil = os.clock() + 10`, `EmpDisabled = true`), принудительно открывает двери на время ЭМИ и отправляет клиентам `DefenseEffect("TurretEmp")` + `ExplosionEffect("emp_grenade")` с искрами и голубой волной.
- **Дымовая граната (`smoke_grenade`):** в `RaidExplosives.TriggerSmokeCloud` спавнит на `15` сек в `Workspace.TacticalSmokeClouds` модель из `8` сферических примитивов `Part` (`CanCollide = false`, `CanQuery = true`, атрибут и тег `SmokeVolume`). Снаряды `Ballistics` свободно пролетают сквозь дым, а `DefenseService.hasLineOfSight` / `isSegmentClear` обрывают трассировку при попадании в `SmokeVolume`, сбивая прицеливание и очередь турелей.

### Активная эвакуация `ExtractionStash` (`18` сек + Сирена + `BaseGhosts`)
- После захвата/уничтожения вражеского TC активация эвакуации (`ExtractionTerminal`, кнопка `Extract` в HUD или `StashExtractPrompt` на `F` у `ExtractionStash`) запускает `18`-секундный отсчёт (`Config.Raid.StashExtractionDuration`).
- На время таймера над `ExtractionStash` включается мигающий маяк и зацикленная сирена на всю базу (`SoundId = "rbxasset://sounds/action_falling.ogg"`, `RollOffMaxDistance = 500`), а каждые `2` сек позиция рейдера записывается в `DeathPoints` с `Cause = "Extraction Route"` (отображаются у владельца базы янтарно-жёлтыми призраками в `BaseGhosts.luau`).
- При гибели рейдера во время отсчёта эвакуация немедленно прерывается без выдачи лута; при итоговом провале рейда оставшийся лут `ExtractionStash` начисляется защитнику через `BonusItems` в `RaidDefenseReport`.

### Онлайн-сигнализация (`Active Raid Defense`)
- При старте реального рейда (или при первом уроне по постройкам, **не срабатывает в `Self-Raid`**) `RaidService.triggerActiveRaidAlarm` проверяет присутствие владельца локально и через `MessagingService` (`MyRobloxGame_RaidAlarm`), отправляя `RaidAlarmNotify` (`Phase = "Prompt"`, `15` сек на принятие).
- При согласии (`RaidAlarmResponse(true, raidId)`) запускается `6`-секундный экран подготовки (`DefensePrepOverlay`), после чего защитник телепортируется к безопасному месту у своего TC (`Mode = "RaidDefense"`, `ReservedAccessCode`), получает спавн-защиту и боекомплект из хранилища TC / инвентаря (дополняется из `Config.Raid.ActiveDefenseFallbackKit`), а по завершении рейда возвращается на `PlayerBase`.

---

## 10. Беспроводная логика-лайт, визуальный износ/ремонт и чертежи планировки (Этап 2)

### Профиль и миграция (`DataVersion = 7`)
- `Types.CURRENT_DATA_VERSION` повышен с `6` до `7` (`DataService.MigrateProfileData` шаг `v6 -> v7`).
- В `PlayerData` добавлено поле `BaseBlueprints: { [string]: BaseBlueprintSlot }` (максимум `2` слота игрока, сериализуются относительные координаты/повороты/типы модулей относительно TC без хранения `Storage`/лута). Существующие постройки (`Base.Pieces`) мигрируют без потерь.

### Беспроводная логика-лайт (`hbhf_sensor` + `smart_door`)
- **Элементы обороны (`Config.DefenseCapacity`, `Defenses.luau`, `BuildingConfig.luau`, `Recipes.luau`):**
  - `hbhf_sensor` (стоимость `10` очков `DefenseCapacity`, `BaseHp = 100`, крепление `WallOrCeiling`, крафт на `workbench_2`): в `DefenseService.tickHbhfSensor` сканирует конус/радиус `16` studs (только враги или `IsQaTest`/`AllowOwnerTarget`, с проверкой `hasLineOfSight`), игнорируя владельца, и рассылает беспроводной сигнал всем `smart_door` того же владельца в радиусе `24` studs (`DefenseEffect("SmartDoorSignal")`).
  - `smart_door` (стоимость `5` очков `DefenseCapacity`, прочность `800` HP как у металлической двери, крепление в `doorway` или на ровный пол, крафт на `workbench_1`): по умолчанию закрыта (скрывая за собой `shotgun_trap`), при сигнале от `hbhf_sensor` открывается на `5` сек (`tickSmartDoor`) и закрывается обратно; обе системы отключаются ЭМИ-гранатой (`DefenseService.DisableTurretsInRadius` + `RaidExplosives.TriggerEmpPulse`).
- **Геометрия и валидация:** модели из примитивов `Part` описаны в `BuildingGeometry.luau`, поддержаны в `BuildingValidator.luau` (посадка `smart_door` в проём `doorway`, учёт `smart_door` как барьера в `CheckMaxWallsToTC`) и `BuildingController.luau`.

### Визуальный износ и Ремонтный молоток (`repair_hammer`)
- **Визуальный износ (`BuildingGeometry.ApplyWearVisuals`):** обновляет внешний вид моделей при спавне, уроне, гниении, апгрейде и ремонте (`BaseService`, `BaseUpkeep`, `RaidService`, `DefenseService`):
  - `>= 60%` MaxHP — штатные материалы и цвета тира;
  - `< 60%` MaxHP — лёгкое потемнение и смена материала на `Concrete` (дерево/камень) или `CorrodedMetal` (металл/броня);
  - `< 30%` MaxHP — сильное потемнение, накладные примитивные трещины `WearCrack_*` (`Part`, `CanCollide = false`) и эффект дыма `WearSmoke` (`Smoke`).
- **Ремонтный молоток (`repair_hammer`):** инструмент в `Items.luau` / `Tools.luau` (`Cooldown = 0.5`) / `Recipes.luau` (ручной крафт без верстака), отдельный режим `RepairHammer` в `BuildingController.luau` и серверный обработчик `BaseService.onBuildRepairRequest`. Удар по повреждённому блоку своей базы вне `30`-секундного рейд-блока восстанавливает `25%` MaxHP за удар, списывая пропорциональное количество ресурсов (`wood`/`stone`/`metal_ore`/`high_quality_metal`) напрямую из хранилища TC (`BaseUpkeep.ConsumeCostFromTcStorage`).

### Чертежи планировки базы (`BaseBlueprints` + `ToolCupboardController`)
- **Встроенный шаблон и слоты игрока (`src/server/Services/Base/BaseBlueprints.luau`):**
  - В окне TC добавлена вкладка **«Планировки»** (`ToolCupboardController`), отправляющая `ToolCupboardAction` (`"SaveBlueprint"`, `"LoadBlueprint"`).
  - Сохранение записывает относительную раскладку (`RelX`, `RelY`, `RelZ`, `RelRotY`, `PieceType`, `Tier`, `MountSurface`) в `slot_1` / `slot_2` без лута.
  - Загрузка (`builtin_2x2` **«Компактный 2x2 с бункером»** из `18` блоков или пользовательский слот) запрещена в рейде/рейд-блоке, предварительно валидирует раскладку через `BuildingValidator` (`IsInRaidOutpostZone`, `CheckWorldOverlap`, `ComputeDefenseCapacity`, `CheckMaxWallsToTC`, `FindUnsupportedPieces`), проверяет ресурсы в TC с учётом `80%` возврата стоимости старых не-TC модулей и перестраивает каркас без потери самого TC и его хранилища.

### Сцена Studio (`QA_TestArena`)
- В `Workspace.QA_TestArena.LogicWearTestStand` добавлена связка `QA_HbhfSensor` (`hbhf_sensor`) + `QA_SmartDoor` (`smart_door`) + скрытый за дверью `QA_HiddenShotgunTrap` (`shotgun_trap`), а также повреждённая каменная стена `QA_DamagedWall` (`120 / 500` HP, `IsQaRepairTarget = true`) для проверки визуального износа и `repair_hammer`.
