//=============================================================================
// X2ChronoMetrics
//
// What ChronoCOM reports about its own work, and the one place it reports to.
//
// Every ChronoCOM class reports through X2ChronoMetrics.Get(). By itself this
// class is a null object: every call does nothing and IsOn() is false, so a
// player's install counts, times and logs nothing. A development mod can
// subclass it and register the subclass at startup (Register); from then on
// every call is counted, timed and logged. Nothing
// in ChronoCOM knows the subclass, and nothing ChronoCOM decides depends on
// what is reported.
//
// Two kinds of report:
//   - plain counts and timings, by enum (Count, AddMs, StartTimer/StopTimer)
//   - events the telemetry interprets (Note...)
//
// A decision log line is built only when IsOn(), so its string costs nothing
// without a registered subclass:
//   `log("ChronoCOM Pod: ...", class'X2ChronoMetrics'.static.Get().IsOn());
//=============================================================================

class X2ChronoMetrics extends Object;

// Counts ChronoCOM's classes keep, one slot each
enum EChronoCount
{
	eCount_Epochs,                // committed frames the unit index advanced to
	eCount_SpatialUpdates,        // unit states applied to the index from frame deltas
	eCount_SpatialBuilds,         // full rebuilds of the unit index (first use, rewinds, audit mismatches)
	eCount_SpatialUnits,          // unit states read by those rebuilds
	eCount_IndexAudits,           // full comparisons of the index with the history
	eCount_IndexAuditMismatches,
	eCount_NativeVisQueries,      // engine visibility queries used instead of scans
	eCount_StatesSubmitted,       // game states ChronoCOM itself submitted
	eCount_DuplicateUpdates,      // alien-turn updates skipped because this turn's already ran
	eCount_PodWalks,              // pod lookups the group -> pod map could not answer
	eCount_FlankMoves,            // flank directives that ended in a move to a flanking tile
	eCount_SetUpRuns,             // runs of a unit holding at the edge of the squad's reach
	eCount_HoldRefusals,          // advancing destination searches refused while the unit's pod held
	eCount_FlushThrows,           // cover-flushing grenades selected
	eCount_FlushTargetDown,       // their target was down when the throw was measured
	eCount_FlushUnresolved,       // thrower or target had moved before it was measured
	eCount_FocusScores,           // target scores that received the focus-fire terms
	eCount_HabitProfileSwaps,     // destination searches run with a habit counter's tile profile
	eCount_HabitSpreadTiles,      // tile scores whose spread penalty was strengthened
	eCount_ContactReports,        // aliens not in the fight told where a sighted XCOM unit is
	eCount_KnownPasses,           // known-enemy questions answered by vanilla's pass over every unit
	eCount_KnownFrameHits,        // ... answered from the list kept for the history frame
	eCount_KnownIndexed,          // known-enemy lists built from the unit index
	eCount_KnownJammed,           // known-enemy lists of jammed aliens: their own sight only
	eCount_OverwatchAllyReads,    // overwatching-ally counts read from the unit index
	eCount_DangerMarks,           // reaction shots at aliens and alien deaths recorded on the danger map
	eCount_DangerTiles,           // alien tile scores discounted by the danger map
	eCount_DangerBearings,        // holds at the edge turned off the straight bearing by the danger map
	eCount_PincerShifts,          // pincer points moved off the straight offset (seen by the squad, or dangerous)
	eCount_HeightSwaps            // alien tile searches run with vanilla's height-aware profile
};

// Times ChronoCOM's classes take, in milliseconds
enum EChronoTime
{
	eTime_TurnUpdate,             // ChronoCOM's own alien-turn update
	eTime_RunSetup,               // StartRunBehaviorTree: everything before the tree's first step
	eTime_LostDistribute,         // DistributeLostUnitsAmongTargets
	eTime_LostAssign,             // AssignLostUnitDestinations
	eTime_LostAttackInit          // InitLostAttackTargets
};

// The registered telemetry, or this null object
static function X2ChronoMetrics Get()
{
	local X2EventListenerTemplate_ChronoCOM Runtime;

	Runtime = class'X2EventListenerTemplate_ChronoCOM'.static.GetRuntime();
	return (Runtime != none) ? Runtime.GetMetrics() : new class'X2ChronoMetrics';
}

// Called once at startup by the registering mod; false when ChronoCOM's runtime
// template does not exist, and nothing would be reported
static function bool Register(X2ChronoMetrics Sink)
{
	local X2EventListenerTemplate_ChronoCOM Runtime;

	Runtime = class'X2EventListenerTemplate_ChronoCOM'.static.GetRuntime();
	if (Runtime == none)
	{
		return false;
	}

	Runtime.SetMetrics(Sink);
	return true;
}

// True when a telemetry is registered: the gate for building a log line
function bool IsOn()
{
	return false;
}

function Count(EChronoCount Counter, optional int Amount = 1);

function AddMs(EChronoTime Timer, float Ms);

// A timed region: StartTimer stamps ClockMs, StopTimer returns the elapsed ms
function StartTimer(out float ClockMs);

function float StopTimer(out float ClockMs)
{
	return 0;
}

// One vanilla tile score (XGAIBehavior.FillTileScoreData), timed, with the
// unit and tile so a tile scored twice in one frame can be told apart
function StartTileScore(out float ClockMs);

function StopTileScore(out float ClockMs, int UnitID, TTile Tile);

// One AI decision: wall time from StartRunBehaviorTree to
// BTRunCompletePreExecute, the behavior-tree steps it took, and whether the
// tree succeeded
function NoteDecision(float WallSeconds, int Steps, bool bSucceeded);

// The kind of directed move a run selected (XGAIBehavior_ChronoCOM.SelectedMoveKind)
function NoteMove(int Kind);

// The directive a directed run was given (XGAIBehavior_ChronoCOM.DIRECTIVE_*)
function NoteDirective(int Directive);

// One pod's intent for the alien turn (EPodIntent)
function NotePodIntent(int Intent);

// One propagated sound: aliens examined, aliens that heard an enemy, aliens
// not yet in the fight that heard their own side
function NoteNoise(int Candidates, int Hearers, int AllyHearers);

// One alien behavior-tree run: how many enemies the unit knew of
function NoteKnownEnemies(int Known);

// One comparison of vanilla's known-enemy list with the one from the unit index
function NoteKnownCheck(bool bSameOrder, bool bSameSet);

// True for the known-enemy refreshes the telemetry wants checked against
// vanilla's pass; never without a telemetry
function bool TakesKnownVerification()
{
	return false;
}

// The cover a flush grenade's target had against the thrower before and after (0 none, 1 low, 2 high)
function NoteFlushCover(int CoverBefore, int CoverAfter);

// One FindGroupDestinationToward call (the Lost's per-unit pathing)
function NoteGroupPath(float Ms, bool bFound);

// One XGAIPlayer_TheLost.InitLostGroupMove call
function NoteLostGroupMove(float Ms, int GroupUnits, int Assignments, bool bMoved);

// One XGAIBehavior_ChronoCOM created
function NoteBehaviorSpawned();

defaultproperties
{
}
