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
- `BaseProgression` — пороги структурных блоков и минимального ранга тира (`Tier1`, `Tier2`, `Tier3`).
- `Upkeep` — разрешённые ресурсы содержания TC (`wood`, `stone`, `metal_ore`, `high_quality_metal`), расход в час на блок по тиру, `TcStorageSlots = 12`.
- `Decay` — интервал тика (`60` с), лимит оффлайн-пересчёта (`24` ч), урон гниения в час по тирам и множитель `NoTcMultiplier = 1.5`.
- `Extraction = { Duration: number, CooldownAfterDamage: number }`
- `MAX_TC_WALL_LAYERS = 2`, `MIN_TURRET_DISTANCE = 14`, `MIN_TRAP_DISTANCE = 6`, `WORKBENCH_RADIUS = 16` — баланс-ограничения защиты базы (максимум 2 слоя стен/перекрытий до TC, анти-киллбокс дистанция между турелями/ловушками) и радиус действия верстаков при крафте (`16` studs).
- `VendorHub` — параметры безопасной зоны торговцев на `PlayerBase`: `Origin = Vector3.new(0, 0, -68)` (вне зоны застройки и на противоположной стороне от `RaidOutpostZone`), `ZoneSize = Vector3.new(44, 32, 34)`, `InteractDistance = 14`, `MaxTradeQuantity = 10`.
- `Raid` — параметры рейда: `MaxLives = 3`, `RespawnDelay = 0.8` (быстрое возрождение `< 1.5` с), `SpawnInvulnerabilityDuration = 2.0` (`ForceField` на 2 с), `TcHackDuration = 10`, `TcHackMaxDistance = 14`, `OutpostRadius = 28`, `OutpostOffsetZ = 46`, `ExtractionStashSlots = 18`, `SupplyCrateSlots = 6`, `StarterSupplyItems` (`bandage` x6, `cooked_meat` x2), `Tiers[1..3]` (`RequiredBaseTier`, `DangerLabel`, `RewardLabel`, `LaunchCost`, `DefenseBonus`).
- `DefenseCapacity` — лимит очков защиты по тирам базы (`MaxByBaseTier`: `[0]=30`, `[1]=60`, `[2]=100`, `[3]=150`) и стоимость защитных установок (`Costs`: `floor_spikes = 5`, `landmine = 10`, `shotgun_trap = 15`, `auto_turret = 25`).

### `Types` (`src/shared/Types.luau`)
- Базовые типы: `ItemType`, `ItemConfig`, `Slot`, `Inventory`, `SurvivalStats`, `ConsumableConfig`, `LootContainerState`, `PlayerData` (`DataVersion = 4`), `ItemBatchEntry`, `ToolCategory`, `ToolConfig`, `NodeType`, `NodeConfig`, `NodeClientState`, `Ingredient`, `RecipeConfig` (`RequiredWorkbench: number`, `Station: string?`), `CraftingState`, `VendorId` (`"recycler" | "weaponsmith" | "quartermaster"`), `VendorOfferMode`, `VendorOffer`, `VendorConfig`, `VendorTradeFeedback`, `WeaponCategory`, `WeaponConfig`, `LootDropEntry`, `LootTableConfig`, `WorldEventPayload`, `ExtractionState`, `ExplosiveConfig`, `ProjectileConfig`, `ExplosionParams`, `ExplosionResult`, `RaidTargetInfo` (`BaseTier?`, `DangerLabel?`, `RewardLabel?`, `LaunchCost?`, `IsPreset?`), `RaidHudState` (`TargetBaseTier?`, `TcCaptured?`, `TcHackProgress?`, `TcHackActive?`, `LivesLeft?`, `MaxLives?`, `StashItemCount?`, `CanExtract?`), `RaidDefenseReport`, `BaseTier`, `ToolCupboardStatus`, `ToolCupboardState` (`DefenseUsed?`, `DefenseMax?`), `DefenseMountSurface`, `DefenseAllowedMount`, `DefenseConfig`, `DefenseUiState`.
- Типы строительства:
  - `BuildPieceType = "foundation" | "triangle_foundation" | "wall" | "doorway" | "window_wall" | "roof" | "triangle_floor" | "square_stairs" | "triangle_stairs" | "storage_box" | "tool_cupboard" | "workbench_1" | "workbench_2" | "workbench_3" | "assault_ladder" | "barricade" | "floor_spikes" | "landmine" | "shotgun_trap" | "auto_turret" | ...`
  - `BuildTier = "wood" | "stone" | "metal" | "armored"`
  - `BaseData = { Pieces: { SavedBuildPiece }, BaseTier: BaseTier, LastUpkeepTimestamp: number }`
  - `SavedBuildPiece = { Uid: string, PieceType: BuildPieceType, Tier: BuildTier, PosX: number, PosY: number, PosZ: number, RotY: number, ParentUid: string?, AnchorUid: string?, SocketId: string?, MountSurface: DefenseMountSurface?, Hp: number, LastDamagedAt: number?, Storage: { [string]: Slot }?, GridX: number?, GridY: number?, GridZ: number? }`
- Константы: `INVENTORY_SIZE = 30`, `HOTBAR_SIZE = 6`, `MAX_GATHER_DISTANCE_SERVER = 14`, `MAX_GATHER_DISTANCE_CLIENT = 12`, `MAX_STATION_DISTANCE = 16`, `MAX_LOOT_DISTANCE = 14`, `MAX_BUILD_DISTANCE = 20`, `PING_DISTANCE_TOLERANCE = 2`, `CURRENT_DATA_VERSION = 4`.

### `Signal` (`src/shared/Signal.luau`) & `Janitor` (`src/shared/Janitor.luau`)
- `Signal.new<T...>(): Signal<T...>` -> Создание типизированного сигнала (`:Connect`, `:Once`, `:Fire`, `:Destroy`).
- `Janitor.new(): Janitor` -> Менеджер очистки ресурсов (`:Add`, `:Cleanup`, `:Destroy`).

### `Ballistics` (`src/shared/Ballistics.luau`)
- `Ballistics.ComputePosition(origin, initialVelocity, gravity, elapsed): Vector3` -> Позиция снаряда по времени.
- `Ballistics.ComputeVelocity(initialVelocity, gravity, elapsed): Vector3` -> Мгновенная скорость снаряда.
- `Ballistics.ComputeCFrame(position, velocity): CFrame` -> Ориентация снаряда по вектору скорости.
- `Ballistics.Spawn(options: SpawnOptions): string` -> Запуск пошаговой симуляции снаряда на `Heartbeat`.
- `Ballistics.Cancel(projectileId: string): boolean` -> Досрочная отмена симуляции снаряда.
- `Ballistics.GetActiveCount(): number` -> Количество активных снарядов.

### `Net` (`src/shared/Net.luau`)
- `Net.Events`: `InventorySync`, `InventoryMove`, `HotbarSelect`, `HitNode`, `NodeUpdated`, `CraftRequest`, `CraftCancel`, `CraftStateSync`, `UseConsumable`, `OpenContainer`, `CloseContainer`, `LootTakeSlot`, `ContainerDepositSlot`, `AttackRequest`, `AttackEffect`, `WorldEventNotify`, `ExtractionStateSync`, `RequestReturnToMap`, `BuildPlaceRequest`, `BuildUpgradeRequest`, `BuildDemolishRequest`, `BuildRepairRequest`, `BaseStateSync`, `BuildFeedback`, `ToolCupboardSync`, `ToolCupboardAction`, `DefenseSync`, `DefenseAction`, `DefenseEffect`, `RaidListRequest`, `RaidListSync`, `StartRaidRequest`, `PlaceExplosiveRequest`, `RaidHudSync`, `RaidExtractRequest`, `RaidTcHackRequest`, `RaidAbandonRequest`, `RaidReportNotify`, `ProjectileSpawn`, `ExplosionEffect`, `VendorOpen`, `VendorTradeRequest`, `VendorTradeFeedback`.
- `Net.InitServer()` -> Создаёт папку `Remotes` и кэширует все `RemoteEvent`.
- `Net.GetEvent(eventName: string): RemoteEvent` -> Возвращает кэшированный `RemoteEvent`.

### Конфиги (`src/shared/configs/`)
- `Items.luau`, `Consumables.luau`, `Tools.luau`, `Nodes.luau`, `Recipes.luau` (все 26 рецептов распределены по `RequiredWorkbench = 0..3`: Tier 0 — базовые инструменты/лук/стрелы/WB1; Tier 1 — TC/пистолет/патроны/шипы/HQM/WB2; Tier 2 — дробь/сачель/мина/`shotgun_trap`/WB3; Tier 3 — C4/ракетница/ракеты/`auto_turret`), `Vendors.luau` (3 торговца Safe Hub: `recycler`, `weaponsmith`, `quartermaster` с офферами обмена за `scrap`), `Weapons.luau`, `Projectiles.luau`, `Explosives.luau`, `LootTables.luau`.
- `Defenses.luau`: параметры защит (`floor_spikes`, `landmine`, `shotgun_trap`, `auto_turret` — стоимость в очках, поверхность крепления, радиус, урон, время наведения, кулдаун, боеприпасы, `Defenses.Get`, `Defenses.GetCapacityLimit`).
- `BuildingConfig.luau`: `GridSize = 12`, `WallHeight = 10`, `WallBodyHeight = 9.2`, `Thickness = 0.8`, `FoundationThickness = 1.0`, `Pieces` (20 модулей: структурные блоки, `storage_box`, `tool_cupboard` с `MaxPerBase = 1` и `StorageSlots = 12`, `workbench_1`/`workbench_2`/`workbench_3` с `RequiredBaseTier = 1/2/3`, штурмовые `assault_ladder`/`barricade` с `AssaultDeployable = true`, защитные `floor_spikes`/`landmine`/`shotgun_trap`/`auto_turret` с `IsDefense = true`), `Tiers` (`wood`, `stone`, `metal`, `armored`).

### `BuildingGeometry` (`src/shared/BuildingGeometry.luau`)
- `BuildingGeometry.CanonicalPieceType(pieceType: string): BuildPieceType` -> Приводит алиасы типа модуля к каноническому `snake_case`.
- `BuildingGeometry.ComposeWorldCFrame(posX, posY, posZ, rotYDeg): CFrame` -> Собирает мировой `CFrame` с опорой на центре нижней плоскости (`Y = 0` локального этажа).
- `BuildingGeometry.GetPieceWorldCFrame(piece: SavedBuildPiece, originOffset: Vector3?): CFrame` -> Возвращает мировой `CFrame` постройки (с поддержкой legacy-координат).
- `BuildingGeometry.ComputeMaxHp(pieceType, tier): number` -> Вычисляет максимальный HP модуля с учётом множителя тира.
- `BuildingGeometry.CreateModel(pieceType, worldCF, isGhost, nameOverride?, mountSurface?): Model` (алиас `CreatePieceModel`) -> Создаёт примитивную модель (`Part`/`WedgePart`, включая `floor_spikes`, `landmine`, настенный/потолочный `shotgun_trap` и `auto_turret`) с `PrimaryPart` и `Pivot`.
- `BuildingGeometry.ApplyTierVisuals(model, pieceType, tier)` -> Применяет материал и цвет тира ко всем деталям модели.
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
- `DataService.MigrateProfileData(rawData): { [string]: any }` -> Пошаговая миграция профиля `DataVersion 1 -> 2 -> 3 -> 4` (`(GridX, GridY, GridZ)` -> `(PosX, PosY, PosZ)`, `ParentUid`, канонические имена модулей, `BaseTier`, `LastUpkeepTimestamp`, `MountSurface` и слоты боеприпасов защит).
- `DataService.GetData(player): PlayerData?` -> Возвращает активный профиль игрока.
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
- `CraftingService.RegisterStation(stationId, stationType, position, ownerUserId?)` / `UnregisterStation(stationId)` -> Учёт динамических и статических верстаков (`workbench_1`, `workbench_2`, `workbench_3` с иерархической совместимостью по тирам и проверкой владельца `OwnerUserId`).
- `CraftingService.GetPlayerWorkbenchTier(player, includePingTolerance?): number` -> Вычисляет максимальный уровень доступного игроку верстака в радиусе `Config.WORKBENCH_RADIUS` (`16` studs).
- `CraftingService.GetActiveCraft(player): CraftingState?` / `CancelCraftForPlayer(player, syncClient, bypassLock?)` -> Управление очередью крафта игрока.
- `CraftingService.Init()` -> Обработка `CraftRequest` (авторитетная проверка `GetPlayerWorkbenchTier(player, true) >= recipe.RequiredWorkbench`) / `CraftCancel`, возврат ресурсов при выходе/смерти и фоновая синхронизация атрибута `WorkbenchTier` игрока.

### `VendorService` (`src/server/Services/VendorService.luau`)
- `VendorService.SpawnBaseVendorHub()` / `DespawnBaseVendorHub()` -> Процедурный спавн безопасной зоны `VendorHubZone` (примитивы `Part`/`WedgePart`, теги `NoBuild` + `VendorHubZone`, 3 NPC-торговца с `ProximityPrompt`) в режиме `PlayerBase` (`BaseService.IsBaseMode()`) и скрытие/удаление при активном рейде (`RaidServerMode`).
- `VendorService.BindStaticVendorHub(container)` -> Регистрация статических NPC-торговцев из сцены (`QA_TestArena/Workbench_Vendor_Stand/QA_VendorHubZone`).
- `VendorService.Init()` -> Обработка `VendorOpen` и авторитетный обмен `VendorTradeRequest` (rate-limit, проверка дистанции, блокировка в рейде, `SecurityService.RunLocked`, проверка наличия предметов `HasItems` и свободного места `CanCraftTransaction`, атомарное списание/выдача и ответ `VendorTradeFeedback`).

### `SurvivalService` (`src/server/Services/SurvivalService.luau`)
- `SurvivalService.GetStats(player): SurvivalStats?` / `GetContainerState(containerId): LootContainerState?` -> Чтение статов выживания.
- `SurvivalService.Init()` -> Тик голода/жажды/регена (`2.0` с), обработка `UseConsumable` и спавн рюкзака лута при смерти.

### `LootService` (`src/server/Services/LootService.luau`)
- `LootService.RollLootTable(tableId): Inventory` -> Генерация лута по весам.
- `LootService.RegisterSlotsContainer(...)` / `RegisterStorageContainer(...)` / `SpawnTemporaryContainer(...)` -> Регистрация временных и постоянных контейнеров с `ProximityPrompt`.
- `LootService.UnregisterContainer(containerId)` / `DestroyContainer(containerId)` -> Удаление контейнера.
- `LootService.OpenContainerForPlayer(player, containerId): boolean` / `CloseContainerForPlayer(player, notifyClient)` -> Открытие/закрытие контейнера с проверкой дистанции.
- `LootService.GetContainerState(containerId)` / `IsContainerDepleted(containerId): boolean` / `DepositToStorageContainer(containerId, itemId, count): number` -> Чтение состояния и пополнение хранилищ.
- `LootService.Init()` -> Наполнение POI-ящиков, обработка `LootTakeSlot` / `ContainerDepositSlot`.

### `WorldEventService` (`src/server/Services/WorldEventService.luau`)
- `WorldEventService.TriggerAirdropNow(descentTimeOverride?): Model` -> Немедленный запуск Supply Drop.
- `WorldEventService.GetActiveAirdropModel(): Model?` / `GetActiveAirdropContainerId(): string?` -> Состояние активного аирдропа.
- `WorldEventService.Init()` -> Цикл Supply Drop раз в `420` с.

### `CombatService` (`src/server/Services/CombatService.luau`)
- `CombatService.GetEquippedWeapon(player): (string, WeaponConfig)` -> Активное оружие игрока.
- `CombatService.Init()` -> Обработка `AttackRequest` (хитскан, ближний бой и баллистические снаряды через `Ballistics.Spawn`, урон по постройкам `BaseService`/`RaidService.DamageRaidPiece`, оповещение `RaidService.NotifyRaiderDamaged` и урон по гуманоидам).

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
- `BuildingValidator.CheckMaxWallsToTC(playerRecords, occupiedSockets, candidatePiece?): (boolean, string?, number?)` (и совместимая обёртка `CanReachToolCupboard`) -> Взвешенный 0-1 BFS по графу сокетов `BuildingGeometry` от внешнего периметра и открытого неба до блока с `tool_cupboard`: открытые грани, проёмы `doorway` без двери и лестницы имеют вес `0`; глухие стены (`wall`, `window_wall`), двери (`HasDoor == true`) и вертикальные перекрытия без лестницы дают `+1` слой. Разрешает глухие Rust-бункеры при условии `minLayers <= Config.MAX_TC_WALL_LAYERS` (`2`).
- `BuildingValidator.CheckWorldOverlap(pieceType, targetCF, excludeInstances?, isDetachedFoundation, allowRaidOutpostZone?, mountSurface?)` -> Проверяет `Workspace:GetPartBoundsInBox` с хитбоксом `0.85` против построек, игроков и запрещённых зон (`POI`, `ExtractionZones`, `AirdropZones`, `ResourceNodes`, `Workbenches`, `RaidTerminal`, `RaidOutpostZone`, `VendorHubZone`, `QA_VendorHubZone`).
- `BuildingValidator.ValidatePlacement(input)` -> Полная серверная валидация размещения блока и защитных установок (`IsDefense`: бюджет `DefenseCapacity` только для ловушек/турелей, запрет в рейде и `RaidOutpostZone`, проверка поверхности крепления `Floor`/`Wall`/`Ceiling`, анти-киллбокс дистанция `MIN_TURRET_DISTANCE = 14` между `auto_turret`, `MIN_TRAP_DISTANCE = 6` для `shotgun_trap` и коллизии).

### `DefenseService` (`src/server/Services/DefenseService.luau`)
- `DefenseService.BindRaidHooks(hooks)` -> Привязка `RaidService.TriggerExplosion` и `RaidService.NotifyRaiderDamaged` без циклических зависимостей.
- `DefenseService.RegisterDefense(options)` / `UnregisterDefense(uid)` / `UpdateDefenseHp(uid, hp, maxHp?)` -> Реестр активных ловушек и турелей для `PlayerBase`, рейд-инстансов и `Workspace.QA_TestArena`.
- `DefenseService.GetActiveCount(): number` -> Количество активных защитных установок.
- `DefenseService.Init()` -> Управление `ProximityPrompt` загрузки/выгрузки патронов (`DefenseSync` / `DefenseAction`), цикл `Heartbeat` сканирования целей с проверкой иммунитета владельца на `PlayerBase` и временной спавн-неуязвимости рейдера (`ForceField` / `RaidInvulnerable`), `RaycastParams` LoS, замедлением от `floor_spikes`, взрывом `landmine`, дробовым залпом `shotgun_trap`, наведением `0.8` с и баллистическими очередями `auto_turret` через `Ballistics.Spawn`.

### `BaseService` (`src/server/Services/BaseService.luau`)
- `BaseService.ComputeHourlyUpkeep(pieces): { [string]: number }` -> Расчёт часового расхода ресурсов на содержание базы по тирам блоков.
- `BaseService.ComputeBaseTier(pieces, hasActiveTc): number` -> Серверный расчёт `BaseTier` (`0..3`) по наличию TC и количеству/тиру несущих конструкций.
- `BaseService.GetPlayerBaseTier(player): number` -> Текущий `BaseTier` игрока.
- `BaseService.BuildToolCupboardState(player): ToolCupboardState?` -> Сборка состояния шкафа (слоты, статус `Protected`/`Decaying`, `ProtectedHours`, статус слоёв защиты TC по `CheckMaxWallsToTC`, бюджет `DefenseUsed`/`DefenseMax`).
- `BaseService.ProcessUpkeepAndDecay(player, elapsedSeconds): boolean` -> Списание ресурсов из TC или нанесение периодического урона гниения по внешним блокам (с оффлайн-пересчётом по `os.time()` при входе и тиком каждые `60` с) с пересчётом `BaseTier`.
- `BaseService.IsBaseMode(): boolean` / `CanBuild(player): boolean` -> Проверка разрешения на строительство.
- `BaseService.DamagePiece(uid, rawDamage, damageKind, attacker?): (boolean, boolean)` -> Нанесение урона постройке с записью `LastDamagedAt = os.clock()` и пересчётом `BaseTier` при разрушении.
- `BaseService.GetLivePieceModelsInRadius(origin, radius)` / `GetPlayerPieces(player)` / `GetStorageContainerId(player, uid)` / `DepositItemsToPlayerBase(player, items)` -> Доступ к постройкам игрока и перенос эвакуированного лута в инвентарь и `storage_box` профиля.
- `BaseService.Init()` -> Спавн базы (включая `ProximityPrompt` для TC, регистрацию верстаков `workbench_1/2/3` и активных защит в `DefenseService`), обработка `BuildPlaceRequest` (из `BuildingPlan` и предметов в хотбаре, игнорируется при `InRaid == true`), `BuildUpgradeRequest`, `BuildRepairRequest` (ремонт киянкой), `BuildDemolishRequest` (с возвратом снятой защиты и её боезапаса), `ToolCupboardAction`, `RequestReturnToMap`, `BuildFeedback` и фоновый цикл Upkeep/Decay.

### `RaidService` (`src/server/Services/RaidService.luau`)
- `RaidService.HasExplosionLineOfSight(blastOrigin, targetModel, excludeInstances?, isCharacterTarget?): boolean` -> Проверка LoS взрыва с окклюзией стенами.
- `RaidService.TriggerExplosion(params: ExplosionParams): ExplosionResult` -> Расчёт AoE-взрыва с учётом `ExplosionResistance` тира, игнорированием целей с активной спавн-неуязвимостью (`ForceField` / `RaidInvulnerable`), записью `LastDamagedAt = os.clock()` и `NotifyRaiderDamaged`.
- `RaidService.DamageRaidPiece(uid, rawDamage, damageKind, attacker?)` / `NotifyRaiderDamaged(player)` -> Урон оружием по рейд-постройкам и срыв взлома TC при получении урона.
- `RaidService.EnterStudioMockRaid(player, targetUserId): boolean` / `IsPlayerInRaid(player): boolean` / `GetActiveSessionInfo(player): RaidHudState?` -> Управление рейд-сессией: спавн базы цели (снепшот или пресет Tier 1/2/3 с активными ловушками и турелями в `DefenseService`), спавн префаба рейд-кибитки в `RaidOutpostZone` (`RaidOutpostStructures`: каркас, `workbench_1`, `OutpostRespawnPad` с 3 жизнями, быстрым респавном `<= 1.5` с через `LoadCharacter()` и 2-секундной неуязвимостью `ForceField`, `ExtractionStash`, стартовый мед-контейнер `RaidSupplyCrate`, `ExtractionTerminal`), временная стройка рейдера, захват/уничтожение вражеского TC (`TcHackPrompt` 10 сек), перенос лута из `ExtractionStash` на `PlayerBase` при эвакуации или сгорание лута с отчётом и бонусом защитнику при поражении.
- `RaidService.Init()` -> Обработка `RaidListRequest`, `StartRaidRequest` (доступ с `PlayerBase`/`MainMap`/Studio, проверка `attackerBaseTier >= targetBaseTier`, списание/возврат `LaunchCost`), `BuildPlaceRequest` (в рейде), `PlaceExplosiveRequest`, `RaidTcHackRequest`, `RaidExtractRequest`, `RaidAbandonRequest`, выдача `RaidReportNotify`.

---

## 4. Клиентские контроллеры (`StarterPlayer.StarterPlayerScripts.Client.Controllers`)

- `InventoryController`: `.Changed`, `.GetInventory()`, `.GetSlot(slotIndex)`, `.OnChanged(cb)`, `.RequestMove(from, to)`, `.Init()`.
- `HotbarController`: `.SelectionChanged`, `.SelectSlot(slotIndex)`, `.GetSelectedSlot()`, `.Init()`.
- `InventoryUIController`: `.OpenChanged`, `.IsOpen()`, `.SetOpen(open)`, `.Toggle()`, `.Init()`.
- `CraftingController`: `.OpenChanged`, `.IsOpen()`, `.SetOpen(open)`, `.Toggle()`, `.GetActiveCraft()`, `.GetWorkbenchTier()`, `.Init()` — отслеживает атрибут `WorkbenchTier` игрока, отображает HUD-плашку `Workbench Level 1 / 2 / 3` при нахождении в радиусе верстака, фильтрует рецепты (`All`, `Avail`, `T0..T3`) и блокирует недоступные крафты (`WB X`).
- `VendorController`: `.OpenChanged`, `.IsOpen()`, `.GetActiveVendorId()`, `.SetOpen(open)`, `.Init()` — окно торговли `VendorGui` по `VendorOpen` (отображение баланса `Scrap`, офферов `BUY`/`SELL` с кнопками `x1`/`x5`, баннер `VendorTradeFeedback`, автозакрытие при отходе или открытии других меню).
- `GatheringController`: `.GetNodeState(nodeId)`, `.IsCursorOnActiveNode()`, `.Init()`.
- `SurvivalHudController`: `.Init()`.
- `ConsumableController`: `.Init()`.
- `LootController`: `.OpenChanged`, `.IsOpen()`, `.GetActiveContainerId()`, `.CanDeposit()`, `.RequestDeposit(playerSlot)`, `.Close()`, `.Init()`.
- `CombatController`: `.Init()`.
- `ProjectileController`: `.SpawnLocalProjectile(id, origin, dir, char): string`, `.GetActiveVisualCount(): number`, `.Init()`.
- `WorldEventController`: `.IsBannerVisible(): boolean`, `.GetActiveBeaconCount(): number`, `.Init()`.
- `ExtractionController`: `.IsVisible(): boolean`, `.GetState(): ExtractionState?`, `.Init()`.
- `BuildingController`: `.IsBaseMode()`, `.CanBuild()`, `.IsBuildMode()`, `.SetBuildMode(enabled)`, `.GetPieces()`, `.Init()` — активация по экипировке `building_plan` (превью размещения), `hammer` (апгрейд/ремонт повреждённых объектов и снятие/демонтаж по ЛКМ/ПКМ и клавишам) или ловушек/турелей из хотбара; кэшированный `RaycastParams`; фантом через `BuildingGeometry.CreateModel` с подсветкой **зелёный** / **синий** / **красный**, поддержкой крепления `Floor`/`Wall`/`Ceiling` и клиентской проверкой анти-киллбокс дистанции (`14` / `6` studs); панель `BaseActionBar` с индикатором `DefenseCapacity` и палитра из 20 модулей.
- `ToolCupboardController`: `.IsOpen()`, `.Close()`, `.GetState()`, `.Init()` — окно Tool Cupboard (12 слотов содержания, быстрый депозит ресурсов `wood`/`stone`/`metal_ore`/`high_quality_metal`, отображение `BaseTier`, статуса `Protected`/`Decaying`, расхода в час, количества слоёв защиты TC (`<= 2`) и текущего бюджета `DefenseCapacity`).
- `DefenseController`: `.IsOpen()`, `.Close()`, `.Init()` — окно загрузки/выгрузки боезапаса для `auto_turret` и `shotgun_trap` (`DefenseSync` / `DefenseAction`), отображение прочности и `DefenseCapacity`, рендер трассеров, лазера наведения и звуковых эффектов по `DefenseEffect`.
- `RaidController`: `.IsInRaid()`, `.IsSelectionOpen()`, `.GetHudState()`, `.OpenTargetList()`, `.CloseTargetList()`, `.Init()` — интерфейс Рейд-терминала (фильтры `Tier 1/2/3`, отображение опасности, награды, стоимости запуска, блокировка при недостаточном `BaseTier`), расширенный рейд-HUD (таймер, жизни, `ExtractionStash`, прогресс захвата TC, кнопки `Extract`/`Abandon`) и уведомления `RaidReportNotify`.

---

## 5. Тестовые стенды в Studio (`Workspace.QA_TestArena`)
- `Workbench_Vendor_Stand` — стенд проверки радиуса верстаков (`16` studs) и безопасной зоны торговцев (`Part`/`WedgePart`):
  - `Workspace.Workbenches`: `QA_WB_Tier1` (`workbench_1`), `QA_WB_Tier2` (`workbench_2`), `QA_WB_Tier3` (`workbench_3`), разнесённые на 35 studs друг от друга с визуальными неоновыми кольцами радиуса `16` studs.
  - `QA_VendorHubZone` (теги `NoBuild` + `VendorHubZone`): 3 примитивных NPC-торговца (`Vendor_recycler`, `Vendor_weaponsmith`, `Vendor_quartermaster`) с `ProximityPrompt`.
