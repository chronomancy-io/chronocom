//=============================================================================
// X2ChronoFirePlan
//
// WASP Role: I(c) — the alien side's shared fire plan for the current turn.
//
//   k  target (XCOM unit ObjectID), alien turn
//   E  target ObjectID -> the alien turn in which a cover-flushing grenade was
//      thrown at it
//   I  one X2ChronoIntMap; a lookup is one probe
//   T  "was this target flushed this turn" (grenadiers do not double up,
//      shooters prefer it), "what did the grenade do to its cover" and "how
//      many flankers has this pod sent this turn"
//   F  the stored turn must equal the current alien turn, so entries from
//      earlier turns read as absent and nothing is ever cleared
//
// Whether a grenade removes a given piece of cover is decided in native code,
// so it is measured, not predicted: with a telemetry registered
// (X2ChronoMetrics), each throw records the cover the thrower faced, and the
// next decision (or the end of the turn) compares it with the cover it faces
// then.
//
// Holds ObjectIDs, tiles and ints only, so it is safe on the session-lived
// listener template (see X2ChronoIndex on why no game-state references).
//=============================================================================

class X2ChronoFirePlan extends Object;

struct PendingFlush
{
	var int ShooterID;
	var int TargetID;
	var TTile ShooterTile;
	var TTile TargetTile;
	var int CoverBefore;   // ECoverType: 0 none, 1 low, 2 high
};

var X2ChronoIntMap FlushedTurn;
var array<PendingFlush> Pending;

// Pod index + 1 -> the alien turn in which one of its units moved to flank,
// read the same way as FlushedTurn: another turn's entry reads as absent
var X2ChronoIntMap FlankTurn;

// Pod ID -> the alien turn in which a member last heard a soldier, and the
// soldier's tile then (packed); the pod update reads them when the hive sees
// nobody. Lost on load, as a cache; vanilla's alert data keeps its own copy.
var X2ChronoIntMap HeardTurn;
var X2ChronoIntMap HeardTile;

// Identity (history index, tick, timestamp) of the turn-begun frame the last
// alien-turn update ran for
var string LastUpdateFrame;

// The hive's focus target: the one soldier every alien's shot prefers until it
// is down or out of every alien's sight. An ObjectID; lost on load and picked again.
var int FocusTargetID;
var int PendingHuntedID;       // a focus target chosen since the last flyover

var localized string HuntedFlyover;

// Flank moves of a pod this alien turn, packed with the turn
const FLANK_SLOTS = 16;

// The squad's habit (XComGameState_AdaptiveMemory), looked up once per alien turn
var name Habit;
var float HabitStrength;   // how hard the aliens counter it (XComGameState_AdaptiveMemory.CounterStrength)
var int HabitTurn;

// The session's plan; a throwaway when templates are not created yet
static function X2ChronoFirePlan GetPlan()
{
	local X2EventListenerTemplate_ChronoCOM Runtime;

	Runtime = class'X2EventListenerTemplate_ChronoCOM'.static.GetRuntime();
	if (Runtime != none)
	{
		return Runtime.GetFirePlan();
	}

	return new class'X2ChronoFirePlan';
}

// A new mission or a loaded save (X2EventListenerTemplate_ChronoCOM
// .RegisterForEvents): turn numbers repeat, so nothing recorded before may be
// read again
function Reset()
{
	FlushedTurn = none;
	FlankTurn = none;
	HeardTurn = none;
	HeardTile = none;
	Pending.Length = 0;
	Habit = '';
	HabitStrength = 0;
	HabitTurn = INDEX_NONE;
	LastUpdateFrame = "";
}

// True the first time an alien turn's turn-begun frame is offered, false for
// every further listener that delivers the same frame
function bool TakesTurnUpdate(XComGameState TurnBegunState)
{
	local string Frame;

	if (TurnBegunState == none)
	{
		return true;
	}

	Frame = TurnBegunState.HistoryIndex $ ":" $ TurnBegunState.TickAddedToHistory $ ":" $ TurnBegunState.TimeStamp;
	if (Frame == LastUpdateFrame)
	{
		class'X2ChronoMetrics'.static.Get().Count(eCount_DuplicateUpdates);
		return false;
	}

	LastUpdateFrame = Frame;
	return true;
}

// The habit the aliens counter this turn. The memory's pattern and tier change
// only at mission end, so one lookup per alien turn serves every decision.
function name HabitThisTurn()
{
	RefreshHabit();
	return Habit;
}

function float HabitStrengthThisTurn()
{
	RefreshHabit();
	return HabitStrength;
}

// Once per alien turn: the habit can change within a mission, as its kills
// come in (XComGameState_AdaptiveMemory.LivePattern)
function RefreshHabit()
{
	local name Previous;
	local int Turn;

	Turn = class'X2ChronoIndex'.static.GetIndex().GetAlienTurn();
	if (HabitTurn != Turn)
	{
		HabitTurn = Turn;
		Previous = Habit;
		Habit = class'XComGameState_AdaptiveMemory'.static.ActiveHabit();
		HabitStrength = class'XComGameState_AdaptiveMemory'.static.ActiveCounterStrength();
		`log("ChronoCOM Adaptive: turn=" $ Turn @ "countering" @ ((Habit == '') ? "nothing" : string(Habit)) @ "strength=" $ HabitStrength @ "(was" @ ((Previous == '') ? "nothing" : string(Previous)) $ ")",
			Habit != Previous);
	}
}

// The cover Target has against a shot from Shooter's tile, from the world's
// cover data: 0 none, 1 low, 2 high
static function int CoverLevel(XComGameState_Unit Shooter, XComGameState_Unit Target)
{
	local vector From, To;
	local float CoverAngle;

	From = `XWORLD.GetPositionFromTileCoordinates(Shooter.TileLocation);
	To = `XWORLD.GetPositionFromTileCoordinates(Target.TileLocation);
	return `XWORLD.GetCoverTypeForTarget(From, To, CoverAngle);
}

static function XComGameState_Unit UnitOf(int UnitID)
{
	return XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitID));
}

// A cover-flushing grenade is on its way from Shooter to the unit TargetID
function NoteFlush(XComGameState_Unit Shooter, int TargetID)
{
	local XComGameState_Unit Target;
	local X2ChronoMetrics Metrics;

	Target = UnitOf(TargetID);
	if (Target == none)
	{
		return;
	}

	MarkFlushed(TargetID);
	Metrics = class'X2ChronoMetrics'.static.Get();
	Metrics.Count(eCount_FlushThrows);
	if (Metrics.IsOn())
	{
		Pending.AddItem(PendingFor(Shooter, Target));
	}
}

function MarkFlushed(int TargetID)
{
	if (FlushedTurn == none)
	{
		FlushedTurn = new class'X2ChronoIntMap';
	}

	FlushedTurn.Put(TargetID, class'X2ChronoIndex'.static.GetIndex().GetAlienTurn());
}

static function PendingFlush PendingFor(XComGameState_Unit Shooter, XComGameState_Unit Target)
{
	local PendingFlush Flush;

	Flush.ShooterID = Shooter.ObjectID;
	Flush.TargetID = Target.ObjectID;
	Flush.ShooterTile = Shooter.TileLocation;
	Flush.TargetTile = Target.TileLocation;
	Flush.CoverBefore = CoverLevel(Shooter, Target);
	return Flush;
}

function bool WasFlushedThisTurn(int TargetID)
{
	return FlushedTurn != none && FlushedTurn.Get(TargetID) == class'X2ChronoIndex'.static.GetIndex().GetAlienTurn();
}

//-----------------------------------------------------------------------------
// Focus target
//-----------------------------------------------------------------------------

// The soldier the hive burns down: kept while some alien sees it and it
// lives; otherwise the weakest soldier in the hive's sight is taken. One probe
// of the hive-sight set (at most a squad) and one unit lookup per question; a
// pass over the sighted soldiers only when the target changes.
function int FocusTarget()
{
	local array<int> SeenIDs;

	SeenIDs = class'X2ChronoComms'.static.SightIndex().HiveSeenIDs;
	if (SeenIDs.Find(FocusTargetID) == INDEX_NONE || !IsFocusable(FocusTargetID))
	{
		FocusTargetID = WeakestOf(SeenIDs);
		PendingHuntedID = FocusTargetID;
		`log("ChronoCOM Focus: turn=" $ class'X2ChronoIndex'.static.GetIndex().GetAlienTurn() @ "target=" $ FocusTargetID @ "of" @ SeenIDs.Length @ "in sight",
			FocusTargetID > 0 && class'X2ChronoMetrics'.static.Get().IsOn());
	}

	return FocusTargetID;
}

// Called after an alien's tree run, before its ability executes (where
// vanilla itself pushes a game state for a scamper): a newly chosen focus
// target gets a flyover, so the squad sees whom the hive hunts before the shot
function AnnounceHunted()
{
	local XComGameState NewGameState;
	local int TargetID;

	TargetID = PendingHuntedID;
	PendingHuntedID = 0;
	if (TargetID <= 0 || !class'X2ChronoConfig'.static.IntentFlyoverOn())
	{
		return;
	}

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("ChronoCOM Hunted");
	NewGameState.ModifyStateObject(class'XComGameState_Unit', TargetID);
	XComGameStateContext_ChangeContainer(NewGameState.GetContext()).BuildVisualizationFn = class'X2ChronoFirePlan'.static.VisualizeHunted;
	`TACTICALRULES.SubmitGameState(NewGameState);
}

static function VisualizeHunted(XComGameState VisualizeGameState)
{
	local XComGameState_Unit Unit;

	foreach VisualizeGameState.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		class'X2PodCoordinator_Optimized'.static.AddFlyover(VisualizeGameState, Unit.ObjectID, default.HuntedFlyover);
	}
}

// A soldier that can still be shot down: alive, not a Gremlin, not already
// down, not in smoke
static function bool IsFocusable(int UnitID)
{
	local XComGameState_Unit Unit;

	Unit = UnitOf(UnitID);
	return Unit != none && Unit.IsAlive() && !Unit.GetMyTemplate().bIsCosmetic && IsHuntable(Unit);
}

// Not down, and not in smoke: smoke hides a soldier from the hunt (the hive
// picks someone else, and comes back once the smoke is gone)
static function bool IsHuntable(XComGameState_Unit Unit)
{
	return !IsDown(Unit) && !Unit.IsUnitAffectedByEffectName(class'X2Effect_SmokeGrenade'.default.EffectName);
}

// Bleeding out, unconscious or in stasis: no alien can target it
static function bool IsDown(XComGameState_Unit Unit)
{
	return Unit.IsBleedingOut() || Unit.IsUnconscious() || Unit.IsInStasis();
}

// The focusable unit with the least health: the quickest to bring down. 0 when there is none.
static function int WeakestOf(const out array<int> UnitIDs)
{
	local int i, HP, LeastHP, WeakestID;

	LeastHP = 0;
	WeakestID = 0;
	for (i = 0; i < UnitIDs.Length; i++)
	{
		HP = FocusHealth(UnitIDs[i]);
		if (IsWeaker(HP, WeakestID, LeastHP))
		{
			LeastHP = HP;
			WeakestID = UnitIDs[i];
		}
	}

	return WeakestID;
}

// 0 for a unit that cannot be the focus target
static function int FocusHealth(int UnitID)
{
	return IsFocusable(UnitID) ? int(UnitOf(UnitID).GetCurrentStat(eStat_HP)) : 0;
}

static function bool IsWeaker(int HP, int WeakestID, int LeastHP)
{
	return HP > 0 && (WeakestID == 0 || HP < LeastHP);
}

// A unit of pod PodIdx has selected its flanking move
function NoteFlank(int PodIdx)
{
	if (PodIdx < 0)
	{
		return;
	}
	if (FlankTurn == none)
	{
		FlankTurn = new class'X2ChronoIntMap';
	}

	FlankTurn.Put(PodIdx + 1, class'X2ChronoIndex'.static.GetIndex().GetAlienTurn() * FLANK_SLOTS + FlanksThisTurn(PodIdx) + 1);
	class'X2ChronoMetrics'.static.Get().Count(eCount_FlankMoves);
}

// Flank moves the pod has made this alien turn; its temperament caps them
// (X2PodCoordinator_Optimized.FlankersOf), and the others keep shooting
function int FlanksThisTurn(int PodIdx)
{
	local int Packed;

	Packed = (FlankTurn != none) ? FlankTurn.Get(PodIdx + 1) : INDEX_NONE;
	return (Packed >= 0 && Packed / FLANK_SLOTS == class'X2ChronoIndex'.static.GetIndex().GetAlienTurn()) ? Packed % FLANK_SLOTS : 0;
}

// A member of pod PodID was told where a soldier is (a sound, a contact report)
function NoteHeard(int PodID, TTile Tile)
{
	if (HeardTurn == none)
	{
		HeardTurn = new class'X2ChronoIntMap';
		HeardTile = new class'X2ChronoIntMap';
	}

	HeardTurn.Put(PodID + 1, class'X2ChronoIndex'.static.GetIndex().GetAlienTurn());
	HeardTile.Put(PodID + 1, PackTile(Tile));
}

function int HeardTurnOf(int PodID)
{
	return (HeardTurn == none) ? INDEX_NONE : HeardTurn.Get(PodID + 1);
}

// True when the pod heard a soldier after alien turn SinceTurn; Tile is where
function bool HeardSince(int PodID, int SinceTurn, out TTile Tile)
{
	local int Turn;

	Turn = HeardTurnOf(PodID);
	if (Turn == INDEX_NONE || Turn <= SinceTurn)
	{
		return false;
	}

	Tile = UnpackTile(HeardTile.Get(PodID + 1));
	return true;
}

// Tiles are at most 1,024 wide and 1,024 deep; Z fits above
static function int PackTile(TTile Tile)
{
	return Tile.X + Tile.Y * 1024 + Tile.Z * 1048576;
}

static function TTile UnpackTile(int Packed)
{
	local TTile Tile;

	Tile.X = Packed % 1024;
	Tile.Y = (Packed / 1024) % 1024;
	Tile.Z = Packed / 1048576;
	return Tile;
}

// Measures every grenade thrown since the last call
function ResolvePending()
{
	local int i;

	for (i = 0; i < Pending.Length; ++i)
	{
		Resolve(Pending[i]);
	}

	Pending.Length = 0;
}

// The target is down, or nobody moved and the cover can be compared, or the
// throw cannot be judged any more
function Resolve(PendingFlush Flush)
{
	local X2ChronoMetrics Metrics;
	local XComGameState_Unit Shooter, Target;

	Metrics = class'X2ChronoMetrics'.static.Get();
	Shooter = UnitOf(Flush.ShooterID);
	Target = UnitOf(Flush.TargetID);
	if (Target == none || !Target.IsAlive())
	{
		Metrics.Count(eCount_FlushTargetDown);
	}
	else if (StillComparable(Flush, Shooter, Target))
	{
		Metrics.NoteFlushCover(Flush.CoverBefore, CoverLevel(Shooter, Target));
	}
	else
	{
		Metrics.Count(eCount_FlushUnresolved);
	}
}

static function bool StillComparable(PendingFlush Flush, XComGameState_Unit Shooter, XComGameState_Unit Target)
{
	return Shooter != none && Shooter.TileLocation == Flush.ShooterTile && Target.TileLocation == Flush.TargetTile;
}

defaultproperties
{
	HabitTurn=-1
}
