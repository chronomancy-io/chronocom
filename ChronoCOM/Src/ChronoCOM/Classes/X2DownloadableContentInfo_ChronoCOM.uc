// X2DownloadableContentInfo_ChronoCOM
// ChronoCOM's hooks into the game: the template changes and the startup
// self-test, the campaign memory's way through strategy and tactical, the
// laser designator's removal from old campaigns, and the alien-turn update
// that drives the pods.

class X2DownloadableContentInfo_ChronoCOM extends X2DownloadableContentInfo;

// ============================================================================
// SHARED DATA STRUCTURES (used by AI subsystems)
// ============================================================================

// Retired 2026-10-06 with the pod's old awareness state (PodData.AlertState):
// nothing writes or reads it; kept so that saved pods load as they were saved
enum EPodAlertState
{
	ePodState_Unaware,
	ePodState_Investigating,
	ePodState_Alerted,
	ePodState_Engaged
};

// What a pod intends this alien turn, decided once per turn from what its
// members see and what the hive knows (X2PodCoordinator_Optimized.DecideIntent)
enum EPodIntent
{
	ePodIntent_None,        // No soldier in sight and not going in: approach and hold at the edge, or the units' own trees
	ePodIntent_Press,       // Engaged on even or better terms: fight normally
	ePodIntent_Hold,        // Weakened and outnumbered, or guarding an objective: fire from where they stand, overwatch back
	ePodIntent_FallBack,    // Defeat is imminent (IsDefeatImminent): back off once, then overwatch
	ePodIntent_Assault      // The squad waits on overwatch, or the pod goes in blind: bait, flank, charge
};

// Pod structure with independent blackboard
struct PodData
{
	var int PodID;                          // Unique pod identifier
	var int GroupID;                        // ObjectID of the XComGameState_AIGroup this pod mirrors
	var int StartingMembers;                // Largest membership the group has had
	var EPodAlertState AlertState;          // Retired 2026-10-06, unused (see EPodAlertState)
	var array<int> MemberUnitIDs;           // The group's members as of this alien turn
	var vector LastKnownEnemyPosition;      // Last reported enemy position
	var int TurnsSinceLastContact;          // Retired 2026-10-06, unused (see EPodAlertState)
	var bool bHasVisualContact;             // This pod can see enemies right now
	var int SquadHealthPercent;             // Cached health for this pod
	var EPodIntent Intent;                  // This turn's intent
	var int LivingMembers;                  // Members alive at the start of this alien turn
	var int VisibleEnemies;                 // XCOM units any member can see
	var int EnemyOverwatchers;              // Of those, how many hold reserve action points
	var bool bHasFallenBack;                // The pod has spent its one fall back this mission
	var bool bAnnounceIntent;               // The intent changed to fall back, hold or assault this turn (flyover)
	var int StalkTurns;                     // Alien turns the pod has started holding at the edge: alerted, nobody in sight, a member within its edge of the believed position
	var int LastKnownTurn;                  // Alien turn LastKnownEnemyPosition was last set (0 = never)
	var int BaitUnitID;                     // The living member of the lowest rank (BAIT_ORDER, then health) this turn: the first in when the pod assaults
	var int Temper;                         // 1 cautious, 2 steady, 3 eager: rolled once when the pod is created (0 = a pod from an older save: steady)
	var bool bGuards;                       // The mission marks an objective for its defenders and the pod guards it
	var vector GuardPosition;               // That objective's tile
	var vector Position;                    // Where the pod's first living member stands, this alien turn
	var int PincerSide;                     // Going in with other pods: -1 or 1, the side of the believed position it swings to; 0 = straight in
	var vector GoInTarget;                  // Where it goes in: the believed position, or the pincer point to one side of it
};

// Set once per session by the first alien turn that finds the pod manager
// (InitializeAISystems). Config only because a class default can be assigned
// at runtime only when it is a config property.
var config bool bAISystemsInitialized;

/**
 * After every template exists: the startup self-test, then ChronoCOM's
 * template changes (the Lost's attack camera, the jam on vanilla's EMP
 * grenade and EMP Bomb). A few template lookups, once per session.
 */
static event OnPostTemplatesCreated()
{
	local X2AbilityTemplateManager AbilityManager;

	LogRuntimeSelfTest();

	`log("ChronoCOM: Initializing" @ class'X2ChronoConfig'.static.FormatMode());

	// Get ability template manager
	AbilityManager = class'X2AbilityTemplateManager'.static.GetAbilityTemplateManager();

	if (class'X2ChronoConfig'.default.bBaselineMode)
	{
		`log("ChronoCOM: Baseline mode - vanilla gameplay");
	}
	else if (AbilityManager != none)
	{
		TrimLostAttackCamera(AbilityManager);
		AddJamToEMP('EMPGrenade');
		AddJamToEMP('EMPGrenadeMk2');
	}
	else
	{
		`log("ChronoCOM: ERROR - Could not get AbilityTemplateManager!");
	}

	if (!class'X2ChronoConfig'.default.bBaselineMode)
	{
		`log("ChronoCOM: Active systems: AI behavior override, pod intent, adaptive memory");
	}
}

/**
 * Writes the facts the rest of the log depends on, so a misconfiguration is
 * visible in Launch.log instead of silently doing nothing: the engine's class
 * override table (with whether each mod class resolves), whether the runtime
 * template exists, and the config switches.
 */
static function LogRuntimeSelfTest()
{
	LogClassOverrides();

	`log("ChronoCOM: runtime template found:" @ (class'X2EventListenerTemplate_ChronoCOM'.static.GetRuntime() != none ? "yes" : "NO (the AI's session state would be lost)"));
	`log("ChronoCOM: config bBaselineMode=" $ class'X2ChronoConfig'.default.bBaselineMode
		@ "bUseTurnIndex=" $ class'X2ChronoConfig'.default.bUseTurnIndex
		@ "bVerboseLogging=" $ class'X2ChronoConfig'.default.bVerboseLogging
		@ "bLostRevealOnlyFirst=" $ class'X2ChronoConfig'.default.bLostRevealOnlyFirst
		@ "bTrimLostAttackCamera=" $ class'X2ChronoConfig'.default.bTrimLostAttackCamera);
	`log("ChronoCOM: config bPodIntent=" $ class'X2ChronoConfig'.default.bPodIntent
		@ "bFocusFire=" $ class'X2ChronoConfig'.default.bFocusFire
		@ "bGrenadiersFirst=" $ class'X2ChronoConfig'.default.bGrenadiersFirst
		@ "bFlankManeuver=" $ class'X2ChronoConfig'.default.bFlankManeuver
		@ "bFlankersFirst=" $ class'X2ChronoConfig'.default.bFlankersFirst
		@ "bIntentFlyover=" $ class'X2ChronoConfig'.default.bIntentFlyover
		@ "bAdaptiveCounter=" $ class'X2ChronoConfig'.default.bAdaptiveCounter
		@ "bSoundPropagation=" $ class'X2ChronoConfig'.default.bSoundPropagation
		@ "bHiveComms=" $ class'X2ChronoConfig'.default.bHiveComms
		@ "bHonestKnowledge=" $ class'X2ChronoConfig'.default.bHonestKnowledge
		@ "bRushToAlerts=" $ class'X2ChronoConfig'.default.bRushToAlerts @ "bGuardObjectives=" $ class'X2ChronoConfig'.default.bGuardObjectives
		@ "bDangerMap=" $ class'X2ChronoConfig'.default.bDangerMap @ "bHiddenApproach=" $ class'X2ChronoConfig'.default.bHiddenApproach
		@ "bHeightAware=" $ class'X2ChronoConfig'.default.bHeightAware);
	LogVanillaFightLimits();
}

// Vanilla's two limits on how much of the alien force may fight at once, as
// the game actually loaded them (Config/XComAI.ini lifts both)
static function LogVanillaFightLimits()
{
	local string AttackLimits;
	local int i;

	for (i = 0; i < class'XComGameState_AIPlayerData'.default.MaxEngagedEnemies.Length; ++i)
	{
		AttackLimits @= string(class'XComGameState_AIPlayerData'.default.MaxEngagedEnemies[i]);
	}

	`log("ChronoCOM: vanilla fight limits: DownThrottleUnitCount=" $ class'XComGameState_AIPlayerData'.default.DownThrottleUnitCount
		@ "| MaxEngagedEnemies per difficulty:" $ AttackLimits);
}

static function string YesNo(bool bYes)
{
	return bYes ? "yes" : "NO";
}

// Every entry of the engine's class override table, then whether ChronoCOM's four are in it
static function LogClassOverrides()
{
	local Engine Eng;
	local int i;

	Eng = class'Engine'.static.GetEngine();
	for (i = 0; i < Eng.ModClassOverrides.Length; ++i)
	{
		LogClassOverride(i, Eng.ModClassOverrides[i].BaseGameClass, Eng.ModClassOverrides[i].ModClass);
	}

	`log("ChronoCOM: XGAIBehavior override registered in engine table:" @ YesNo(IsOverrideRegistered('XGAIBehavior_ChronoCOM'))
		@ "| XGAIPlayer override registered:" @ YesNo(IsOverrideRegistered('XGAIPlayer_ChronoCOM'))
		@ "| XGAIPlayer_TheLost override registered:" @ YesNo(IsOverrideRegistered('XGAIPlayer_TheLost_ChronoCOM'))
		@ "| X2Action_RevealAIBegin override registered:" @ YesNo(IsOverrideRegistered('X2Action_RevealAIBegin_ChronoCOM'))
		@ "(" $ Eng.ModClassOverrides.Length @ "entries total)");
}

static function LogClassOverride(int Index, name BaseGameClass, name ModClass)
{
	`log("ChronoCOM: ModClassOverride[" $ Index $ "]" @ BaseGameClass @ "->" @ ModClass
		@ "(mod class resolves:" @ YesNo(class'XComEngine'.static.GetClassByName(ModClass) != none) $ ")");
}

static function bool IsOverrideRegistered(name ModClass)
{
	return class'Engine'.static.GetEngine().ModClassOverrides.Find('ModClass', ModClass) != INDEX_NONE;
}

/**
 * New campaign: the adaptive memory is born in the strategy start state, so it
 * survives every mission (objects first created in tactical are discarded when
 * the mission ends). InstallNewCampaign may not add history frames.
 */
static event InstallNewCampaign(XComGameState StartState)
{
	local XComGameState_AdaptiveMemory Existing;

	if (class'X2ChronoConfig'.default.bBaselineMode)
		return;

	// The game can build the start state more than once; one memory per campaign
	foreach StartState.IterateByClassType(class'XComGameState_AdaptiveMemory', Existing)
	{
		return;
	}

	class'XComGameState_AdaptiveMemory'.static.CreateMemory(StartState);
	`log("ChronoCOM Adaptive: created campaign memory in the new-campaign start state");
}

// Saves from before the mod, or from before the memory lived in strategy
static event OnLoadedSavedGame()
{
	if (!class'X2ChronoConfig'.default.bBaselineMode)
		class'XComGameState_AdaptiveMemory'.static.EnsureMemoryInStrategy("save without the mod");
}

static event OnLoadedSavedGameToStrategy()
{
	if (!class'X2ChronoConfig'.default.bBaselineMode)
		class'XComGameState_AdaptiveMemory'.static.EnsureMemoryInStrategy("strategy load");
	RemoveDesignators();
}

// Vanilla's EMP grenade and EMP Bomb also jam every enemy they hit
// (X2Ability_ChronoSupport.CreateJammedEffect), organic or not: the pulse
// fries the hive's comms. Every difficulty variant, thrown and launched.
static function AddJamToEMP(name GrenadeName)
{
	local array<X2DataTemplate> Variants;
	local X2GrenadeTemplate Grenade;
	local int i;

	class'X2ItemTemplateManager'.static.GetItemTemplateManager().FindDataTemplateAllDifficulties(GrenadeName, Variants);
	for (i = 0; i < Variants.Length; i++)
	{
		Grenade = X2GrenadeTemplate(Variants[i]);
		if (Grenade != none)
		{
			Grenade.ThrownGrenadeEffects.AddItem(class'X2Ability_ChronoSupport'.static.CreateJammedEffect());
			Grenade.LaunchedGrenadeEffects.AddItem(class'X2Ability_ChronoSupport'.static.CreateJammedEffect());
		}
	}
	`log("ChronoCOM: EMP jams comms:" @ GrenadeName @ "(" $ Variants.Length @ "variants)");
}

// The laser designator was removed on 2026-10-06. It was a starting item, so
// a campaign that holds one loses it here: from the Avenger's inventory and
// from every soldier's loadout, as vanilla replaces upgraded gear
// (XComGameState_HeadquartersXCom.UpgradeItems). Soldiers on a covert action
// keep theirs until a strategy load after they return. One pass over the
// soldiers' inventories per strategy load.
static function RemoveDesignators()
{
	local XComGameState NewGameState;
	local XComGameState_HeadquartersXCom XComHQ;
	local int Removed;

	XComHQ = XComGameState_HeadquartersXCom(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom', true));
	if (XComHQ == none)
	{
		return;
	}

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("ChronoCOM: remove the laser designator");
	XComHQ = XComGameState_HeadquartersXCom(NewGameState.ModifyStateObject(class'XComGameState_HeadquartersXCom', XComHQ.ObjectID));
	Removed = RemoveDesignatorsFromHQ(NewGameState, XComHQ) + RemoveDesignatorsFromSoldiers(NewGameState, XComHQ);
	if (Removed > 0)
	{
		`XCOMHISTORY.AddGameStateToHistory(NewGameState);
		`log("ChronoCOM: removed" @ Removed @ "laser designators from the campaign");
	}
	else
	{
		`XCOMHISTORY.CleanupPendingGameState(NewGameState);
	}
}

static function int RemoveDesignatorsFromHQ(XComGameState NewGameState, XComGameState_HeadquartersXCom XComHQ)
{
	local XComGameState_Item Item;
	local int Removed;

	Item = XComHQ.GetItemByName(class'X2Item_ChronoSupport'.const.RETIRED_DESIGNATOR);
	while (Item != none)
	{
		XComHQ.Inventory.RemoveItem(Item.GetReference());
		NewGameState.RemoveStateObject(Item.ObjectID);
		Removed++;
		Item = XComHQ.GetItemByName(class'X2Item_ChronoSupport'.const.RETIRED_DESIGNATOR);
	}

	return Removed;
}

static function int RemoveDesignatorsFromSoldiers(XComGameState NewGameState, XComGameState_HeadquartersXCom XComHQ)
{
	local array<XComGameState_Unit> Soldiers;
	local int i, Removed;

	Soldiers = XComHQ.GetSoldiers(false, true);
	for (i = 0; i < Soldiers.Length; i++)
	{
		Removed += RemoveDesignatorsFromSoldier(NewGameState, Soldiers[i]);
	}

	return Removed;
}

static function int RemoveDesignatorsFromSoldier(XComGameState NewGameState, XComGameState_Unit Soldier)
{
	local array<XComGameState_Item> Items;
	local int i, Removed;

	if (!Soldier.HasItemOfTemplateType(class'X2Item_ChronoSupport'.const.RETIRED_DESIGNATOR))
	{
		return 0;
	}

	Soldier = XComGameState_Unit(NewGameState.ModifyStateObject(class'XComGameState_Unit', Soldier.ObjectID));
	Items = Soldier.GetAllInventoryItems(NewGameState);
	for (i = 0; i < Items.Length; i++)
	{
		Removed += RemoveIfDesignator(NewGameState, Soldier, Items[i]);
	}

	return Removed;
}

static function int RemoveIfDesignator(XComGameState NewGameState, XComGameState_Unit Soldier, XComGameState_Item Item)
{
	if (Item.GetMyTemplateName() != class'X2Item_ChronoSupport'.const.RETIRED_DESIGNATOR || !Soldier.RemoveItemFromInventory(Item, NewGameState))
	{
		return 0;
	}

	NewGameState.RemoveStateObject(Item.ObjectID);
	return 1;
}

/**
 * Before a mission: a fresh pod manager (XComGameState_TacticalInfluenceManager), and
 * the campaign memory carried into the tactical start state so tactical code
 * can read and modify it. Its modifications are carried back at mission end.
 */
static event OnPreMission(XComGameState StartGameState, XComGameState_MissionSite MissionState)
{
	if (class'X2ChronoConfig'.default.bBaselineMode)
		return;

	class'XComGameState_TacticalInfluenceManager'.static.CreateManager(StartGameState);
	CarryMemoryIntoMission(StartGameState, "mission start");
}

// Direct tactical-to-tactical transfer (multi-part missions): same as OnPreMission
static event ModifyTacticalTransferStartState(XComGameState TransferStartState)
{
	if (class'X2ChronoConfig'.default.bBaselineMode)
		return;

	class'XComGameState_TacticalInfluenceManager'.static.CreateOrReuseManager(TransferStartState);
	CarryMemoryIntoMission(TransferStartState, "tactical transfer");
}

static function CarryMemoryIntoMission(XComGameState StartGameState, string Reason)
{
	local XComGameState_AdaptiveMemory Memory;

	Memory = class'XComGameState_AdaptiveMemory'.static.GetMemory();
	if (Memory != none)
	{
		StartGameState.ModifyStateObject(class'XComGameState_AdaptiveMemory', Memory.ObjectID);
		`log("ChronoCOM Adaptive: memory carried into" @ Reason $ ": missions=" $ Memory.MissionsCompleted @ "tier=" $ Memory.CurrentAdaptationTier @ "pattern=" $ Memory.DominantPattern
			@ "kills_so_far=" $ Memory.InProgress.Kills @ "shots_so_far=" $ Memory.InProgress.Shots);
	}
	else
	{
		// The campaign predates the fix and has not been in strategy since; this
		// memory lives for one mission only
		class'XComGameState_AdaptiveMemory'.static.CreateMemory(StartGameState);
		`log("ChronoCOM Adaptive: no campaign memory found at" @ Reason $ "; created a mission-only one (discarded at mission end)");
	}
}

// PlayerTurnBegun, registered by XComGameState_TacticalInfluenceManager.OnBeginTacticalPlay.
// Every manager in the history registers, and a mission that moved to another
// map can hold more than one (Lost and Abandoned ran this two and three times
// per alien turn), so the update is taken once per turn-begun frame.
static function EventListenerReturn OnPlayerTurnBegun(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	local XComGameState_Player PlayerState;

	PlayerState = XComGameState_Player(EventData);
	if (PlayerState != none && PlayerState.GetTeam() == eTeam_Alien && class'X2ChronoFirePlan'.static.GetPlan().TakesTurnUpdate(GameState))
	{
		OnAlienTurnUpdate();
		class'X2ChronoComms'.static.ReportContacts(GameState);
	}

	return ELR_NoInterrupt;
}

// The Lost's melee attack requests a cinescript close-up ("Lost_Attack") on
// every swing. With no camera type the ability uses the default framing
// (X2Camera_Cinescript.CreateCinescriptCameraForAbility returns none), the
// same path most abilities take.
static function TrimLostAttackCamera(X2AbilityTemplateManager AbilityManager)
{
	local X2AbilityTemplate Template;

	if (!class'X2ChronoConfig'.default.bTrimLostAttackCamera)
		return;

	Template = AbilityManager.FindAbilityTemplate('LostAttack');
	if (Template != none)
	{
		Template.CinescriptCameraType = "";
		`log("ChronoCOM: LostAttack cinescript camera removed (default framing)");
	}
}

// ============================================================================
// ALIEN TURN UPDATE
// ============================================================================

// Marks the AI systems ready once the mission's influence manager exists
static function InitializeAISystems()
{
	if (class'XComGameState_TacticalInfluenceManager'.static.GetManager() == none)
	{
		`log("ChronoCOM: ERROR - TacticalInfluenceManager not found! AI systems cannot initialize.");
		return;
	}

	default.bAISystemsInitialized = true;
	`log("ChronoCOM: AI systems initialized: pod intent, AI behavior director");
}

// Lazy initialization on the first alien turn (the tactical ruleset exists by then)
static function bool EnsureAISystems()
{
	if (!default.bAISystemsInitialized)
	{
		InitializeAISystems();
	}

	return default.bAISystemsInitialized;
}

/**
 * One update per alien turn, in one game state: pod initialization on the
 * first alien turn, and the pod state machine. Every submission is a history
 * frame the AI, the UI and the event system react to, so the update is a
 * single submission.
 */
static function OnAlienTurnUpdate()
{
	local XComGameState NewGameState;
	local XComGameState_TacticalInfluenceManager InfluenceMgr;
	local X2ChronoMetrics Metrics;
	local float ClockMs;

	if (!EnsureAISystems())
	{
		return;
	}

	Metrics = class'X2ChronoMetrics'.static.Get();
	Metrics.StartTimer(ClockMs);

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("ChronoCOM: Alien turn update");
	InfluenceMgr = class'XComGameState_TacticalInfluenceManager'.static.GetModifiableManager(NewGameState);
	if (InfluenceMgr == none)
	{
		`XCOMHISTORY.CleanupPendingGameState(NewGameState);
		`log("ChronoCOM: ERROR - TacticalInfluenceManager not found during the alien turn update");
		return;
	}

	UpdatePods(InfluenceMgr);
	AttachIntentFlyovers(NewGameState, InfluenceMgr);
	`TACTICALRULES.SubmitGameState(NewGameState);

	Metrics.Count(eCount_StatesSubmitted);
	Metrics.AddMs(eTime_TurnUpdate, Metrics.StopTimer(ClockMs));
}

// The update's game state is visualized only on a turn a pod has something to
// announce; otherwise it stays a silent state change
static function AttachIntentFlyovers(XComGameState NewGameState, XComGameState_TacticalInfluenceManager InfluenceMgr)
{
	if (class'X2PodCoordinator_Optimized'.static.HasAnnouncement(InfluenceMgr.MissionPods))
	{
		XComGameStateContext_ChangeContainer(NewGameState.GetContext()).BuildVisualizationFn = class'X2PodCoordinator_Optimized'.static.VisualizeIntent;
	}
}

// Pods follow the AI groups: the first alien turn builds them, later turns add
// pods for groups that arrived since (reinforcements). (Until 2026-10-06 the
// first build also handed every pod the squad's landing zone, unseen.)
static function UpdatePods(XComGameState_TacticalInfluenceManager InfluenceMgr)
{
	class'X2PodCoordinator_Optimized'.static.SyncPodsWithGroups(InfluenceMgr.MissionPods);
	SyncPodMap(InfluenceMgr.MissionPods);
	class'X2PodCoordinator_Optimized'.static.UpdateAllPods(InfluenceMgr.MissionPods);
}

// Group -> pod map for the AI's per-decision pod lookups (one probe instead of
// a walk over the pods), rewritten every alien turn: one entry per pod
static function SyncPodMap(const out array<PodData> Pods)
{
	local X2ChronoIndex Index;
	local int i;

	Index = class'X2ChronoIndex'.static.GetIndex();
	Index.ClearPodMap(Pods.Length);
	for (i = 0; i < Pods.Length; ++i)
	{
		Index.SetPodOfGroup(Pods[i].GroupID, i);
	}
}

defaultproperties
{
}
