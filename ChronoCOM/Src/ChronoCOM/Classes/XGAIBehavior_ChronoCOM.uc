/**
 * XGAIBehavior_ChronoCOM
 *
 * WASP Role: T(q) — query translator between the alien side's shared state
 * (pod intent, the turn's fire plan) and each unit's behavior tree
 *
 * Replaces XGAIBehavior through ModClassOverride: every unit whose character
 * template uses the base XGAIBehavior class (XGAIBehavior_Civilian and other
 * subclasses are untouched).
 *
 * Every alien decision passes through a few vanilla functions this class
 * overrides; each override is a field read, a map probe, or a loop over at
 * most a pod or a squad:
 *
 *  StartRunBehaviorTree: an alien-team unit on the default tree runs
 *  ChronoRoot instead (XComAI.ini), which is vanilla's root with one branch
 *  added in front of the character's own tree. The branch reads the unit's
 *  directive from behavior-tree variables set here: fall back, flush cover
 *  with a grenade, move to flank, hold the line, or, when the pod assaults,
 *  go in first as its bait or flank and charge. With no directive the branch
 *  fails and the tree is vanilla's, node for node. An alerted unit whose pod
 *  sees nobody closes to the edge of the squad's reach and holds there
 *  (SetUpKind) until the pod goes in. A unit whose job outranks its character
 *  tree (terrorist, rendezvous, evacuation) gets none (JobOutranksTree).
 *
 *  BT_FindDestination: every destination search of every tree. While the
 *  unit's pod holds, a search with an advancing tile profile fails before it
 *  starts, so the unit's own tree moves on to what it can do from where it
 *  stands (its abilities, a shot, overwatch). Retreating profiles and melee
 *  profiles are not refused.
 *
 *  BT_UpdateBestTarget: where every target-scoring sequence ends. A standard
 *  shot's score gains a term linear in hit chance, a bonus per earlier attack
 *  on the target this turn, and a bonus for a target whose cover was just
 *  grenaded: focus fire.
 *
 *  GetAllKnownEnemyStates, GetNearestKnownEnemy: with
 *  X2ChronoConfig.bHonestKnowledge an alien's known enemies are the XCOM units
 *  any alien sees now (a hivemind); whoever the hive lost sight of is hunted
 *  through vanilla's alert data, which holds the tile where the unit was last
 *  seen or heard.
 *
 *  Habit counters (BT_FindDestination, FillTileScoreData): the squad's
 *  campaign habit picks among vanilla's tile profiles and strengthens
 *  vanilla's spread rule.
 *
 * The three generic-ability overrides (BT_InitGenericAbilities,
 * BT_ChooseGenericAbilityOption, BT_MoveCloserForGenericAbility) only run for
 * behavior trees that include GenericAbilityRoot (the default CharacterRoot,
 * mind-controlled units, Shadowbind, autorun soldiers); ordinary alien roots
 * never call them.
 *
 * FindGroupDestinationToward is overridden for measurement only.
 *
 * With X2ChronoConfig.bBaselineMode every override defers to vanilla.
 */

class XGAIBehavior_ChronoCOM extends XGAIBehavior
	dependson(X2DownloadableContentInfo_ChronoCOM);

const ATTACK_SCORE_BOOST = 1.5;

// A unit's directive for one behavior-tree run; ChronoRoot's branches test
// these values through the ChronoDirective behavior-tree variable
const DIRECTIVE_NONE = 0;
const DIRECTIVE_FALLBACK = 1;
const DIRECTIVE_FLUSH = 2;
const DIRECTIVE_HOLD = 3;
const DIRECTIVE_FLANK = 4;
const DIRECTIVE_BAIT = 5;        // the pod assaults: this unit goes in first, into the open, to draw the overwatch
const DIRECTIVE_ASSAULT = 6;     // the pod assaults: flank if a flanking tile is in reach, else charge

const DIRECTED_ROOT = 'ChronoRoot';
const FLUSH_PROFILE = 'ChronoFlushProfile';

var bool bNoVisibleEnemies;          // Set during ability init if no enemies are visible
var bool bInOptimalCover;            // Set during ability init, see IsInOptimalCover
var int CachedVisibleEnemyCount;     // Visible enemy count from ability init

var array<name> FilteredAttackAbilities;  // dropped from the options when nothing is in sight
var array<name> BoostedAttackAbilities;   // direct-fire abilities preferred when in cover with a target
var array<name> HoldMoveProfiles;         // tile profiles a holding unit may still move with (retreats)

// Decision timing, see X2ChronoMetrics.NoteDecision
var float DecisionStartRealTime;
var int DecisionSteps;
var bool bDecisionOpen;

// This run's directive
var bool bChronoDirected;        // the run uses ChronoRoot
var int ChronoDirective;
var int ChronoPodIdx;
var EPodIntent ChronoPodIntent;
var bool bChronoHolds;           // the pod holds and this unit fights from cover at range
var bool bChronoExempt;          // vanilla's fallback or an overriding job decides for this unit
var int ChronoRushKind;          // RUSH_*: why this run may dash toward its alert
var X2DownloadableContentInfo_ChronoCOM.PodData ChronoPod;   // the unit's pod record, fetched once per run (IDs and values only)
var bool bChronoHasPod;

const RUSH_NONE = 0;
const RUSH_TOLD = 1;             // yellow alert: told about a fight, not in it
const RUSH_APPROACH = 2;         // alerted, nobody in sight, still far from where the squad was: close to the edge
const RUSH_GUARD = 3;            // alerted, nobody in sight, the pod guards an objective and the unit is away from it: pull back to it
const MOVE_KIND_GUARD = 7;       // SelectedMoveKind: a pull back to the guarded objective

// The hold at the edge: what this run asks of a red unit whose pod sees nobody
var int ChronoSetUp;             // SETUP_*
var vector ChronoCoverDest;      // SETUP_COVER: the cover tile the unit moves to

const SETUP_NONE = 0;
const SETUP_HOLD = 1;            // stay: reload, overwatch under the pod's cap, else wait
const SETUP_COVER = 2;           // first move to cover against the believed position, no nearer to it
const MOVE_KIND_COVER = 6;       // SelectedMoveKind: a holding unit's move into cover
var name ChronoHabit;            // the squad's habit this unit counters during the run ('' = none)
var float ChronoSpreadScale;     // this run's multiplier on vanilla's spread penalty (1 = no counter): ApplyHabitSpread
var int ChronoLastSwapAsked;     // profile index of the last counted habit swap this run
var bool bChronoAvoidsDanger;    // this run's tile scores are discounted by the hive's danger map (X2ChronoDanger)
var bool bChronoSeeksHeight;     // this run's tile searches use vanilla's height-aware profiles (HeightProfile)
var int ChronoLastHeightAsked;   // profile index of the last counted height swap this run
var array<int> ChronoHeightTwin; // profile index -> its height-aware twin's index (itself without one), built once per behavior
var int ChronoFlushTargetID;     // the XCOM unit a flush grenade is meant for
var float ChronoFlushReach;      // how far the flush grenade reaches this run (throw range plus blast radius, units); 0 = unlimited

// Honest knowledge: this unit's known enemies (vanilla's list filtered by
// what the hive sees), per history frame
var array<int> ChronoKnown;
var int ChronoKnownFrame;

// Counted in telemetry so the first-AI-turn census can report how many
// behaviors this class actually spawned (proof the override is live)
function Init(XGUnit kUnit)
{
	super.Init(kUnit);

	class'X2ChronoMetrics'.static.Get().NoteBehaviorSpawned();
	`log("ChronoCOM AI: behavior spawned for unit" @ kUnit.ObjectID, `CHRONO_VERBOSE);
}

//=============================================================================
// A behavior-tree run starts here, steps once per engine frame while the tree
// reports RUNNING, and ends in BTRunCompletePreExecute on both SUCCESS and
// FAILURE, before any ability executes.
//=============================================================================

function bool StartRunBehaviorTree(Name OverrideNode='', bool bSkipTurnOnFailure=false, bool bInitFromPlayerEachRun=false)
{
	local X2ChronoMetrics Metrics;
	local float ClockMs;
	local bool bStarted;

	DecisionStartRealTime = WorldInfo.RealTimeSeconds;
	DecisionSteps = 0;
	bDecisionOpen = true;

	ChronoDirective = DIRECTIVE_NONE;
	ChronoRushKind = RUSH_NONE;
	ChronoSetUp = SETUP_NONE;
	ChronoPodIdx = INDEX_NONE;
	bChronoHasPod = false;
	ChronoFlushTargetID = 0;
	bChronoHolds = false;
	ChronoHabit = HabitToCounter();
	ChronoSpreadScale = SpreadScaleFor(ChronoHabit);
	ChronoLastSwapAsked = INDEX_NONE;
	ChronoLastHeightAsked = INDEX_NONE;
	bChronoAvoidsDanger = AvoidsDanger();
	bChronoSeeksHeight = SeeksHeight();
	bChronoDirected = IsDirected(OverrideNode);

	// Timed: everything a run does before the tree's first step (vanilla's
	// unit, ally and known-enemy caches, then the directive)
	Metrics = class'X2ChronoMetrics'.static.Get();
	Metrics.StartTimer(ClockMs);
	bStarted = super.StartRunBehaviorTree(RootFor(OverrideNode), bSkipTurnOnFailure, bInitFromPlayerEachRun);
	if (bStarted)
	{
		OnRunStarted();
	}
	Metrics.AddMs(eTime_RunSetup, Metrics.StopTimer(ClockMs));

	return bStarted;
}

function StepProcessBehaviorTree()
{
	DecisionSteps++;
	super.StepProcessBehaviorTree();
}

function BTRunCompletePreExecute()
{
	if (bDecisionOpen)
	{
		bDecisionOpen = false;
		class'X2ChronoMetrics'.static.Get().NoteDecision(
			WorldInfo.RealTimeSeconds - DecisionStartRealTime, DecisionSteps, m_eBTStatus == BTS_SUCCESS);
	}

	NoteSelection();
	SteerMove();
	AnnounceFocus();
	super.BTRunCompletePreExecute();
}

// The hive's new focus target gets its flyover before this unit's ability runs;
// not during a scamper, where vanilla pushes its own reveal state at this point
function AnnounceFocus()
{
	if (m_kPlayer == none || !m_kPlayer.IsScampering(UnitState.ObjectID))
	{
		class'X2ChronoFirePlan'.static.GetPlan().AnnounceHunted();
	}
}

// What the run selected, for the fire plan and the telemetry
function NoteSelection()
{
	if (ThrewFlushGrenade())
	{
		class'X2ChronoFirePlan'.static.GetPlan().NoteFlush(UnitState, ChronoFlushTargetID);
	}
	if (MovesToFlank())
	{
		class'X2ChronoFirePlan'.static.GetPlan().NoteFlank(ChronoPodIdx);
	}
	class'X2ChronoMetrics'.static.Get().NoteMove(SelectedMoveKind());
}

//=============================================================================
// Directive: the unit's part in its pod's intent
//=============================================================================

// A regular run (no override node, so not a scamper or an effect-driven run)
// of an alien-team unit on the default tree, with the directed tree loaded
function bool IsDirected(Name OverrideNode)
{
	return OverrideNode == '' && class'X2ChronoConfig'.static.PodIntentOn() && IsDirectableUnit()
		&& `BEHAVIORTREEMGR.IsValidBehavior(DIRECTED_ROOT);
}

function bool IsDirectableUnit()
{
	return UnitState != none && IsDirectableKind(UnitState);
}

// The hive directs a unit of a directable kind that is not exempt. The pod
// survey asks it of every member, so a pod whose members are all exempt (the
// ADVENT general on its escape, a terrorist) takes no part in the hive's plans.
static function bool IsHiveDirected(XComGameState_Unit Unit)
{
	return IsDirectableKind(Unit) && !IsExempt(Unit);
}

// An alien on the default tree. A Chosen runs its own tree: its fight is
// scripted around its own abilities and its own activation, and it is
// nobody's pod member.
static function bool IsDirectableKind(XComGameState_Unit Unit)
{
	return Unit.GetTeam() == eTeam_Alien && Unit.GetMyTemplate().strBehaviorTree == "GenericAIRoot" && !Unit.GetMyTemplate().bIsChosen;
}

// Vanilla decides for the unit: its group is in vanilla's fallback, or its job
// outranks the tree (HasJobOutranking)
static function bool IsExempt(XComGameState_Unit Unit)
{
	return IsGroupFallingBack(Unit) || HasJobOutranking(Unit);
}

static function bool IsGroupFallingBack(XComGameState_Unit Unit)
{
	local XComGameState_AIGroup Group;

	Group = Unit.GetGroupMembership();
	return Group != none && Group.IsFallingBack();
}

function Name RootFor(Name OverrideNode)
{
	return bChronoDirected ? DIRECTED_ROOT : OverrideNode;
}

// The unit and ability caches are fresh here, and the tree's first step runs
// on a later tick, so the variables set here are what the tree reads
function OnRunStarted()
{
	if (IsAlienPlayerUnit())
	{
		class'X2ChronoMetrics'.static.Get().NoteKnownEnemies(CachedKnownUnitRefs.Length);
	}

	if (bChronoDirected)
	{
		class'X2ChronoFirePlan'.static.GetPlan().ResolvePending();
		ApplyDirective();
	}
}

function bool IsAlienPlayerUnit()
{
	return m_kPlayer != none && m_kPlayer.m_eTeam == eTeam_Alien;
}

// ChronoHold is its own variable so a unit whose grenade turns out not to
// reach still holds with its pod
function ApplyDirective()
{
	bChronoExempt = IsExempt(UnitState);
	ChronoPodIntent = PodIntent();
	bChronoHolds = ChronoPodIntent == ePodIntent_Hold && FightsFromCover();
	ChronoDirective = ChooseDirective();
	BT_SetBTVar("ChronoDirective", ChronoDirective);
	BT_SetBTVar("ChronoHold", int(HoldsTheLine()));
	BT_SetBTVar("ChronoOverwatch", int(bChronoHasPod && class'X2PodCoordinator_Optimized'.static.IsUnderOverwatchCap(ChronoPod)));
	ChronoRushKind = RushKind();
	BT_SetBTVar("ChronoRush", int(ChronoRushKind != RUSH_NONE));
	ChronoSetUp = SetUpKind();
	BT_SetBTVar("ChronoSetUp", ChronoSetUp);
	class'X2ChronoMetrics'.static.Get().NoteDirective(ChronoDirective);
	class'X2ChronoMetrics'.static.Get().Count(eCount_SetUpRuns, int(ChronoSetUp != SETUP_NONE));
	`log("ChronoCOM AI: unit" @ UnitState.ObjectID @ "pod" @ ChronoPodIdx @ "intent" @ ChronoPodIntent @ "directive" @ ChronoDirective @ "flush_target" @ ChronoFlushTargetID, `CHRONO_VERBOSE);
}

// Ranged units that use cover are the ones that fall back and hold; melee
// units and units that cannot take cover keep their own trees
function bool FightsFromCover()
{
	return UnitState.CanTakeCover() && !UnitState.IsMeleeOnly();
}

// The hold branch of the directed tree (shoot or overwatch from where it
// stands) replaces the character's own first choices, so it is given only to
// the character groups listed as line infantry; every other holding unit keeps
// its own tree and only loses its advancing moves
function bool HoldsTheLine()
{
	return bChronoHolds && class'X2PodCoordinator_Optimized'.default.HOLD_LINE_GROUPS.Find(UnitState.GetMyTemplate().CharacterGroupName) != INDEX_NONE;
}

// Falling back outranks everything; the rest is how the unit attacks
function int ChooseDirective()
{
	if (bChronoExempt)
	{
		return DIRECTIVE_NONE;
	}
	if (FallsBack())
	{
		return DIRECTIVE_FALLBACK;
	}
	if (ChronoPodIntent == ePodIntent_Assault)
	{
		return AssaultDirective();
	}

	return AttackDirective();
}

// The pod assaults: its bait goes in first; a grenadier flushes; the rest
// flank or charge
function int AssaultDirective()
{
	if (ChronoPod.BaitUnitID == UnitState.ObjectID)
	{
		return DIRECTIVE_BAIT;
	}

	return PicksFlushTarget() ? DIRECTIVE_FLUSH : DIRECTIVE_ASSAULT;
}

// A unit that already flanks an enemy keeps that shot: no grenade, no new
// move. Otherwise a grenade at a covered target it cannot hit comes first (it
// needs no pod: the unit's own shot targets decide), then the pod's one flank
// of the turn, then holding. With none of these the unit's own tree decides.
function int AttackDirective()
{
	if (FlanksAnEnemy())
	{
		return HoldDirective();
	}
	if (PicksFlushTarget())
	{
		return DIRECTIVE_FLUSH;
	}
	if (GoesToFlank())
	{
		return DIRECTIVE_FLANK;
	}

	return HoldDirective();
}

// The engine's own flank count: visible enemies that use cover and have none
// against this unit
function bool FlanksAnEnemy()
{
	return class'X2TacticalVisibilityHelpers'.static.GetNumEnemiesFlankedBySource(UnitState.ObjectID) > 0;
}

function int HoldDirective()
{
	return bChronoHolds ? DIRECTIVE_HOLD : DIRECTIVE_NONE;
}

// The pod's intent. An exempt unit has none: vanilla's own fallback (the last
// survivor running to another group) or a job that outranks the character
// tree already decides for it.
function EPodIntent PodIntent()
{
	bChronoHasPod = class'X2PodCoordinator_Optimized'.static.GetPodOfUnit(UnitState.ObjectID, ChronoPod, ChronoPodIdx);
	return (bChronoHasPod && !bChronoExempt) ? ChronoPod.Intent : ePodIntent_None;
}

// Vanilla's character roots try the unit's job before anything else
// (TryJob). The jobs that carry out the mission's own script are left alone:
// the terrorist (killing civilians on a retaliation) and the ADVENT general's
// escape (Rendezvous: run to the escape point; EvacAtRendezvous: leave there).
// Every other job yields to the hive's direction. Until 2026-10-05 the
// general's escape yielded too, and in a Neutralize Field Commander mission
// the general approached the squad, set up on overwatch at the edge and was
// going in when the squad revealed it, instead of running for the exit. Until
// 2026-10-02 every job that needs no engagement (scout, defender, hunter,
// charger, executioner) and the observer job exempted the unit, and vanilla
// hands those jobs to pods that have not been revealed, so a told pod whose
// leader held one never came (test mission launch 6: the Muton pod).
static function bool HasJobOutranking(XComGameState_Unit Unit)
{
	local XComGameState_AIUnitData UnitData;

	UnitData = XComGameState_AIUnitData(`XCOMHISTORY.GetGameStateForObjectID(Unit.GetAIUnitDataID()));
	return UnitData != none && UnitData.JobIndex != INDEX_NONE && JobOutranksTree(UnitData.JobIndex);
}

function XComGameState_AIUnitData OwnAIUnitData()
{
	local int DataID;

	DataID = GetAIUnitDataID(UnitState.ObjectID);
	if (DataID <= 0)
	{
		return none;
	}

	return XComGameState_AIUnitData(`XCOMHISTORY.GetGameStateForObjectID(DataID));
}

static function bool JobOutranksTree(int JobIndex)
{
	local name Job;

	Job = `AIJOBMGR.GetJobName(JobIndex);
	return Job == 'Terrorist' || Job == 'Rendezvous' || Job == 'EvacAtRendezvous';
}

function bool FallsBack()
{
	return ChronoPodIntent == ePodIntent_FallBack && FightsFromCover();
}

//=============================================================================
// Flank: one unit of a pressing pod moves to a tile that flanks an enemy
//=============================================================================

// The directed tree's flank branch does the rest with vanilla's own nodes: a
// move only with both actions left and only when vanilla judges moving safe
// (its overwatch and suppression checks), to a tile that flanks a known enemy
// and is itself not flanked, scored with vanilla's flanking profile. No such
// tile in reach: the branch fails and the unit's own tree decides.
function bool GoesToFlank()
{
	return PodWantsFlank() && FightsFromCover() && UnitState.NumActionPoints() > 1;
}

// A pod that presses sends as many flankers per turn as its temperament
// allows (TEMPER_FLANKERS: none, one or two); the rest keep shooting
function bool PodWantsFlank()
{
	return class'X2ChronoConfig'.static.FlankManeuverOn() && ChronoPodIntent == ePodIntent_Press
		&& class'X2ChronoFirePlan'.static.GetPlan().FlanksThisTurn(ChronoPodIdx) < class'X2PodCoordinator_Optimized'.static.FlankersOf(ChronoPod.Temper);
}

// The tree succeeded with the flank branch's move as its selection
function bool MovesToFlank()
{
	return ChronoDirective == DIRECTIVE_FLANK && m_eBTStatus == BTS_SUCCESS && IsFlankMoveSelected();
}

//=============================================================================
// Rush and assault moves: the destination is where the hive believes the
// squad is, and the move is a dash
//=============================================================================

// An alerted unit whose pod sees nobody closes to the edge of the squad's
// reach (its temperament's edge, X2PodCoordinator_Optimized.EdgeTilesOf) and holds there (SetUpKind) until its pod goes in
// (X2PodCoordinator_Optimized.GoesIn). Going in, a yellow unit dashes at the
// believed position: the directed tree's assault branches need red alert, and
// a pod that has never been revealed moves as one group behind its leader. A
// red unit takes its assault directive (ChooseDirective). Units vanilla
// exempts from direction keep their trees; a unit whose pod knows no position
// has nowhere to go. Until 2026-10-04 a told unit dashed at the position
// every turn until it saw the squad.
function int RushKind()
{
	if (!RushAllowed())
	{
		return RUSH_NONE;
	}
	if (ChronoPodIntent == ePodIntent_Assault)
	{
		return GoInKind();
	}

	return ChronoPod.bGuards ? GuardMoveKind() : ApproachKind();
}

// A guarding pod's unit that is away from the objective pulls back to it;
// within GUARD_RADIUS_TILES it holds (SetUpKind)
function int GuardMoveKind()
{
	return (IsAlertedAndBlind() && TilesToGuard() > class'X2PodCoordinator_Optimized'.default.GUARD_RADIUS_TILES) ? RUSH_GUARD : RUSH_NONE;
}

function int TilesToGuard()
{
	return class'X2PodCoordinator_Optimized'.static.TilesBetween(ChronoPod.GuardPosition, UnitState.TileLocation);
}

function int GoInKind()
{
	return (UnitState.GetCurrentStat(eStat_AlertLevel) == 1) ? RUSH_TOLD : RUSH_NONE;
}

// The switch is on, the unit is directed, and its pod knows where to go
function bool RushAllowed()
{
	return class'X2ChronoConfig'.static.RushToAlertsOn() && !bChronoExempt && KnowsSquadPosition();
}

// The unit's pod has, at some point, known where the squad is
function bool KnowsSquadPosition()
{
	return bChronoHasPod && ChronoPod.LastKnownTurn > 0;
}

// No member of the unit's pod saw a soldier at this alien turn's update
function bool IsPodBlind()
{
	return bChronoHasPod && !ChronoPod.bHasVisualContact;
}

// Alerted, the pod blind, and still outside the edge
function int ApproachKind()
{
	return (IsAlertedAndBlind() && TilesToKnown() > class'X2PodCoordinator_Optimized'.static.EdgeTilesOf(ChronoPod.Temper)) ? RUSH_APPROACH : RUSH_NONE;
}

// Tiles from the unit to where its pod believes the squad is, or -1
function int TilesToKnown()
{
	if (!KnowsSquadPosition())
	{
		return -1;
	}

	return class'X2PodCoordinator_Optimized'.static.TilesFromKnown(ChronoPod, UnitState.TileLocation);
}

//=============================================================================
// Hold at the edge: an alerted pod that cannot see the squad sets up and waits
//=============================================================================

// An alerted unit (yellow or red) whose pod sees nobody, knows where the squad
// is and is not yet assaulting does not advance once it is inside the edge (outside it the unit
// is still approaching: RushKind). The pod's intent is decided once, at the
// alien turn's update: if some alien has a soldier in sight then, the pod
// assaults instead (X2PodCoordinator_Optimized.BlindIntent), so the hold is
// for a squad nobody can see. If the unit stands without cover against the
// believed position it first moves to cover no nearer to it; then the directed
// tree's set-up branch has it reload, go on overwatch under the pod's cap, or
// wait. The pod's patience ends the hold with an assault
// (X2PodCoordinator_Optimized.CountHoldTurn). Until 2026-10-03 the unit's own
// tree ran here, and vanilla's red-alert hunting walked the pod's members
// toward the squad one at a time (test mission launch 9: a stun lancer into
// three overwatch shots, its pod-mate away from it).
function int SetUpKind()
{
	if (!HoldsAtEdge())
	{
		return SETUP_NONE;
	}

	return FindsHoldCover() ? SETUP_COVER : SETUP_HOLD;
}

// Directed, with no approach left to make
function bool HoldsAtEdge()
{
	return RushAllowed() && ChronoRushKind == RUSH_NONE && WaitsUnseen();
}

// Alerted, the pod blind and not going in
function bool WaitsUnseen()
{
	return IsAlertedAndBlind() && ChronoPodIntent != ePodIntent_Assault;
}

// True when the unit stands without cover against the believed position and
// a cover tile within one move has it and is no nearer to that position; the
// tile is left in ChronoCoverDest. The search is vanilla's: of the cover tiles
// the unit can reach in one move, the nearest that the believed position does
// not flank and no known enemy sees uncovered. It runs only for a unit that
// stands exposed with both actions left.
function bool FindsHoldCover()
{
	local array<vector> Threats;

	if (!NeedsHoldCover())
	{
		return false;
	}

	m_bBTCanDash = false;
	Threats.AddItem(ChronoPod.LastKnownEnemyPosition);
	return GetClosestCoverLocation(GetGameStateLocation(), ChronoCoverDest, false, false, Threats) && IsHoldTile(ChronoCoverDest);
}

// A revealed cover user with both actions left that has no cover against the
// believed position. A pod that has not been revealed stays where it stopped:
// its leader's move would take the whole group with it.
function bool NeedsHoldCover()
{
	return !UnitState.IsUnrevealedAI() && UnitState.CanTakeCover() && UnitState.NumActionPoints() > 1 && !HasCoverFromKnown();
}

function bool HasCoverFromKnown()
{
	local vector Shooter, Target;
	local float Angle;

	Shooter = ChronoPod.LastKnownEnemyPosition;
	Target = GetGameStateLocation();
	Angle = 0;
	return `XWORLD.GetCoverTypeForTarget(Shooter, Target, Angle) != CT_None;
}

// Another tile, and no nearer to the believed position than the unit stands:
// the hold never brings a unit closer to the squad
function bool IsHoldTile(vector Dest)
{
	return `XWORLD.GetTileCoordinatesFromPosition(Dest) != UnitState.TileLocation
		&& VSizeSq(Dest - ChronoPod.LastKnownEnemyPosition) >= VSizeSq(GetGameStateLocation() - ChronoPod.LastKnownEnemyPosition);
}

// The set-up branch selected the move into cover
function bool TakesHoldCover()
{
	return ChronoSetUp == SETUP_COVER && m_strBTAbilitySelection == 'StandardMove' && !m_bBTDestinationSet;
}

// What kind of move the run selected, for the telemetry (X2ChronoMetrics.NoteMove):
// 0 none, 1 told rush, 2 approach, 3 bait, 4 assault flank, 5 charge, 6 a
// holding unit's move into cover, 7 a pull back to a guarded objective
function int SelectedMoveKind()
{
	if (m_strBTAbilitySelection != 'StandardMove')
	{
		return 0;
	}

	return DirectedMoveKind();
}

function int DirectedMoveKind()
{
	if (ChronoDirective == DIRECTIVE_BAIT)
	{
		return 3;
	}

	return (ChronoDirective == DIRECTIVE_ASSAULT) ? AssaultMoveKind() : RushOrCoverKind();
}

function int RushOrCoverKind()
{
	if (ChronoSetUp == SETUP_COVER)
	{
		return MOVE_KIND_COVER;
	}

	return (ChronoRushKind == RUSH_GUARD) ? MOVE_KIND_GUARD : ChronoRushKind;
}

function int AssaultMoveKind()
{
	return IsFlankMoveSelected() ? 4 : 5;
}

// The rush, the approach, the bait, the charge and a holding unit's move into
// cover select a standard move without a destination; the destination is set
// here, where vanilla's move states read it. A flanking tile found by the tree
// keeps its own destination.
function SteerMove()
{
	if (TakesHoldCover())
	{
		SetMoveDestination(ChronoCoverDest);
	}
	else
	{
		SteerDash();
	}
	LogMove();
}

// The farthest reachable tile toward the target, dashing
function SteerDash()
{
	local vector Dest;

	if (NeedsSteering() && KnowsSquadPosition() && HasValidDestinationToward(SteerTarget(), Dest, true))
	{
		SetMoveDestination(Dest);
		m_bCanDash = true;
	}
}

// An approach stops at the edge (EdgePoint); a pull back goes to the guarded
// objective; everything else goes in: at the believed position, or at the
// pincer point beside it when the pod goes in with others
// (X2PodCoordinator_Optimized.AssignPincers). Until 2026-10-03 an approach
// went for the position itself, and a dash from 21 tiles ended deep inside
// the edge.
function vector SteerTarget()
{
	if (ChronoRushKind == RUSH_APPROACH)
	{
		return EdgePoint();
	}

	return (ChronoRushKind == RUSH_GUARD) ? ChronoPod.GuardPosition : GoInPoint();
}

// The point the pod's own edge (its temperament's) from the believed position,
// on the line to the unit; where that point lies in a cell the squad has hurt
// the hive in, the bearing turns to the safest of up to four others
// (X2ChronoDanger.SafestBearing: one probe each)
function vector EdgePoint()
{
	local vector Away;
	local float Reach;

	Away = GetGameStateLocation() - ChronoPod.LastKnownEnemyPosition;
	Away.Z = 0;
	Reach = class'X2PodCoordinator_Optimized'.static.EdgeTilesOf(ChronoPod.Temper) * class'XComWorldData'.const.WORLD_StepSize;
	return ChronoPod.LastKnownEnemyPosition + EdgeBearing(Normal(Away), Reach) * Reach;
}

function vector EdgeBearing(vector Away, float Reach)
{
	return bChronoAvoidsDanger ? class'X2ChronoDanger'.static.GetDanger().SafestBearing(ChronoPod.LastKnownEnemyPosition, Away, Reach) : Away;
}

function vector GoInPoint()
{
	return (ChronoPodIntent == ePodIntent_Assault && ChronoPod.PincerSide != 0) ? ChronoPod.GoInTarget : ChronoPod.LastKnownEnemyPosition;
}

// m_vBTDestination is honored by vanilla's patrol, red and alert-data move states
function SetMoveDestination(vector Dest)
{
	m_vBTDestination = Dest;
	m_bBTDestinationSet = true;
	m_bAlertDataMovementDestinationSet = false;
}

// A rush, a bait move or a charge: a standard move the tree did not give a destination
function bool NeedsSteering()
{
	return IsSteeredKind(SelectedMoveKind()) && !m_bBTDestinationSet;
}

// Every move kind but none, an assault flank (the tree found the tile) and a
// move into cover (SteerMove sets it)
function bool IsSteeredKind(int Kind)
{
	return Kind > 0 && Kind != 4 && Kind != MOVE_KIND_COVER;
}

// One line per run of a unit that was told, is red and blind, or whose pod
// assaults: what it decided and where it goes
function LogMove()
{
	local TTile Dest;

	if (!LogsMove())
	{
		return;
	}

	Dest = `XWORLD.GetTileCoordinatesFromPosition(m_vBTDestination);
	`log("ChronoCOM Rush: turn=" $ class'X2ChronoIndex'.static.GetIndex().GetAlienTurn() @ "unit=" $ UnitState.ObjectID @ "pod=" $ ChronoPodIdx
		@ "intent=" $ ChronoPodIntent @ "directive=" $ ChronoDirective @ "rush=" $ ChronoRushKind @ "setup=" $ ChronoSetUp @ "move_kind=" $ SelectedMoveKind()
		@ "exempt=" $ bChronoExempt @ "job=" $ JobName() @ "root=" $ ((m_kBehaviorTree != none) ? string(m_kBehaviorTree.m_strName) : "none")
		@ "alert=" $ UnitState.GetCurrentStat(eStat_AlertLevel) @ "stalk=" $ ChronoPod.StalkTurns @ "tiles_to_known=" $ TilesToKnown()
		@ "guards=" $ ChronoPod.bGuards @ "pincer=" $ ChronoPod.PincerSide
		@ "unrevealed=" $ UnitState.IsUnrevealedAI() @ "selected=" $ m_strBTAbilitySelection @ "dash=" $ m_bCanDash @ "dest_set=" $ m_bBTDestinationSet
		@ "dest=" $ Dest.X $ "," $ Dest.Y @ "tile=" $ UnitState.TileLocation.X $ "," $ UnitState.TileLocation.Y);
}

// A run worth a line, with telemetry on: it rushes or assaults, or the unit is
// alerted and its pod sees nobody (the case in which it should be coming and
// may not be). Read from the pod record: no query is made for a log line.
function bool LogsMove()
{
	return class'X2ChronoMetrics'.static.Get().IsOn() && (ChronoRushKind != RUSH_NONE || ChronoPodIntent == ePodIntent_Assault || IsAlertedAndBlind());
}

function bool IsAlertedAndBlind()
{
	return UnitState.GetCurrentStat(eStat_AlertLevel) >= 1 && IsPodBlind();
}

// The unit's vanilla AI job, or '' (for the Rush log line; JobOutranksTree decides which jobs exempt a unit)
function name JobName()
{
	local XComGameState_AIUnitData UnitData;

	UnitData = OwnAIUnitData();
	return (UnitData != none && UnitData.JobIndex != INDEX_NONE) ? `AIJOBMGR.GetJobName(UnitData.JobIndex) : '';
}

// Every other move of the unit's trees resets the search first, which clears
// the flanking restriction
function bool IsFlankMoveSelected()
{
	return m_strBTAbilitySelection == 'StandardMove' && m_bUseMoveRestriction && m_kCurrMoveRestriction.bFlanking;
}

//=============================================================================
// Hold: no advance while the pod holds
//=============================================================================

/**
 * Every destination search of every tree comes through here (the line-of-
 * sight and restricted variants call it). A holding unit's search with an
 * advancing profile fails as vanilla's own failed search does, so the tree's
 * selector moves on to its next option.
 */
function bt_status BT_FindDestination(int MoveTypeIndex, bool bRestricted=false)
{
	MoveTypeIndex = HabitProfile(MoveTypeIndex);
	if (RefusesAdvance(MoveTypeIndex))
	{
		class'X2ChronoMetrics'.static.Get().Count(eCount_HoldRefusals);
		BT_ResetDestinationSearch();
		return BTS_FAILURE;
	}

	// After the hold's check, which knows the vanilla profiles by name
	return super.BT_FindDestination(HeightProfile(MoveTypeIndex), bRestricted);
}

function bool RefusesAdvance(int MoveTypeIndex)
{
	return bChronoHolds && MoveTypeIndex >= 0 && MoveTypeIndex < m_arrMoveWeightProfile.Length && IsAdvanceProfile(MoveTypeIndex);
}

// Any profile that is neither a melee profile nor one of the retreats
function bool IsAdvanceProfile(int MoveTypeIndex)
{
	return !m_arrMoveWeightProfile[MoveTypeIndex].bIsMelee && HoldMoveProfiles.Find(m_arrMoveWeightProfile[MoveTypeIndex].Profile) == INDEX_NONE;
}

//=============================================================================
// Cover flush: a grenade at the covered target this unit cannot hit
//=============================================================================

// Chooses the target and hands it to the tree as the AoE profile's required
// target ('Potential'); false when there is no grenade or no such target
function bool PicksFlushTarget()
{
	if (FlushGrenadeReady())
	{
		ChronoFlushReach = FlushReach();
		ChronoFlushTargetID = BestFlushTarget();
	}
	if (ChronoFlushTargetID <= 0)
	{
		return false;
	}

	SetBestTargetOption('Potential', ChronoFlushTargetID);
	return true;
}

// The flush profile is loaded and its grenade ability can be used right now
function bool FlushGrenadeReady()
{
	local Name Grenade;

	Grenade = GetAbilityFromTargetingProfile(FLUSH_PROFILE);
	return Grenade != '' && FindAbilityByName(Grenade).AvailableCode == 'AA_Success';
}

// How far the flush grenade can hurt someone, as vanilla measures it for an
// area ability (XGAIBehavior: the cursor range plus the blast radius). Until
// 2026-10-05 flush targets were not checked against it, and most flush
// directives ended without a throw: the target was out of reach (ADVENT
// grenades reach 10 tiles; launch 13, turn 6: four directives, no throw, the
// squad 14 tiles away)
function float FlushReach()
{
	local XComGameState_Ability Grenade;
	local float RangeMeters;

	Grenade = AbilityStateOf(FindAbilityByName(GetAbilityFromTargetingProfile(FLUSH_PROFILE)));
	RangeMeters = (Grenade != none) ? Grenade.GetAbilityCursorRangeMeters() : -1.0;
	if (RangeMeters < 0)
	{
		return 0;
	}

	return `METERSTOUNITS(RangeMeters) + Grenade.GetAbilityRadius();
}

// Among the targets of this unit's own standard shot (at most a squad): the
// one in the heaviest cover, then the one it is least likely to hit
function int BestFlushTarget()
{
	local AvailableAction Shot;
	local XComGameState_Ability ShotState;
	local int i, Score, BestScore, BestID;

	Shot = GetShotAbility(true);
	ShotState = AbilityStateOf(Shot);
	if (ShotState == none)
	{
		return 0;
	}

	for (i = 0; i < Shot.AvailableTargets.Length; ++i)
	{
		Score = FlushScore(ShotState, Shot.AvailableTargets[i]);
		if (Score > BestScore)
		{
			BestScore = Score;
			BestID = Shot.AvailableTargets[i].PrimaryTarget.ObjectID;
		}
	}

	return BestID;
}

// The ability's state, or none for the empty action a failed lookup returns
static function XComGameState_Ability AbilityStateOf(AvailableAction Action)
{
	if (Action.AbilityObjectRef.ObjectID <= 0)
	{
		return none;
	}

	return XComGameState_Ability(`XCOMHISTORY.GetGameStateForObjectID(Action.AbilityObjectRef.ObjectID));
}

// 0 when the target is not worth a grenade: no cover against this unit, or a
// shot at FLUSH_MAX_HIT_CHANCE or better
function int FlushScore(XComGameState_Ability ShotState, AvailableTarget Target)
{
	local XComGameState_Unit Enemy;
	local int Cover, HitChance;

	Enemy = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Target.PrimaryTarget.ObjectID));
	if (!IsFlushable(Enemy, Target))
	{
		return 0;
	}

	Cover = class'X2ChronoFirePlan'.static.CoverLevel(UnitState, Enemy);
	HitChance = ShotHitChance(ShotState, Target);
	if (Cover == 0 || HitChance >= class'X2AIBehaviorDirector_Optimized'.default.FLUSH_MAX_HIT_CHANCE)
	{
		return 0;
	}

	return Cover * 100 + (100 - HitChance);
}

// An XCOM unit that uses cover, that vanilla would let this unit target, that
// the grenade can reach, and that nobody has grenaded yet this turn
function bool IsFlushable(XComGameState_Unit Enemy, AvailableTarget Target)
{
	return IsCoverUser(Enemy) && IsValidTarget(Target) && InFlushReach(Enemy) && !class'X2ChronoFirePlan'.static.GetPlan().WasFlushedThisTurn(Enemy.ObjectID);
}

function bool InFlushReach(XComGameState_Unit Enemy)
{
	return ChronoFlushReach <= 0 || VSize(`XWORLD.GetPositionFromTileCoordinates(Enemy.TileLocation) - GetGameStateLocation()) <= ChronoFlushReach;
}

static function bool IsCoverUser(XComGameState_Unit Enemy)
{
	return Enemy != none && Enemy.GetTeam() == eTeam_XCom && Enemy.CanTakeCover();
}

// The displayed hit chance
static function int ShotHitChance(XComGameState_Ability ShotState, AvailableTarget Target)
{
	local ShotBreakdown Breakdown;

	ShotState.GetShotBreakdown(Target, Breakdown);
	return Breakdown.HideShotBreakdown ? 100 : Breakdown.FinalHitChance;
}

// The tree succeeded with the flush profile's grenade as its selection
function bool ThrewFlushGrenade()
{
	return ChronoDirective == DIRECTIVE_FLUSH && m_eBTStatus == BTS_SUCCESS && TopAoETarget.Profile == FLUSH_PROFILE
		&& m_strBTAbilitySelection == GetAbilityFromTargetingProfile(FLUSH_PROFILE);
}

//=============================================================================
// Habit counters: the squad's campaign habit picks among vanilla's own tile
// profiles and strengthens vanilla's own spread rule
//=============================================================================

// Only the alien player's units counter the squad's habits
function name HabitToCounter()
{
	if (!IsAlienPlayerUnit())
	{
		return '';
	}

	return class'X2ChronoFirePlan'.static.GetPlan().HabitThisTurn();
}

// The profile index this search runs with. The swap happens before vanilla
// starts the search, so vanilla scores the candidate tiles with the swapped
// profile and reads that profile's best tile.
function int HabitProfile(int MoveTypeIndex)
{
	local int Swapped;

	if (ChronoHabit == '' || MoveTypeIndex < 0 || MoveTypeIndex >= m_arrMoveWeightProfile.Length)
	{
		return MoveTypeIndex;
	}

	Swapped = m_arrMoveWeightProfile.Find('Profile',
		class'X2AIBehaviorDirector_Optimized'.static.CounterProfile(ChronoHabit, m_arrMoveWeightProfile[MoveTypeIndex].Profile));
	return NoteProfileSwap(MoveTypeIndex, Swapped);
}

// Counted once per swapped profile in a row (the tree calls again every tick
// while a search runs)
function int NoteProfileSwap(int Asked, int Swapped)
{
	if (Swapped == INDEX_NONE || Swapped == Asked)
	{
		return Asked;
	}

	class'X2ChronoMetrics'.static.Get().Count(eCount_HabitProfileSwaps, int(Asked != ChronoLastSwapAsked));
	ChronoLastSwapAsked = Asked;
	return Swapped;
}

//=============================================================================
// Height: vanilla's height-aware profiles for every alien search
//=============================================================================

function bool SeeksHeight()
{
	return IsAlienPlayerUnit() && class'X2ChronoConfig'.static.HeightAwareOn();
}

// Vanilla defines a height-aware twin of its main tile profiles (DefaultAI.ini:
// MWP_StandardHeight and the rest), which adds the tile's height to the score;
// an alien-player unit's search runs with the twin (HEIGHT_PROFILES). One
// read of the twin table per search.
function int HeightProfile(int MoveTypeIndex)
{
	if (!bChronoSeeksHeight || !IsProfileIndex(MoveTypeIndex))
	{
		return MoveTypeIndex;
	}

	EnsureHeightTwins();
	return NoteHeightSwap(MoveTypeIndex, ChronoHeightTwin[MoveTypeIndex]);
}

// Once per behavior: every profile is its own twin, then each HEIGHT_PROFILES
// pair found in vanilla's list (a handful of lookups in it) points its
// profile at its twin
function EnsureHeightTwins()
{
	local int i;

	if (ChronoHeightTwin.Length == m_arrMoveWeightProfile.Length)
	{
		return;
	}

	ChronoHeightTwin.Length = m_arrMoveWeightProfile.Length;
	for (i = 0; i < ChronoHeightTwin.Length; ++i)
	{
		ChronoHeightTwin[i] = i;
	}
	for (i = 0; i < class'X2AIBehaviorDirector_Optimized'.default.HEIGHT_PROFILES.Length; ++i)
	{
		PairTwin(class'X2AIBehaviorDirector_Optimized'.default.HEIGHT_PROFILES[i].FromProfile, class'X2AIBehaviorDirector_Optimized'.default.HEIGHT_PROFILES[i].ToProfile);
	}
}

function PairTwin(name FromProfile, name ToProfile)
{
	local int From, To;

	From = m_arrMoveWeightProfile.Find('Profile', FromProfile);
	To = m_arrMoveWeightProfile.Find('Profile', ToProfile);
	if (From != INDEX_NONE && To != INDEX_NONE)
	{
		ChronoHeightTwin[From] = To;
	}
}

function bool IsProfileIndex(int MoveTypeIndex)
{
	return MoveTypeIndex >= 0 && MoveTypeIndex < m_arrMoveWeightProfile.Length;
}

// Counted once per swapped profile in a row (the tree calls again every tick
// while a search runs)
function int NoteHeightSwap(int Asked, int Swapped)
{
	class'X2ChronoMetrics'.static.Get().Count(eCount_HeightSwaps, int(Swapped != Asked && Asked != ChronoLastHeightAsked));
	ChronoLastHeightAsked = Asked;
	return Swapped;
}

//=============================================================================
// Danger: tiles where the squad has hurt the hive score lower
//=============================================================================

// An alien-player unit reads the danger map during the run's tile searches;
// the map is brought up to the mission's marks first (one history lookup and
// the marks since the last run)
function bool AvoidsDanger()
{
	if (!IsAlienPlayerUnit() || !class'X2ChronoConfig'.static.DangerMapOn())
	{
		return false;
	}

	class'X2ChronoDanger'.static.GetDanger().Sync();
	return true;
}

/**
 * Vanilla's score for a candidate tile, discounted where the squad has hurt
 * the hive (X2ChronoDanger.TileScale: one probe). Only a positive score
 * changes, as with vanilla's own spread penalty, so a tile vanilla rejects (0)
 * or ranks below the unit's own (negative) keeps its place; vanilla keeps the
 * highest score.
 */
function float GetWeightedTileScore(ai_tile_score kTileDiffScore, ai_tile_score kRawTileData, int MoveProfileIndex, out DebugTileScore DebugScore)
{
	local float Score;

	Score = super.GetWeightedTileScore(kTileDiffScore, kRawTileData, MoveProfileIndex, DebugScore);
	return (bChronoAvoidsDanger && Score > 0) ? DangerScaled(Score, kRawTileData.kTile) : Score;
}

function float DangerScaled(float Score, TTile Tile)
{
	local float Scale;

	Scale = class'X2ChronoDanger'.static.GetDanger().TileScale(Tile);
	class'X2ChronoMetrics'.static.Get().Count(eCount_DangerTiles, int(Scale < 1.0));
	return Score * Scale;
}

// Against a grenade-heavy squad a tile within vanilla's spread distance of a
// teammate is penalized harder
function ApplyHabitSpread(out ai_tile_score Score)
{
	if (ChronoSpreadScale < 1.0 && Score.bWithinSpreadMin)
	{
		Score.SpreadMultiplier *= ChronoSpreadScale;
		class'X2ChronoMetrics'.static.Get().Count(eCount_HabitSpreadTiles);
	}
}

// HABIT_SPREAD_SCALE raised to the counter's strength this alien turn
// (XComGameState_AdaptiveMemory.CounterStrength): the penalty compounds as the
// campaign's tier and difficulty rise. 1 against any other habit.
static function float SpreadScaleFor(name Habit)
{
	return (Habit == 'PATTERN_EXPLOSIVE_HEAVY')
		? class'X2AIBehaviorDirector_Optimized'.default.HABIT_SPREAD_SCALE ** class'X2ChronoFirePlan'.static.GetPlan().HabitStrengthThisTurn()
		: 1.0;
}

//=============================================================================
// Focus fire
//=============================================================================

/**
 * Every target-scoring sequence ends here. For an alien's standard shot at a
 * target vanilla has not ruled out (score above 0), adds the focus terms
 * before vanilla compares the target with the best so far.
 */
function BT_UpdateBestTarget()
{
	if (ScoresFocus())
	{
		BT_AddToTargetScore(FocusBonus(), 'ChronoFocus');
		class'X2ChronoMetrics'.static.Get().Count(eCount_FocusScores);
	}

	super.BT_UpdateBestTarget();
}

function bool ScoresFocus()
{
	return FocusApplies() && m_kBTCurrTarget.iScore > 0 && m_kBTCurrTarget.TargetID > 0 && IsStandardShotStack();
}

function bool FocusApplies()
{
	return class'X2ChronoConfig'.static.FocusFireOn() && IsAlienPlayerUnit();
}

// The target stack being scored belongs to this unit's standard shot
function bool IsStandardShotStack()
{
	return m_kBTCurrAbility.AbilityObjectRef.ObjectID > 0 && string(m_strBTCurrAbility) == GetStandardShotName();
}

// Linear in hit chance (vanilla's tiers score 41% and 79% the same), plus the
// attacks already made on this target this turn (the AI player's own counter),
// plus a target whose cover was grenaded this turn, plus the hive's focus
// target: the one soldier every alien shoots until it is down
function int FocusBonus()
{
	local int Bonus;

	Bonus = (Clamp(BT_GetHitChanceOnTarget(), 0, 100) * class'X2AIBehaviorDirector_Optimized'.default.FOCUS_HIT_WEIGHT) / 100;
	Bonus += Min(BT_GetTargetSelectedThisTurnCount(), class'X2AIBehaviorDirector_Optimized'.default.FOCUS_PILE_ON_MAX)
		* class'X2AIBehaviorDirector_Optimized'.default.FOCUS_PILE_ON_BONUS;
	Bonus += int(class'X2ChronoFirePlan'.static.GetPlan().WasFlushedThisTurn(m_kBTCurrTarget.TargetID))
		* class'X2AIBehaviorDirector_Optimized'.default.FOCUS_FLUSHED_BONUS;
	Bonus += int(class'X2ChronoFirePlan'.static.GetPlan().FocusTarget() == m_kBTCurrTarget.TargetID)
		* class'X2AIBehaviorDirector_Optimized'.default.FOCUS_TARGET_BONUS;
	return Bonus;
}

//=============================================================================
// Honest knowledge
//=============================================================================

// Vanilla's alien player knows every unconcealed XCOM unit on the map, and
// its callers read each one's current tile. Here an alien's known enemies are
// the XCOM units that any alien can see right now: the aliens are a hivemind,
// so one pod's sighting lets every pod move to a firing position. Whoever no
// alien sees is no longer known, so the unit's own tree falls through to
// vanilla's hunt, which walks to alert data, and alert data stores the tile
// where the unit was last seen (XComGameState_AIUnitData.GetAlertLocation):
// the pod goes where you were, not where you are.
//
// The vanilla flag (XGAIPlayer.bAIHasKnowledgeOfAllUnconcealedXCom) is left
// on. With it off, target validity depends on a native "spotted" test whose
// script-side flag nothing sets.

function bool UsesHonestKnowledge()
{
	return class'X2ChronoConfig'.static.HonestKnowledgeOn() && IsAlienPlayerUnit();
}

/**
 * The list behind the tree's cached known enemies (tile scoring, enemy cover,
 * overwatch counts, grenade targets). Vanilla's list, minus the XCOM units no
 * alien can see.
 *
 * Vanilla builds its list with a pass over every unit in the history, on
 * every call, and it is asked per run and, through the nearest-enemy lookup,
 * per scored tile while nobody is in sight. Without excluded effects the
 * answer changes only with the history frame, so it is kept per frame as IDs
 * in vanilla's own order: one pass per frame, then a loop over the answer.
 * The civilians a terror mission adds are this unit's own sightings, one
 * engine query, added per call as vanilla adds them.
 */
function GetAllKnownEnemyStates(optional out array<XComGameState_Unit> UnitList, optional out array<StateObjectReference> RefList, bool IncludeCiviliansOnTerrorMaps=false, optional array<Name> ExcludedEffects)
{
	if (KeepsKnownPerFrame(ExcludedEffects.Length))
	{
		RefreshKnown();
		KnownFromFrame(UnitList, RefList);
		AddTerrorCivilians(IncludeCiviliansOnTerrorMaps, RefList);
		return;
	}

	class'X2ChronoMetrics'.static.Get().Count(eCount_KnownPasses);
	super.GetAllKnownEnemyStates(UnitList, RefList, IncludeCiviliansOnTerrorMaps, ExcludedEffects);

	if (UsesHonestKnowledge())
	{
		DropUnseenUnits(UnitList);
		DropUnseenRefs(RefList);
	}
}

function bool KeepsKnownPerFrame(int ExcludedCount)
{
	return ExcludedCount == 0 && class'X2ChronoConfig'.default.bUseTurnIndex && UsesHonestKnowledge();
}

// Vanilla's rule (XComGameState_AIUnitData.GetAbsoluteKnowledgeUnitList): on a
// mission where civilians are targets, the ones this unit sees are added, to
// the reference list only, and only for a unit that has AI data
function AddTerrorCivilians(bool bInclude, out array<StateObjectReference> RefList)
{
	if (bInclude && GetAIUnitDataID(m_kUnit.ObjectID) > 0 && CiviliansAreTargets())
	{
		class'X2TacticalVisibilityHelpers'.static.GetAllVisibleUnitsOnTeamForSource(m_kUnit.ObjectID, eTeam_Neutral, RefList);
	}
}

static function bool CiviliansAreTargets()
{
	local XComGameState_BattleData Battle;

	Battle = XComGameState_BattleData(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_BattleData'));
	return Battle != none && Battle.AreCiviliansAlienTargets();
}

function RefreshKnown()
{
	local X2ChronoMetrics Metrics;
	local int Frame;

	Metrics = class'X2ChronoMetrics'.static.Get();
	Frame = `XCOMHISTORY.GetCurrentHistoryIndex();
	if (Frame == ChronoKnownFrame)
	{
		Metrics.Count(eCount_KnownFrameHits);
		return;
	}

	ChronoKnownFrame = Frame;
	ChronoKnown.Length = 0;
	if (class'X2ChronoComms'.static.IsJammed(UnitState))
	{
		Metrics.Count(eCount_KnownJammed);
		OwnSightKnown(ChronoKnown);
	}
	else if (ListsFromIndex(Metrics))
	{
		Metrics.Count(eCount_KnownIndexed);
		IndexedKnown(ChronoKnown);
	}
	else
	{
		ListFromVanilla(Metrics);
	}
}

// The list comes from the unit index (the hive's sightings, a handful of
// probes) for a unit with AI data. A unit without AI data keeps vanilla's
// pass (vanilla builds its list another way), and the refreshes a telemetry
// asks to verify (X2ChronoMetrics.TakesKnownVerification) still run vanilla's
// pass and are compared with the index.
function bool ListsFromIndex(X2ChronoMetrics Metrics)
{
	return GetAIUnitDataID(m_kUnit.ObjectID) > 0 && !Metrics.TakesKnownVerification();
}

// Vanilla's pass over every unit, filtered to the hive's sightings
function ListFromVanilla(X2ChronoMetrics Metrics)
{
	local array<XComGameState_Unit> Units;
	local array<StateObjectReference> Refs;
	local int i;

	Metrics.Count(eCount_KnownPasses);
	super.GetAllKnownEnemyStates(Units, Refs);
	DropUnseenRefs(Refs);
	for (i = 0; i < Refs.Length; ++i)
	{
		ChronoKnown.AddItem(Refs[i].ObjectID);
	}
	CheckIndexedKnown();
}

//-----------------------------------------------------------------------------
// The list from the unit index, and its check against vanilla.
// Vanilla's list for an alien is the enemy player's playable, unconcealed
// units (XGPlayer.GetPlayableUnits, a pass over every unit in the history);
// the hive filter keeps the ones some alien sees. The index already holds
// that set (hive sight). Vanilla's consumers break ties by list order, and
// vanilla's order is ascending ObjectID: measured on 2026-10-03, 73 passes
// compared, 51 of them with two to five units, no difference in content or
// order. Every vanilla pass that still runs is compared with the indexed list.
//-----------------------------------------------------------------------------

function CheckIndexedKnown()
{
	local array<int> Indexed;
	local bool bSameOrder;

	if (!class'X2ChronoMetrics'.static.Get().IsOn() || GetAIUnitDataID(m_kUnit.ObjectID) <= 0)
	{
		return;
	}

	IndexedKnown(Indexed);
	bSameOrder = SameList(ChronoKnown, Indexed);
	class'X2ChronoMetrics'.static.Get().NoteKnownCheck(bSameOrder, bSameOrder || SameSet(ChronoKnown, Indexed));
	`log("ChronoCOM Known: unit=" $ UnitState.ObjectID @ "vanilla=" $ JoinIDs(ChronoKnown) @ "indexed=" $ JoinIDs(Indexed), !bSameOrder);
}

// The hive's sightings that vanilla would list: playable units of the enemy
// player, in ascending ObjectID
function IndexedKnown(out array<int> IDs)
{
	local array<int> SeenIDs;
	local int i, EnemyPlayerID;

	EnemyPlayerID = `BATTLE.GetEnemyPlayer(m_kUnit.m_kPlayer).ObjectID;
	SeenIDs = class'X2ChronoComms'.static.SightIndex().HiveSeenIDs;
	for (i = 0; i < SeenIDs.Length; ++i)
	{
		if (IsListedByVanilla(SeenIDs[i], EnemyPlayerID))
		{
			InsertSorted(IDs, SeenIDs[i]);
		}
	}
}

// A jammed alien (X2ChronoComms.IsJammed) knows only what it sees itself:
// vanilla's visibility for this unit, filtered and ordered as the indexed
// list is
function OwnSightKnown(out array<int> IDs)
{
	local array<StateObjectReference> Seen;
	local int i, EnemyPlayerID;

	EnemyPlayerID = `BATTLE.GetEnemyPlayer(m_kUnit.m_kPlayer).ObjectID;
	class'X2TacticalVisibilityHelpers'.static.GetAllVisibleEnemyUnitsForUnit(UnitState.ObjectID, Seen);
	for (i = 0; i < Seen.Length; ++i)
	{
		if (IsListedByVanilla(Seen[i].ObjectID, EnemyPlayerID))
		{
			InsertSorted(IDs, Seen[i].ObjectID);
		}
	}
}

static function bool IsListedByVanilla(int UnitID, int EnemyPlayerID)
{
	local XComGameState_Unit Unit;

	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitID));
	return Unit != none && Unit.ControllingPlayer.ObjectID == EnemyPlayerID && class'X2ChronoIndex'.static.IsPlayable(Unit);
}

static function InsertSorted(out array<int> IDs, int ID)
{
	local int i;

	i = IDs.Length;
	IDs.AddItem(ID);
	while (i > 0 && IDs[i - 1] > ID)
	{
		IDs[i] = IDs[i - 1];
		--i;
	}
	IDs[i] = ID;
}

static function bool SameList(const out array<int> A, const out array<int> B)
{
	local int i;

	if (A.Length != B.Length)
	{
		return false;
	}

	for (i = 0; i < A.Length; ++i)
	{
		if (A[i] != B[i])
		{
			return false;
		}
	}

	return true;
}

static function bool SameSet(const out array<int> A, const out array<int> B)
{
	local int i;

	if (A.Length != B.Length)
	{
		return false;
	}

	for (i = 0; i < A.Length; ++i)
	{
		if (B.Find(A[i]) == INDEX_NONE)
		{
			return false;
		}
	}

	return true;
}

static function string JoinIDs(const out array<int> IDs)
{
	local string Text;
	local int i;

	for (i = 0; i < IDs.Length; ++i)
	{
		Text $= ((i > 0) ? "," : "") $ IDs[i];
	}

	return "[" $ Text $ "]";
}

// Both lists from the kept IDs: the committed state of each, which is the
// object vanilla's pass returns
function KnownFromFrame(out array<XComGameState_Unit> UnitList, out array<StateObjectReference> RefList)
{
	local XComGameState_Unit Enemy;
	local int i;

	UnitList.Length = 0;
	RefList.Length = 0;
	for (i = 0; i < ChronoKnown.Length; ++i)
	{
		Enemy = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(ChronoKnown[i]));
		UnitList.AddItem(Enemy);
		RefList.AddItem(Enemy.GetReference());
	}
}

/**
 * Vanilla counts a unit's overwatching allies with a pass over every unit in
 * the history (XGPlayer.GetPlayableUnits), each time a tree asks before
 * choosing overwatch. The unit index keeps that count per player as unit
 * states change, under vanilla's own test, so the answer is two probes.
 */
function int GetNumOverwatchingAllies()
{
	if (class'X2ChronoConfig'.default.bBaselineMode || !class'X2ChronoConfig'.default.bUseTurnIndex)
	{
		return super.GetNumOverwatchingAllies();
	}

	class'X2ChronoMetrics'.static.Get().Count(eCount_OverwatchAllyReads);
	return class'X2ChronoIndex'.static.GetIndex().CountReserveAllies(m_kUnit.m_kPlayer.ObjectID, UnitState.ObjectID);
}

// One pass, order kept (removing in place would shift the tail on every drop)
function DropUnseenUnits(out array<XComGameState_Unit> UnitList)
{
	local array<XComGameState_Unit> Kept;
	local int i;

	for (i = 0; i < UnitList.Length; ++i)
	{
		if (!IsUnseenXCom(UnitList[i]))
		{
			Kept.AddItem(UnitList[i]);
		}
	}

	UnitList = Kept;
}

function DropUnseenRefs(out array<StateObjectReference> RefList)
{
	local array<StateObjectReference> Kept;
	local int i;

	for (i = 0; i < RefList.Length; ++i)
	{
		if (!IsUnseenXCom(XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(RefList[i].ObjectID))))
		{
			Kept.AddItem(RefList[i]);
		}
	}

	RefList = Kept;
}

// Only XCOM-team units are filtered; civilians and the Lost stay as vanilla
// lists them
function bool IsUnseenXCom(XComGameState_Unit Enemy)
{
	return Enemy != none && Enemy.GetTeam() == eTeam_XCom && !class'X2ChronoComms'.static.HiveSees(Enemy.ObjectID);
}

/**
 * The nearest known enemy, for vanilla's fallback moves (heat seeking,
 * priority distance). Given visibility infos vanilla already picks among
 * visible enemies; without them it would pick among every XCOM unit on the
 * map, so here it picks among the hive's sightings. A unit without AI data
 * (mind-controlled) keeps vanilla's own path, its closest visible enemy.
 *
 * Vanilla asks this once per scored tile while the unit sees nobody, and each
 * time passes over every unit; here each call loops over the kept answer.
 */
function XComGameState_Unit GetNearestKnownEnemy(vector vLocation, optional out float fClosestDistSq, optional array<GameRulesCache_VisibilityInfo> EnemyInfos, bool IncludeCiviliansOnTerrorMaps=true)
{
	if (!UsesHonestKnowledge() || EnemyInfos.Length > 0 || GetAIUnitDataID(m_kUnit.ObjectID) <= 0)
	{
		return super.GetNearestKnownEnemy(vLocation, fClosestDistSq, EnemyInfos, IncludeCiviliansOnTerrorMaps);
	}

	return NearestSeenEnemy(vLocation, fClosestDistSq, IncludeCiviliansOnTerrorMaps);
}

// Over the reference list, as vanilla does: it is the one that carries the
// civilians of a terror mission
function XComGameState_Unit NearestSeenEnemy(vector vLocation, out float fClosestDistSq, bool IncludeCiviliansOnTerrorMaps)
{
	local array<StateObjectReference> Known;
	local XComGameState_Unit Enemy, Closest;
	local float DistSq;
	local int i;

	Closest = none;
	GetAllKnownEnemyStates(, Known, IncludeCiviliansOnTerrorMaps);
	for (i = 0; i < Known.Length; ++i)
	{
		Enemy = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Known[i].ObjectID));
		DistSq = SeekDistanceSq(Enemy, vLocation);
		if (IsNearer(DistSq, Closest, fClosestDistSq))
		{
			Closest = Enemy;
			fClosestDistSq = DistSq;
		}
	}

	return Closest;
}

static function bool IsNearer(float DistSq, XComGameState_Unit Closest, float ClosestDistSq)
{
	return DistSq >= 0 && (Closest == none || DistSq < ClosestDistSq);
}

// Squared distance to a unit worth seeking; negative for a faceless civilian,
// which vanilla skips here too
function float SeekDistanceSq(XComGameState_Unit Enemy, vector vLocation)
{
	if (Enemy.GetTeam() == eTeam_Neutral && Enemy.IsAlien())
	{
		return -1.0;
	}

	return VSizeSq(`XWORLD.GetPositionFromTileCoordinates(Enemy.TileLocation) - vLocation);
}

//=============================================================================
// Generic-ability trees
//=============================================================================

/**
 * Caches visibility and cover flags for the choose/move overrides below, then
 * lets vanilla collect and weight the abilities.
 *
 * @return true if abilities were successfully collected and weighted
 */
function bool BT_InitGenericAbilities()
{
	if (class'X2ChronoConfig'.default.bBaselineMode)
	{
		return super.BT_InitGenericAbilities();
	}

	// No action points = nothing to choose
	if (UnitState.NumActionPoints() <= 0)
	{
		return false;
	}

	CachedVisibleEnemyCount = CountVisibleEnemies();
	bNoVisibleEnemies = (CachedVisibleEnemyCount == 0);
	bInOptimalCover = IsInOptimalCover();

	GenericAbilityList.Length = 0;
	return super.BT_InitGenericAbilities();
}

// Number of XCOM units this unit can see (one engine visibility query)
function int CountVisibleEnemies()
{
	local array<XComGameState_Unit> VisibleEnemies;

	VisibleEnemies = class'X2AIBehaviorDirector_Optimized'.static.GetVisibleThreats(UnitState);
	return VisibleEnemies.Length;
}

// True when the unit can take cover and has a visible enemy. CanTakeCover() is
// a capability check, not "is currently in cover".
function bool IsInOptimalCover()
{
	return (UnitState.CanTakeCover() && CachedVisibleEnemyCount > 0);
}

/**
 * Filters and boosts attack options using the flags from ability init, then
 * defers to vanilla selection.
 *
 * @return true if an ability was successfully selected
 */
function bool BT_ChooseGenericAbilityOption()
{
	if (!class'X2ChronoConfig'.default.bBaselineMode)
	{
		ShapeAbilityList();
	}

	return super.BT_ChooseGenericAbilityOption();
}

// With nothing in sight the attack options are dropped; in cover with a
// target (bInOptimalCover) shooting is preferred over moving
function ShapeAbilityList()
{
	if (bNoVisibleEnemies)
	{
		FilterAttackAbilities();
	}
	if (bInOptimalCover)
	{
		BoostAttackAbilityWeights();
	}
}

// Removes the attack abilities (FilteredAttackAbilities) from the option list:
// one pass, order kept
function FilterAttackAbilities()
{
	local array<GenericAbilitySelection> Kept;
	local int i;

	for (i = 0; i < GenericAbilityList.Length; ++i)
	{
		if (FilteredAttackAbilities.Find(GenericAbilityList[i].AbilityName) == INDEX_NONE)
		{
			Kept.AddItem(GenericAbilityList[i]);
		}
	}

	GenericAbilityList = Kept;
}

// Raises the score of the direct-fire abilities (BoostedAttackAbilities)
function BoostAttackAbilityWeights()
{
	local int i;

	for (i = 0; i < GenericAbilityList.Length; i++)
	{
		if (BoostedAttackAbilities.Find(GenericAbilityList[i].AbilityName) != INDEX_NONE)
		{
			GenericAbilityList[i].Score *= ATTACK_SCORE_BOOST;
		}
	}
}

/**
 * Holds position when already covered with a target (the tree then picks an
 * attack instead), and otherwise defers to vanilla.
 *
 * @return true if a valid destination was found
 */
function bool BT_MoveCloserForGenericAbility()
{
	if (!class'X2ChronoConfig'.default.bBaselineMode && bInOptimalCover)
	{
		return false;
	}

	return super.BT_MoveCloserForGenericAbility();
}

//=============================================================================
// Measurement only
//=============================================================================

/**
 * The Lost's per-unit pathing. XGAIPlayer_TheLost calls this for every Lost
 * in a group move (AssignLostUnitDestinations); it tests each melee tile
 * around the target for reachability and falls back to the furthest reachable
 * tile toward it. The destination is always vanilla's.
 */
function bool FindGroupDestinationToward(XComGameState_Unit TargetState, out TTile DestinationTile, out array<TTile> ValidAttackTiles, out array<TTile> ReservedTiles, optional int GroupUnitIndex=0)
{
	local X2ChronoMetrics Metrics;
	local float ClockMs;
	local bool bFound;

	Metrics = class'X2ChronoMetrics'.static.Get();
	Metrics.StartTimer(ClockMs);
	bFound = super.FindGroupDestinationToward(TargetState, DestinationTile, ValidAttackTiles, ReservedTiles, GroupUnitIndex);
	Metrics.NoteGroupPath(Metrics.StopTimer(ClockMs), bFound);

	return bFound;
}

/**
 * Counts and times vanilla destination scoring for the telemetry. The
 * score is vanilla's; against a grenade-heavy squad its spread penalty is
 * strengthened (ApplyHabitSpread).
 */
function ai_tile_score FillTileScoreData(TTile kTile, vector vLoc, XComCoverPoint kCover, optional array<GameRulesCache_VisibilityInfo> arrEnemyInfos, optional out float fDist, optional bool AddSpreadToOldLocation=true)
{
	local X2ChronoMetrics Metrics;
	local ai_tile_score Score;
	local float ClockMs;

	Metrics = class'X2ChronoMetrics'.static.Get();
	Metrics.StartTileScore(ClockMs);
	Score = super.FillTileScoreData(kTile, vLoc, kCover, arrEnemyInfos, fDist, AddSpreadToOldLocation);
	ApplyHabitSpread(Score);
	Metrics.StopTileScore(ClockMs, UnitState != none ? UnitState.ObjectID : 0, kTile);

	return Score;
}

defaultproperties
{
	bNoVisibleEnemies=false
	bInOptimalCover=false
	CachedVisibleEnemyCount=0
	ChronoPodIdx=-1
	ChronoKnownFrame=-1

	FilteredAttackAbilities(0)="StandardShot"
	FilteredAttackAbilities(1)="SniperStandardFire"
	FilteredAttackAbilities(2)="PistolStandardShot"
	FilteredAttackAbilities(3)="Suppression"
	FilteredAttackAbilities(4)="AreaSuppression"

	BoostedAttackAbilities(0)="StandardShot"
	BoostedAttackAbilities(1)="SniperStandardFire"
	BoostedAttackAbilities(2)="PistolStandardShot"

	HoldMoveProfiles(0)="MWP_Defensive"
	HoldMoveProfiles(1)="MWP_Fallback"
	HoldMoveProfiles(2)="MWP_DefensiveHeight"
	HoldMoveProfiles(3)="MWP_FallbackHeight"
}
