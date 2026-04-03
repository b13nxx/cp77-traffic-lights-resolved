
// Internal Mod Id: g5BfH2xv
public class g5BfH2xv_Callback extends DelayCallback {
  public let source: wref<IScriptable>;
  public let func: CName;
  public let data: array<Variant>;

  public static func Create(source: wref<IScriptable>, func: CName, opt data: array<Variant>) -> ref<g5BfH2xv_Callback> {
    let cb = new g5BfH2xv_Callback();

    cb.source = source;
    cb.func = func;
    cb.data = data;

    return cb;
  }

  public func Call() -> Variant {
    return this.Call([]);
  }

  public func Call(data: array<Variant>) -> Variant {
    if !IsDefined(this.source) {
      return ToVariant(null);
    }

    let args = this.data;
    for item in data {
      ArrayPush(args, item);
    }

    return Reflection
      .GetClassOf(ToVariant(this.source))
      .GetFunction(this.func)
      .Call(this.source, args);
  }

  public func IsValid() -> Bool {
    return IsDefined(this.source)
      && IsDefined(Reflection.GetClassOf(ToVariant(this.source)).GetFunction(this.func));
  }
}

public class g5BfH2xv_Timer extends IScriptable {
  public let callback: ref<g5BfH2xv_Callback>;
  public let delay: Int32;
  public let id: DelayID;

  public static func Create() -> ref<g5BfH2xv_Timer> {
    let timer: ref<g5BfH2xv_Timer> = new g5BfH2xv_Timer();
    return timer;
  }

  public func Start(callback: ref<g5BfH2xv_Callback>, delay: Int32) -> Bool {
    this.callback = callback;
    this.delay = delay;
    this.id = GameInstance
      .GetDelaySystem(GetGameInstance())
      .DelayCallback(this.callback, g5BfH2xv_Timer.ToSeconds(this.delay), true);

    return true;
  }

  public func Stop() -> Bool {
    if this.id == GetInvalidDelayID() {
      return false;
    }

    GameInstance.GetDelaySystem(GetGameInstance()).CancelCallback(this.id);
    this.id = GetInvalidDelayID();

    return true;
  }

  public func IsValid() -> Bool {
    return IsDefined(this.callback) && this.callback.IsValid();
  }

  public static func ToSeconds(ms: Int32) -> Float {
    return Cast<Float>(ms) / 1000.0;
  }
}

class g5BfH2xv_TrafficLightsResolvedService extends ScriptableService {
  public let enableLogs: Bool;
  public let firstLevelStreamingPadding: Float;
  public let secondLevelStreamingPadding: Float;
  public let streamingDistance: Float;
  public let streamingCache: ref<inkHashMap>;
  public let entityCache: ref<inkHashMap>;

  public cb func OnLoad() {
    this.streamingCache = new inkHashMap();
    this.entityCache = new inkHashMap();

    this.ResetValues();

    GameInstance
      .GetCallbackSystem()
      .RegisterCallback(n"Resource/PostLoad", this, n"OnStreamingBlockReady")
      .AddTarget(ResourceTarget.Type(n"worldStreamingBlock"));
    GameInstance
      .GetCallbackSystem()
      .RegisterCallback(n"Resource/PostLoad", this, n"OnStreamingSectorReady")
      .AddTarget(ResourceTarget.Type(n"worldStreamingSector"));
    GameInstance
      .GetCallbackSystem()
      .RegisterCallback(n"Entity/Attach", this, n"OnEntityAttach");
    GameInstance
      .GetCallbackSystem()
      .RegisterCallback(n"Session/Ready", this, n"OnSessionStart");
    GameInstance.GetCallbackSystem().RegisterCallback(n"Session/End", this, n"OnSessionEnd");
  }

  public cb func OnReload() {
    this.ResetValues();
  }

  public cb func OnSessionStart(event: ref<GameSessionEvent>) {
    if event.IsPreGame() {
      return;
    }

    this.ResetValues();
  }

  public cb func OnSessionEnd(event: ref<GameSessionEvent>) {
    if event.IsPreGame() {
      return;
    }

    this.ResetValues();
  }

  public func ResetValues() {
    this.enableLogs = false;

    this.firstLevelStreamingPadding = 150.0;
    this.secondLevelStreamingPadding = 50.0;
    this.streamingDistance = 300.0;
  }

  public func OnStreamingBlockReady(event: ref<ResourceEvent>) -> Void {
    let block: ref<worldStreamingBlock> = event.GetResource() as worldStreamingBlock;
    let sectorSize: Int32 = ArraySize(block.descriptors);
    let i: Int32 = 0;

    while i < sectorSize {
      if Equals(block.descriptors[i].category, worldStreamingSectorCategory.Exterior)
        && (block.descriptors[i].level == Cast<Uint8>(0) || block.descriptors[i].level == Cast<Uint8>(1)) {
        if block.descriptors[i].level == Cast<Uint8>(0) {
          block.descriptors[i].streamingBox = this
            .ScaleStreamingBox(block.descriptors[i].streamingBox, this.firstLevelStreamingPadding);
        } else {
          block.descriptors[i].streamingBox = this
            .ScaleStreamingBox(block.descriptors[i].streamingBox, this.secondLevelStreamingPadding);
        }
      }

      i += 1;
    }
  }

  public func OnStreamingSectorReady(event: ref<ResourceEvent>) -> Void {
    // Skip if the player is in interior
    if this.IsPlayerInInterior() {
      return;
    }

    let sector: ref<worldStreamingSector> = event.GetResource() as worldStreamingSector;
    let nodeSetupCount: Int32 = sector.GetNodeSetupCount();

    // Skip non exterior, higher level, and heavy sectors
    if NotEquals(sector.category, worldStreamingSectorCategory.Exterior) || sector.level > Cast<Uint8>(2) || nodeSetupCount > 5000 {
      return;
    }

    let hash: Uint64 = event.GetPath().GetHash();
    let hasCached: Bool = this.streamingCache.KeyExist(hash);
    let cachedIds: ref<inkIntHashMap> = this.streamingCache.Get(hash) as inkIntHashMap;

    if hasCached && !IsDefined(cachedIds) {
      if this.enableLogs {
        FTLog(
          s"Sector (id: \(hash) has been SKIPPED with the cache BCS none of node necessary TOTAL: \(sector.GetNodeSetupCount())."
        );
      }

      return;
    }

    let targetIds: array<Int32>;

    if hasCached {
      cachedIds.GetValues(targetIds);
    }

    let nodeSize: Int32;

    if !hasCached {
      nodeSize = sector.GetNodeSetupCount();
      cachedIds = new inkIntHashMap();
    } else {
      nodeSize = ArraySize(targetIds);
    }

    let i: Int32 = 0;
    let processed: Int32 = 0;
    let setup: ref<WorldNodeSetupWrapper>;
    let node: ref<worldNode>;
    let path: String;

    while i < nodeSize {
      if !hasCached {
        setup = sector.GetNodeSetup(i);
      } else {
        setup = sector.GetNodeSetup(targetIds[i]);
      }

      node = setup.GetNode();

      if hasCached || node.isVisibleInGame && this.CheckNodeType(node) {
        path = this.GetNodePath(node);

        if hasCached || this.CheckTemplatePath(path) {
          if !hasCached {
            cachedIds.Insert(Cast<Uint64>(processed), i);
          }

          if node.IsA(n"worldStaticMeshNode") || node.IsA(n"worldEntityNode") {
            setup
              .SetStreamingDistance(MaxF(this.streamingDistance, setup.GetStreamingDistance()));
          }

          if node.IsA(n"worldStaticMeshNode") {
            setup
              .SetSecondaryRefPointDistance(MaxF(this.streamingDistance, setup.GetSecondaryRefPointDistance()));

            (node as worldStaticMeshNode).forceAutoHideDistance = MaxF((node as worldStaticMeshNode).forceAutoHideDistance, 999.0);
          } else {
            if node.IsA(n"worldPrefabProxyMeshNode") {
              if node.IsA(n"worldEntityProxyMeshNode") {
                (node as worldEntityProxyMeshNode).entityAttachDistance = MaxF(
                  this.streamingDistance,
                  (node as worldEntityProxyMeshNode).entityAttachDistance
                );
              } else {
                if node.IsA(n"worldGenericProxyMeshNode") {
                  (node as worldGenericProxyMeshNode).nearAutoHideDistance = MaxF(
                    this.streamingDistance,
                    (node as worldGenericProxyMeshNode).nearAutoHideDistance
                  );
                }
              }
            }
          }

          processed += 1;
        }
      }

      i += 1;
    }

    if !hasCached {
      if processed > 0 {
        this.streamingCache.Insert(hash, cachedIds);

        if this.enableLogs {
          FTLog(
            s"Sector ID: \(hash) has been SAVED into the cache first time TOTAL: \(processed)."
          );
        }
      } else {
        this.streamingCache.Insert(hash, null);

        if this.enableLogs {
          FTLog(s"Sector ID: \(hash) has been SAVED into the cache with NULL");
        }
      }
    } else {
      if this.enableLogs {
        FTLog(
          s"Sector ID: \(hash) has been SERVED from the cache TOTAL: \(processed)."
        );
      }
    }
  }

  public func OnEntityAttach(event: ref<EntityLifecycleEvent>) -> Void {
    let entity: wref<Entity> = event.GetEntity();
    let entityId: Uint64 = Cast<Uint64>(entity.GetEntityID().GetHash());
    let hasCached: Bool = this.entityCache.KeyExist(entityId);
    let cachedIds: ref<inkIntHashMap> = this.entityCache.Get(entityId) as inkIntHashMap;

    if hasCached && !IsDefined(cachedIds) {
      if this.enableLogs {
        FTLog(
          s"Entity ID: \(entityId) has been SKIPPED with the cache BCS not required."
        );
      }

      return;
    }

    if !hasCached && !this.CheckEntityType(entity) {
      return;
    }

    let path: String = entity.GetTemplatePath().ToString();

    if !hasCached && !this.CheckTemplatePath(path) {
      return;
    }

    let targetIds: array<Int32>;

    if hasCached {
      cachedIds.GetValues(targetIds);
    }

    let components: array<ref<IComponent>> = entity.GetComponents();
    let componentSize: Int32;

    if !hasCached {
      componentSize = ArraySize(components);
      cachedIds = new inkIntHashMap();
    } else {
      componentSize = ArraySize(targetIds);
    }

    let i: Int32 = 0;
    let processed: Int32 = 0;
    let component: ref<IComponent>;

    while i < componentSize {
      if !hasCached {
        component = components[i];
      } else {
        component = components[targetIds[i]];
      }

      if component.IsA(n"entPhysicalDestructionComponent") {
        if !hasCached {
          cachedIds.Insert(Cast<Uint64>(processed), i);
        }

        (component as PhysicalDestructionComponent).forceAutoHideDistance = MaxF((component as PhysicalDestructionComponent).forceAutoHideDistance, 999.0);

        processed += 1;
      }

      i += 1;
    }

    if !hasCached {
      if processed > 0 {
        this.entityCache.Insert(entityId, cachedIds);

        if this.enableLogs {
          FTLog(
            s"Entity ID: \(entityId) has been SAVED into the cache with TOTAL: \(processed)."
          );
        }
      } else {
        this.entityCache.Insert(entityId, null);

        if this.enableLogs {
          FTLog(s"Entity ID: \(entityId) has been SAVED into the cache with NULL");
        }
      }
    } else {
      if this.enableLogs {
        FTLog(
          s"Entity ID: \(entityId) has been SERVED from the cache TOTAL: \(processed)."
        );
      }
    }
  }

  public func GetNodePath(node: wref<worldNode>) -> String {
    let path: String = "[undetermined]";

    if node.IsA(n"worldMeshNode") {
      path = ResRef.ToString(ResourceAsyncRef.GetPath((node as worldMeshNode).mesh));
    } else if node.IsA(n"worldEntityNode") {
      path = ResRef
        .ToString(ResourceAsyncRef.GetPath((node as worldEntityNode).entityTemplate));
    }

    return StrLower(path);
  }

  public func CheckNodeType(node: wref<worldNode>) -> Bool {
    // TODO: Look for worldDestructibleEntityProxyMeshNode (descendent of worldEntityProxyMeshNode) if we need this NodeType or not
    return node.IsExactlyA(n"worldStaticMeshNode")
      || node.IsExactlyA(n"worldEntityNode")
      || node.IsExactlyA(n"worldDeviceNode")
      || node.IsA(n"worldEntityProxyMeshNode")
      || node.IsExactlyA(n"worldGenericProxyMeshNode");
  }

  public func CheckEntityType(entity: wref<Entity>) -> Bool {
    return entity.IsExactlyA(n"entEntity")
      || entity.IsExactlyA(n"DestructibleMasterDevice")
      || entity.IsExactlyA(n"DestructibleMasterLight")
      || entity.IsExactlyA(n"ElectricLight")
      || entity.IsExactlyA(n"DestructibleRoadSign");
  }

  public func CheckTemplatePath(path: String) -> Bool {
    return StrContains(path, "traffic_light")
      || StrContains(path, "crossing_light")
      || StrContains(path, "street_lamp")
      || StrContains(path, "highway_sign")
      || StrContains(path, "road_sign")
      || StrContains(path, "street_sign")
      || StrContains(path, "market_stand_01_a_roof_support_")
      || StrContains(path, "lamp_f_")
      || StrContains(path, "lamp_e_")
      || StrContains(path, "fuse_box_large_module_");
  }

  public func ScaleStreamingBox(box: Box, padding: Float) -> Box {
    let bodyDiagonal = Vector4(box.Max.X, box.Max.Y, 0, 0) - Vector4(box.Min.X, box.Min.Y, 0, 0);
    let forward = Vector4.Normalize(bodyDiagonal);
    let backward = -forward;

    box.Max = box.Max + forward * padding;
    box.Min = box.Min + backward * padding;

    return box;
  }

  public func IsCrowdCar(car: wref<VehicleObject>) -> Bool {
    // && car.IsCrowdVehicle()
    return car.IsA(n"vehicleCarBaseObject")
      && !car.IsVehicleParked()
      && !car.IsVehicleUpsideDown()
      && !car.IsAbandoned()
      && !car.IsQuest()
      && !car.GetVehiclePS().GetHasExploded()
      && !car.IsPrevention();
  }

  public func GetCarSpeed(car: wref<VehicleObject>) -> Float {
    if !IsDefined(car) {
      return 0.0;
    }

    return Vector4.Length(car.GetLinearVelocity());
  }

  public func SoftSpawnCar(car: wref<VehicleObject>) -> Bool {
    if !IsDefined(car) {
      return false;
    }

    GameInstance.GetPreventionSpawnSystem(car.GetGame()).InterruptAllActionAndCommands(car);
    let joinTrafficCommand: ref<JoinTrafficVehicleEvent> = new JoinTrafficVehicleEvent();
    car.QueueEvent(joinTrafficCommand);

    return true;
  }

  public func IsPlayerInInterior() -> Bool {
    return IsEntityInInteriorArea(GetPlayer(GetGameInstance()));
  }
}

@addMethod(GameInstance)
public static func GetTrafficLightsResolvedService() -> ref<g5BfH2xv_TrafficLightsResolvedService> {
  return GameInstance
    .GetScriptableServiceContainer()
    .GetService(n"g5BfH2xv_TrafficLightsResolvedService") as g5BfH2xv_TrafficLightsResolvedService;
}

@addField(VehicleObject)
public let g5BfH2xv_bumpedByPlayer: Bool;

@addField(VehicleObject)
public let g5BfH2xv_calmTimer: ref<g5BfH2xv_Timer>;

@wrapMethod(VehicleObject)
protected cb func OnGameAttached() -> Bool {
  this.g5BfH2xv_calmTimer = g5BfH2xv_Timer.Create();
  return wrappedMethod();
}

@wrapMethod(VehicleObject)
protected cb func OnDetach() -> Bool {
  this.g5BfH2xv_calmTimer.Stop();
  this.g5BfH2xv_calmTimer = null;

  return wrappedMethod();
}

@wrapMethod(VehicleObject)
protected cb func OnVehicleBumpEvent(evt: ref<VehicleBumpEvent>) -> Bool {
  let result: Bool = wrappedMethod(evt);

  if evt.hitVehicle.IsPlayerDriver() {
    this.g5BfH2xv_bumpedByPlayer = true;
  } else {
    this.g5BfH2xv_bumpedByPlayer = false;
  }

  return result;
}

@wrapMethod(VehicleObject)
protected cb func OnOutOfCrowd(evt: ref<OutOfCrowd>) -> Bool {
  if !this.IsA(n"vehicleCarBaseObject") {
    return wrappedMethod(evt);
  }

  let player: ref<PlayerPuppet> = GetPlayer(this.GetGame());
  let drivingState: gamePSMVehicle = PlayerPuppet.GetCurrentVehicleState(player);
  let isPlayerDriving: Bool = Equals(drivingState, gamePSMVehicle.Driving) || Equals(drivingState, gamePSMVehicle.DriverCombat);

  if !isPlayerDriving {
    return wrappedMethod(evt);
  }

  let TrafficLightsResolvedService: ref<g5BfH2xv_TrafficLightsResolvedService> = GameInstance.GetTrafficLightsResolvedService();
  let currentSpeed: Float = TrafficLightsResolvedService.GetCarSpeed(this);

  if TrafficLightsResolvedService.enableLogs {
    FTLog(
      s"VehicleObject OnOutOfCrowd fired \(this.GetEntityID().GetHash()) IsCrowdCar: \(TrafficLightsResolvedService.IsCrowdCar(this)) IsCrowdVehicle: \(this.IsCrowdVehicle())"
    );
  }

  if this.m_hitByPlayer
    || this.m_bumpedRecently > 0 && this.g5BfH2xv_bumpedByPlayer
    || !TrafficLightsResolvedService.IsCrowdCar(this)
    || currentSpeed >= 1.0 {
    return wrappedMethod(evt);
  }

  let playerVehicle: wref<VehicleObject> = player.GetMountedVehicle();

  if !TrafficLightsResolvedService.IsCrowdCar(playerVehicle) || playerVehicle.GetCurrentSpeed() >= 1.0 {
    return wrappedMethod(evt);
  }

  let driver: wref<NPCPuppet> = VehicleComponent.GetDriverMounted(this.GetGame(), this.GetEntityID()) as NPCPuppet;
  let reactionComp: wref<ReactionManagerComponent> = driver.GetStimReactionComponent();
  let isPlayerClose: Bool = reactionComp.IsTargetClose(player, 18);
  let isPlayerInFront: Bool = reactionComp.IsTargetInFront(player, 15);

  if isPlayerClose && isPlayerInFront {
    TrafficLightsResolvedService.SoftSpawnCar(this);

    if this.g5BfH2xv_calmTimer.IsValid() {
      this.g5BfH2xv_calmTimer.Start(this.g5BfH2xv_calmTimer.callback, 500);
    } else {
      this
        .g5BfH2xv_calmTimer
        .Start(g5BfH2xv_Callback.Create(this, n"g5BfH2xv_OnCarCalm"), 500);
    }

    if TrafficLightsResolvedService.enableLogs {
      FTLog("NPC Vehicle: It has been calmed down and marked to be FORCE BRAKE");
    }
  }

  return wrappedMethod(evt);
}

@addMethod(VehicleObject)
public cb func g5BfH2xv_OnCarCalm() -> Void {
  let TrafficLightsResolvedService: ref<g5BfH2xv_TrafficLightsResolvedService> = GameInstance.GetTrafficLightsResolvedService();

  this.ForceBrakesUntilStoppedOrFor(3);

  if TrafficLightsResolvedService.enableLogs {
    FTLog("NPC Vehicle: It has been force stopped");
  }
}
