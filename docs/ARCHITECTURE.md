# Архитектура проекта MyRobloxGame

## 1. Структура Rojo и точка входа
- `src/shared` -> `ReplicatedStorage.Shared`
- `src/server` -> `ServerScriptService.Server` (`init.server.luau` вызывает `service.Init()` для `Services/`)
- `src/client` -> `StarterPlayer.StarterPlayerScripts.Client` (`init.client.luau` вызывает `controller.Init()` для `Controllers/`)
- Детальный баланс, пострелизные механики и QA-стенды -> [`docs/BALANCE.md`](BALANCE.md).
- Нагрузочные замеры и бенчмарки -> [`docs/BENCHMARKS.md`](BENCHMARKS.md).

---

## 2. Shared-модули (`ReplicatedStorage.Shared`)

### `Config` (`src/shared/Config.luau`)
- `Game`, `Places`, `Maps`, `MapOrder` -> Параметры игры, привязка `MainMap_Tier1/2/3` к `RequiredBaseTier` (`1..3`).
- `BaseProgression`, `Upkeep`, `Decay` -> Пороги `BaseTier`, часовой расход TC, интервал гниения (`60` с) и множитель `NoTcMultiplier`.
- `Extraction`, `Explosion`, `MapLootScaling` -> Таймеры экстракции, формула взрыва (`UpgradeRaidBlockSeconds = 30`, `DoorDamageMultiplier = 1.6`) и множители лута (`1.0 / 1.35 / 1.75`).
- `MAX_TC_WALL_LAYERS = 2`, `MIN_TURRET_DISTANCE = 14`, `MIN_TRAP_DISTANCE = 6`, `WORKBENCH_RADIUS = 16` -> Лимиты защиты базы и радиус верстаков.
- `BASE_WALK_SPEED`, `SPRINT_WALK_SPEED`, `MAX_STAMINA`, `WELL_FED_*`, `COMBAT_REGEN_COOLDOWN` -> Параметры спринта, выносливости и сытости.
- `VendorHub`, `Raid`, `DefenseCapacity`, `Recycler` -> Параметры Safe Hub, рейдов (`MaxLives = 3`, `TcHackDuration = 10`, `OutpostRadius = 28`), бюджета защит (`[0..3] = 30/60/100/150`) и переработчика.

### `Types` (`src/shared/Types.luau`)
- Константы: `INVENTORY_SIZE = 30`, `HOTBAR_SIZE = 6`, `MAX_GATHER_DISTANCE_SERVER = 14`, `MAX_LOOT_DISTANCE = 14`, `MAX_BUILD_DISTANCE = 20`, `CURRENT_SCHEMA_VERSION = 9`, `CURRENT_DATA_VERSION = 9`.
- Основные типы: `PlayerData`, `InventorySlot`, `SurvivalStats`, `BuildPieceType`, `BuildTier`, `SavedBuildPiece`, `BaseSnapshot`, `BaseBlueprintSlot`, `ToolCupboardState`, `RaidIntelCard`, `RaidHudState`, `ExtractionState`, `TransferPayload`, `BallisticShotRequest`, `ExplosionRequest`, `NetResult<T>`.
- `Types.IsFiniteNumber`, `IsValidInteger`, `IsValidString`, `IsValidVector3`, `IsValidInventorySlot`, `IsValidModuleType`, `IsValidBuildingTier`, `IsValidShotRequest`, `IsValidExplosionRequest`, `IsValidTransferPayload`, `IsValidBuildPlaceArgs` -> Runtime-валидация сетевых аргументов.

### `Signal` (`src/shared/Signal.luau`) & `Janitor` (`src/shared/Janitor.luau`)
- `Signal.new<T...>(): Signal<T...>` -> Типизированный сигнал (`:Connect`, `:Once`, `:Fire`, `:Destroy`).
- `Janitor.new(): Janitor` -> Менеджер очистки ресурсов (`:Add`, `:Cleanup`, `:Destroy`).

### `Net` (`src/shared/Net.luau`)
- `Net.Events` -> Единый реестр имён всех `RemoteEvent`.
- `Net.InitServer()` / `Net.GetEvent(eventName): RemoteEvent` -> Создание папки `Remotes` и кэшированный доступ к `RemoteEvent`.

### `Ballistics` (`src/shared/Ballistics.luau`)
- `Ballistics.IsIgnoredCharacterPart(inst)` / `IsSmokeVolume(inst)` -> Фильтрация аксессуаров, визуала оружия и объёмов дыма (`SmokeVolume`).
- `Ballistics.ClassifyHitZone(hitPart)` / `ResolveHitZoneMultiplier(hitPart, headshotMult?)` -> Классификация хитбокса (`Head`/`Torso`/`Limb`) и множителя урона.
- `Ballistics.ComputeDistanceFalloff(...)` / `ComputeFinalDamage(...)` -> Расчёт падения урона с дистанцией и финального урона.
- `Ballistics.CastHitscan(origin, unitDir, range, baseExclude, blockOnSmoke?)` -> Серверный hitscan-рейкаст с отсечкой по `SmokeVolume`.
- `Ballistics.ComputePosition` / `ComputeVelocity` / `ComputeCFrame` -> Кинематика параболического снаряда.
- `Ballistics.Spawn(options)` / `Cancel(id)` / `GetActiveCount()` -> Симуляция снарядов на `Heartbeat`.

### Конфиги (`src/shared/configs/`)
- `Items.luau`, `Consumables.luau`, `Tools.luau`, `Nodes.luau`, `Recipes.luau` -> Декларативные таблицы предметов, расходников, инструментов, нод и 27+ рецептов крафта.
- `Vendors.luau`, `Recycling.luau`, `Weapons.luau`, `Projectiles.luau`, `Explosives.luau`, `LootTables.luau`, `NPCs.luau`, `Defenses.luau` -> Данные торговцев, переработки, оружия, снарядов, взрывчатки, лута, NPC и защит.
- `BuildingConfig.luau` -> Параметры сетки (`GridSize = 12`, `WallHeight = 10`), `PieceOrder` (26 модулей), тиры и `BuildingConfig.ComputeExplosionDamage(rawDamage, pieceType, tier, hasDoor?)`.

### `BaseSerializer` (`src/shared/BaseSerializer.luau`)
- `BaseSerializer.PackBuffer(blocks, originCFrame?)` / `UnpackBuffer(buf, originCFrame?)` -> Упаковка/распаковка бинарного буфера построек (`FORMAT_VERSION = 1`, `HEADER_SIZE = 7`, `BLOCK_STRIDE = 12`, `MAX_BLOCKS = 200`).
- `BaseSerializer.EncodeBase64(buf)` / `DecodeBase64(encoded)` / `ComputeCRC32(buf)` -> Base64 и контрольная сумма IEEE CRC32.
- `BaseSerializer.SerializeBase(blocks, originCFrame?)` / `DeserializeBase(encoded, originCFrame?)` -> Сериализация базы и чертежей в Base64-строку.

### `BuildingGeometry` (`src/shared/BuildingGeometry.luau`)
- `CanonicalPieceType(pieceType)` / `IsFullHeightWall(pieceType)` / `GetWallBodyHeight(pieceType)` -> Нормализация типов и высоты стен (`wall`, `half_wall`, `quarter_wall`).
- `ComposeWorldCFrame(x, y, z, rotY)` / `GetPieceWorldCFrame(piece, originOffset?)` -> Сборка мирового `CFrame` с опорой на нижнюю плоскость.
- `ComputeMaxHp(pieceType, tier)` -> Максимальный HP блока.
- `CreateModel(pieceType, worldCF, isGhost, nameOverride?, mountSurface?)` -> Генерация примитивной модели (`Part`/`WedgePart`) с `PrimaryPart`.
- `ApplyTierVisuals(model, pieceType, tier)` / `ApplyWearVisuals(model, pieceType, tier, hp, maxHp)` -> Материалы тира и визуальный износ (`< 60%` / `< 30%` HP).
- `AttachDoorPanel(model, worldCF, tier, isOpen?)` / `SetDoorOpen(model, isOpen)` -> Створка двери в `doorway`.
- `SetGhostColor(model, color)` -> Окраска фантома (`Green`/`Blue`/`Red`).
- `GetPieceSockets(pieceType)` / `IsSocketCompatible(...)` / `GetSocketSlotKey(...)` / `ComputeSnappedCFrame(...)` -> Граф сокетов и привязка модулей.
- `GetOverlapBoxes(...)` / `IsNoBuildInstance(inst, allowRaidOutpost?)` / `CheckWorldOverlap(...)` -> Проверка OBB/`WedgePart` коллизий и запрещённых зон.

---

## 3. Серверные сервисы (`ServerScriptService.Server.Services`)

### `SecurityService` (`src/server/Services/SecurityService.luau`)
- `CheckRateLimit(player, remoteName, cost?)` -> Token Bucket лимитер входящих пакетов.
- `IsFiniteNumber` / `IsValidInteger` / `IsValidString` / `IsValidVector3` / `IsValidCFrame` -> Type-guards входных данных.
- `GetAliveCharacterRoot(player)` / `IsWithinDistance(player, targetPos, maxDist, pingTol?)` -> Проверка живого персонажа и дистанции.
- `RunLocked(player, reason, fn)` -> Per-player мьютекс транзакций.
- `SetTeleportLock` / `IsTeleportLocked` / `SetActiveContainer` / `ClearActiveContainer` / `IsActiveContainerOutOfRange` -> Блокировка телепорта и контроль дистанции контейнера.

### `DataService` (`src/server/Services/DataService.luau`)
- `CURRENT_SCHEMA_VERSION` (`9`) & `MigrateProfileData(rawData)` -> Цепочка миграций `v1..v9` до `Profile:Reconcile()`.
- `SetTransferLock` / `IsTransferLocked` / `SetTransferring` / `IsTransferring` / `IsTeleporting` -> Блокировка мутаций на время межплейсового перехода.
- `ComputeInventoryHash(inv, equip?)` / `GetPlayerInventoryHash(player)` -> 64-битный хеш (`CRC32 + FNV-1a`) для анти-дюп сверки.
- `FlushBeforeUnload` / `ResetUnloadFlag` / `SetArrivalHandler` / `LoadProfileForPlayer` -> Сброс `OnBeforeUnload` и загрузка `ProfileStore` с ретраями `SessionLock`.
- `GetData` / `GetProfileSnapshot` / `GetInventorySlot` / `SetInventorySlot` / `GetField` / `SetField` / `UpdateProfile` -> Безопасные геттеры/сеттеры профиля.
- `OnDataLoaded` / `OnBeforeUnload` / `ReleaseForTeleport` / `RestoreAfterFailedTeleport` -> Жизненный цикл профиля.
- `RegisterRaidableBase` / `GetRaidTargets` / `GetPresetTier` / `LoadBaseSnapshot` / `RecordRaidDefenseReport` / `ConsumeDefenseReports` / `AppendDefenseLog` -> Индексация баз, пресеты и отчёты обороны.

### `TeleportService` (`src/server/Services/TeleportService.luau`)
- `TransferPlayer(player, options): TransferReceipt` -> Транзакционный переход **Commit-Before-Teleport** (Lock -> Flush + `InventoryHash` + `TransferNonce` в `MemoryStoreService` -> `ReleaseForTeleport` -> `TeleportAsync` с откатом при сбое).
- `OnPlayerArrived(player)` -> Атомарный consume `TransferNonce`, ожидание `SessionLock` и сверка `ExpectedInventoryHash`.
- `GetArrivedPayload(player)` / `GetLastReceipt(player)` / `Init()` -> Инициализация строго до `DataService`.

### `CreativeService` (`src/server/Services/CreativeService.luau`)
- `IsCreative(player): boolean` -> Авторитарный серверный флаг креатива (без чтения клиентских атрибутов).
- `ApplyPlayerDamage(humanoid, amount)` -> Урон с порогом `HP >= 1` для игроков в креативе.
- `Init()` -> Чат-команды `/creative` и `/giveall` (только в Studio или для `CreatorId`).

### `InventoryService` (`src/server/Services/InventoryService.luau`)
- `GetEquippedSlot` / `GetEquippedItem` / `GetSlot` / `GetItemCount` / `HasItems` / `CanCraftTransaction` -> Чтение слотов и проверка ресурсов/вместимости.
- `AddItem` / `AddItemToSlot` / `AddItems` / `RemoveItem` / `RemoveItems` / `ConsumeSlot` / `ClearInventory` -> Атомарные операции с инвентарём + `InventorySync`.

### `ResourceService` (`src/server/Services/ResourceService.luau`)
- `Init()` -> Обработка `HitNode`, кулдауны, рассылка `NodeUpdated` и респавн ресурсных нод.

### `CraftingService` (`src/server/Services/CraftingService.luau`)
- `RegisterStation` / `UnregisterStation` / `GetPlayerWorkbenchTier` / `GetActiveCraft` / `CancelCraftForPlayer` -> Учёт верстаков (`workbench_1..3`), костров (`campfire`) и очереди крафта.
- `Init()` -> Обработка `CraftRequest` / `CraftCancel` (проверка `WorkbenchTier`, `Station` и `BlueprintService.CanCraftRecipe`), синхронизация `WorkbenchTier` и `NearCampfire`.

### `BlueprintService` (`src/server/Services/BlueprintService.luau`)
- `CanCraftRecipe(player, recipeId)` / `HasBlueprint(player, recipeId)` / `LearnBlueprintScroll(player, itemId)` / `UnlockAllBlueprints(player)` -> Управление `UnlockedBlueprints` и изучение свитков `bp_*`.
- `Init()` -> Обработка `ResearchItemRequest` и `LearnBlueprintRequest` на `research_table`, синхронизация `BlueprintSync`.

### `RecyclerService` (`src/server/Services/RecyclerService.luau`)
- `Init()` -> Очередь переработки (`6 -> 6` слотов, тик `3.0` с, `EfficiencyMultiplier` `1.2` РТ / `0.8` Safe Hub), обработка `RecyclerAction` и `RecyclerStateSync`.

### `VendorService` (`src/server/Services/VendorService.luau`)
- `SpawnBaseVendorHub()` / `DespawnBaseVendorHub()` / `BindStaticVendorHub(container)` -> Управление зоной `VendorHubZone` на `PlayerBase` и в `QA_TestArena`.
- `Init()` -> Обработка `VendorOpen`, `VendorTradeRequest` и `VendorStarterKitRequest` (`quartermaster`).

### `SurvivalService` (`src/server/Services/SurvivalService.luau`)
- `GetStats` / `GetStamina` / `AddStamina` / `ResetSprintState` / `ApplyBleeding` / `ClearBleeding` -> Статы выживания, выносливость, кровотечение и `WellFed`.
- `Init()` -> Тик выживания (`2.0` с), `Heartbeat` спринта (`16 <-> 24` с `SlowMultiplier`), `UseConsumable` и спавн рюкзака при смерти.

### `LootService` (`src/server/Services/LootService.luau`)
- `RollLootTable(tableId, mapTierOverride?)` -> Генерация лута с `Config.MapLootScaling`.
- `RegisterSlotsContainer` / `RegisterStorageContainer` / `SpawnTemporaryContainer` / `UnregisterContainer` / `DestroyContainer` -> Жизненный цикл контейнеров.
- `OpenContainerForPlayer` / `CloseContainerForPlayer` / `GetContainerState` / `IsContainerDepleted` / `DepositToStorageContainer` / `ClearContainerSlots` -> Работа с открытыми контейнерами.

### `WorldEventService` (`src/server/Services/WorldEventService.luau`)
- `TriggerAirdropNow(descentTimeOverride?)` / `GetActiveAirdropModel()` / `GetActiveAirdropContainerId()` / `Init()` -> Цикл Supply Drop (раз в `420` с).

### `CombatService` (`src/server/Services/CombatService.luau`)
- `GetEquippedWeapon(player)` / `Init()` -> Валидация `AttackRequest` (`BallisticShotRequest`), `FireRate`, `validateAttackOrigin`, параболические снаряды (`Ballistics.Spawn`), hitscan с `SmokeVolume`, секторный ближний бой и урон по постройкам.

### `NPCService` (`src/server/Services/NPCService.luau`)
- `GetActiveCount()` / `SpawnFromMarker(marker)` / `DespawnAll()` / `Init()` -> ИИ охранников/учёных РТ, мирных животных и хищников (только `MainMap` при активных игроках), лут-мешки и респавн.

### `ExtractionService` (`src/server/Services/ExtractionService.luau`)
- `CanAccessMap(player, mapKey, playerBaseTier)` / `GetExtractionState(player)` / `IsInCombatCooldown(player)` / `RecordDamage(player)` / `Init()` -> Допуск к `MainMap_Tier1/2/3`, зоны эвакуации и переход через `TeleportService`.

### `BuildingValidator` (`src/server/Services/BuildingValidator.luau`)
- `ComputeDefenseCapacity(pieces, baseTier)` -> Подсчёт бюджета `DefenseCapacity`.
- `QuantizeSocketWorldKey` / `GetWorldSocketKeyForPiece` / `RegisterOccupationsForRecord` / `UnregisterSocketsForPiece` -> Учёт занятых сокетов и общих граней.
- `HasSupportingWallOnEdges` / `CheckParallelWallStacking` / `IsInRaidOutpostZone` / `IsPointInRaidOutpostOrBuffer` -> Проверки опор, анти-стакинга (включая вертикальные интервалы `half_wall`/`quarter_wall`) и зоны кибитки.
- `CheckMaxWallsToTC` (`CanReachToolCupboard`) -> 0-1 BFS подсчёт слоёв защиты до TC (`<= 2`, учёт `half_wall` и `sloped_roof`).
- `FindUnsupportedPieces(pieces, removedUids?)` -> BFS устойчивости от фундаментов (исключая `quarter_wall`).
- `CheckWorldOverlap(...)` / `ValidatePlacement(input)` -> Полная валидация размещения блоков и защит (включая запрет надстройки на `quarter_wall` и `WedgePart` probe).

### `DefenseService` (`src/server/Services/DefenseService.luau`)
- `BindRaidHooks(hooks)` / `RegisterDefense(options)` / `UnregisterDefense(uid)` / `UpdateDefenseHp(uid, hp, maxHp?)` / `DisableTurretsInRadius(origin, radius, duration)` / `GetActiveCount()` -> Реестр ловушек, турелей и `hbhf_sensor`/`smart_door`, ЭМИ-отключение.
- `Init()` -> Патроны (`DefenseSync`/`DefenseAction`), цикл `Heartbeat` с LoS-проверкой (и обрывом на `SmokeVolume`), `hbhf_sensor` -> `smart_door`, `SlowMultiplier`.

### `BaseService` (`src/server/Services/BaseService.luau` + `Base/`)
- Подмодули:
  - `Base/BaseUpkeep.luau` -> `BaseTier`, содержание, `ProcessUpkeepAndDecay`, начисление `Scrap`/лута в TC, `PackBaseSnapshot`/`UnpackBaseSnapshot`, `ValidateLoadedBasePieces`.
  - `Base/BaseBlueprints.luau` -> Сохранение/загрузка планировок базы (`builtin_2x2` + 2 слота).
  - `Base/BaseGhosts.luau` -> Спавн и очистка призраков павших рейдеров (`SpawnSessionDeathGhosts`, `ClearSessionGhosts`).
- `GetBaseOrigin` / `SerializePlayerBase` / `LoadSerializedBase` / `ComputeHourlyUpkeep` / `ComputeBaseTier` / `GetPlayerBaseTier` / `BuildToolCupboardState` / `ProcessUpkeepAndDecay` -> Управление базой и TC.
- `IsBaseMode` / `CanBuild` / `DamagePiece` / `GetLivePieceModelsInRadius` / `GetPlayerPieces` / `GetStorageContainerId` / `DepositItemsToPlayerBase` / `DepositScrapToToolCupboard` -> Постройки и урон.
- `BindRaidHooks` / `Init()` -> Стройка, апгрейд, ремонт (`BuildRepairRequest`), снос, `ToolCupboardAction` (включая `Self-Raid` и планировки) и цикл Upkeep/Decay.

### `RaidService` (`src/server/Services/RaidService.luau` + `Raid/`)
- Подмодули:
  - `Raid/RaidIntel.luau` -> `ComputeBaseIntel`, `BuildPresetBaseForTarget`, `GetIntelPool`, `RefreshIntelPool`.
  - `Raid/RaidExplosives.luau` -> `CreateExplosiveVisual`, `HasExplosionLineOfSight` (5-лучевая окклюзия), `TriggerExplosion`, `DetonateExplosive`, `TriggerEmpPulse`, `TriggerSmokeCloud`.
  - `Raid/RaidOutpost.luau` -> `SpawnRaidOutpost`, `ExtractionStash`, `RaidSupplyCrate`, `CollectStashBatch`, `SpawnDroppedLootBag`.
- `HasExplosionLineOfSight` / `TriggerExplosion` / `TriggerEmpPulse` / `TriggerSmokeCloud` / `DamageRaidPiece` / `NotifyRaiderDamaged` -> Взрывы, тактические гаджеты и урон в рейде.
- `EnterStudioMockRaid` / `StartSelfRaid` / `IsPlayerInRaid` / `GetActiveSessionInfo` / `Init()` -> Сессии рейда/Self-Raid, взлом TC, 18с экстракция `ExtractionStash` и онлайн-сигнализация (`MessagingService`).

---

## 4. Клиентские контроллеры (`StarterPlayer.StarterPlayerScripts.Client.Controllers`)

- `InventoryController`: `.Changed`, `.GetInventory()`, `.GetSlot(i)`, `.OnChanged(cb)`, `.RequestMove(from, to)`, `.Init()`.
- `HotbarController`: `.SelectionChanged`, `.SelectSlot(i)`, `.GetSelectedSlot()`, `.Init()`.
- `InventoryUIController`: `.OpenChanged`, `.IsOpen()`, `.SetOpen(open)`, `.Toggle()`, `.RegisterSlotInterceptor(fn)`, `.Init()`.
- `CraftingController`: `.OpenChanged`, `.IsOpen()`, `.SetOpen(open)`, `.Toggle()`, `.GetActiveCraft()`, `.GetWorkbenchTier()`, `.Init()`.
- `BlueprintController`: `.HasBlueprint(recipeId)`, `.IsResearchOpen()`, `.CloseResearch()`, `.Init()` — интерфейс `research_table` и фильтр чертежей.
- `RecyclerController`: `.IsOpen()`, `.Close()`, `.Init()` — окно переработчика (`RecyclerGui`) с депозитом и `Take All Output`.
- `VendorController`: `.OpenChanged`, `.IsOpen()`, `.GetActiveVendorId()`, `.SetOpen(open)`, `.Init()`.
- `GatheringController`: `.GetNodeState(nodeId)`, `.IsCursorOnActiveNode()`, `.Init()`.
- `SurvivalHudController`: `.Init()` — полосы HP (`Well Fed`), голода, жажды, стамины, кровотечения и бейдж `CREATIVE MODE`.
- `MovementController`: `.Init()` — запрос спринта (`LeftShift` / сенсорная кнопка) и `SprintStateRequest`.
- `ConsumableController`: `.Init()` — использование расходников и изучение свитков `bp_*`.
- `LootController`: `.OpenChanged`, `.IsOpen()`, `.GetActiveContainerId()`, `.CanDeposit()`, `.RequestDeposit(slot)`, `.Close()`, `.Init()`.
- `CombatController`: `.Init()` — прицел, хитмаркер, отдача, разброс, натяжение лука и метание гранат.
- `ProjectileController`: `.SpawnLocalProjectile(...)`, `.GetActiveVisualCount()`, `.Init()` — визуал ракет, стрел и гранат (`emp_grenade`, `smoke_grenade`).
- `WorldEventController`: `.IsBannerVisible()`, `.GetActiveBeaconCount()`, `.Init()`.
- `ExtractionController`: `.IsVisible()`, `.GetState()`, `.Init()`.
- `BuildingController`: `.IsBaseMode()`, `.CanBuild()`, `.IsBuildMode()`, `.SetBuildMode(enabled)`, `.GetPieces()`, `.Init()` — превью строительства (`building_plan`, `hammer`, `repair_hammer`, ловушки), кэшированный `RaycastParams` и палитра блоков.
- `ToolCupboardController`: `.IsOpen()`, `.Close()`, `.GetState()`, `.Init()` — окно TC (содержание, `BaseTier`, слои защиты, `DefenseCapacity`, вкладка «Планировки» и кнопка `Self-Raid`).
- `DefenseController`: `.IsOpen()`, `.Close()`, `.Init()` — окно турелей/ловушек, трассеры, лазер, ЭМИ-искры (`TurretEmp`).
- `RaidController`: `.IsInRaid()`, `.IsSelectionOpen()`, `.GetHudState()`, `.OpenTargetList()`, `.CloseTargetList()`, `.Init()` — Рейд-терминал (3 карточки), рейд-HUD, баннер тревоги `RaidAlarmFrame` и `DefensePrepOverlay`.
