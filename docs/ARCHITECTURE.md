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
- `PlayerData = { Version: number, Inventory: Inventory }`
- `ItemBatchEntry = { Id: string, Count: number }`
- `ToolCategory = "Tree" | "Rock" | "Ore"`
- `ToolConfig = { Power: number, Cooldown: number, PreferredNodeType: ToolCategory, BonusMultiplier: number }`
- `NodeType = "tree" | "stone_node" | "metal_node"`
- `NodeConfig = { Name: string, Category: ToolCategory, MaxHp: number, ResourceId: string, YieldPerHit: number, BonusOnDestroy: number, RespawnTime: number }`
- `NodeClientState = { Hp: number, MaxHp: number, Depleted: boolean }`

Константы:
- `INVENTORY_SIZE = 30`, `HOTBAR_SIZE = 6`
- `HANDS_POWER = 5`, `HANDS_COOLDOWN = 0.8`, `BASE_TOOL_MULTIPLIER = 1.0`
- `MAX_GATHER_DISTANCE_SERVER = 14`, `MAX_GATHER_DISTANCE_CLIENT = 12`

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
- `Net.InitServer()` — создаёт папку `Remotes` и все события.
- `Net.GetEvent(eventName: string): RemoteEvent` — на сервере находит/создаёт `RemoteEvent`, на клиенте ожидает через `WaitForChild`.

### Конфиги (`src/shared/configs/`)
- `Items` (`Items.luau`): словарь `itemId -> Types.ItemConfig` (`wood`, `stone`, `metal_ore`, `cloth`, `hatchet`, `pickaxe`, `bandage`, `cooked_meat`).
- `Tools` (`Tools.luau`): словарь `itemId -> Types.ToolConfig` (`hatchet`, `pickaxe`).
- `Nodes` (`Nodes.luau`): словарь `nodeType -> Types.NodeConfig` (`tree`, `stone_node`, `metal_node`).

---

## 3. Серверные сервисы (`ServerScriptService.Server.Services`)

### `DataService` (`src/server/Services/DataService.luau`)
- `DataService.DataLoaded: Signal.Signal<Player, PlayerData>` — событие завершения загрузки профиля игрока.
- `DataService.GetData(player: Player): PlayerData?` — возвращает данные игрока или `nil`, если профиль ещё не загружен/не активен.
- `DataService.OnDataLoaded(callback: (player: Player, data: PlayerData) -> ()): Signal.Connection` — подписывается на `DataLoaded` и немедленно вызывает `callback` для уже загруженных игроков.
- `DataService.Init()` — подключает `PlayerAdded` / `PlayerRemoving`, управляет сессиями `ProfileStore` (сериализация разрежённого инвентаря в строковые ключи при сохранении).

### `InventoryService` (`src/server/Services/InventoryService.luau`)
- `InventoryService.GetEquippedSlot(player: Player): number` — возвращает текущий слот хотбара игрока (`1..6`, по умолчанию `1`).
- `InventoryService.GetEquippedItem(player: Player): Types.Slot?` — возвращает предмет в активном слоте хотбара игрока.
- `InventoryService.AddItem(player: Player, id: string, count: number): number` — добавляет предмет (сначала в существующие стаки, затем в пустые слоты 1..30), отправляет `InventorySync`, возвращает невлезший остаток.
- `InventoryService.AddItems(player: Player, items: { Types.ItemBatchEntry }): { number }` — пакетное добавление предметов с одной отправкой `InventorySync` в конце.
- `InventoryService.RemoveItem(player: Player, id: string, count: number): boolean` — списывает предметы по принципу «всё или ничего» и отправляет `InventorySync`.
- `InventoryService.Init()` — инициализирует `Net`, слушает `InventoryMove` (валидация целых `1..30`, слияние/обмен), `HotbarSelect` (валидация целых `1..6`) и выдаёт стартовый набор в Studio при пустом инвентаре.

### `ResourceService` (`src/server/Services/ResourceService.luau`)
- `ResourceService.Init()` — сканирует `Workspace.ResourceNodes` по атрибутам `NodeId`/`NodeType`, обрабатывает `HitNode` (проверка дистанции `<= 14` studs, серверного кулдауна по активному инструменту, множителя `PreferredNodeType`, пропорциональной добычи, `BonusOnDestroy`, истощения/респавна) и рассылает `NodeUpdated`.

---

## 4. Клиентские контроллеры (`StarterPlayer.StarterPlayerScripts.Client.Controllers`)

### `InventoryController` (`src/client/Controllers/InventoryController.luau`)
- `InventoryController.Changed: Signal.Signal<Inventory>` — сигнал обновления клиентского кэша инвентаря.
- `InventoryController.GetInventory(): Inventory` — возвращает текущий стейт инвентаря.
- `InventoryController.GetSlot(slotIndex: number): Slot?` — возвращает слот по индексу.
- `InventoryController.OnChanged(callback: (inventory: Inventory) -> ()): Signal.Connection` — подписывается на `Changed` и сразу передаёт текущий стейт.
- `InventoryController.RequestMove(fromSlot: number, toSlot: number)` — отправляет запрос `InventoryMove` на сервер.
- `InventoryController.Init()` — подписывается на `InventorySync`.

### `HotbarController` (`src/client/Controllers/HotbarController.luau`)
- `HotbarController.SelectSlot(slotIndex: number)` — выбирает слот `1..6`, обновляет подсветку UI и отправляет `HotbarSelect` на сервер.
- `HotbarController.GetSelectedSlot(): number` — возвращает индекс выбранного слота.
- `HotbarController.Init()` — строит `HotbarGui` (слоты `1–6`), синхронизирует начальный слот, слушает `InventoryController.OnChanged` и клавиши `1–6`.

### `InventoryUIController` (`src/client/Controllers/InventoryUIController.luau`)
- `InventoryUIController.IsOpen(): boolean`
- `InventoryUIController.SetOpen(open: boolean)`
- `InventoryUIController.Toggle()`
- `InventoryUIController.Init()` — строит окно `InventoryGui` на 30 слотов (24 рюкзака + 6 хотбара), обрабатывает перекладывание двумя кликами и переключение по `Tab` / `I`.

### `GatheringController` (`src/client/Controllers/GatheringController.luau`)
- `GatheringController.GetNodeState(nodeId: string): NodeClientState?` — возвращает кэшированное состояние ноды.
- `GatheringController.Init()` — строит `GatherHudGui`, выполняет raycast от курсора (до 12 studs по ЛКМ, до 16 studs для HUD наведения), отправляет `HitNode`, слушает `NodeUpdated` и проигрывает визуальный отклик (`Highlight` + `BillboardGui`).
