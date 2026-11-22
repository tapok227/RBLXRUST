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

### `Types` (`src/shared/Types.luau`)
- Базовые типы: `ItemType`, `ItemConfig`, `Slot`, `Inventory`, `SurvivalStats`, `ConsumableConfig`, `LootContainerState`, `PlayerData` (`DataVersion = 3`), `ItemBatchEntry`, `ToolCategory`, `ToolConfig`, `NodeType`, `NodeConfig`, `NodeClientState`, `Ingredient`, `RecipeConfig`, `CraftingState`, `WeaponCategory`, `WeaponConfig`, `LootDropEntry`, `LootTableConfig`, `WorldEventPayload`, `ExtractionState`, `ExplosiveConfig`, `ProjectileConfig`, `ExplosionParams`, `ExplosionResult`, `RaidTargetInfo` (`BaseTier?`), `RaidHudState`, `BaseTier`, `ToolCupboardStatus`, `ToolCupboardState`.
- Типы строительства:
  - `BuildPieceType = "foundation" | "triangle_foundation" | "wall" | "doorway" | "window_wall" | "roof" | "triangle_floor" | "square_stairs" | "triangle_stairs" | "storage_box" | "tool_cupboard" | "workbench_1" | "workbench_2" | "workbench_3" | ...`
  - `BuildTier = "wood" | "stone" | "metal" | "armored"`
  - `BaseData = { Pieces: { SavedBuildPiece }, BaseTier: BaseTier, LastUpkeepTimestamp: number }`
  - `SavedBuildPiece = { Uid: string, PieceType: BuildPieceType, Tier: BuildTier, PosX: number, PosY: number, PosZ: number, RotY: number, ParentUid: string?, AnchorUid: string?, SocketId: string?, Hp: number, LastDamagedAt: number?, Storage: { [string]: Slot }?, GridX: number?, GridY: number?, GridZ: number? }`
- Константы: `INVENTORY_SIZE = 30`, `HOTBAR_SIZE = 6`, `MAX_GATHER_DISTANCE_SERVER = 14`, `MAX_GATHER_DISTANCE_CLIENT = 12`, `MAX_STATION_DISTANCE = 14`, `MAX_LOOT_DISTANCE = 14`, `MAX_BUILD_DISTANCE = 20`, `PING_DISTANCE_TOLERANCE = 2`, `CURRENT_DATA_VERSION = 3`.

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
- `Net.Events`: `InventorySync`, `InventoryMove`, `HotbarSelect`, `HitNode`, `NodeUpdated`, `CraftRequest`, `CraftCancel`, `CraftStateSync`, `UseConsumable`, `OpenContainer`, `CloseContainer`, `LootTakeSlot`, `ContainerDepositSlot`, `AttackRequest`, `AttackEffect`, `WorldEventNotify`, `ExtractionStateSync`, `RequestReturnToMap`, `BuildPlaceRequest`, `BuildUpgradeRequest`, `BuildDemolishRequest`, `BaseStateSync`, `BuildFeedback`, `ToolCupboardSync`, `ToolCupboardAction`, `RaidListRequest`, `RaidListSync`, `StartRaidRequest`, `PlaceExplosiveRequest`, `RaidHudSync`, `RaidExtractRequest`, `ProjectileSpawn`, `ExplosionEffect`.
- `Net.InitServer()` -> Создаёт папку `Remotes` и кэширует все `RemoteEvent`.
- `Net.GetEvent(eventName: string): RemoteEvent` -> Возвращает кэшированный `RemoteEvent`.

### Конфиги (`src/shared/configs/`)
- `Items.luau`, `Consumables.luau`, `Tools.luau`, `Nodes.luau`, `Recipes.luau` (включая `craft_tool_cupboard`, `craft_workbench_2`, `craft_workbench_3`), `Weapons.luau`, `Projectiles.luau`, `Explosives.luau`, `LootTables.luau`.
- `BuildingConfig.luau`: `GridSize = 12`, `WallHeight = 10`, `WallBodyHeight = 9.2`, `Thickness = 0.8`, `FoundationThickness = 1.0`, `Pieces` (14 модулей: структурные блоки, `storage_box`, `tool_cupboard` с `MaxPerBase = 1` и `StorageSlots = 12`, `workbench_1`/`workbench_2`/`workbench_3` с `RequiredBaseTier = 1/2/3`), `Tiers` (`wood`, `stone`, `metal`, `armored`).

### `BuildingGeometry` (`src/shared/BuildingGeometry.luau`)
- `BuildingGeometry.CanonicalPieceType(pieceType: string): BuildPieceType` -> Приводит алиасы типа модуля к каноническому `snake_case`.
- `BuildingGeometry.ComposeWorldCFrame(posX, posY, posZ, rotYDeg): CFrame` -> Собирает мировой `CFrame` с опорой на центре нижней плоскости (`Y = 0` локального этажа).
- `BuildingGeometry.GetPieceWorldCFrame(piece: SavedBuildPiece, originOffset: Vector3?): CFrame` -> Возвращает мировой `CFrame` постройки (с поддержкой legacy-координат).
- `BuildingGeometry.ComputeMaxHp(pieceType, tier): number` -> Вычисляет максимальный HP модуля с учётом множителя тира.
- `BuildingGeometry.CreateModel(pieceType, worldCF, isGhost, nameOverride?): Model` (алиас `CreatePieceModel`) -> Создаёт примитивную модель (`Part`/`WedgePart`) с `PrimaryPart` и `Pivot` в центре нижней плоскости модуля.
- `BuildingGeometry.ApplyTierVisuals(model, pieceType, tier)` -> Применяет материал и цвет тира ко всем деталям модели.
- `BuildingGeometry.SetGhostColor(model, color)` -> Окрашивает полупрозрачный фантом (`Green` / `Blue` / `Red`).
- `BuildingGeometry.GetPieceSockets(pieceType): { BuildSocketDef }` -> Список сокетов модуля (`Edge_1..N`, `Top`, `Center`, `WallTop`).
- `BuildingGeometry.IsSocketCompatible(parentType, socket, childType): boolean` -> Проверяет совместимость родительского сокета и дочернего модуля.
- `BuildingGeometry.GetSocketSlotKey(socket, childType, rotStep?): string` -> Ключ канала сокета для разделения стен и перекрытий.
- `BuildingGeometry.ComputeSnappedCFrame(parentType, parentWorldCF, socket, childType, rotStep?): CFrame` -> Вычисляет точный мировой `CFrame` дочернего модуля на сокете.
- `BuildingGeometry.GetOverlapBoxes(pieceType, worldCF, expandXZ?): { BuildOverlapBox }` -> Возвращает уменьшенные (`0.85`) OBB-боксы модуля для проверки коллизий.

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
- `DataService.MigrateProfileData(rawData): { [string]: any }` -> Пошаговая миграция профиля `DataVersion 1 -> 2 -> 3` (`(GridX, GridY, GridZ)` -> `(PosX, PosY, PosZ)`, `ParentUid`, канонические имена модулей, `BaseTier`, `LastUpkeepTimestamp`).
- `DataService.GetData(player): PlayerData?` -> Возвращает активный профиль игрока.
- `DataService.OnDataLoaded(callback): Signal.Connection` -> Подписка на загрузку профиля.
- `DataService.OnBeforeUnload(callback)` -> Хук перед сохранением/выгрузкой профиля.
- `DataService.ReleaseForTeleport(player): boolean` / `RestoreAfterFailedTeleport(player): boolean` -> Безопасное освобождение и восстановление сессии `ProfileStore`.
- `DataService.RegisterRaidableBase(player)` / `GetRaidTargets(excludeUserId, limit)` / `LoadBaseSnapshot(targetUserId)` -> Индексация и загрузка снимков баз для рейдов (включая `BaseTier`).
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
- `CraftingService.RegisterStation(stationId, stationType, position)` / `UnregisterStation(stationId)` -> Учёт динамических верстаков (`workbench_1`, `workbench_2`, `workbench_3` с иерархической совместимостью по тирам).
- `CraftingService.GetActiveCraft(player): CraftingState?` / `CancelCraftForPlayer(player, syncClient, bypassLock?)` -> Управление очередью крафта игрока.
- `CraftingService.Init()` -> Обработка `CraftRequest` / `CraftCancel` и возврат ресурсов при выходе/смерти.

### `SurvivalService` (`src/server/Services/SurvivalService.luau`)
- `SurvivalService.GetStats(player): SurvivalStats?` / `GetContainerState(containerId): LootContainerState?` -> Чтение статов выживания.
- `SurvivalService.Init()` -> Тик голода/жажды/регена (`2.0` с), обработка `UseConsumable` и спавн рюкзака лута при смерти.

### `LootService` (`src/server/Services/LootService.luau`)
- `LootService.RollLootTable(tableId): Inventory` -> Генерация лута по весам.
- `LootService.RegisterSlotsContainer(...)` / `RegisterStorageContainer(...)` / `SpawnTemporaryContainer(...)` -> Регистрация временных и постоянных контейнеров с `ProximityPrompt`.
- `LootService.UnregisterContainer(containerId)` / `DestroyContainer(containerId)` -> Удаление контейнера.
- `LootService.OpenContainerForPlayer(player, containerId): boolean` / `CloseContainerForPlayer(player, notifyClient)` -> Открытие/закрытие контейнера с проверкой дистанции.
- `LootService.GetContainerState(containerId)` / `IsContainerDepleted(containerId): boolean` -> Чтение состояния контейнера.
- `LootService.Init()` -> Наполнение POI-ящиков, обработка `LootTakeSlot` / `ContainerDepositSlot`.

### `WorldEventService` (`src/server/Services/WorldEventService.luau`)
- `WorldEventService.TriggerAirdropNow(descentTimeOverride?): Model` -> Немедленный запуск Supply Drop.
- `WorldEventService.GetActiveAirdropModel(): Model?` / `GetActiveAirdropContainerId(): string?` -> Состояние активного аирдропа.
- `WorldEventService.Init()` -> Цикл Supply Drop раз в `420` с.

### `CombatService` (`src/server/Services/CombatService.luau`)
- `CombatService.GetEquippedWeapon(player): (string, WeaponConfig)` -> Активное оружие игрока.
- `CombatService.Init()` -> Обработка `AttackRequest` (хитскан, ближний бой и баллистические снаряды через `Ballistics.Spawn`, урон по постройкам и гуманоидам).

### `ExtractionService` (`src/server/Services/ExtractionService.luau`)
- `ExtractionService.CanAccessMap(player, mapKey, playerBaseTier): (boolean, string?)` -> Проверка допуска к PvP-карте (`MainMap_Tier1/2/3`) по `BaseTier` игрока.
- `ExtractionService.GetExtractionState(player): ExtractionState?` / `IsInCombatCooldown(player): boolean` -> Статус эвакуации игрока.
- `ExtractionService.RecordDamage(player)` -> Сброс таймера эвакуации при получении урона.
- `ExtractionService.Init()` -> Проверка зон эвакуации и телепорт на `PlayerBase`.

### `BuildingValidator` (`src/server/Services/BuildingValidator.luau`)
- `BuildingValidator.QuantizeSocketWorldKey(worldPos: Vector3, slotCategory: string): string` -> Квантованный мировой ключ сокета для защиты от двойного занятия общей грани.
- `BuildingValidator.GetWorldSocketKeyForPiece(pieceType, worldCF): string` -> Возвращает мировой ключ слота для размещённого модуля.
- `BuildingValidator.RegisterOccupationsForRecord(record, playerRecords, occupiedSockets, occupiedWorldKeys)` / `UnregisterSocketsForPiece(uid, occupiedSockets, occupiedWorldKeys)` -> Регистрация и освобождение занятых сокетов (включая смежные грани и квантованные мировые ключи).
- `BuildingValidator.HasSupportingWallOnEdges(anchorEntry, playerRecords, occupiedSockets): boolean` -> Проверяет наличие несущей стены на гранях перед установкой перекрытия.
- `BuildingValidator.CheckParallelWallStacking(targetType, targetCF, allRecordsByUid): (boolean, string?)` -> Блокирует установку параллельных стен (угол между нормалями `< 15°`, радиус `6` studs, расстояние `< 3.5` studs).
- `BuildingValidator.IsInRaidOutpostZone(pieceType, targetCF): boolean` -> Проверяет попадание постройки в зону рейд-кибитки (`RaidOutpostZone`).
- `BuildingValidator.CanReachToolCupboard(playerRecords, occupiedSockets, candidatePiece?): (boolean, string?)` -> Лёгкий BFS-поиск по сокетам `BuildingGeometry` от внешнего периметра до блока с `tool_cupboard` (проходимы открытые грани, `doorway`, `window_wall`, лестницы; глухие `wall` блокируют путь).
- `BuildingValidator.CheckWorldOverlap(pieceType, targetCF, excludeInstances?, isDetachedFoundation?): OverlapCheckResult` -> Проверяет `Workspace:GetPartBoundsInBox` с хитбоксом `0.85` против построек, игроков и запрещённых зон (`POI`, `ExtractionZones`, `AirdropZones`, `ResourceNodes`, `Workbenches`, `RaidTerminal`, `RaidOutpostZone`).
- `BuildingValidator.ValidatePlacement(input): PlacementValidationResult` -> Полная серверная валидация размещения блока (лимит `MaxPerBase`, проверка `RequiredBaseTier` для верстаков, запрет `RaidOutpostZone`, BFS-доступность TC, дистанция `<= 20 + PING_DISTANCE_TOLERANCE`, сокеты, опора, анти-стакинг, коллизии).

### `BaseService` (`src/server/Services/BaseService.luau`)
- `BaseService.ComputeHourlyUpkeep(pieces): { [string]: number }` -> Расчёт часового расхода ресурсов на содержание базы по тирам блоков.
- `BaseService.ComputeBaseTier(pieces, hasActiveTc): number` -> Серверный расчёт `BaseTier` (`0..3`) по наличию TC и количеству/тиру несущих конструкций.
- `BaseService.GetPlayerBaseTier(player): number` -> Текущий `BaseTier` игрока.
- `BaseService.BuildToolCupboardState(player): ToolCupboardState?` -> Сборка состояния шкафа (слоты, статус `Protected`/`Decaying`, `ProtectedHours`, валидность пути BFS).
- `BaseService.ProcessUpkeepAndDecay(player, elapsedSeconds): boolean` -> Списание ресурсов из TC или нанесение периодического урона гниения по внешним блокам (с оффлайн-пересчётом по `os.time()` при входе и тиком каждые `60` с) с пересчётом `BaseTier`.
- `BaseService.IsBaseMode(): boolean` / `CanBuild(player): boolean` -> Проверка разрешения на строительство.
- `BaseService.DamagePiece(uid, rawDamage, damageKind, attacker?): (boolean, boolean)` -> Нанесение урона постройке с записью `LastDamagedAt = os.clock()` и пересчётом `BaseTier` при разрушении.
- `BaseService.GetLivePieceModelsInRadius(origin, radius)` / `GetPlayerPieces(player)` / `GetStorageContainerId(player, uid)` -> Доступ к постройкам игрока.
- `BaseService.Init()` -> Спавн базы (включая `ProximityPrompt` для TC и регистрацию верстаков `workbench_1/2/3`), обработка `BuildPlaceRequest`, `BuildUpgradeRequest`, `BuildDemolishRequest`, `ToolCupboardAction`, `RequestReturnToMap` (с проверкой `ExtractionService.CanAccessMap`), `BuildFeedback` и фоновый цикл Upkeep/Decay.

### `RaidService` (`src/server/Services/RaidService.luau`)
- `RaidService.HasExplosionLineOfSight(blastOrigin, targetModel, excludeInstances?, isCharacterTarget?): boolean` -> Проверка LoS взрыва с окклюзией стенами.
- `RaidService.TriggerExplosion(params: ExplosionParams): ExplosionResult` -> Расчёт AoE-взрыва с учётом `ExplosionResistance` тира и записью `LastDamagedAt = os.clock()` при любом уроне.
- `RaidService.EnterStudioMockRaid(player, targetUserId): boolean` / `IsPlayerInRaid(player): boolean` / `GetActiveSessionInfo(player): RaidHudState?` -> Управление рейд-сессией (спавн моделей через `BuildingGeometry.CreateModel` и `ApplyTierVisuals`, лут из `storage_box` и `tool_cupboard`).
- `RaidService.Init()` -> Обработка `RaidListRequest`, `StartRaidRequest` (с проверкой `attackerBaseTier >= targetBaseTier` для баз Tier 2/3), `PlaceExplosiveRequest`, `RaidExtractRequest`.

---

## 4. Клиентские контроллеры (`StarterPlayer.StarterPlayerScripts.Client.Controllers`)

- `InventoryController`: `.Changed`, `.GetInventory()`, `.GetSlot(slotIndex)`, `.OnChanged(cb)`, `.RequestMove(from, to)`, `.Init()`.
- `HotbarController`: `.SelectionChanged`, `.SelectSlot(slotIndex)`, `.GetSelectedSlot()`, `.Init()`.
- `InventoryUIController`: `.OpenChanged`, `.IsOpen()`, `.SetOpen(open)`, `.Toggle()`, `.Init()`.
- `CraftingController`: `.IsOpen()`, `.SetOpen(open)`, `.Toggle()`, `.GetActiveCraft()`, `.Init()`.
- `GatheringController`: `.GetNodeState(nodeId)`, `.IsCursorOnActiveNode()`, `.Init()`.
- `SurvivalHudController`: `.Init()`.
- `ConsumableController`: `.Init()`.
- `LootController`: `.OpenChanged`, `.IsOpen()`, `.GetActiveContainerId()`, `.CanDeposit()`, `.RequestDeposit(playerSlot)`, `.Close()`, `.Init()`.
- `CombatController`: `.Init()`.
- `ProjectileController`: `.SpawnLocalProjectile(id, origin, dir, char): string`, `.GetActiveVisualCount(): number`, `.Init()`.
- `WorldEventController`: `.IsBannerVisible(): boolean`, `.GetActiveBeaconCount(): number`, `.Init()`.
- `ExtractionController`: `.IsVisible(): boolean`, `.GetState(): ExtractionState?`, `.Init()`.
- `BuildingController`: `.IsBaseMode()`, `.CanBuild()`, `.IsBuildMode()`, `.SetBuildMode(enabled)`, `.GetPieces()`, `.Init()` — активация по экипировке `building_plan` (превью размещения) или `hammer` (апгрейд/демонтаж по ЛКМ/ПКМ и клавишам) как на `PlayerBase`, так и в разрешённых зонах `MainMap`/Studio; кэшированный `RaycastParams`; фантом через `BuildingGeometry.CreateModel` с подсветкой **зелёный** (сетка) / **синий** (сокет) / **красный** (ошибка/коллизия/`> 20` studs); панель `BaseActionBar` с индикатором `BaseTier`, выбором карты `MainMap_Tier1/2/3` и уведомлениями `BuildFeedback`.
- `ToolCupboardController`: `.IsOpen()`, `.Close()`, `.GetState()`, `.Init()` — окно Tool Cupboard (12 слотов содержания, быстрый депозит ресурсов `wood`/`stone`/`metal_ore`/`high_quality_metal`, отображение `BaseTier`, статуса `Protected`/`Decaying`, расхода в час и валидности пути до TC).
- `RaidController`: `.IsInRaid()`, `.IsSelectionOpen()`, `.GetHudState()`, `.OpenTargetList()`, `.CloseTargetList()`, `.Init()`.
