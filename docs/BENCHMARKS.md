# Производительность и нагрузочные замеры (Этап 10)

## 1. Проведённые оптимизации и аудит утечек памяти
- **Кэширование `RemoteEvent` (`Net`)**: `Net.GetEvent` кэширует найденные/созданные `RemoteEvent` в `eventCache`, исключая повторный `FindFirstChild` при частых тиках.
- **Таргетированная сетевая рассылка**:
  - `ResourceService`: `NodeUpdated` рассылается игрокам в радиусе `120` studs от ноды (и всем при истощении/респавне); `GatheringController` читает атрибут `Hp` модели при наведении.
  - `CombatService`: `AttackEffect` для ближнего боя отправляется только атакующему при попадании; для дальнобойного оружия — игрокам в радиусе `250` studs.
  - `SurvivalService`: атрибуты `Hunger` / `Thirst` / `Starving` / `Dehydrated` обновляются через `SetAttribute` только при изменении значения.
  - `ExtractionService` и `RaidService`: рассылка `ExtractionStateSync` и `RaidHudSync` выполняется только для активных участников, а цикл зон экстракшена имеет ранний выход при `#zones == 0` и предвычисленный `HalfSize`.
- **Оптимизация рендера строительства (`BuildingController`)**:
  - `RaycastParams` кэшируется на уровне контроллера (`FilterDescendantsInstances` обновляется только при смене персонажа или пересоздании `ghostModel`, без `RaycastParams.new()` в каждом кадре `RenderStepped`).
- **Полная очистка при выходе и смерти (`PlayerRemoving` / `CharacterRemoving`)**:
  - `DataService`: безусловная очистка `Profiles`, `RuntimeData`, `unloadedByPlayer`, `teleportingPlayers` и `lastRegisteredPieceCount` в `onPlayerRemoving`; ограничение `nameCache` (`<= 256` записей).
  - `InventoryService`: проверка `player.Parent == Players` перед `InventorySync`.
  - `SurvivalService` и `ExtractionService`: очистка пер-персонажных связей через `CharacterRemoving` (`Janitor:Cleanup()`).
  - `CraftingService` и `LootService`: отмена отложенных потоков `task.delay` через `task.cancel` и отключение `ProximityPrompt.Triggered` (`PromptConn:Disconnect()`) при отмене/уничтожении контейнера; ранний выход в `stepViewerDistanceCheck` при отсутствии открытых контейнеров.
  - `RaidService`: удаление сработавших зарядов из `session.ActiveExplosives` при детонации.

## 2. Результаты замеров в Roblox Studio (50 виртуальных игроков × 100 итераций)
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
