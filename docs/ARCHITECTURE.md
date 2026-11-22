# Архитектура проекта MyRobloxGame

## 1. Структура Rojo и точка входа
Маппинг из `default.project.json`:
- `src/shared` -> `ReplicatedStorage.Shared`
- `src/server` -> `ServerScriptService.Server`
- `src/client` -> `StarterPlayer.StarterPlayerScripts.Client`

Инициализация:
- Сервер (`src/server/init.server.luau`): перебирает все `ModuleScript` в `Services/` и вызывает `service.Init()`.
- Клиент (`src/client/init.client.luau`): перебирает все `ModuleScript` в `Controllers/` и вызывает `controller.Init()`.

---

## 2. Shared-модули (`ReplicatedStorage.Shared`)

### `Config` (`src/shared/Config.luau`)
- `Game = { Name: string, MaxPlayers: number }`
- `Places = { MainMap: number, PlayerBase: number }` (`MainMap = 115796771630565`, `PlayerBase = 133157812100009`)
- `Extraction = { Duration: number, CooldownAfterDamage: number }` (`Duration = 8`, `CooldownAfterDamage = 5`)

### `Types` (`src/shared/Types.luau`)
Экспортируемые типы:
- `ItemType = "Resource" | "Tool" | "Consumable"`
- `ItemConfig = { Name: string, Type: ItemType, MaxStack: number }`
- `Slot = { Id: string, Count: number }`
- `Inventory = { [number]: Slot? }`
- `SurvivalStats = { Health: number, Hunger: number, Thirst: number }`
- `ConsumableConfig = { Health: number, Hunger: number, Thirst: number, UseCooldown: number }`
- `LootContainerState = { ContainerId: string, OwnerName: string, Slots: Inventory, ExpiresAt: number }`
- `BuildPieceType = "foundation" | "wall" | "doorway" | "roof" | "storage_box" | "workbench_1"`
- `BuildTier = "wood" | "stone" | "metal"`
- `SavedBuildPiece = { Uid: string, PieceType: BuildPieceType, Tier: BuildTier, GridX: number, GridY: number, GridZ: number, RotY: number, Hp: number, Storage: { [string]: Slot }? }`
- `BaseData = { Pieces: { SavedBuildPiece } }`
- `BuildPieceConfig = { Name: string, Cost: { [string]: number }, BaseHp: number, Upgradeable: boolean, StorageSlots: number? }`
- `BuildTierConfig = { Name: string, HpMultiplier: number, UpgradeCost: { [string]: number }? }`
- `PlayerData = { DataVersion: number, Version: number, Inventory: Inventory, Stats: SurvivalStats, Base: BaseData }`
- `ItemBatchEntry = { Id: string, Count: number }`
- `ToolCategory = "Tree" | "Rock" | "Ore"`
- `ToolConfig = { Power: number, Cooldown: number, PreferredNodeType: ToolCategory, BonusMultiplier: number }`
- `NodeType = "tree" | "stone_node" | "metal_node"`
- `NodeConfig = { Name: string, Category: ToolCategory, MaxHp: number, ResourceId: string, YieldPerHit: number, BonusOnDestroy: number, RespawnTime: number }`
- `NodeClientState = { Hp: number, MaxHp: number, Depleted: boolean }`
- `Ingredient = { Id: string, Count: number }`
- `RecipeConfig = { Id: string, ResultId: string, ResultCount: number, CraftTime: number, Station: string?, Ingredients: { Ingredient } }`
- `CraftingState = { RecipeId: string, StartTime: number, EndTime: number }`
- `WeaponCategory = "Melee" | "Ranged"`
- `WeaponConfig = { Category: WeaponCategory, Damage: number, HeadshotMultiplier: number, Range: number, Cooldown: number, AmmoId: string?, ProjectileId: string? }`
- `LootDropEntry = { Id: string, Weight: number, MinCount: number, MaxCount: number }`
- `LootTableConfig = { Rolls: number, RespawnTime: number, Items: { LootDropEntry } }`
- `WorldEventPayload = { EventType: string, Title: string, Position: Vector3, Duration: number }`
- `ExtractionState = { Active: boolean, ZoneName: string, TimeLeft: number, TotalTime: number, StatusText: string? }`
- `ExplosiveConfig = { StructureDamage: number, PlayerDamage: number, Radius: number, FuseTime: number }`
- `ProjectileConfig = { Id: string, Speed: number, Gravity: number, MaxLifetime: number, BlastRadius: number, StructureDamage: number, PlayerDamage: number, MinFalloffMultiplier: number }`
- `ExplosionParams = { Origin: Vector3, Radius: number, StructureDamage: number, PlayerDamage: number, Attacker: Player?, SourceId: string?, ProjectileId: string?, ExcludeInstances: { Instance }?, MinFalloffMultiplier: number? }`
- `ExplosionResult = { DamagedStructures: number, DestroyedStructures: number, DamagedHumanoids: number, OccludedStructures: number, OccludedHumanoids: number }`
- `RaidTargetInfo = { UserId: number, DisplayName: string, PieceCount: number }`
- `RaidHudState = { Active: boolean, TargetName: string, TimeLeft: number, StatusText: string? }`

Константы:
- `INVENTORY_SIZE = 30`, `HOTBAR_SIZE = 6`
- `HANDS_POWER = 5`, `HANDS_COOLDOWN = 0.8`, `BASE_TOOL_MULTIPLIER = 1.0`
- `MAX_GATHER_DISTANCE_SERVER = 14`, `MAX_GATHER_DISTANCE_CLIENT = 12`
- `MAX_STATION_DISTANCE = 14`
- `MAX_HEALTH = 100`, `MAX_HUNGER = 100`, `MAX_THIRST = 100`
- `RESPAWN_HEALTH = 100`, `RESPAWN_HUNGER = 80`, `RESPAWN_THIRST = 80`
- `SURVIVAL_TICK_INTERVAL = 2.0`, `MAX_LOOT_DISTANCE = 14`, `LOOT_CONTAINER_LIFETIME = 300`
- `MAX_ATTACK_ORIGIN_OFFSET = 8`
- `MAX_EXPLOSIVE_PLACE_DISTANCE = 14`, `RAID_DURATION = 300`
- `CURRENT_DATA_VERSION = 1`, `PING_DISTANCE_TOLERANCE = 2`
- `MAX_BUILD_DISTANCE = 72`, `MAX_RAID_TERMINAL_DISTANCE = 24`
- `MAX_PROJECTILE_LIFETIME = 10`, `MAX_ACTIVE_PROJECTILES_PER_PLAYER = 3`

### `Signal` (`src/shared/Signal.luau`)
- `Signal.new<T...>(): Signal<T...>`
  - `:Connect(fn: (T...) -> ()): Connection`
  - `:Once(fn: (T...) -> ()): Connection`
  - `:Fire(...: T...)`
  - `:Destroy()`
- `Connection`: `{ Connected: boolean, Disconnect: (self: Connection) -> () }`

### `Janitor` (`src/shared/Janitor.luau`)
- `Janitor.new(): Janitor`
  - `:Add<T>(item: T, methodName: string?): T` — регистрирует `RBXScriptConnection`, `Instance`, `function` или таблицу-объект.
  - `:Cleanup()` — очищает все добавленные ресурсы в обратном порядке (LIFO).
  - `:Destroy()` — вызывает `:Cleanup()`.

### `Ballistics` (`src/shared/Ballistics.luau`)
Общий детерминированный симулятор баллистической траектории (используется сервером для авторитетного полёта/попаданий и клиентом для визуализации):
- `Ballistics.ComputePosition(origin: Vector3, initialVelocity: Vector3, gravity: Vector3, elapsed: number): Vector3` — кинематика `p0 + v*t + 0.5*g*t^2`.
- `Ballistics.ComputeVelocity(initialVelocity: Vector3, gravity: Vector3, elapsed: number): Vector3` — мгновенная скорость `v0 + g*t`.
- `Ballistics.ComputeCFrame(position: Vector3, velocity: Vector3): CFrame` — ориентация снаряда по вектору скорости (`CFrame.lookAt`).
- `Ballistics.Spawn(options: SpawnOptions): string` — запускает снаряд с ленивой подпиской на `RunService.Heartbeat` (шаг `<= 0.1` сек, пошаговый сегментный `Workspace:Raycast` между предыдущей и следующей позицией с пропуском `CanCollide == false` не-террейн деталей и вызовом `OnStep` / `OnHit` / `OnExpire`). При опустошении списка активных снарядов `Heartbeat` отключается.
- `Ballistics.Cancel(projectileId: string): boolean` — досрочно отменяет симуляцию снаряда.
- `Ballistics.GetActiveCount(): number` — возвращает текущее количество активных снарядов.

### `Net` (`src/shared/Net.luau`)
Хранилище `RemoteEvent` в `ReplicatedStorage.Remotes`:
- `Net.Events`:
  - `InventorySync` (Server -> Client): `(inventory: Types.Inventory)`
  - `InventoryMove` (Client -> Server): `(fromSlot: number, toSlot: number)`
  - `HotbarSelect` (Client -> Server): `(slot: number)`
  - `HitNode` (Client -> Server): `(nodeId: string)`
  - `NodeUpdated` (Server -> Client): `(nodeId: string, hp: number, maxHp: number, depleted: boolean)`
  - `CraftRequest` (Client -> Server): `(recipeId: string)`
  - `CraftCancel` (Client -> Server): `()`
  - `CraftStateSync` (Server -> Client): `(state: Types.CraftingState?)`
  - `UseConsumable` (Client -> Server): `(slotIndex: number)`
  - `OpenContainer` (Server -> Client): `(containerId: string, title: string, slots: { [string]: Types.Slot }, maxSlots: number?, allowDeposit: boolean?)`
  - `CloseContainer` (Client <-> Server): `(containerId: string?)`
  - `LootTakeSlot` (Client -> Server): `(containerId: string, containerSlot: number, targetPlayerSlot: number?)`
  - `ContainerDepositSlot` (Client -> Server): `(containerId: string, playerSlot: number, targetContainerSlot: number?)`
  - `AttackRequest` (Client -> Server): `(origin: Vector3, direction: Vector3, targetModel: Model?, isHeadshotHint: boolean?)`
  - `AttackEffect` (Server -> Client): `(attacker: Player, weaponId: string, startPos: Vector3, endPos: Vector3, didHit: boolean, isHeadshot: boolean)`
  - `WorldEventNotify` (Server -> Client): `(payload: Types.WorldEventPayload)`
  - `ExtractionStateSync` (Server -> Client): `(state: Types.ExtractionState)`
  - `RequestReturnToMap` (Client -> Server): `()`
  - `BuildPlaceRequest` (Client -> Server): `(pieceType: Types.BuildPieceType, gridX: number, gridY: number, gridZ: number, rotY: number)`
  - `BuildUpgradeRequest` (Client -> Server): `(uid: string, targetTier: Types.BuildTier)`
  - `BuildDemolishRequest` (Client -> Server): `(uid: string)`
  - `BaseStateSync` (Server -> Client): `(pieces: { Types.SavedBuildPiece })`
  - `RaidListRequest` (Client -> Server): `()`
  - `RaidListSync` (Server -> Client): `(targets: { Types.RaidTargetInfo })`
  - `StartRaidRequest` (Client -> Server): `(targetUserId: number)`
  - `PlaceExplosiveRequest` (Client -> Server): `(targetUid: string, hitPosition: Vector3)`
  - `RaidHudSync` (Server -> Client): `(state: Types.RaidHudState)`
  - `RaidExtractRequest` (Client -> Server): `()`
  - `ProjectileSpawn` (Server -> Client): `(projectileId: string, shooter: Player, projectileConfigId: string, origin: Vector3, velocity: Vector3, gravity: number)`
  - `ExplosionEffect` (Server -> Client): `(origin: Vector3, radius: number, sourceId: string, projectileId: string?)`
- `Net.InitServer()` — создаёт папку `Remotes`, все события и прогревает кэш ссылок `RemoteEvent`.
- `Net.GetEvent(eventName: string): RemoteEvent` — возвращает кэшированный `RemoteEvent` (при промахе кэша находит/создаёт на сервере или ожидает через `WaitForChild` на клиенте).

### Конфиги (`src/shared/configs/`)
- `Items` (`Items.luau`): словарь `itemId -> Types.ItemConfig` (`wood`, `stone`, `metal_ore`, `cloth`, `hatchet`, `pickaxe`, `bandage`, `cooked_meat`, `water_bottle`, `workbench_1`, `spear`, `metal_hatchet`, `wooden_spear`, `hunting_bow`, `arrow`, `pipe_pistol`, `pistol_ammo`, `scrap`, `tech_parts`, `satchel_charge`, `c4_charge`, `rocket_launcher`, `rocket`).
- `Consumables` (`Consumables.luau`): словарь `itemId -> Types.ConsumableConfig` (`bandage`, `cooked_meat`, `water_bottle`).
- `Tools` (`Tools.luau`): словарь `itemId -> Types.ToolConfig` (`hatchet`, `pickaxe`, `metal_hatchet`).
- `Nodes` (`Nodes.luau`): словарь `nodeType -> Types.NodeConfig` (`tree`, `stone_node`, `metal_node`).
- `Recipes` (`Recipes.luau`): словарь `recipeId -> Types.RecipeConfig` (`craft_bandage`, `craft_water_bottle`, `craft_hatchet`, `craft_pickaxe`, `craft_workbench_1`, `craft_spear`, `craft_metal_hatchet`, `craft_hunting_bow`, `craft_arrow`, `craft_pipe_pistol`, `craft_pistol_ammo`, `craft_satchel_charge`, `craft_c4_charge`, `craft_rocket_launcher`, `craft_rocket`).
- `Weapons` (`Weapons.luau`): словарь `itemId -> Types.WeaponConfig` (`wooden_spear`, `spear`, `hatchet`, `metal_hatchet`, `pickaxe`, `hunting_bow`, `pipe_pistol`, `rocket_launcher`, а также константа `FISTS`).
- `Projectiles` (`Projectiles.luau`): словарь `projectileId -> Types.ProjectileConfig` (`rocket`: `Speed = 110`, `Gravity = 28`, `MaxLifetime = 10`, `BlastRadius = 15`, `StructureDamage = 300`, `PlayerDamage = 110`, `MinFalloffMultiplier = 0.25`).
- `Explosives` (`Explosives.luau`): словарь `itemId -> Types.ExplosiveConfig` (`satchel_charge`, `c4_charge`, с параметрами `StructureDamage`, `PlayerDamage`, `Radius`, `FuseTime`).
- `LootTables` (`LootTables.luau`): словарь `tableId -> Types.LootTableConfig` (`wooden_crate`, `military_crate`, `airdrop`, включая `rocket` и `rocket_launcher` в `airdrop`).
- `BuildingConfig` (`BuildingConfig.luau`): константы сетки (`GridSize = 12`, `WallHeight = 10`, `GridMinXZ = -10`, `GridMaxXZ = 10`, `GridMinY = 0`, `GridMaxY = 4`, `MaxPiecesPerBase = 200`, `ValidRotations`, `PieceOrder`, `TierOrder`), словарь `Pieces` (`foundation`, `wall`, `doorway`, `roof`, `storage_box`, `workbench_1`) и словарь `Tiers` (`wood`, `stone`, `metal`).

---

## 3. Серверные сервисы (`ServerScriptService.Server.Services`)

### `SecurityService` (`src/server/Services/SecurityService.luau`)
- `RateLimitRule = { Capacity: number, RefillPerSec: number, Category: string }`
- `SecurityService.CheckRateLimit(player: Player, remoteName: string, cost: number?): boolean` — Token Bucket limiter по `(player.UserId, remoteName)`; при исчерпании токенов дропает вызов и пишет throttled `warn` (`<= 1` раз в `2.0` сек).
- `SecurityService.GetRateLimitRules(): { [string]: RateLimitRule }` — возвращает копию таблицы правил лимитов.
- `SecurityService.LogSuspicious(player: Player, remoteName: string, reason: string)` — throttled-логирование подозрительных вызовов.
- `SecurityService.IsFiniteNumber(val: any): boolean` — проверка числа на `typeof == "number"`, отсутствие `NaN` и `math.abs(val) < math.huge`.
- `SecurityService.IsValidInteger(val: any, minVal: number?, maxVal: number?): boolean` — проверка конечного целого числа и диапазона.
- `SecurityService.IsValidString(val: any, minLen: number?, maxLen: number?): boolean` — проверка строки и длины (`1..64` по умолчанию).
- `SecurityService.IsValidVector3(val: any, maxCoordAbs: number?): boolean` — проверка `Vector3` на `NaN`/`inf` и ограничение координат (`<= 1e6`).
- `SecurityService.GetAliveCharacterRoot(player: Player): (Model?, BasePart?, Humanoid?)` — проверяет `player.Parent == Players`, наличие `Character`, `HumanoidRootPart` и живого `Humanoid` (`Health > 0`).
- `SecurityService.IsWithinDistance(player: Player, targetPosition: Vector3, maxDistance: number, pingTolerance: number?): boolean` — серверная проверка `Magnitude` от `HumanoidRootPart` до цели с допуском под пинг.
- `SecurityService.IsTeleportLocked(player: Player): boolean` / `SecurityService.SetTeleportLock(player: Player, locked: boolean)` — блокировка операций при телепорте и закрытии сессии.
- `SecurityService.IsTransactionLocked(player: Player): boolean` / `SecurityService.AcquireTransactionLock(player: Player, reason: string): boolean` / `SecurityService.ReleaseTransactionLock(player: Player)` — per-player мьютекс транзакций.
- `SecurityService.RunLocked(player: Player, reason: string, fn: () -> ()): boolean` — выполняет критическую транзакцию под `pcall` с гарантированным снятием блокировки.
- `SecurityService.SetActiveContainer(player: Player, containerId: string, primaryPart: BasePart)` / `SecurityService.ClearActiveContainer(player: Player, containerId: string?)` / `SecurityService.IsActiveContainerOutOfRange(player: Player, maxDistance: number, pingTolerance: number?): boolean` — трекинг активного контейнера и проверка дистанции для `InventoryMove`.
- `SecurityService.Init()` — инициализирует `Net` и очищает все per-`UserId` таблицы при `Players.PlayerRemoving`.

### `DataService` (`src/server/Services/DataService.luau`)
- `DataService.DataLoaded: Signal.Signal<Player, PlayerData>` — событие завершения загрузки профиля игрока.
- `DataService.MOCK_RAID_TARGET_USER_ID: number` — идентификатор тестовой цели рейда в Studio (`-1001`).
- `DataService.MigrateProfileData(rawData: { [string]: any }): { [string]: any }` — чистая функция глубокого клонирования и пошаговой миграции профиля (`DataVersion`, актуальная версия `1`), вызываемая сразу после `profile:Reconcile()`.
- `DataService.GetData(player: Player): PlayerData?` — возвращает данные игрока или `nil`, если профиль ещё не загружен/не активен.
- `DataService.OnDataLoaded(callback: (player: Player, data: PlayerData) -> ()): Signal.Connection` — подписывается на `DataLoaded` и немедленно вызывает `callback` для уже загруженных игроков.
- `DataService.OnBeforeUnload(callback: (player: Player, data: PlayerData) -> ())` — синхронный хук перед сериализацией и закрытием сессии (`PlayerRemoving` / `OnLastSave`).
- `DataService.IsTeleporting(player: Player): boolean` — возвращает `true`, если профиль игрока освобождён для штатного телепорта (чтобы `OnSessionEnd` не кикал игрока).
- `DataService.ReleaseForTeleport(player: Player): boolean` — выставляет `SecurityService.SetTeleportLock(player, true)`, синхронизирует `RuntimeData` в `profile.Data`, вызывает `profile:EndSession()`, ожидает `profile:IsActive() == false` и завершения `OnLastSave`/`OnAfterSave` (таймаут `8` сек) и возвращает результат.
- `DataService.RestoreAfterFailedTeleport(player: Player): boolean` — перезагружает профиль игрока при сбое телепортации (`TeleportInitFailed` / таймаут) и снимает блокировку `SecurityService.SetTeleportLock(player, false)`.
- `DataService.RegisterRaidableBase(player: Player)` — при наличии построек на базе игрока записывает `UserId` и их количество в `OrderedDataStore("RaidableBases_v1")` (внутри `pcall`).
- `DataService.GetRaidTargets(excludeUserId: number, limit: number): { Types.RaidTargetInfo }` — возвращает топ целей из `RaidableBases_v1` (в Studio при отсутствии реальных целей добавляет `MockRaidTarget`).
- `DataService.LoadBaseSnapshot(targetUserId: number): Types.BaseData?` — загружает read-only снимок базы цели через `PlayerStore:GetAsync("Player_" .. targetUserId)` без захвата `SessionLock`.
- `DataService.Init()` — подключает `PlayerAdded` / `PlayerRemoving` (безусловная очистка таблиц игрока и `SecurityService.SetTeleportLock(player, false)`, ограниченный кэш имён `nameCache <= 256`), управляет сессиями `ProfileStore` (`PlayerData_v1`, `DataVersion = 1`, `Reconcile` -> `MigrateProfileData`, кик при неожиданном `OnSessionEnd` с предварительной блокировкой транзакций).

### `InventoryService` (`src/server/Services/InventoryService.luau`)
- `InventoryService.GetEquippedSlot(player: Player): number` — возвращает текущий слот хотбара игрока (`1..6`, по умолчанию `1`).
- `InventoryService.GetEquippedItem(player: Player): Types.Slot?` — возвращает предмет в активном слоте хотбара игрока.
- `InventoryService.GetSlot(player: Player, slotIndex: number): Types.Slot?` — возвращает предмет в конкретном слоте `1..30`.
- `InventoryService.GetItemCount(player: Player, id: string): number` — суммарное количество предмета `id` в инвентаре.
- `InventoryService.HasItems(player: Player, items: { Types.ItemBatchEntry }): boolean` — проверка наличия всех позиций (с агрегацией дублирующихся `Id`).
- `InventoryService.CanCraftTransaction(player: Player, ingredients: { Types.Ingredient }, resultId: string, resultCount: number): boolean` — симулирует списание ингредиентов и проверяет, влезет ли результат в освобождённые/существующие слоты.
- `InventoryService.AddItem(player: Player, id: string, count: number): number` — добавляет предмет (сначала в существующие стаки, затем в пустые слоты 1..30), отправляет `InventorySync`, возвращает остаток.
- `InventoryService.AddItemToSlot(player: Player, id: string, count: number, targetSlot: number): number` — добавляет предмет в указанный слот `1..30` (если пуст или совпадает `Id`), отправляет `InventorySync`, возвращает остаток.
- `InventoryService.AddItems(player: Player, items: { Types.ItemBatchEntry }): { number }` — пакетное добавление с одной отправкой `InventorySync`.
- `InventoryService.RemoveItem(player: Player, id: string, count: number): boolean` — списание «всё или ничего» + `InventorySync`.
- `InventoryService.RemoveItems(player: Player, items: { Types.ItemBatchEntry }): boolean` — транзакционное списание набора предметов (с откатом по снимку при сбое) + одна отправка `InventorySync`.
- `InventoryService.ConsumeSlot(player: Player, slotIndex: number, count: number): boolean` — списывает `count` единиц из конкретного слота `1..30`, удаляет слот при `<= 0` и отправляет `InventorySync`.
- `InventoryService.ClearInventory(player: Player): Types.Inventory` — очищает все 30 слотов игрока, отправляет `InventorySync` и возвращает копию изъятых предметов.
- `InventoryService.Init()` — инициализирует `Net`, слушает `InventoryMove` (`1..30`, под Rate Limiter, блокировками `SecurityService`, проверкой жизни и дистанции открытого контейнера, атомарное списание-зачисление) и `HotbarSelect` (`1..6`, проверка жизни и блокировки телепорта), синхронизирует атрибут `Player.EquippedItemId` при смене слота/обновлении инвентаря для 3D-визуализации экипированного оружия, безопасно пропускает `InventorySync` для выходящих игроков (`player.Parent ~= Players`), очищает `equippedSlots` в `PlayerRemoving` и выдаёт стартовый набор в Studio (включая `rocket_launcher` и `rocket`).

### `ResourceService` (`src/server/Services/ResourceService.luau`)
- `ResourceService.Init()` — сканирует `Workspace.ResourceNodes`, обрабатывает `HitNode` (Rate Limiter, строгая проверка типа/длины строки, блокировок `SecurityService`, жизни, дистанции `<= 14`, серверного кулдауна `os.clock()`, атомарное обновление под `RunLocked`) и рассылает `NodeUpdated` ближайшим игрокам в радиусе `120` studs (и всем при истощении/респавне).

### `CraftingService` (`src/server/Services/CraftingService.luau`)
- `CraftingService.RegisterStation(stationId: string, stationType: string, position: Vector3)` — регистрирует динамически размещённый верстак (например, на базе игрока).
- `CraftingService.UnregisterStation(stationId: string)` — удаляет динамический верстак по `stationId`.
- `CraftingService.GetActiveCraft(player: Player): Types.CraftingState?` — возвращает текущий активный крафт игрока или `nil`.
- `CraftingService.CancelCraftForPlayer(player: Player, syncClient: boolean, bypassLock: boolean?)` — отменяет активный крафт и возвращает ингредиенты (под `SecurityService.RunLocked` либо с `bypassLock = true` внутри транзакций смерти/выгрузки).
- `CraftingService.Init()` — сканирует `Workspace.Workbenches` (атрибут `StationType`, дистанция `<= 14 + PING_DISTANCE_TOLERANCE` studs, а также проверяет `dynamicStations`), обрабатывает `CraftRequest` и `CraftCancel` (под Rate Limiter, проверкой жизни и блокировок `SecurityService`, списанием ресурсов до старта `task.delay`, атомарным завершением) и возвращает ресурсы через `DataService.OnBeforeUnload` и `PlayerRemoving`.

### `SurvivalService` (`src/server/Services/SurvivalService.luau`)
- `SurvivalService.GetStats(player: Player): Types.SurvivalStats?` — возвращает копию текущих статов выживания игрока.
- `SurvivalService.GetContainerState(containerId: string): Types.LootContainerState?` — делегирует в `LootService.GetContainerState(containerId)`.
- `SurvivalService.Init()` — запускает цикл выживания раз в `2.0` сек (`-0.35` голода, `-0.5` жажды, пассивный реген `+1.5 HP` при `> 70`, урон `1.5 HP` при `<= 0`), реплицирует `Hunger` / `Thirst` / `Starving` / `Dehydrated` через атрибуты `Player` с diff-проверкой `GetAttribute ~= value`, очищает пер-персонажные ресурсы по `CharacterRemoving` и `PlayerRemoving` через `Janitor`, обрабатывает `UseConsumable` (Rate Limiter, проверка жизни, блокировок `SecurityService`, серверный кулдаун `os.clock()`, атомарное списание до применения эффекта), при смерти (`Humanoid.Died`) под блокировкой `PlayerDeath` (с пропуском при активном телепорте) отменяет крафт, очищает инвентарь и спавнит Greybox-рюкзак в `Workspace.LootContainers` на `300` сек и сбрасывает статы после респавна (`100 / 80 / 80`).

### `LootService` (`src/server/Services/LootService.luau`)
- `LootService.RollLootTable(tableId: string): Types.Inventory` — взвешенная генерация лута по таблице из `LootTables`.
- `LootService.RegisterSlotsContainer(model: Model, title: string, ownerName: string, slots: Types.Inventory, lifeTime: number): string` — регистрирует временный контейнер (рюкзак смерти, аирдроп и т.п.) с `ProximityPrompt` и авто-удалением по `lifeTime`.
- `LootService.RegisterStorageContainer(model: Model, title: string, ownerUserId: number?, maxSlots: number, initialSlots: Types.Inventory, onChanged: ((slots: Types.Inventory) -> ())?, allowDeposit: boolean?): string` — регистрирует постоянный или рейдовый сундук (`Kind = "Storage"`, опциональная проверка владельца `OwnerUserId`, флаг `allowDeposit`, `ProximityPrompt`).
- `LootService.UnregisterContainer(containerId: string)` — отвязывает контейнер, отключает `PromptConn` / отменяет `ExpireThread` и закрывает UI у зрителей без уничтожения модели.
- `LootService.SpawnTemporaryContainer(model: Model, title: string, tableId: string, lifeTime: number): string` — генерирует лут по `tableId` и регистрирует временный контейнер.
- `LootService.OpenContainerForPlayer(player: Player, containerId: string): boolean` — открывает контейнер игроку после проверки владельца, блокировок `SecurityService`, состояния и дистанции `<= MAX_LOOT_DISTANCE` (`14` studs); регистрирует активный контейнер в `SecurityService`.
- `LootService.CloseContainerForPlayer(player: Player, notifyClient: boolean)` — закрывает активный контейнер игрока и сбрасывает трекинг в `SecurityService`.
- `LootService.DestroyContainer(containerId: string)` — закрывает окно у всех зрителей, отключает `PromptConn` / отменяет `ExpireThread`, удаляет контейнер и уничтожает его модель.
- `LootService.GetContainerState(containerId: string): Types.LootContainerState?` — возвращает копию состояния контейнера или `nil`.
- `LootService.IsContainerDepleted(containerId: string): boolean` — возвращает `true`, если POI-ящик сейчас истощён и ожидает респавна.
- `LootService.Init()` — сканирует `Workspace.POI` (модели с атрибутом `LootTable`), наполняет ящики, привязывает `ProximityPrompt`, обрабатывает `CloseContainer`, `LootTakeSlot` и `ContainerDepositSlot` (Rate Limiter, проверка `openContainerByPlayer`, дистанции `<= 14 + PING_DISTANCE_TOLERANCE`, per-player и per-container `Locked` с атомарным списанием до зачисления), истощение/респавн POI-ящиков и периодическую проверку дистанции активных зрителей.

### `WorldEventService` (`src/server/Services/WorldEventService.luau`)
- `WorldEventService.TriggerAirdropNow(descentTimeOverride: number?): Model` — немедленно запускает событие Supply Drop в случайной точке из `Workspace.AirdropZones` (или в безопасном радиусе на карте), рассылает `WorldEventNotify`, плавно спускает груз с парашютом и дымом, после посадки регистрирует контейнер через `LootService.SpawnTemporaryContainer(..., "Supply Drop", "airdrop", 180)`.
- `WorldEventService.GetActiveAirdropModel(): Model?` — возвращает текущую модель активного аирдропа или `nil`.
- `WorldEventService.GetActiveAirdropContainerId(): string?` — возвращает `containerId` приземлившегося активного аирдропа или `nil`.
- `WorldEventService.Init()` — инициализирует `Net`, создаёт `Workspace.WorldEvents`, запускает периодический цикл Supply Drop раз в `420` сек и слушает атрибут `Workspace.TriggerAirdropNow` в Studio.

### `CombatService` (`src/server/Services/CombatService.luau`)
- `CombatService.GetEquippedWeapon(player: Player): (string, Types.WeaponConfig)` — возвращает `weaponId` и конфиг активного оружия игрока (или `"fists", Weapons.FISTS`).
- `CombatService.Init()` — инициализирует `Net`, подписывается на `AttackRequest` (Rate Limiter, валидация `Vector3` на `NaN`/бесконечность/длину/ограничение координат, проверка блокировок `SecurityService`, жизни атакующего и дистанции `origin` от `HumanoidRootPart` `<= 8` studs, серверный кулдаун `os.clock()` и атомарное списание `AmmoId` под `RunLocked`). Для хитскан/ближнего оружия выполняет авторитетный серверный `Workspace:Raycast` с множителем хэдшота по `Head`, записью `LastAttackerUserId` и рассылкой `AttackEffect`. Для баллистического оружия с `ProjectileId` (например, `rocket_launcher`) дополнительно проверяет LoS от головы до `origin` (анти-прострел сквозь стены) и лимит активных снарядов (`<= MAX_ACTIVE_PROJECTILES_PER_PLAYER = 3`), рассылает `ProjectileSpawn` в радиусе `400` studs и запускает серверную симуляцию через `Ballistics.Spawn` (при попадании вызывает `RaidService.TriggerExplosion` со смещением по нормали `+0.25`, максимальное время жизни ограничено `MAX_PROJECTILE_LIFETIME = 10` сек). Также обновляет `HpLabel` манекенов в `Workspace.TestDummies`.

### `ExtractionService` (`src/server/Services/ExtractionService.luau`)
- `ExtractionService.GetExtractionState(player: Player): Types.ExtractionState?` — возвращает текущее состояние активного экстракшена игрока или `nil`.
- `ExtractionService.IsInCombatCooldown(player: Player): boolean` — проверяет, действуют ли ещё `Config.Extraction.CooldownAfterDamage` секунд с последнего получения урона.
- `ExtractionService.RecordDamage(player: Player)` — фиксирует получение урона игроком и немедленно сбрасывает активный экстракшен.
- `ExtractionService.Init()` — сканирует `Workspace.ExtractionZones` (с предвычисленным `HalfSize`), отслеживает урон/смерть игроков (`Humanoid.HealthChanged`, `Humanoid.Died`) и очищает состояние по `CharacterRemoving` / `PlayerRemoving`, проверяет нахождение живых игроков в зонах раз в `0.25` сек, по завершении таймера закрывает открытые контейнеры, выставляет `SecurityService.SetTeleportLock(player, true)`, вызывает `DataService.ReleaseForTeleport(player)` и выполняет симуляцию телепорта в Studio или `TeleportService:TeleportAsync` на `Config.Places.PlayerBase` (с обработкой `TeleportInitFailed`, повторами и восстановлением/разблокировкой через `DataService.RestoreAfterFailedTeleport`).

### `BaseService` (`src/server/Services/BaseService.luau`)
- `BaseService.IsBaseMode(): boolean` — возвращает `true`, если `game.PlaceId == Config.Places.PlayerBase` (и не активен режим рейда `Workspace.RaidServerMode` / `PrivateServerOwnerId == 0`) или в Studio включён `Workspace:GetAttribute("ForceBaseMode") == true`.
- `BaseService.GetPlayerPieces(player: Player): { Types.SavedBuildPiece }` — возвращает копию сохранённых построек игрока из `DataService`.
- `BaseService.GetStorageContainerId(player: Player, uid: string): string?` — возвращает `containerId` заспавненного сундука базы по `uid` постройки.
- `BaseService.Init()` — в режиме базы (игнорируя подключения с `TeleportData.Mode == "Raid"`) спавнит постройки из `data.Base.Pieces` в `Workspace.PlayerBaseStructures` (с регистрацией `storage_box` в `LootService` и `workbench_1` в `CraftingService`), обрабатывает `BuildPlaceRequest`, `BuildUpgradeRequest`, `BuildDemolishRequest` (Rate Limiter, проверка жизни, дистанции `<= MAX_BUILD_DISTANCE + PING_DISTANCE_TOLERANCE`, серверного кулдауна `0.15` сек, сетки/коллизий/ресурсов под `RunLocked`) и `RequestReturnToMap` (Rate Limiter, закрытие контейнеров, блокировка через `SecurityService.SetTeleportLock`, освобождение профиля через `DataService.ReleaseForTeleport`, возврат на `Config.Places.MainMap` и разблокировка при сбое через `DataService.RestoreAfterFailedTeleport`).

### `RaidService` (`src/server/Services/RaidService.luau`)
- `RaidService.HasExplosionLineOfSight(blastOrigin: Vector3, targetModel: Model, excludeInstances: { Instance }?, isCharacterTarget: boolean?): boolean` — проверяет прямую видимость (`Workspace:Raycast` с `FilterType.Exclude`) от эпицентра взрыва до контрольных точек цели (до 3 точек: центр/верх/низ или стороны у широких элементов, стойки/перемычка у `doorway`, HRP/голова/ноги у персонажей). Исключает только саму цель, переданные `excludeInstances`, `CanCollide == false` не-террейн детали и модели персонажей; другие строительные блоки и `Terrain` блокируют урон.
- `RaidService.TriggerExplosion(params: Types.ExplosionParams): Types.ExplosionResult` — единый серверный расчёт AoE-взрывов (используется как для C4/Satchel, так и для ракет):
  - **Фаза 1 (до разрушения построек):** собирает постройки в `activeSessions` и живых гуманоидов (`Players` + `Workspace.TestDummies`) в радиусе `Radius`, проверяет `HasExplosionLineOfSight` (цель за неразрушенной стеной получает `0` урона даже при разрушении самой стены этим взрывом) и рассчитывает дистанционное затухание (`1.0` до `1` stud, линейное падение до `MinFalloffMultiplier`).
  - **Фаза 2:** применяет урон постройкам (с дропом мешка лута при разрушении `storage_box`) и гуманоидам (`LastAttackerUserId` + `Humanoid:TakeDamage`).
  - **Фаза 3:** рассылает `ExplosionEffect` клиентам в радиусе `350` studs (и атакующему).
- `RaidService.EnterStudioMockRaid(player: Player, targetUserId: number): boolean` — запускает локальный мок-рейд в Studio, спавнит копию базы цели (или готовую тестовую базу с укреплёнными стенами и сундуком) в `Workspace.RaidTargetStructures` и запускает 300-секундный таймер.
- `RaidService.IsPlayerInRaid(player: Player): boolean` — возвращает `true`, если игрок находится в активной рейд-сессии.
- `RaidService.GetActiveSessionInfo(player: Player): Types.RaidHudState?` — возвращает состояние активной рейд-сессии игрока или `nil`.
- `RaidService.Init()` — в режиме `MainMap` обрабатывает `RaidListRequest` и `StartRaidRequest` (Rate Limiter, проверка жизни и близости к `Workspace.RaidTerminal` `<= 24 + 2` studs, `SecurityService.SetTeleportLock`, `DataService.ReleaseForTeleport` + `ReserveServer` + `TeleportAsync` с `ReservedServerAccessCode` или Studio Mock Raid, восстановление через `RestoreAfterFailedTeleport` при ошибке); в режиме рейда спавнит копию базы цели по `LoadBaseSnapshot` без записи в профиль цели, обновляет таймер (`RaidHudSync`), обрабатывает `PlaceExplosiveRequest` (Rate Limiter, проверка предмета из `Explosives`, дистанции `<= 14 + 2` studs, серверного кулдауна `0.5` сек и атомарного списания под `RunLocked`, визуальный заряд с `FuseTime`, вызов `RaidService.TriggerExplosion` при детонации с окклюзией стенами) и эвакуирует игрока на `MainMap` (или из мок-рейда) по `RaidExtractRequest` (с Rate Limiter и проверкой жизни) или истечении таймера.

---

## 4. Клиентские контроллеры (`StarterPlayer.StarterPlayerScripts.Client.Controllers`)

### `InventoryController` (`src/client/Controllers/InventoryController.luau`)
- `InventoryController.Changed: Signal.Signal<Inventory>`
- `InventoryController.GetInventory(): Inventory`
- `InventoryController.GetSlot(slotIndex: number): Slot?`
- `InventoryController.OnChanged(callback: (inventory: Inventory) -> ()): Signal.Connection`
- `InventoryController.RequestMove(fromSlot: number, toSlot: number)`
- `InventoryController.Init()`

### `HotbarController` (`src/client/Controllers/HotbarController.luau`)
- `HotbarController.SelectSlot(slotIndex: number)`
- `HotbarController.GetSelectedSlot(): number`
- `HotbarController.Init()`

### `InventoryUIController` (`src/client/Controllers/InventoryUIController.luau`)
- `InventoryUIController.OpenChanged: Signal.Signal<boolean>` — сигнал открытия/закрытия окна инвентаря.
- `InventoryUIController.IsOpen(): boolean`
- `InventoryUIController.SetOpen(open: boolean)`
- `InventoryUIController.Toggle()`
- `InventoryUIController.Init()` — строит `InventoryGui` (30 слотов), перекладывание двумя кликами, переключение по `Tab` / `I`, автоматическое открытие при открытии сундука с возможностью вложения и отправку `LootController.RequestDeposit` по клику при открытом `LootController.CanDeposit()`.

### `CraftingController` (`src/client/Controllers/CraftingController.luau`)
- `CraftingController.IsOpen(): boolean`
- `CraftingController.SetOpen(open: boolean)`
- `CraftingController.Toggle()`
- `CraftingController.GetActiveCraft(): Types.CraftingState?`
- `CraftingController.Init()` — строит `CraftingGui` со списком рецептов (подсветка ингредиентов из `InventoryController`, пометка станции `[Workbench Lv.1]`), прогресс-баром по `CraftStateSync`, кнопками `Craft` / `Cancel`, открытием вместе с `InventoryUIController` (кроме случая открытого `LootController`) или по `C`.

### `GatheringController` (`src/client/Controllers/GatheringController.luau`)
- `GatheringController.GetNodeState(nodeId: string): NodeClientState?`
- `GatheringController.IsCursorOnActiveNode(): boolean` — проверяет, наведён ли курсор на неистощённую ноду ресурсов в радиусе добычи (`MAX_GATHER_DISTANCE_CLIENT`).
- `GatheringController.Init()` — строит `GatherHudGui`, выполняет raycast от курсора (блокируется при активном `BuildingController.IsBuildMode()`, открытых `InventoryUIController`, `CraftingController`, `LootController`, экипированном расходнике из `Consumables` или дальнобойном оружии из `Weapons`; при наведении приоритетно читает атрибут `Hp` модели), отправляет `HitNode`, слушает `NodeUpdated` и проигрывает визуальный отклик.

### `SurvivalHudController` (`src/client/Controllers/SurvivalHudController.luau`)
- `SurvivalHudController.Init()` — строит `SurvivalHudGui` (полоски `Health`, `Hunger`, `Thirst` в левом нижнем углу), читает `Humanoid.Health` и атрибуты `Hunger` / `Thirst` у `LocalPlayer`, подсвечивает/пульсирует полоску при `<= 15`.

### `ConsumableController` (`src/client/Controllers/ConsumableController.luau`)
- `ConsumableController.Init()` — по клику ЛКМ (если не активен `BuildingController.IsBuildMode()`, закрыты окна `InventoryUIController`, `CraftingController`, `LootController` и выбранный слот хотбара содержит предмет из `Consumables`) отправляет `UseConsumable(selectedSlot)` с локальным кулдауном.

### `LootController` (`src/client/Controllers/LootController.luau`)
- `LootController.OpenChanged: Signal.Signal<boolean>` — сигнал открытия/закрытия окна лута.
- `LootController.IsOpen(): boolean`
- `LootController.GetActiveContainerId(): string?`
- `LootController.CanDeposit(): boolean` — возвращает `true`, если открыт сундук с разрешением вложения предметов.
- `LootController.RequestDeposit(playerSlot: number)` — отправляет `ContainerDepositSlot(activeContainerId, playerSlot)`.
- `LootController.Close()`
- `LootController.Init()` — строит `LootGui` (динамическая сетка до 30 слотов, 18 слотов и парное расположение рядом с `InventoryGui` для сундуков базы), открывается/обновляется по `OpenContainer`, закрывается по `CloseContainer` или кнопке `X`, по клику на слот отправляет `LootTakeSlot`.

### `CombatController` (`src/client/Controllers/CombatController.luau`)
- `CombatController.Init()` — строит минималистичный прицел `CrosshairGui` по центру экрана (крестик + вспышка хитмаркера на `0.15s`, красная при хэдшоте), по ЛКМ (если не активен `BuildingController.IsBuildMode()`, закрыты UI-окна, нет фокуса в `TextBox`, в руках не предмет из `Consumables`/`Explosives`, а для `Melee` также `GatheringController.IsCursorOnActiveNode() == false`) вычисляет `origin` от головы/`HumanoidRootPart` и `direction` в точку прицеливания курсора, проверяет локальный кулдаун и боеприпасы, для оружия с `ProjectileId` сразу запускает клиентскую баллистическую визуализацию через `ProjectileController.SpawnLocalProjectile` и отправляет `AttackRequest`, а по `AttackEffect` отрисовывает трассер для хитскан-оружия (`0.12s`).

### `ProjectileController` (`src/client/Controllers/ProjectileController.luau`)
- `ProjectileController.SpawnLocalProjectile(projectileConfigId: string, origin: Vector3, direction: Vector3, shooterCharacter: Model): string` — мгновенно спавнит локально предсказанный визуальный снаряд `Rocket` (из `ReplicatedStorage.Assets.Projectiles.Rocket` или встроенного примитивного фолбэка) с `Trail` и `ParticleEmitter` дыма, симулирует дугу полёта через `Ballistics.Spawn`, проигрывает 3D-звук выстрела и ставит запись в очередь сопоставления с серверным `ProjectileSpawn`.
- `ProjectileController.GetActiveVisualCount(): number` — возвращает число активных визуальных снарядов на клиенте.
- `ProjectileController.Init()` — отслеживает атрибут `EquippedItemId` у всех игроков и при экипировке `rocket_launcher` крепит примитивную модель ракетницы (`ReplicatedStorage.Assets.Weapons.RocketLauncher`) к `RightHand` / `Right Arm` через `Motor6D` (`WeaponGripMotor`); слушает `ProjectileSpawn` (без дублирования локально предсказанной ракеты) и `ExplosionEffect` (очищает снаряд и спавнит `Explosion`, расширяющуюся неоновую сферу и 3D-звук взрыва в `Workspace.ClientProjectileVfx`).

### `WorldEventController` (`src/client/Controllers/WorldEventController.luau`)
- `WorldEventController.IsBannerVisible(): boolean` — возвращает, отображается ли сейчас верхний HUD-баннер мирового события.
- `WorldEventController.GetActiveBeaconCount(): number` — возвращает количество активных 3D-маяков мировых событий.
- `WorldEventController.Init()` — строит `WorldEventHudGui`, слушает `WorldEventNotify`, показывает верхний баннер на `6` сек, создаёт 3D-маяк (`BillboardGui` с `AlwaysOnTop = true` и якорем в `Workspace.ClientEventBeacons`), обновляет расстояние в реальном времени через `RenderStepped` и удаляет маяк при исчезновении модели груза или по истечении `Duration`.

### `ExtractionController` (`src/client/Controllers/ExtractionController.luau`)
- `ExtractionController.IsVisible(): boolean` — возвращает, отображается ли сейчас панель таймера экстракшена `ExtractionGui.ExtractionPanel`.
- `ExtractionController.GetState(): Types.ExtractionState?` — возвращает копию последнего полученного от сервера состояния экстракшена или `nil`.
- `ExtractionController.Init()` — создаёт `ExtractionGui` в верхней-центральной части экрана (`ExtractionPanel`), слушает `ExtractionStateSync`, отображает название зоны, текст статуса/таймера (`Extracting in %.1fs...`) и прогресс-бар заполнения и автоматически скрывает панель при `state.Active == false`.

### `BuildingController` (`src/client/Controllers/BuildingController.luau`)
- `BuildingController.IsBaseMode(): boolean` — возвращает `true` на плейсе базы (кроме режима рейда `RaidServerMode` / `InRaid`) или при `ForceBaseMode == true` в Studio.
- `BuildingController.IsBuildMode(): boolean` — возвращает `true`, когда активен режим строительства на базе.
- `BuildingController.SetBuildMode(enabled: boolean)` — включает/выключает режим строительства, сбрасывает превью и подсветку.
- `BuildingController.GetPieces(): { Types.SavedBuildPiece }` — возвращает копию кэшированного списка построек базы.
- `BuildingController.Init()` — строит `BuildingGui` (панель действий `Build [B]` и `Deploy to PvP Map`, меню выбора построек, кнопки `Rotate`, `Upgrade [G]`, `Demolish`), управляет призрачным превью по сетке `GridSize = 12` с зелёной/красной индикацией коллизии и ресурсов, отправляет `BuildPlaceRequest`, `BuildUpgradeRequest`, `BuildDemolishRequest`, `RequestReturnToMap` и слушает `BaseStateSync`.

### `RaidController` (`src/client/Controllers/RaidController.luau`)
- `RaidController.IsInRaid(): boolean` — возвращает `true` во время активного рейда.
- `RaidController.IsSelectionOpen(): boolean` — возвращает `true`, пока открыто окно выбора цели рейда.
- `RaidController.GetHudState(): Types.RaidHudState?` — возвращает копию последнего `RaidHudState` от сервера или `nil`.
- `RaidController.OpenTargetList()` — открывает `RaidSelectFrame` и отправляет `RaidListRequest`.
- `RaidController.CloseTargetList()` — закрывает `RaidSelectFrame`.
- `RaidController.Init()` — строит `RaidGui` (верхний красный HUD `RaidHudFrame` с таймером `RAIDING: <TargetName> | Time Left: MM:SS` и кнопкой `"Extract with Loot"`, а также модальное окно `RaidSelectFrame` со списком целей и кнопками `"Launch Raid"`), привязывает `ProximityPrompt` на `Workspace.RaidTerminal`, слушает `RaidListSync` / `RaidHudSync` и по ЛКМ (при выбранной взрывчатке из `Explosives` в руках) отправляет `PlaceExplosiveRequest` по цели в `Workspace.RaidTargetStructures`. (При открытом окне терминала или взрывчатке в руках также блокируются клики в `CombatController`, `GatheringController` и `ConsumableController`.)

---

## 5. Производительность и нагрузочный тест (Этап 10)

### Проведённые оптимизации и аудит утечек памяти
- **Кэширование `RemoteEvent` (`Net`)**: `Net.GetEvent` кэширует найденные/созданные `RemoteEvent` в `eventCache`, исключая повторный `FindFirstChild` при частых тиках.
- **Таргетированная сетевая рассылка**:
  - `ResourceService`: `NodeUpdated` рассылается игрокам в радиусе `120` studs от ноды (и всем при истощении/респавне); `GatheringController` читает атрибут `Hp` модели при наведении.
  - `CombatService`: `AttackEffect` для ближнего боя отправляется только атакующему при попадании; для дальнобойного оружия — игрокам в радиусе `250` studs.
  - `SurvivalService`: атрибуты `Hunger` / `Thirst` / `Starving` / `Dehydrated` обновляются через `SetAttribute` только при изменении значения.
  - `ExtractionService` и `RaidService`: рассылка `ExtractionStateSync` и `RaidHudSync` выполняется только для активных участников, а цикл зон экстракшена имеет ранний выход при `#zones == 0` и предвычисленный `HalfSize`.
- **Полная очистка при выходе и смерти (`PlayerRemoving` / `CharacterRemoving`)**:
  - `DataService`: безусловная очистка `Profiles`, `RuntimeData`, `unloadedByPlayer`, `teleportingPlayers` и `lastRegisteredPieceCount` в `onPlayerRemoving`; ограничение `nameCache` (`<= 256` записей).
  - `InventoryService`: проверка `player.Parent == Players` перед `InventorySync`.
  - `SurvivalService` и `ExtractionService`: добавлена очистка пер-персонажных связей через `CharacterRemoving` (`Janitor:Cleanup()`).
  - `CraftingService` и `LootService`: отмена отложенных потоков `task.delay` через `task.cancel` и отключение `ProximityPrompt.Triggered` (`PromptConn:Disconnect()`) при отмене/уничтожении контейнера; ранний выход в `stepViewerDistanceCheck` при отсутствии открытых контейнеров.
  - `RaidService`: удаление сработавших зарядов из `session.ActiveExplosives` при детонации.

### Результаты замеров в Roblox Studio (50 виртуальных игроков × 100 итераций)
- **Время серверного тика (бюджет `< 4.0 мс`)**:
  - Суммарно все 6 подсистем за тик на 50 игроков: **0.809 мс** (пик **1.767 мс**).
  - `Inventory`: **0.119 мс** (макс **0.313 мс**)
  - `Resource`: **0.035 мс** (макс **0.185 мс**)
  - `Crafting`: **0.097 мс** (макс **0.280 мс**)
  - `Survival`: **0.165 мс** (макс **0.461 мс**)
  - `Combat` (50 Raycast): **0.297 мс** (макс **0.790 мс**)
  - `Extraction`: **0.092 мс** (макс **0.171 мс**)
- **Память и утечки (`SceneAnalysisService` / `Stats`)**:
  - `ScriptMemory` на сервере: **0.84 МБ** до спавна, **0.84 МБ** на пике, **0.84 МБ** после массовой очистки; на клиенте в чистом прогоне: **1.75 МБ** (`1,837,328` байт).
  - Утечка экземпляров (`GetUnparentedInstancesAsync`): **0** экземпляров от сервисов и контроллеров проекта (2 системных на сервере и 11 встроенных `PlayerModule`/`Animate` на клиенте).
- **Сетевой стресс-тест (`settings().Network`: 100 мс Inbound/Outbound, Jitter 15 мс, Loss 0.2%)**:
  - Добыча дерева `tree_1` на бегу (`11.44` studs на клиенте): успешное попадание (`Hp: 100 -> 50`, `Wood: 250 -> 280`).
  - Стрельба из `hunting_bow` по `Dummy_1`: успешный хэдшот (`Health: 100 -> 10`, `Wooden Arrow: 20 -> 19`).
  - Двойной быстрый `InventoryMove` и двойной `CraftRequest("craft_bandage")`: без дублирования/потери предметов (`610 == 610`), крафт запустился однократно (`Cloth: 20 -> 18`, `Bandage: 5 -> 6`), UI корректно сбросился.
- **Сквозной E2E-прогон и анализ сцены**:
  - Ошибок скриптов в `Output`: **0**.
  - Клиентский рендер (`GetTriangleCompositionAsync`): `Opaque` = `16` draw calls / `7,452` треугольников; `UI` = `12` draw calls / `210` треугольников.
  - Карта: 1 `SpawnLocation`, все папки сцен на месте, тестовые атрибуты и временные объекты отсутствуют.

---

## 6. Безопасность, анти-дюп и сохранность данных (Фаза B)

### Лимиты Rate Limiter (`SecurityService`, Token Bucket по `(UserId, RemoteName)`)
При превышении лимита пакет отбрасывается на сервере с логированием `warn` (throttled `<= 1` раз в `2.0` сек на пару игрок/ремоут).

| Категория | RemoteEvent | Capacity (burst) | Refill (tokens/sec) |
| :--- | :--- | :---: | :---: |
| **Combat** | `AttackRequest` | 6 | 5.0 |
| **Combat** | `HitNode` | 5 | 4.0 |
| **Combat** | `PlaceExplosiveRequest` | 3 | 1.5 |
| **Inventory** | `InventoryMove` | 12 | 8.0 |
| **Inventory** | `HotbarSelect` | 15 | 12.0 |
| **Inventory** | `LootTakeSlot` | 10 | 6.0 |
| **Inventory** | `ContainerDepositSlot` | 10 | 6.0 |
| **Inventory** | `UseConsumable` | 4 | 2.0 |
| **Inventory** | `CraftRequest` | 4 | 2.0 |
| **Inventory** | `CraftCancel` | 4 | 2.0 |
| **Building** | `BuildPlaceRequest` | 8 | 4.0 |
| **Building** | `BuildUpgradeRequest` | 8 | 4.0 |
| **Building** | `BuildDemolishRequest` | 8 | 4.0 |
| **UI** | `CloseContainer` | 8 | 5.0 |
| **UI** | `RaidListRequest` | 3 | 1.0 |
| **UI** | `StartRaidRequest` | 2 | 0.5 |
| **UI** | `RaidExtractRequest` | 2 | 0.5 |
| **UI** | `RequestReturnToMap` | 2 | 0.5 |

По умолчанию для незарегистрированных ремоутов: `Capacity = 5`, `RefillPerSec = 3.0`.

### Система блокировок от дюпа и атомарность
- **Per-player мьютекс (`SecurityService.RunLocked`)** и **флаг телепортации (`SecurityService.SetTeleportLock`)**: все критические операции (`InventoryMove`, `LootTakeSlot`, `ContainerDepositSlot`, `CraftRequest`, `CraftCancel`, `CraftComplete`, `UseConsumable`, `HitNode`, `AttackAmmo`, `BuildPlace`, `BuildUpgrade`, `BuildDemolish`, `PlaceExplosive`, `PlayerDeath`) выполняются эксклюзивно под блокировкой игрока и немедленно отклоняются при активном `IsTeleportLocked` / `IsTransactionLocked` или смерти персонажа.
- **Per-container блокировка (`ServerContainer.Locked`)**: в `LootService` слоты контейнера блокируются на время переноса; в `LootTakeSlot` требуется `openContainerByPlayer[player] == containerId` и дистанция `<= MAX_LOOT_DISTANCE + PING_DISTANCE_TOLERANCE`; в `InventoryMove` проверяется дистанция до открытого контейнера (`IsActiveContainerOutOfRange`).
- **Атомарность «списание -> начисление»**:
  - `InventoryMove`: очистка исходного слота / списание стака до записи в целевой слот.
  - `LootTakeSlot`: удаление из `container.Slots[containerSlot]` до вызова `InventoryService.AddItem*` с возвратом `remainder` при переполнении.
  - `ContainerDepositSlot`: вызов `InventoryService.ConsumeSlot` до записи в контейнер.
  - `CraftingService`: `InventoryService.RemoveItems` до регистрации `activeCrafts[player]`; при отмене/смерти `activeCrafts[player] = nil` выполняется до возврата ингредиентов.
  - `SurvivalService` (`Humanoid.Died`): пропуск дропа при активном телепорте (`IsTeleporting`/`IsTeleportLocked`), отмена активного крафта и `InventoryService.ClearInventory` до спавна рюкзака в мире.

### Сохранность профиля при телепортации и миграция данных (`DataService`)
- **Телепортация без двойной сессии**: до вызова `TeleportService:TeleportAsync` сервисы (`ExtractionService`, `BaseService`, `RaidService`) закрывают открытые контейнеры, выставляют `SecurityService.SetTeleportLock(player, true)` и вызывают `DataService.ReleaseForTeleport(player)`.
- **`DataService.ReleaseForTeleport`**: выполняет `OnBeforeUnload`, синхронизирует `RuntimeData` в `profile.Data`, вызывает `profile:EndSession()` и ожидает `not profile:IsActive()` и завершения сохранения (`OnLastSave` + `OnAfterSave`, таймаут `8` сек).
- **Обработка `Profile.OnSessionEnd`**: при неожиданном завершении сессии (пока `not teleportingPlayers[player]`) немедленно блокирует операции игрока и вызывает `player:Kick(...)`, исключая работу на сервере без активной блокировки сессии.
- **Откат при сбое `TeleportAsync`**: при таймауте сохранения, ошибке `ReserveServer` / `TeleportAsync` или событии `TeleportInitFailed` вызывается `DataService.RestoreAfterFailedTeleport(player)`, который восстанавливает профиль и снимает `SecurityService.SetTeleportLock(player, false)`.
- **Версионирование и миграция (`ProfileStore` `"PlayerData_v1"`)**:
  - Актуальная схема задаётся константой `Types.CURRENT_DATA_VERSION = 1`; шаблон профиля содержит `DataVersion = 1` (и зеркальное поле `Version` для обратной совместимости).
  - Сразу после `profile:Reconcile()` вызывается чистая функция `DataService.MigrateProfileData(rawData)`, которая клонирует таблицу и пошагово применяет миграции (`if data.DataVersion < 1 then ... data.DataVersion = 1 end`, заготовка для `if Types.CURRENT_DATA_VERSION >= 2 and data.DataVersion < 2 then ... end`).
