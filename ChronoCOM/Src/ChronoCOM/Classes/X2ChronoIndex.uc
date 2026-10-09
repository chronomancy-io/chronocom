//=============================================================================
// X2ChronoIndex
//
// WASP Role: I(c) — the unit index over the committed game state, maintained
// from the history's own deltas so that no query scans the history.
//
// Axes. Every unit record is a point on axes the game already exposes:
//   frame    the history index in which the unit's state last changed
//   identity ObjectID
//   team     ETeam, together with "live" (alive and not removed from play)
//   player   the controlling player, for units on overwatch
//   space    tile (X, Y), bucketed into CELL_TILES x CELL_TILES cells
// A submitted frame contains exactly the state objects that changed in it,
// so the frame axis is the change log: syncing the index means applying the
// unit states of the frames since the last sync, never re-reading the rest.
//
// Tables (all bounded probes, all ints/values, no game-state references):
//   RecordMap    ObjectID -> record index       (X2ChronoIntMap)
//   Teams        team -> live record list       (swap-remove, O(1) membership change)
//   ReserveByPlayer  player -> units on overwatch (X2ChronoIntMap)
//   CellMap/Cells    cell -> live record list     (X2ChronoIntMap + swap-remove lists)
//   HiveSeen         XCOM unit -> epoch it was seen by the hive (epoch-stamped)
//   PodMap       AI group ObjectID -> pod index (X2ChronoIntMap, rewritten by the alien-turn update)
//
// Sync. RefreshEpoch notices a new committed frame; Sync then walks the
// frames (synced, current] and upserts the unit states they contain. A
// rewind or replaced frame (a save load) is detected by the identity of the
// last synced frame (index, tick, timestamp) and triggers one full rebuild,
// the only full pass, counted as `spatial builds`.
//
// Exactness premise (Guarantee of the engine's history design): a committed
// unit state is never mutated in place; every change to team, life, removal,
// tile or reserve action points is a new state object in a submitted frame. A once-per-turn audit
// (telemetry-gated) compares the index with a full pass and reports
// mismatches, so the premise is measured, not assumed.
//
// Lifetime: session-lived, so it holds no game-state or actor references
// (a unit state references its pawn; a rooted reference would keep the old
// level alive through a save load's garbage collection and crash).
//=============================================================================

class X2ChronoIndex extends Object;

const RECORD_CAPACITY = 2048;    // initial record-map capacity; the map grows at half load
const NUM_TEAM_SLOTS = 9;        // ETeam values are bit flags 0..255: slot = 1 + index of the highest bit
const CELL_TILES = 16;           // edge of a spatial cell; a sound's earshot (up to about 50 tiles) spans a few cells
const CELL_KEY_SPAN = 4096;      // cells per row in a packed cell key

// One known unit (by ID, never by reference)
struct UnitRecord
{
	var int ObjectID;
	var ETeam Team;
	var bool bLive;
	var int TeamSlot;   // Teams slot holding this record, or INDEX_NONE when not live
	var int TeamPos;
	var int ReservePlayer;  // the player this unit counts as an overwatching ally for in ReserveByPlayer, or 0
	var int CellKey;    // packed spatial cell of a live unit, 0 when not live
	var int CellIdx;    // Cells entry holding this record while CellKey != 0
	var int CellPos;
};

struct IntList
{
	var array<int> Idx;
};

var array<UnitRecord> Records;
var X2ChronoIntMap RecordMap;
var array<IntList> Teams;       // NUM_TEAM_SLOTS
var X2ChronoIntMap ReserveByPlayer;   // controlling player ObjectID -> playable units holding reserve action points
var X2ChronoIntMap CellMap;     // packed cell -> Cells entry
var array<IntList> Cells;       // live records per spatial cell (cells are created on first use and never removed)
var float MaxHearing;           // largest hearing radius of any unit applied since the last rebuild (world units)
var X2ChronoIntMap HiveSeen;    // XCOM unit ObjectID -> the epoch in which the hive saw it
var array<int> HiveSeenIDs;     // the units the hive sees in HiveSightEpoch
var int HiveSightEpoch;
var X2ChronoIntMap PodMap;
var int AlienPlayerID;

// Sync state: the last frame whose unit states are in the index
var bool bBuilt;
var int SyncedIndex;
var int SyncedTick;
var string SyncedStamp;

// Identity of the committed frame the epoch belongs to, as values
var int Epoch;
var int EpochHistoryIndex;
var int EpochFrameTick;
var string EpochFrameStamp;

// The session instance lives on X2EventListenerTemplate_ChronoCOM
static function X2ChronoIndex GetIndex()
{
	local X2EventListenerTemplate_ChronoCOM Runtime;

	Runtime = class'X2EventListenerTemplate_ChronoCOM'.static.GetRuntime();
	if (Runtime != none)
	{
		return Runtime.GetIndex();
	}

	// Templates not created yet: a throwaway index still returns exact results
	return new class'X2ChronoIndex';
}

static function bool IsLive(XComGameState_Unit Unit)
{
	return Unit.IsAlive() && !Unit.bRemovedFromPlay;
}

//-----------------------------------------------------------------------------
// Frame axis: epoch and sync
//-----------------------------------------------------------------------------

// Advances the epoch when the committed history frame has changed, and brings
// the unit index up to that frame
function int RefreshEpoch()
{
	local int HistoryIndex;

	HistoryIndex = `XCOMHISTORY.GetCurrentHistoryIndex();
	if (HistoryIndex >= 0)
	{
		RefreshEpochAt(HistoryIndex);
	}

	return Epoch;
}

function RefreshEpochAt(int HistoryIndex)
{
	local XComGameState Frame;

	Frame = `XCOMHISTORY.GetGameStateFromHistory(HistoryIndex);
	if (Frame == none)
	{
		return;
	}

	if (FrameChanged(HistoryIndex, Frame))
	{
		AdvanceEpoch(HistoryIndex, Frame);
	}
	else if (!bBuilt)
	{
		Sync(HistoryIndex);
	}
}

function bool FrameChanged(int HistoryIndex, XComGameState Frame)
{
	return HistoryIndex != EpochHistoryIndex || Frame.TickAddedToHistory != EpochFrameTick || Frame.TimeStamp != EpochFrameStamp;
}

function AdvanceEpoch(int HistoryIndex, XComGameState Frame)
{
	++Epoch;
	EpochHistoryIndex = HistoryIndex;
	EpochFrameTick = Frame.TickAddedToHistory;
	EpochFrameStamp = Frame.TimeStamp;
	class'X2ChronoMetrics'.static.Get().Count(eCount_Epochs);
	Sync(HistoryIndex);
}

function bool FrameIs(int HistoryIndex, int Tick, string Stamp)
{
	local XComGameState Frame;

	Frame = `XCOMHISTORY.GetGameStateFromHistory(HistoryIndex);
	return Frame != none && Frame.TickAddedToHistory == Tick && Frame.TimeStamp == Stamp;
}

function MarkSynced(int HistoryIndex)
{
	local XComGameState Frame;

	Frame = `XCOMHISTORY.GetGameStateFromHistory(HistoryIndex);
	SyncedIndex = HistoryIndex;
	SyncedTick = (Frame != none) ? Frame.TickAddedToHistory : 0;
	SyncedStamp = (Frame != none) ? Frame.TimeStamp : "";
	bBuilt = true;
}

// Applies the unit states of the frames since the last sync. A rewind or a
// replaced frame rebuilds from scratch.
function Sync(int Current)
{
	local int i;

	if (NeedsRebuild(Current))
	{
		Rebuild(Current);
		return;
	}

	for (i = SyncedIndex + 1; i <= Current; ++i)
	{
		ApplyFrame(i);
	}

	MarkSynced(Current);
}

function bool NeedsRebuild(int Current)
{
	return !bBuilt || Current < SyncedIndex || !FrameIs(SyncedIndex, SyncedTick, SyncedStamp);
}

// Upserts the units whose state changed in one frame
function ApplyFrame(int HistoryIndex)
{
	local XComGameState Frame;
	local XComGameState_Unit Unit;

	Frame = `XCOMHISTORY.GetGameStateFromHistory(HistoryIndex);
	if (Frame == none)
	{
		return;
	}

	foreach Frame.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		ApplyLatest(Unit.ObjectID);
	}
}

// The latest committed version, in case a later frame in the range changed the unit again
function ApplyLatest(int ObjectID)
{
	local XComGameState_Unit Latest;

	Latest = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(ObjectID));
	if (Latest != none)
	{
		Upsert(Latest);
		class'X2ChronoMetrics'.static.Get().Count(eCount_SpatialUpdates);
	}
}

// The only full pass: first use, and after a rewind or replaced frame
function Rebuild(int Current)
{
	local XComGameState_Unit Unit;

	ClearRecords();
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		Upsert(Unit);
	}

	class'X2ChronoMetrics'.static.Get().Count(eCount_SpatialBuilds);
	class'X2ChronoMetrics'.static.Get().Count(eCount_SpatialUnits, Records.Length);
	MarkSynced(Current);
}

// Empties the unit tables. Shrinking a dynamic array to zero and growing it
// again yields zeroed elements: empty lists.
function ClearRecords()
{
	EnsureTables();
	Records.Length = 0;
	RecordMap.Reset(RECORD_CAPACITY);
	Teams.Length = 0;
	Teams.Length = NUM_TEAM_SLOTS;
	ReserveByPlayer.Reset(0);
	CellMap.Reset(0);
	Cells.Length = 0;
	MaxHearing = 0;
	AlienPlayerID = 0;
}

function EnsureTables()
{
	if (RecordMap == none)
	{
		RecordMap = new class'X2ChronoIntMap';
		ReserveByPlayer = new class'X2ChronoIntMap';
		CellMap = new class'X2ChronoIntMap';
		HiveSeen = new class'X2ChronoIntMap';
	}
}

// Once per turn (telemetry-gated): compares the index with a full pass and
// rebuilds on any mismatch. Returns the mismatch count.
function int Audit()
{
	local int Mismatches;

	RefreshEpoch();
	class'X2ChronoMetrics'.static.Get().Count(eCount_IndexAudits);

	Mismatches = CountMismatches();
	if (Mismatches > 0)
	{
		class'X2ChronoMetrics'.static.Get().Count(eCount_IndexAuditMismatches, Mismatches);
		`log("ChronoCOM: unit index audit found" @ Mismatches @ "mismatches; rebuilding");
		Rebuild(EpochHistoryIndex);
	}

	return Mismatches;
}

// Units whose record disagrees with the history, plus one if the live totals differ
function int CountMismatches()
{
	local XComGameState_Unit Unit;
	local int Mismatches, Live;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		Live += int(IsLive(Unit));
		Mismatches += int(!RecordMatches(Unit));
	}

	return Mismatches + int(Live != CountLive());
}

// True when the unit has a record that agrees with its committed state
function bool RecordMatches(XComGameState_Unit Unit)
{
	local int Idx;

	Idx = RecordMap.Get(Unit.ObjectID);
	return Idx != INDEX_NONE && StateMatches(Idx, Unit, IsLive(Unit));
}

function bool StateMatches(int Idx, XComGameState_Unit Unit, bool bLive)
{
	return Records[Idx].bLive == bLive && Records[Idx].Team == Unit.GetTeam() && Records[Idx].ReservePlayer == ReservePlayerOf(Unit)
		&& PlaceMatches(Idx, Unit, bLive);
}

// The record sits in the unit's spatial cell
function bool PlaceMatches(int Idx, XComGameState_Unit Unit, bool bLive)
{
	return Records[Idx].CellKey == LiveCellKey(Unit, bLive);
}

// The player this unit counts as an overwatching ally for, or 0. The test is
// vanilla's own (XGAIBehavior.GetNumOverwatchingAllies): a playable unit of the
// player (XGPlayer.GetPlayableUnits) holding any reserve action point.
static function int ReservePlayerOf(XComGameState_Unit Unit)
{
	if (Unit.NumAllReserveActionPoints() > 0 && IsPlayable(Unit))
	{
		return Unit.ControllingPlayer.ObjectID;
	}

	return 0;
}

// XGPlayer.GetPlayableUnits' conditions, term for term
static function bool IsPlayable(XComGameState_Unit Unit)
{
	return !IsDown(Unit) && !IsHeldOut(Unit) && !IsNeverPlayed(Unit.GetMyTemplate());
}

static function bool IsDown(XComGameState_Unit Unit)
{
	return Unit.bRemovedFromPlay || Unit.IsDead() || Unit.IsUnconscious() || Unit.IsBleedingOut();
}

static function bool IsHeldOut(XComGameState_Unit Unit)
{
	return Unit.IsStasisLanced() || Unit.bDisabled;
}

static function bool IsNeverPlayed(X2CharacterTemplate Template)
{
	return Template.bIsCosmetic || Template.bNeverSelectable;
}

//-----------------------------------------------------------------------------
// Identity axis: ObjectID -> record
//-----------------------------------------------------------------------------

// Brings one unit's record up to its committed state: team, reserve and cell
// membership change in O(1) by swap-remove
function Upsert(XComGameState_Unit Unit)
{
	local int Idx;
	local bool bLive;

	if (Unit == none || Unit.ObjectID <= 0)
	{
		return;
	}

	Idx = RecordIndexFor(Unit.ObjectID);
	bLive = IsLive(Unit);
	Records[Idx].bLive = bLive;
	Records[Idx].Team = Unit.GetTeam();

	MoveToTeam(Idx, LiveTeamSlot(Idx, bLive));
	SetReserve(Idx, ReservePlayerOf(Unit));
	MoveToCell(Idx, LiveCellKey(Unit, bLive));
	MaxHearing = FMax(MaxHearing, Unit.GetCurrentStat(eStat_HearingRadius));
}

// Moves the unit's reserve count to PlayerID's total (0 = counted for nobody)
function SetReserve(int Idx, int PlayerID)
{
	if (Records[Idx].ReservePlayer == PlayerID)
	{
		return;
	}

	BumpReserve(Records[Idx].ReservePlayer, -1);
	BumpReserve(PlayerID, 1);
	Records[Idx].ReservePlayer = PlayerID;
}

function BumpReserve(int PlayerID, int Delta)
{
	if (PlayerID > 0)
	{
		ReserveByPlayer.Put(PlayerID, Max(ReserveByPlayer.Get(PlayerID), 0) + Delta);
	}
}

// PlayerID's playable units holding reserve action points other than
// ExceptUnitID, as of the committed frame: two probes
function int CountReserveAllies(int PlayerID, int ExceptUnitID)
{
	local int Idx;

	RefreshEpoch();
	if (!bBuilt)
	{
		return 0;
	}

	Idx = RecordMap.Get(ExceptUnitID);
	return Max(ReserveByPlayer.Get(PlayerID), 0) - int(Idx != INDEX_NONE && Records[Idx].ReservePlayer == PlayerID);
}

// The unit's record index, creating the record on first sight
function int RecordIndexFor(int ObjectID)
{
	local int Idx;

	Idx = RecordMap.Get(ObjectID);
	if (Idx == INDEX_NONE)
	{
		Idx = AddRecord(ObjectID);
	}

	return Idx;
}

function int AddRecord(int ObjectID)
{
	local UnitRecord Blank;
	local int Idx;

	Blank.ObjectID = ObjectID;
	Blank.TeamSlot = INDEX_NONE;
	Blank.TeamPos = INDEX_NONE;

	Idx = Records.Length;
	Records.AddItem(Blank);
	RecordMap.Put(ObjectID, Idx);
	return Idx;
}

function int LiveTeamSlot(int Idx, bool bLive)
{
	if (!bLive)
	{
		return INDEX_NONE;
	}

	return TeamSlotFor(Records[Idx].Team);
}

// Team-list membership change in O(1); INDEX_NONE = no list
function MoveToTeam(int Idx, int NewTeamSlot)
{
	if (Records[Idx].TeamSlot == NewTeamSlot)
	{
		return;
	}

	TeamRemove(Idx);
	if (NewTeamSlot != INDEX_NONE)
	{
		TeamAdd(Idx, NewTeamSlot);
	}
}

//-----------------------------------------------------------------------------
// Space axis: live units by cell, for "who is within this distance of here"
//-----------------------------------------------------------------------------

static function int CellCoord(int TileCoord)
{
	return Clamp(TileCoord / CELL_TILES, 0, CELL_KEY_SPAN - 1);
}

// Positive, so it can key an X2ChronoIntMap
static function int CellKeyAt(int CX, int CY)
{
	return 1 + CX + CY * CELL_KEY_SPAN;
}

// The cell of a live unit; 0 for a unit that is not live
static function int LiveCellKey(XComGameState_Unit Unit, bool bLive)
{
	return bLive ? CellKeyAt(CellCoord(Unit.TileLocation.X), CellCoord(Unit.TileLocation.Y)) : 0;
}

// Cell membership change in O(1); key 0 = no cell
function MoveToCell(int Idx, int NewKey)
{
	if (Records[Idx].CellKey == NewKey)
	{
		return;
	}

	CellRemove(Idx);
	if (NewKey != 0)
	{
		CellAdd(Idx, NewKey);
	}
}

function CellAdd(int Idx, int Key)
{
	local int CellIdx;

	CellIdx = CellIndexFor(Key);
	Records[Idx].CellKey = Key;
	Records[Idx].CellIdx = CellIdx;
	Records[Idx].CellPos = Cells[CellIdx].Idx.Length;
	Cells[CellIdx].Idx.AddItem(Idx);
}

// The cell's list, created the first time a unit stands in the cell
function int CellIndexFor(int Key)
{
	local int CellIdx;

	CellIdx = CellMap.Get(Key);
	if (CellIdx == INDEX_NONE)
	{
		CellIdx = Cells.Length;
		Cells.Length = CellIdx + 1;
		CellMap.Put(Key, CellIdx);
	}

	return CellIdx;
}

function CellRemove(int Idx)
{
	local int CellIdx, Pos, Last, Moved;

	if (Records[Idx].CellKey == 0)
	{
		return;
	}

	CellIdx = Records[Idx].CellIdx;
	Pos = Records[Idx].CellPos;
	Last = Cells[CellIdx].Idx.Length - 1;
	if (Pos != Last)
	{
		Moved = Cells[CellIdx].Idx[Last];
		Cells[CellIdx].Idx[Pos] = Moved;
		Records[Moved].CellPos = Pos;
	}
	Cells[CellIdx].Idx.Remove(Last, 1);
	Records[Idx].CellKey = 0;
}

// ObjectIDs of the live units of Team in the cells that overlap the square of
// half-side RadiusUnits around Origin: a superset of the units within
// RadiusUnits of Origin, so callers apply their own distance test and the
// result is exact. Work: the cells of the window plus the units in them.
function CollectNear(TTile Origin, float RadiusUnits, ETeam Team, out array<int> ObjectIDs)
{
	local int Reach, CX, CY;

	ObjectIDs.Length = 0;
	RefreshEpoch();
	if (!bBuilt)
	{
		return;
	}

	Reach = FCeil(FMax(RadiusUnits, 0) / class'XComWorldData'.const.WORLD_StepSize);
	for (CX = CellCoord(Origin.X - Reach); CX <= CellCoord(Origin.X + Reach); ++CX)
	{
		for (CY = CellCoord(Origin.Y - Reach); CY <= CellCoord(Origin.Y + Reach); ++CY)
		{
			AppendCell(CellKeyAt(CX, CY), Team, ObjectIDs);
		}
	}
}

function AppendCell(int Key, ETeam Team, out array<int> ObjectIDs)
{
	local int CellIdx, i, RecIdx;

	CellIdx = CellMap.Get(Key);
	for (i = 0; CellIdx != INDEX_NONE && i < Cells[CellIdx].Idx.Length; ++i)
	{
		RecIdx = Cells[CellIdx].Idx[i];
		if (Records[RecIdx].Team == Team)
		{
			ObjectIDs.AddItem(Records[RecIdx].ObjectID);
		}
	}
}

//-----------------------------------------------------------------------------
// Hive sight (per frame): the XCOM units any alien sees, computed once per
// committed frame by X2ChronoComms and shared by every alien
//-----------------------------------------------------------------------------

function bool HasHiveSight()
{
	return bBuilt && HiveSightEpoch == RefreshEpoch();
}

function SetHiveSight(const out array<int> SeenIDs)
{
	local int i;

	EnsureTables();
	HiveSightEpoch = Epoch;
	HiveSeenIDs = SeenIDs;
	for (i = 0; i < SeenIDs.Length; ++i)
	{
		HiveSeen.Put(SeenIDs[i], Epoch);
	}
}

// One probe; an entry from another frame reads as unseen
function bool HiveSees(int UnitID)
{
	return HiveSightEpoch == Epoch && HiveSeen.Get(UnitID) == Epoch;
}

//-----------------------------------------------------------------------------
// Team axis: live lists
//-----------------------------------------------------------------------------

// ETeam's values are bit flags (None 0, Neutral 1, One 2, Two 4 ... Resistance
// 64, All 255), so a team's slot is 1 + the index of its highest bit: 0..8
static function int TeamSlotFor(ETeam Team)
{
	local int Bits, Slot;

	Bits = int(Team);
	while (Bits > 0)
	{
		Bits = Bits >> 1;
		++Slot;
	}

	return Slot;
}

function TeamAdd(int Idx, int Slot)
{
	Records[Idx].TeamSlot = Slot;
	Records[Idx].TeamPos = Teams[Slot].Idx.Length;
	Teams[Slot].Idx.AddItem(Idx);
}

function TeamRemove(int Idx)
{
	local int Slot, Pos, Last, Moved;

	Slot = Records[Idx].TeamSlot;
	if (Slot == INDEX_NONE)
	{
		return;
	}

	Pos = Records[Idx].TeamPos;
	Last = Teams[Slot].Idx.Length - 1;
	if (Pos != Last)
	{
		Moved = Teams[Slot].Idx[Last];
		Teams[Slot].Idx[Pos] = Moved;
		Records[Moved].TeamPos = Pos;
	}
	Teams[Slot].Idx.Remove(Last, 1);

	Records[Idx].TeamSlot = INDEX_NONE;
	Records[Idx].TeamPos = INDEX_NONE;
}

// ObjectIDs of the live units on one team, as of the committed frame
function GetLiveUnits(ETeam Team, out array<int> ObjectIDs)
{
	ObjectIDs.Length = 0;
	RefreshEpoch();
	if (Teams.Length == NUM_TEAM_SLOTS)
	{
		AppendTeamIDs(TeamSlotFor(Team), ObjectIDs);
	}
}

// ObjectIDs of every live unit not on Team (eTeam_None = all live units)
function GetLiveUnitsNotOnTeam(ETeam Team, out array<int> ObjectIDs)
{
	local int Slot, Skip;

	ObjectIDs.Length = 0;
	RefreshEpoch();

	Skip = SkipSlotFor(Team);
	for (Slot = 0; Slot < Teams.Length; ++Slot)
	{
		if (Slot != Skip)
		{
			AppendTeamIDs(Slot, ObjectIDs);
		}
	}
}

static function int SkipSlotFor(ETeam Team)
{
	return (Team == eTeam_None) ? INDEX_NONE : TeamSlotFor(Team);
}

function AppendTeamIDs(int Slot, out array<int> ObjectIDs)
{
	local int i;

	for (i = 0; i < Teams[Slot].Idx.Length; ++i)
	{
		ObjectIDs.AddItem(Records[Teams[Slot].Idx[i]].ObjectID);
	}
}

function int CountLive()
{
	local int Slot, Total;

	for (Slot = 0; Slot < Teams.Length; ++Slot)
	{
		Total += Teams[Slot].Idx.Length;
	}

	return Total;
}

function int CountKnown()
{
	return Records.Length;
}

//-----------------------------------------------------------------------------
// Pod axis: AI group ObjectID -> pod index, rewritten by every alien-turn update
//-----------------------------------------------------------------------------

function ClearPodMap(int PodCount)
{
	if (PodMap == none)
	{
		PodMap = new class'X2ChronoIntMap';
	}

	PodMap.Reset(PodCount);
}

function SetPodOfGroup(int GroupID, int PodIndex)
{
	if (GroupID > 0 && PodMap != none)
	{
		PodMap.Put(GroupID, PodIndex);
	}
}

function int GetPodOfGroup(int GroupID)
{
	if (GroupID <= 0 || PodMap == none)
	{
		return INDEX_NONE;
	}

	return PodMap.Get(GroupID);
}

//-----------------------------------------------------------------------------
// Turn axis: the alien player's turn counter, located once per mission
//-----------------------------------------------------------------------------

function int GetAlienTurn()
{
	local XComGameState_Player PlayerState;

	PlayerState = AlienPlayer();
	if (PlayerState == none)
	{
		return 0;
	}

	return PlayerState.PlayerTurnCount;
}

// The alien player's state by its remembered ObjectID, located on first use
function XComGameState_Player AlienPlayer()
{
	local XComGameState_Player PlayerState;

	if (AlienPlayerID > 0)
	{
		PlayerState = XComGameState_Player(`XCOMHISTORY.GetGameStateForObjectID(AlienPlayerID));
	}

	if (PlayerState != none && PlayerState.GetTeam() == eTeam_Alien)
	{
		return PlayerState;
	}

	return LocateAlienPlayer();
}

// Players are created with the mission; this pass runs once per mission
function XComGameState_Player LocateAlienPlayer()
{
	local XComGameState_Player PlayerState;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Player', PlayerState)
	{
		if (PlayerState.GetTeam() == eTeam_Alien)
		{
			AlienPlayerID = PlayerState.ObjectID;
			return PlayerState;
		}
	}

	AlienPlayerID = 0;
	return none;
}

defaultproperties
{
	Epoch=1
	EpochHistoryIndex=-1
	SyncedIndex=-1
	HiveSightEpoch=-1
}
