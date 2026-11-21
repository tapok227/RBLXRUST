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

### `Types` (`src/shared/Types.luau`)
Экспортируемые типы:
- `ItemType = "Resource" | "Tool" | "Consumable"`
- `ItemConfig = { Name: string, Type: ItemType, MaxStack: number }`
- `Slot = { Id: string, Count: number }`
- `Inventory = { [number]: Slot? }`
- `SurvivalStats = { Health: number, Hunger: number, Thirst: number }`
- `ConsumableConfig = { Health: number, Hunger: number, Thirst: number, UseCooldown: number }`
- `LootContainerState = { ContainerId: string, OwnerName: string, Slots: Inventory, ExpiresAt: number }`
- `PlayerData = { Version: number, Inventory: Inventory, Stats: SurvivalStats }`
- `ItemBatchEntry = { Id: string, Count: number }`
- `ToolCategory = "Tree" | "Rock" | "Ore"`
- `ToolConfig = { Power: number, Cooldown: number, PreferredNodeType: ToolCategory, BonusMultiplier: number }`
- `NodeType = "tree" | "stone_node" | "metal_node"`
- `NodeConfig = { Name: string, Category: ToolCategory, MaxHp: number, ResourceId: string, YieldPerHit: number, BonusOnDestroy: number, RespawnTime: number }`
- `NodeClientState = { Hp: number, MaxHp: number, Depleted: boolean }`
- `Ingredient = { Id: string, Count: number }`
- `RecipeConfig = { Id: string, ResultId: string, ResultCount: number, CraftTime: number, Station: string?, Ingredients: { Ingredient } }`
- `CraftingState = { RecipeId: string, StartTime: number, EndTime: number }`

Константы:
- `INVENTORY_SIZE = 30`, `HOTBAR_SIZE = 6`
- `HANDS_POWER = 5`, `HANDS_COOLDOWN = 0.8`, `BASE_TOOL_MULTIPLIER = 1.0`
- `MAX_GATHER_DISTANCE_SERVER = 14`, `MAX_GATHER_DISTANCE_CLIENT = 12`
- `MAX_STATION_DISTANCE = 14`
- `MAX_HEALTH = 100`, `MAX_HUNGER = 100`, `MAX_THIRST = 100`
- `RESPAWN_HEALTH = 100`, `RESPAWN_HUNGER = 80`, `RESPAWN_THIRST = 80`
- `SURVIVAL_TICK_INTERVAL = 2.0`, `MAX_LOOT_DISTANCE = 14`, `LOOT_CONTAINER_LIFETIME = 300`

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
  - `OpenContainer` (Server -> Client): `(containerId: string, title: string, slots: { [string]: Types.Slot })`
  - `CloseContainer` (Client <-> Server): `(containerId: string?)`
  - `LootTakeSlot` (Client -> Server): `(containerId: string, containerSlot: number, targetPlayerSlot: number?)`
- `Net.InitServer()` — создаёт папку `Remotes` и все события.
- `Net.GetEvent(eventName: string): RemoteEvent` — на сервере находит/создаёт `RemoteEvent`, на клиенте ожидает через `WaitForChild`.

### Конфиги (`src/shared/configs/`)
- `Items` (`Items.luau`): словарь `itemId -> Types.ItemConfig` (`wood`, `stone`, `metal_ore`, `cloth`, `hatchet`, `pickaxe`, `bandage`, `cooked_meat`, `water_bottle`, `workbench_1`, `spear`, `metal_hatchet`).
- `Consumables` (`Consumables.luau`): словарь `itemId -> Types.ConsumableConfig` (`bandage`, `cooked_meat`, `water_bottle`).
- `Tools` (`Tools.luau`): словарь `itemId -> Types.ToolConfig` (`hatchet`, `pickaxe`, `metal_hatchet`).
- `Nodes` (`Nodes.luau`): словарь `nodeType -> Types.NodeConfig` (`tree`, `stone_node`, `metal_node`).
- `Recipes` (`Recipes.luau`): словарь `recipeId -> Types.RecipeConfig` (`craft_bandage`, `craft_water_bottle`, `craft_hatchet`, `craft_pickaxe`, `craft_workbench_1`, `craft_spear`, `craft_metal_hatchet`).

---

## 3. Серверные сервисы (`ServerScriptService.Server.Services`)

### `DataService` (`src/server/Services/DataService.luau`)
- `DataService.DataLoaded: Signal.Signal<Player, PlayerData>` — событие завершения загрузки профиля игрока.
- `DataService.GetData(player: Player): PlayerData?` — возвращает данные игрока или `nil`, если профиль ещё не загружен/не активен.
- `DataService.OnDataLoaded(callback: (player: Player, data: PlayerData) -> ()): Signal.Connection` — подписывается на `DataLoaded` и немедленно вызывает `callback` для уже загруженных игроков.
- `DataService.OnBeforeUnload(callback: (player: Player, data: PlayerData) -> ())` — синхронный хук перед сериализацией и закрытием сессии (`PlayerRemoving` / `OnLastSave`).
- `DataService.Init()` — подключает `PlayerAdded` / `PlayerRemoving`, управляет сессиями `ProfileStore` (включая `Stats: SurvivalStats` с `Reconcile` для старых профилей).

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
- `InventoryService.Init()` — инициализирует `Net`, слушает `InventoryMove` (`1..30`), `HotbarSelect` (`1..6`) и выдаёт стартовый набор в Studio (включая `water_bottle`).

### `ResourceService` (`src/server/Services/ResourceService.luau`)
- `ResourceService.Init()` — сканирует `Workspace.ResourceNodes`, обрабатывает `HitNode` (валидация дистанции `<= 14`, кулдаун по инструменту, множители, `BonusOnDestroy`, истощение/респавн) и рассылает `NodeUpdated`.

### `CraftingService` (`src/server/Services/CraftingService.luau`)
- `CraftingService.GetActiveCraft(player: Player): Types.CraftingState?` — возвращает текущий активный крафт игрока или `nil`.
- `CraftingService.Init()` — сканирует `Workspace.Workbenches` (атрибут `StationType`, дистанция `<= 14` studs), обрабатывает `CraftRequest` (транзакционное списание, `task.delay` с токеном сессии, выдача результата) и `CraftCancel`, а также возвращает ресурсы через `DataService.OnBeforeUnload` и `PlayerRemoving`.

### `SurvivalService` (`src/server/Services/SurvivalService.luau`)
- `SurvivalService.GetStats(player: Player): Types.SurvivalStats?` — возвращает копию текущих статов выживания игрока.
- `SurvivalService.GetContainerState(containerId: string): Types.LootContainerState?` — возвращает копию состояния контейнера лута или `nil`.
- `SurvivalService.Init()` — запускает цикл выживания раз в `2.0` сек (`-0.35` голода, `-0.5` жажды, пассивный реген `+1.5 HP` при `> 70`, урон `1.5 HP` при `<= 0`), реплицирует `Hunger` / `Thirst` / `Starving` / `Dehydrated` через атрибуты `Player`, обрабатывает `UseConsumable`, спавнит Greybox-рюкзак в `Workspace.LootContainers` при смерти (`Humanoid.Died`) на `300` сек с `ProximityPrompt` (`"Loot Body"`), сбрасывает статы после респавна (`100 / 80 / 80`) и валидирует `LootTakeSlot` (`<= 14` studs) и `CloseContainer`.

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
- `InventoryUIController.Init()` — строит `InventoryGui` (30 слотов), перекладывание двумя кликами, переключение по `Tab` / `I`.

### `CraftingController` (`src/client/Controllers/CraftingController.luau`)
- `CraftingController.IsOpen(): boolean`
- `CraftingController.SetOpen(open: boolean)`
- `CraftingController.Toggle()`
- `CraftingController.GetActiveCraft(): Types.CraftingState?`
- `CraftingController.Init()` — строит `CraftingGui` со списком рецептов (подсветка ингредиентов из `InventoryController`, пометка станции `[Workbench Lv.1]`), прогресс-баром по `CraftStateSync`, кнопками `Craft` / `Cancel`, открытием вместе с `InventoryUIController` или по `C`.

### `GatheringController` (`src/client/Controllers/GatheringController.luau`)
- `GatheringController.GetNodeState(nodeId: string): NodeClientState?`
- `GatheringController.Init()` — строит `GatherHudGui`, выполняет raycast от курсора (блокируется при открытом `InventoryUIController`, `CraftingController`, `LootController` или экипированном расходнике из `Consumables`), отправляет `HitNode`, слушает `NodeUpdated` и проигрывает визуальный отклик.

### `SurvivalHudController` (`src/client/Controllers/SurvivalHudController.luau`)
- `SurvivalHudController.Init()` — строит `SurvivalHudGui` (полоски `Health`, `Hunger`, `Thirst` в левом нижнем углу), читает `Humanoid.Health` и атрибуты `Hunger` / `Thirst` у `LocalPlayer`, подсвечивает/пульсирует полоску при `<= 15`.

### `ConsumableController` (`src/client/Controllers/ConsumableController.luau`)
- `ConsumableController.Init()` — по клику ЛКМ (если закрыты окна `InventoryUIController`, `CraftingController`, `LootController` и выбранный слот хотбара содержит предмет из `Consumables`) отправляет `UseConsumable(selectedSlot)` с локальным кулдауном.

### `LootController` (`src/client/Controllers/LootController.luau`)
- `LootController.OpenChanged: Signal.Signal<boolean>` — сигнал открытия/закрытия окна лута.
- `LootController.IsOpen(): boolean`
- `LootController.GetActiveContainerId(): string?`
- `LootController.Close()`
- `LootController.Init()` — строит `LootGui` (30-слотовая сетка контейнера и кнопка закрытия), открывается/обновляется по `OpenContainer`, закрывается по `CloseContainer` или кнопке `X`, по клику на слот отправляет `LootTakeSlot`.
