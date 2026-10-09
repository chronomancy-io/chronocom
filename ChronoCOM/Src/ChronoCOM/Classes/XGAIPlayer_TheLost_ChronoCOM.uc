//=============================================================================
// XGAIPlayer_TheLost_ChronoCOM
//
// Replaces XGAIPlayer_TheLost through ModClassOverride. The Lost do not
// decide through the behavior tree that XGAIBehavior_ChronoCOM times;
// XGAIPlayer_TheLost moves a whole group at once (InitLostGroupMove:
// distribute the group over visible targets, then path every member) and
// assigns their attacks (InitLostAttackTargets).
//
// Two of those steps are rewritten with bounded probes; everything else is
// vanilla, timed for the telemetry (X2ChronoMetrics):
//
//  DistributeLostUnitsAmongTargets: vanilla answers "is this target AI or
//  XCOM" and "which assignment holds this target" with linear Find calls
//  inside a loop over every visible enemy of every member: O(L * E^2) for L
//  members and E enemies. Here both lookups are one map probe keyed by target
//  ObjectID, the candidate targets come from the unit index's live lists
//  instead of a history pass, and the in-range members leave the
//  cleared-blocking list in one pass instead of one RemoveItem each:
//  O(L * E). Assignment order, quota rule, team rule and the random pass are
//  vanilla's, in the same order, so the assignments are the same.
//
//  AssignLostUnitDestinations: vanilla tests membership of the cleared list
//  and finds the mover's tile in the reserved list per member, O(L) each, so
//  O(L^2) per group move. Here the cleared list is a set and the reserved
//  tiles carry a tile-keyed index, so each is one probe. The reserved list is
//  a set to its consumers (membership tests and exclusion lists), so removing
//  by swap does not change any destination. Vanilla's own per-member pathing
//  (FindGroupDestinationToward and the natives under it) is unchanged and
//  measured as grouppath ms.
//
// Definitions: the SYNC_RAND stream is keyed by object name, so the random
// pass draws a different (still deterministic) sequence than vanilla's class
// would; that is true of any override of this class. A lured unit that is
// dead or removed from play is not a target (vanilla's history pass listed it;
// the distance matrix filtered it out).
//=============================================================================

class XGAIPlayer_TheLost_ChronoCOM extends XGAIPlayer_TheLost;

struct LostTargetInfo
{
	var int ObjectID;
	var bool bIsAI;
	var int AssignmentIndex;  // index into LostAITargetAssignments, or INDEX_NONE
};

var bool bAnnounced;

// Scratch maps, reused across calls (ints only)
var X2ChronoIntMap TargetMap;    // target ObjectID -> index in the call's target list
var X2ChronoIntMap ClearedMap;   // member ObjectID -> 1 while its tile blocking is cleared
var X2ChronoIntMap ReservedMap;  // packed tile -> index in the reserved-tile list

function EnsureMaps()
{
	if (TargetMap == none)
	{
		TargetMap = new class'X2ChronoIntMap';
	}
	if (ClearedMap == none)
	{
		ClearedMap = new class'X2ChronoIntMap';
	}
	if (ReservedMap == none)
	{
		ReservedMap = new class'X2ChronoIntMap';
	}
}

// Makes Map the set of Keys (value 1)
static function FillSet(X2ChronoIntMap Map, const out array<int> Keys)
{
	local int i;

	Map.Reset(Keys.Length);
	for (i = 0; i < Keys.Length; ++i)
	{
		Map.Put(Keys[i], 1);
	}
}

static function int PackTile(TTile Tile)
{
	return 1 + Tile.X + (Tile.Y << 10) + (Tile.Z << 20);
}

static function XGAIBehavior BehaviorOf(int UnitID)
{
	local XGUnit UnitVis;

	UnitVis = XGUnit(`XCOMHISTORY.GetVisualizer(UnitID));
	if (UnitVis == none)
	{
		return none;
	}

	return UnitVis.m_kBehavior;
}

//-----------------------------------------------------------------------------
// Timing
//-----------------------------------------------------------------------------

// One group move: distribution, pathing and blocking updates for the group
function bool InitLostGroupMove(XGUnit SourceUnit, XComGameState_AIGroup MyGroupState, bool bScamperMove)
{
	local X2ChronoMetrics Metrics;
	local float ClockMs;
	local int MovesBefore;
	local bool bResult;

	Announce();
	Metrics = class'X2ChronoMetrics'.static.Get();
	MovesBefore = LostAIMoveAssignments.Length;
	Metrics.StartTimer(ClockMs);

	bResult = super.InitLostGroupMove(SourceUnit, MyGroupState, bScamperMove);

	Metrics.NoteLostGroupMove(Metrics.StopTimer(ClockMs), MyGroupState != none ? MyGroupState.m_arrMembers.Length : 0,
		LostAIMoveAssignments.Length - MovesBefore, bResult);
	return bResult;
}

// Once per mission, so the log proves the override is live
function Announce()
{
	if (!bAnnounced)
	{
		bAnnounced = true;
		`log("ChronoCOM: XGAIPlayer_TheLost override active (bounded target distribution and destination bookkeeping; group moves timed)");
	}
}

function InitLostAttackTargets(XComGameState_AIGroup MyGroupState)
{
	local X2ChronoMetrics Metrics;
	local float ClockMs;

	Metrics = class'X2ChronoMetrics'.static.Get();
	Metrics.StartTimer(ClockMs);
	super.InitLostAttackTargets(MyGroupState);
	Metrics.AddMs(eTime_LostAttackInit, Metrics.StopTimer(ClockMs));
}

//-----------------------------------------------------------------------------
// Distribution: vanilla's rules with hashed lookups
//-----------------------------------------------------------------------------

function DistributeLostUnitsAmongTargets(XComGameState_AIGroup MyGroupState)
{
	local X2ChronoMetrics Metrics;
	local float ClockMs;

	Metrics = class'X2ChronoMetrics'.static.Get();
	Metrics.StartTimer(ClockMs);

	if (class'X2ChronoConfig'.default.bBaselineMode)
	{
		super.DistributeLostUnitsAmongTargets(MyGroupState);
	}
	else
	{
		DistributeBounded(MyGroupState);
	}

	Metrics.AddMs(eTime_LostDistribute, Metrics.StopTimer(ClockMs));
}

function DistributeBounded(XComGameState_AIGroup MyGroupState)
{
	local array<VisibleEnemyDistanceList> DistanceMatrix, Unassigned;
	local array<int> MemberIDs, InRangeIDs;
	local array<XComGameState_Unit> MemberStates;
	local array<LostTargetInfo> Targets;
	local array<StateObjectReference> VisibleEnemies;
	local bool bAnyXComEnemies;

	LostAITargetAssignments.Length = 0;
	if (!GetGroupMoveUnitList(MemberIDs, MemberStates, MyGroupState))
	{
		return;
	}

	EnsureMaps();
	InitTeamAssignments(MemberIDs);
	bAnyXComEnemies = CollectLostTargets(Targets, VisibleEnemies);
	IndexTargets(Targets);
	GetVisibleDistanceMatrix(DistanceMatrix, MemberStates, LostEnemyFilter, VisibleEnemies);

	AssignMembers(DistanceMatrix, Targets, bAnyXComEnemies, InRangeIDs, Unassigned);
	ReleaseInRangeMembers(InRangeIDs);
	AssignRandomly(Unassigned, Targets);
}

// Candidate targets with vanilla's filters, from the unit index's live lists.
// Lured units, when there are any, are the only targets. Returns whether any
// XCOM target is among the candidates (the side rule applies then).
function bool CollectLostTargets(out array<LostTargetInfo> Targets, out array<StateObjectReference> VisibleEnemies)
{
	local array<int> LiveIDs;
	local array<StateObjectReference> Lured;
	local int i;
	local bool bAnyXComEnemies;

	Targets.Length = 0;
	VisibleEnemies.Length = 0;

	class'X2ChronoIndex'.static.GetIndex().GetLiveUnitsNotOnTeam(eTeam_None, LiveIDs);
	for (i = 0; i < LiveIDs.Length; ++i)
	{
		bAnyXComEnemies = ConsiderTarget(LiveIDs[i], Targets, VisibleEnemies, Lured) || bAnyXComEnemies;
	}

	if (Lured.Length == 0)
	{
		return bAnyXComEnemies;
	}

	UseLuredTargets(Lured, Targets, VisibleEnemies);
	return false;
}

// Adds one live unit to the candidates when vanilla's filters accept it;
// true when it is an XCOM target
function bool ConsiderTarget(int UnitID, out array<LostTargetInfo> Targets, out array<StateObjectReference> VisibleEnemies, out array<StateObjectReference> Lured)
{
	local XComGameState_Unit Unit;

	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitID));
	if (Unit == none)
	{
		return false;
	}

	NoteIfLured(Unit, Lured);
	if (IsXComTarget(Unit))
	{
		AddTarget(Unit.GetReference(), false, Targets, VisibleEnemies);
		return true;
	}
	if (IsActiveAITarget(Unit))
	{
		AddTarget(Unit.GetReference(), true, Targets, VisibleEnemies);
	}

	return false;
}

static function NoteIfLured(XComGameState_Unit Unit, out array<StateObjectReference> Lured)
{
	if (Unit.IsUnitAffectedByEffectName(class'X2StatusEffects'.default.UltrasonicLureName))
	{
		Lured.AddItem(Unit.GetReference());
	}
}

static function AddTarget(StateObjectReference UnitRef, bool bIsAI, out array<LostTargetInfo> Targets, out array<StateObjectReference> VisibleEnemies)
{
	local LostTargetInfo Info;

	Info.ObjectID = UnitRef.ObjectID;
	Info.bIsAI = bIsAI;
	Info.AssignmentIndex = INDEX_NONE;
	Targets.AddItem(Info);
	VisibleEnemies.AddItem(UnitRef);
}

// Vanilla: with lured units present they replace every other target and count as the AI side
static function UseLuredTargets(const out array<StateObjectReference> Lured, out array<LostTargetInfo> Targets, out array<StateObjectReference> VisibleEnemies)
{
	local int i;

	Targets.Length = 0;
	VisibleEnemies.Length = 0;
	for (i = 0; i < Lured.Length; ++i)
	{
		AddTarget(Lured[i], true, Targets, VisibleEnemies);
	}
}

// Vanilla: XCOM units that are not concealed, not cosmetic and not incapacitated
static function bool IsXComTarget(XComGameState_Unit Unit)
{
	return Unit.GetTeam() == eTeam_XCom
		&& !Unit.IsConcealed()
		&& !Unit.GetMyTemplate().bIsCosmetic
		&& !Unit.IsIncapacitated();
}

// Vanilla: revealed aliens; a Chosen only once engaged
static function bool IsActiveAITarget(XComGameState_Unit Unit)
{
	return Unit.GetTeam() == eTeam_Alien
		&& !Unit.IsUnrevealedAI()
		&& (!Unit.IsChosen() || Unit.IsEngagedChosen());
}

// Target ObjectID -> index in Targets
function IndexTargets(const out array<LostTargetInfo> Targets)
{
	local int i;

	TargetMap.Reset(Targets.Length);
	for (i = 0; i < Targets.Length; ++i)
	{
		TargetMap.Put(Targets[i].ObjectID, i);
	}
}

// Every valid member with a visible enemy is assigned, kept in range, or left for the random pass
function AssignMembers(const out array<VisibleEnemyDistanceList> DistanceMatrix, out array<LostTargetInfo> Targets, bool bAnyXComEnemies,
	out array<int> InRangeIDs, out array<VisibleEnemyDistanceList> Unassigned)
{
	local VisibleEnemyDistanceList Info;
	local int i;

	for (i = 0; i < DistanceMatrix.Length; ++i)
	{
		Info = DistanceMatrix[i];
		if (CanBeAssigned(Info))
		{
			AssignMember(Info, Targets, bAnyXComEnemies, InRangeIDs, Unassigned);
		}
	}
}

function bool CanBeAssigned(const out VisibleEnemyDistanceList Info)
{
	return Info.EnemyList.Length > 0 && IsValidGroupMoveUnit(Info.MemberState);
}

static function float MeleeRangeSq()
{
	return `METERSTOUNITS_SQ(class'XComWorldData'.const.WORLD_Melee_Range_Meters);
}

function AssignMember(const out VisibleEnemyDistanceList Info, out array<LostTargetInfo> Targets, bool bAnyXComEnemies,
	out array<int> InRangeIDs, out array<VisibleEnemyDistanceList> Unassigned)
{
	if (Info.DistanceList[0] <= MeleeRangeSq())
	{
		KeepInRange(Info, Targets, InRangeIDs);
	}
	else if (!AssignClosestFirst(Info, Targets, bAnyXComEnemies))
	{
		Unassigned.AddItem(Info);
	}
}

// Already able to attack: stays put, keeps its tile blocked, and is still assigned to that target
function KeepInRange(const out VisibleEnemyDistanceList Info, out array<LostTargetInfo> Targets, out array<int> InRangeIDs)
{
	local int TargetIdx;

	`XWORLD.SetTileBlockedByUnitFlag(Info.MemberState);
	InRangeIDs.AddItem(Info.MemberState.ObjectID);

	TargetIdx = TargetMap.Get(Info.EnemyList[0]);
	if (TargetIdx != INDEX_NONE)
	{
		TryAssign(Targets, TargetIdx, Info.MemberState.ObjectID, true);
	}
}

// Vanilla's two loops: closest first among the member's own side until quotas
// fill, then closest first on any side. True when assigned.
function bool AssignClosestFirst(const out VisibleEnemyDistanceList Info, out array<LostTargetInfo> Targets, bool bAnyXComEnemies)
{
	local bool bTargetsAI;

	bTargetsAI = TargetsAISide(Info.MemberState, bAnyXComEnemies);
	return AssignPass(Info, Targets, bTargetsAI, true) || AssignPass(Info, Targets, bTargetsAI, false);
}

// With no XCOM targets every member hunts the AI side
static function bool TargetsAISide(XComGameState_Unit Member, bool bAnyXComEnemies)
{
	return !bAnyXComEnemies || GetTargetTeamForLostUnit(Member) == eTeam_Alien;
}

function bool AssignPass(const out VisibleEnemyDistanceList Info, out array<LostTargetInfo> Targets, bool bTargetsAI, bool bOwnSideOnly)
{
	local int i, TargetIdx;

	for (i = 0; i < Info.EnemyList.Length; ++i)
	{
		TargetIdx = EligibleTarget(Info.EnemyList[i], Targets, bTargetsAI, bOwnSideOnly);
		if (TargetIdx != INDEX_NONE && TryAssign(Targets, TargetIdx, Info.MemberState.ObjectID, false))
		{
			return true;
		}
	}

	return false;
}

// The target's index, or INDEX_NONE when it is unknown or (own side only) on the other side
function int EligibleTarget(int TargetID, const out array<LostTargetInfo> Targets, bool bTargetsAI, bool bOwnSideOnly)
{
	local int TargetIdx;

	TargetIdx = TargetMap.Get(TargetID);
	if (TargetIdx != INDEX_NONE && bOwnSideOnly && Targets[TargetIdx].bIsAI != bTargetsAI)
	{
		return INDEX_NONE;
	}

	return TargetIdx;
}

// Adds the member to the target's assignment (creating it) when the quota
// allows; returns true when assigned. Mirrors vanilla's two inner branches.
function bool TryAssign(out array<LostTargetInfo> Targets, int TargetIdx, int MemberID, bool bIgnoreQuota)
{
	local TargetAssignment Assignment;
	local int AssignmentIndex;

	AssignmentIndex = Targets[TargetIdx].AssignmentIndex;
	if (AssignmentIndex == INDEX_NONE)
	{
		Assignment.AssignedUnitIDs.AddItem(MemberID);
		Assignment.TargetID = Targets[TargetIdx].ObjectID;
		Targets[TargetIdx].AssignmentIndex = LostAITargetAssignments.Length;
		LostAITargetAssignments.AddItem(Assignment);
		return true;
	}

	if (bIgnoreQuota || LostAITargetAssignments[AssignmentIndex].AssignedUnitIDs.Length < LOST_TARGET_ASSIGNMENT_QUOTA)
	{
		LostAITargetAssignments[AssignmentIndex].AssignedUnitIDs.AddItem(MemberID);
		return true;
	}

	return false;
}

// Members already in range leave the cleared-blocking list in one pass
function ReleaseInRangeMembers(const out array<int> InRangeIDs)
{
	local array<int> KeptIDs;
	local int i;

	if (InRangeIDs.Length == 0)
	{
		return;
	}

	FillSet(ClearedMap, InRangeIDs);
	for (i = 0; i < ClearedBlockingIDs.Length; ++i)
	{
		if (ClearedMap.Get(ClearedBlockingIDs[i]) == INDEX_NONE)
		{
			KeptIDs.AddItem(ClearedBlockingIDs[i]);
		}
	}
	ClearedBlockingIDs = KeptIDs;
}

// Everyone still unassigned joins a random visible target (every target has
// an assignment by now, as in vanilla)
function AssignRandomly(const out array<VisibleEnemyDistanceList> Unassigned, out array<LostTargetInfo> Targets)
{
	local VisibleEnemyDistanceList Info;
	local int i, TargetIdx;

	for (i = 0; i < Unassigned.Length; ++i)
	{
		Info = Unassigned[i];
		TargetIdx = TargetMap.Get(Info.EnemyList[`SYNC_RAND(Info.EnemyList.Length)]);
		if (TargetIdx != INDEX_NONE)
		{
			TryAssign(Targets, TargetIdx, Info.MemberState.ObjectID, true);
		}
	}
}

//-----------------------------------------------------------------------------
// Destinations: vanilla's loop with a hashed cleared set and indexed reserved tiles
//-----------------------------------------------------------------------------

function AssignLostUnitDestinations()
{
	local X2ChronoMetrics Metrics;
	local float ClockMs;

	Metrics = class'X2ChronoMetrics'.static.Get();
	Metrics.StartTimer(ClockMs);

	if (class'X2ChronoConfig'.default.bBaselineMode)
	{
		super.AssignLostUnitDestinations();
	}
	else
	{
		AssignDestinationsBounded();
	}

	Metrics.AddMs(eTime_LostAssign, Metrics.StopTimer(ClockMs));
}

function AssignDestinationsBounded()
{
	local array<TTile> ReservedTiles;
	local array<int> Movers;
	local int i;

	EnsureMaps();
	FillSet(ClearedMap, ClearedBlockingIDs);

	// Reserved tiles start as the group's current tiles; the pathing appends one
	// destination per success, and the mover's own tile is released after
	ReservedTiles = CurrTileOccupancy;
	ReservedMap.Reset(ReservedTiles.Length * 2);
	IndexReservedTiles(ReservedTiles, 0);

	for (i = 0; i < LostAITargetAssignments.Length; ++i)
	{
		AssignDestinationsForTarget(i, ReservedTiles, Movers);
	}

	RestoreBlocking(Movers);
}

// Paths every still-cleared member assigned to one target toward its melee tiles
function AssignDestinationsForTarget(int AssignmentIdx, out array<TTile> ReservedTiles, out array<int> Movers)
{
	local array<TTile> ValidAttackTiles;
	local array<int> Assigned;
	local XComGameState_Unit TargetState;
	local int i, UnitNumber;

	Assigned = LostAITargetAssignments[AssignmentIdx].AssignedUnitIDs;
	if (Assigned.Length == 0)
	{
		return;
	}

	TargetState = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(LostAITargetAssignments[AssignmentIdx].TargetID));
	class'Helpers'.static.FindTilesForMeleeAttack(TargetState, ValidAttackTiles);

	for (i = 0; i < Assigned.Length; ++i)
	{
		UnitNumber += TryMoveMember(Assigned[i], TargetState, ValidAttackTiles, ReservedTiles, UnitNumber, Movers);
	}
}

// One member's path attempt toward its target. Returns 1 when an attempt was
// made (vanilla numbers the attempts, not the members), 0 when the member is
// already in melee range or has no behavior.
function int TryMoveMember(int MemberID, XComGameState_Unit TargetState, out array<TTile> ValidAttackTiles, out array<TTile> ReservedTiles,
	int UnitNumber, out array<int> Movers)
{
	local XGAIBehavior Behavior;
	local TTile Tile;
	local int FirstAppended;

	if (ClearedMap.Get(MemberID) != 1)
	{
		return 0;
	}

	Behavior = BehaviorOf(MemberID);
	if (Behavior == none)
	{
		return 0;
	}

	FirstAppended = ReservedTiles.Length;
	if (Behavior.FindGroupDestinationToward(TargetState, Tile, ValidAttackTiles, ReservedTiles, UnitNumber))
	{
		RecordMove(MemberID, Tile, ReservedTiles, FirstAppended, Movers);
	}

	return 1;
}

// Vanilla's bookkeeping for a found destination: release the mover's current
// tile, record the move, block the destination, mark the member as moved
function RecordMove(int MemberID, TTile Tile, out array<TTile> ReservedTiles, int FirstAppended, out array<int> Movers)
{
	local XComGameState_Unit MemberState;
	local MoveAssignment Move;

	MemberState = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(MemberID));
	IndexReservedTiles(ReservedTiles, FirstAppended);
	ReleaseReservedTile(ReservedTiles, MemberState.TileLocation);

	Move.MoverID = MemberID;
	Move.Destination = Tile;
	LostAIMoveAssignments.AddItem(Move);
	`XWORLD.SetTileBlockedByUnitFlagAtLocation(MemberState, Tile);

	ClearedMap.Put(MemberID, 0);
	Movers.AddItem(MemberID);
}

// Units that did not move get their blocking back where they stand; movers
// block where they actually are, not where they will be
function RestoreBlocking(const out array<int> Movers)
{
	local XComGameStateHistory History;
	local XComWorldData XWorld;
	local int i;

	History = `XCOMHISTORY;
	XWorld = `XWORLD;

	for (i = 0; i < ClearedBlockingIDs.Length; ++i)
	{
		if (ClearedMap.Get(ClearedBlockingIDs[i]) == 1)
		{
			XWorld.SetTileBlockedByUnitFlag(XComGameState_Unit(History.GetGameStateForObjectID(ClearedBlockingIDs[i])));
		}
	}
	ClearedBlockingIDs.Length = 0;

	for (i = 0; i < Movers.Length; ++i)
	{
		XWorld.SetTileBlockedByUnitFlag(XComGameState_Unit(History.GetGameStateForObjectID(Movers[i])));
	}
}

// Indexes ReservedTiles[From..] by packed tile
function IndexReservedTiles(const out array<TTile> ReservedTiles, int From)
{
	local int i;

	for (i = From; i < ReservedTiles.Length; ++i)
	{
		ReservedMap.Put(PackTile(ReservedTiles[i]), i);
	}
}

// Removes a tile from the reserved set by swap-remove, keeping the index exact
function ReleaseReservedTile(out array<TTile> ReservedTiles, TTile Tile)
{
	local int TileIndex, LastIndex;

	TileIndex = ReservedMap.Get(PackTile(Tile));
	if (TileIndex == INDEX_NONE)
	{
		return;
	}

	LastIndex = ReservedTiles.Length - 1;
	ReservedMap.Put(PackTile(Tile), INDEX_NONE);
	if (TileIndex != LastIndex)
	{
		ReservedTiles[TileIndex] = ReservedTiles[LastIndex];
		ReservedMap.Put(PackTile(ReservedTiles[TileIndex]), TileIndex);
	}
	ReservedTiles.Remove(LastIndex, 1);
}

defaultproperties
{
}
