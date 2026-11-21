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
- `PlayerData = { Version: number, Inventory: Inventory, Stats: SurvivalStats, Base: BaseData }`
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
- `WeaponConfig = { Category: WeaponCategory, Damage: number, HeadshotMultiplier: number, Range: number, Cooldown: number, AmmoId: string? }`
- `LootDropEntry = { Id: string, Weight: number, MinCount: number, MaxCount: number }`
- `LootTableConfig = { Rolls: number, RespawnTime: number, Items: { LootDropEntry } }`
- `WorldEventPayload = { EventType: string, Title: string, Position: Vector3, Duration: number }`
- `ExtractionState = { Active: boolean, ZoneName: string, TimeLeft: number, TotalTime: number, StatusText: string? }`

Константы:
- `INVENTORY_SIZE = 30`, `HOTBAR_SIZE = 6`
- `HANDS_POWER = 5`, `HANDS_COOLDOWN = 0.8`, `BASE_TOOL_MULTIPLIER = 1.0`
- `MAX_GATHER_DISTANCE_SERVER = 14`, `MAX_GATHER_DISTANCE_CLIENT = 12`
- `MAX_STATION_DISTANCE = 14`
- `MAX_HEALTH = 100`, `MAX_HUNGER = 100`, `MAX_THIRST = 100`
- `RESPAWN_HEALTH = 100`, `RESPAWN_HUNGER = 80`, `RESPAWN_THIRST = 80`
- `SURVIVAL_TICK_INTERVAL = 2.0`, `MAX_LOOT_DISTANCE = 14`, `LOOT_CONTAINER_LIFETIME = 300`
- `MAX_ATTACK_ORIGIN_OFFSET = 8`

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
- `Net.InitServer()` — создаёт папку `Remotes` и все события.
- `Net.GetEvent(eventName: string): RemoteEvent` — на сервере находит/создаёт `RemoteEvent`, на клиенте ожидает через `WaitForChild`.

### Конфиги (`src/shared/configs/`)
- `Items` (`Items.luau`): словарь `itemId -> Types.ItemConfig` (`wood`, `stone`, `metal_ore`, `cloth`, `hatchet`, `pickaxe`, `bandage`, `cooked_meat`, `water_bottle`, `workbench_1`, `spear`, `metal_hatchet`, `wooden_spear`, `hunting_bow`, `arrow`, `pipe_pistol`, `pistol_ammo`, `scrap`, `tech_parts`).
- `Consumables` (`Consumables.luau`): словарь `itemId -> Types.ConsumableConfig` (`bandage`, `cooked_meat`, `water_bottle`).
- `Tools` (`Tools.luau`): словарь `itemId -> Types.ToolConfig` (`hatchet`, `pickaxe`, `metal_hatchet`).
- `Nodes` (`Nodes.luau`): словарь `nodeType -> Types.NodeConfig` (`tree`, `stone_node`, `metal_node`).
- `Recipes` (`Recipes.luau`): словарь `recipeId -> Types.RecipeConfig` (`craft_bandage`, `craft_water_bottle`, `craft_hatchet`, `craft_pickaxe`, `craft_workbench_1`, `craft_spear`, `craft_metal_hatchet`, `craft_hunting_bow`, `craft_arrow`, `craft_pipe_pistol`, `craft_pistol_ammo`).
- `Weapons` (`Weapons.luau`): словарь `itemId -> Types.WeaponConfig` (`wooden_spear`, `spear`, `hatchet`, `metal_hatchet`, `pickaxe`, `hunting_bow`, `pipe_pistol`, а также константа `FISTS`).
- `LootTables` (`LootTables.luau`): словарь `tableId -> Types.LootTableConfig` (`wooden_crate`, `military_crate`, `airdrop`).
- `BuildingConfig` (`BuildingConfig.luau`): константы сетки (`GridSize = 12`, `WallHeight = 10`, `GridMinXZ = -10`, `GridMaxXZ = 10`, `GridMinY = 0`, `GridMaxY = 4`, `MaxPiecesPerBase = 200`, `ValidRotations`, `PieceOrder`, `TierOrder`), словарь `Pieces` (`foundation`, `wall`, `doorway`, `roof`, `storage_box`, `workbench_1`) и словарь `Tiers` (`wood`, `stone`, `metal`).

---

## 3. Серверные сервисы (`ServerScriptService.Server.Services`)

### `DataService` (`src/server/Services/DataService.luau`)
- `DataService.DataLoaded: Signal.Signal<Player, PlayerData>` — событие завершения загрузки профиля игрока.
- `DataService.GetData(player: Player): PlayerData?` — возвращает данные игрока или `nil`, если профиль ещё не загружен/не активен.
- `DataService.OnDataLoaded(callback: (player: Player, data: PlayerData) -> ()): Signal.Connection` — подписывается на `DataLoaded` и немедленно вызывает `callback` для уже загруженных игроков.
- `DataService.OnBeforeUnload(callback: (player: Player, data: PlayerData) -> ())` — синхронный хук перед сериализацией и закрытием сессии (`PlayerRemoving` / `OnLastSave`).
- `DataService.IsTeleporting(player: Player): boolean` — возвращает `true`, если профиль игрока освобождён для штатного телепорта (чтобы `OnSessionEnd` не кикал игрока).
- `DataService.ReleaseForTeleport(player: Player): boolean` — синхронизирует `RuntimeData` в `profile.Data`, вызывает `profile:EndSession()`, ожидает снятия `SessionLock` (`profile:IsActive() == false` и завершение `OnAfterSave` в пределах `5` сек) и возвращает результат.
- `DataService.RestoreAfterFailedTeleport(player: Player): boolean` — перезагружает профиль игрока при сбое телепортации (`TeleportInitFailed` / таймаут).
- `DataService.Init()` — подключает `PlayerAdded` / `PlayerRemoving`, управляет сессиями `ProfileStore` (`PlayerData_v1`, включая `Stats: SurvivalStats` и `Base: BaseData` со строковой сериализацией слотов сундуков и `Reconcile` для старых профилей).

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
- `InventoryService.Init()` — инициализирует `Net`, слушает `InventoryMove` (`1..30`), `HotbarSelect` (`1..6`) и выдаёт стартовый набор в Studio (включая `water_bottle`, `hunting_bow`, `arrow`).

### `ResourceService` (`src/server/Services/ResourceService.luau`)
- `ResourceService.Init()` — сканирует `Workspace.ResourceNodes`, обрабатывает `HitNode` (валидация дистанции `<= 14`, кулдаун по инструменту, множители, `BonusOnDestroy`, истощение/респавн) и рассылает `NodeUpdated`.

### `CraftingService` (`src/server/Services/CraftingService.luau`)
- `CraftingService.RegisterStation(stationId: string, stationType: string, position: Vector3)` — регистрирует динамически размещённый верстак (например, на базе игрока).
- `CraftingService.UnregisterStation(stationId: string)` — удаляет динамический верстак по `stationId`.
- `CraftingService.GetActiveCraft(player: Player): Types.CraftingState?` — возвращает текущий активный крафт игрока или `nil`.
- `CraftingService.Init()` — сканирует `Workspace.Workbenches` (атрибут `StationType`, дистанция `<= 14` studs, а также проверяет `dynamicStations`), обрабатывает `CraftRequest` (транзакционное списание, `task.delay` с токеном сессии, выдача результата) и `CraftCancel`, а также возвращает ресурсы через `DataService.OnBeforeUnload` и `PlayerRemoving`.

### `SurvivalService` (`src/server/Services/SurvivalService.luau`)
- `SurvivalService.GetStats(player: Player): Types.SurvivalStats?` — возвращает копию текущих статов выживания игрока.
- `SurvivalService.GetContainerState(containerId: string): Types.LootContainerState?` — делегирует в `LootService.GetContainerState(containerId)`.
- `SurvivalService.Init()` — запускает цикл выживания раз в `2.0` сек (`-0.35` голода, `-0.5` жажды, пассивный реген `+1.5 HP` при `> 70`, урон `1.5 HP` при `<= 0`), реплицирует `Hunger` / `Thirst` / `Starving` / `Dehydrated` через атрибуты `Player`, обрабатывает `UseConsumable`, спавнит Greybox-рюкзак в `Workspace.LootContainers` при смерти (`Humanoid.Died`) на `300` сек (регистрация и логика контейнера делегированы `LootService`) и сбрасывает статы после респавна (`100 / 80 / 80`).

### `LootService` (`src/server/Services/LootService.luau`)
- `LootService.RollLootTable(tableId: string): Types.Inventory` — взвешенная генерация лута по таблице из `LootTables`.
- `LootService.RegisterSlotsContainer(model: Model, title: string, ownerName: string, slots: Types.Inventory, lifeTime: number): string` — регистрирует временный контейнер (рюкзак смерти, аирдроп и т.п.) с `ProximityPrompt` и авто-удалением по `lifeTime`.
- `LootService.RegisterStorageContainer(model: Model, title: string, ownerUserId: number, maxSlots: number, initialSlots: Types.Inventory, onChanged: ((slots: Types.Inventory) -> ())?): string` — регистрирует постоянный сундук базы (`Kind = "Storage"`, `AllowDeposit = true`, проверка владельца `OwnerUserId`, `ProximityPrompt` `"Open Storage"`).
- `LootService.UnregisterContainer(containerId: string)` — отвязывает контейнер и закрывает UI у зрителей без уничтожения модели.
- `LootService.SpawnTemporaryContainer(model: Model, title: string, tableId: string, lifeTime: number): string` — генерирует лут по `tableId` и регистрирует временный контейнер.
- `LootService.OpenContainerForPlayer(player: Player, containerId: string): boolean` — открывает контейнер игроку после проверки владельца, состояния и дистанции `<= MAX_LOOT_DISTANCE` (`14` studs).
- `LootService.CloseContainerForPlayer(player: Player, notifyClient: boolean)` — закрывает активный контейнер игрока.
- `LootService.DestroyContainer(containerId: string)` — закрывает окно у всех зрителей, удаляет контейнер и уничтожает его модель.
- `LootService.GetContainerState(containerId: string): Types.LootContainerState?` — возвращает копию состояния контейнера или `nil`.
- `LootService.IsContainerDepleted(containerId: string): boolean` — возвращает `true`, если POI-ящик сейчас истощён и ожидает респавна.
- `LootService.Init()` — сканирует `Workspace.POI` (модели с атрибутом `LootTable`), наполняет ящики, привязывает `ProximityPrompt`, обрабатывает `CloseContainer`, `LootTakeSlot` и `ContainerDepositSlot` (двусторонний обмен для сундуков с проверкой дистанции `<= 14` studs), истощение/респавн POI-ящиков (`RespawnTime` или `RespawnTimeOverride` в Studio) и периодическую проверку дистанции активных зрителей.

### `WorldEventService` (`src/server/Services/WorldEventService.luau`)
- `WorldEventService.TriggerAirdropNow(descentTimeOverride: number?): Model` — немедленно запускает событие Supply Drop в случайной точке из `Workspace.AirdropZones` (или в безопасном радиусе на карте), рассылает `WorldEventNotify`, плавно спускает груз с парашютом и дымом, после посадки регистрирует контейнер через `LootService.SpawnTemporaryContainer(..., "Supply Drop", "airdrop", 180)`.
- `WorldEventService.GetActiveAirdropModel(): Model?` — возвращает текущую модель активного аирдропа или `nil`.
- `WorldEventService.GetActiveAirdropContainerId(): string?` — возвращает `containerId` приземлившегося активного аирдропа или `nil`.
- `WorldEventService.Init()` — инициализирует `Net`, создаёт `Workspace.WorldEvents`, запускает периодический цикл Supply Drop раз в `420` сек и слушает атрибут `Workspace.TriggerAirdropNow` в Studio.

### `CombatService` (`src/server/Services/CombatService.luau`)
- `CombatService.GetEquippedWeapon(player: Player): (string, Types.WeaponConfig)` — возвращает `weaponId` и конфиг активного оружия игрока (или `"fists", Weapons.FISTS`).
- `CombatService.Init()` — инициализирует `Net`, подписывается на `AttackRequest` (валидация `Vector3` на `NaN`/бесконечность/длину, проверка жизни атакующего и дистанции `origin` от `HumanoidRootPart` `<= 8` studs, серверный кулдаун `Cooldown`, списание `AmmoId`, авторитетный серверный `Workspace:Raycast` с учётом препятствий и игнорированием не-коллизионных декораций, множитель хэдшота по `Head`, запись атрибута `LastAttackerUserId` на модель цели, рассылка `AttackEffect` всем клиентам) и обновляет `HpLabel` манекенов в `Workspace.TestDummies`.

### `ExtractionService` (`src/server/Services/ExtractionService.luau`)
- `ExtractionService.GetExtractionState(player: Player): Types.ExtractionState?` — возвращает текущее состояние активного экстракшена игрока или `nil`.
- `ExtractionService.IsInCombatCooldown(player: Player): boolean` — проверяет, действуют ли ещё `Config.Extraction.CooldownAfterDamage` секунд с последнего получения урона.
- `ExtractionService.RecordDamage(player: Player)` — фиксирует получение урона игроком и немедленно сбрасывает активный экстракшен.
- `ExtractionService.Init()` — сканирует `Workspace.ExtractionZones`, отслеживает урон/смерть игроков (`Humanoid.HealthChanged`, `Humanoid.Died`), проверяет нахождение живых игроков в зонах раз в `0.25` сек, рассылает `ExtractionStateSync`, по завершении таймера вызывает `DataService.ReleaseForTeleport(player)` и выполняет симуляцию телепорта в Studio или `TeleportService:TeleportAsync` на `Config.Places.PlayerBase` (с обработкой `TeleportInitFailed`, повторами и восстановлением через `DataService.RestoreAfterFailedTeleport`).

### `BaseService` (`src/server/Services/BaseService.luau`)
- `BaseService.IsBaseMode(): boolean` — возвращает `true`, если `game.PlaceId == Config.Places.PlayerBase` или в Studio включён `Workspace:GetAttribute("ForceBaseMode") == true`.
- `BaseService.GetPlayerPieces(player: Player): { Types.SavedBuildPiece }` — возвращает копию сохранённых построек игрока из `DataService`.
- `BaseService.GetStorageContainerId(player: Player, uid: string): string?` — возвращает `containerId` заспавненного сундука базы по `uid` постройки.
- `BaseService.Init()` — в режиме базы спавнит постройки из `data.Base.Pieces` в `Workspace.PlayerBaseStructures` (с регистрацией `storage_box` в `LootService` и `workbench_1` в `CraftingService`), обрабатывает `BuildPlaceRequest`, `BuildUpgradeRequest`, `BuildDemolishRequest` (серверная валидация сетки/коллизий/ресурсов, пересчёт HP и материалов) и `RequestReturnToMap` (освобождение профиля через `DataService.ReleaseForTeleport` и возврат на `Config.Places.MainMap`).

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
- `GatheringController.Init()` — строит `GatherHudGui`, выполняет raycast от курсора (блокируется при активном `BuildingController.IsBuildMode()`, открытых `InventoryUIController`, `CraftingController`, `LootController` или экипированном расходнике из `Consumables`), отправляет `HitNode`, слушает `NodeUpdated` и проигрывает визуальный отклик.

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
- `CombatController.Init()` — строит минималистичный прицел `CrosshairGui` по центру экрана (крестик + вспышка хитмаркера на `0.15s`, красная при хэдшоте), по ЛКМ (если не активен `BuildingController.IsBuildMode()`, закрыты UI-окна, нет фокуса в `TextBox`, в руках не предмет из `Consumables` и `GatheringController.IsCursorOnActiveNode() == false`) вычисляет `origin` от головы/`HumanoidRootPart` и `direction` в точку прицеливания курсора, проверяет локальный кулдаун и боеприпасы и отправляет `AttackRequest`, а по `AttackEffect` отрисовывает трассер для дальнобойного оружия (`0.12s`).

### `WorldEventController` (`src/client/Controllers/WorldEventController.luau`)
- `WorldEventController.IsBannerVisible(): boolean` — возвращает, отображается ли сейчас верхний HUD-баннер мирового события.
- `WorldEventController.GetActiveBeaconCount(): number` — возвращает количество активных 3D-маяков мировых событий.
- `WorldEventController.Init()` — строит `WorldEventHudGui`, слушает `WorldEventNotify`, показывает верхний баннер на `6` сек, создаёт 3D-маяк (`BillboardGui` с `AlwaysOnTop = true` и якорем в `Workspace.ClientEventBeacons`), обновляет расстояние в реальном времени через `RenderStepped` и удаляет маяк при исчезновении модели груза или по истечении `Duration`.

### `ExtractionController` (`src/client/Controllers/ExtractionController.luau`)
- `ExtractionController.IsVisible(): boolean` — возвращает, отображается ли сейчас панель таймера экстракшена `ExtractionGui.ExtractionPanel`.
- `ExtractionController.GetState(): Types.ExtractionState?` — возвращает копию последнего полученного от сервера состояния экстракшена или `nil`.
- `ExtractionController.Init()` — создаёт `ExtractionGui` в верхней-центральной части экрана (`ExtractionPanel`), слушает `ExtractionStateSync`, отображает название зоны, текст статуса/таймера (`Extracting in %.1fs...`) и прогресс-бар заполнения и автоматически скрывает панель при `state.Active == false`.

### `BuildingController` (`src/client/Controllers/BuildingController.luau`)
- `BuildingController.IsBaseMode(): boolean` — возвращает `true` на плейсе базы или при `ForceBaseMode == true` в Studio.
- `BuildingController.IsBuildMode(): boolean` — возвращает `true`, когда активен режим строительства на базе.
- `BuildingController.SetBuildMode(enabled: boolean)` — включает/выключает режим строительства, сбрасывает превью и подсветку.
- `BuildingController.GetPieces(): { Types.SavedBuildPiece }` — возвращает копию кэшированного списка построек базы.
- `BuildingController.Init()` — строит `BuildingGui` (панель действий `Build [B]` и `Deploy to PvP Map`, меню выбора построек, кнопки `Rotate`, `Upgrade [G]`, `Demolish`), управляет призрачным превью по сетке `GridSize = 12` с зелёной/красной индикацией коллизии и ресурсов, отправляет `BuildPlaceRequest`, `BuildUpgradeRequest`, `BuildDemolishRequest`, `RequestReturnToMap` и слушает `BaseStateSync`.
