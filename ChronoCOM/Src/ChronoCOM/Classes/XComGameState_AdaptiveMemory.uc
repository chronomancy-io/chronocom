//=============================================================================
// XComGameState_AdaptiveMemory
//
// WASP Role: I(c) — campaign-scoped index of how XCOM fights
// MSS: literal minimal sufficient statistics. Nothing about individual kills
// or shots is stored; only decayed counters, so the object is a fixed size no
// matter how long the campaign runs, and every update is O(1).
//
// Lifetime: created in the strategy layer (InstallNewCampaign, or on the
// first strategy load for older campaigns), carried into each mission's start
// state and modified there, and carried back when the mission ends. Objects
// created in tactical are discarded on return to strategy, which is why the
// previous version never survived a mission.
//
// Data: X2AdaptiveCollector counts XCOM's tactics from real events (KillMail,
// AbilityActivated) and adds each event's counts to InProgress in the event's
// own game state; FoldInMission decays the totals and adds InProgress at
// mission end. InProgress is game state, so a save carries the mission's
// counts so far and a mission finished in a later session is counted whole.
//
// The habit is judged live (LivePattern): on the decayed totals plus the
// mission so far, at full weight, once per alien turn. So a squad's habit can
// be seen, and countered, during its first mission; the tiers only make the
// counter stronger as the campaign goes on (CounterStrength).
//=============================================================================

class XComGameState_AdaptiveMemory extends XComGameState_BaseObject config(Game);

// One mission's counts, produced by X2AdaptiveCollector
struct MissionTactics
{
	var int Kills;              // XCOM kills of alien-team units
	var int CloseKills;         // <= CloseRangeMaxTiles
	var int MediumKills;        // <= MediumRangeMaxTiles
	var int LongKills;
	var int HighGroundKills;    // killer at least HighGroundTileZ above the victim
	var int LevelKills;
	var int LowGroundKills;
	var int FlankKills;         // engine flanking test at the moment of the kill
	var int ReactionKills;      // killing ability had bReactionFire
	var int ExplosiveKills;     // grenade or explosive weapon
	var int Shots;              // offensive ability activations
	var int OverwatchActivations;
	var int GrenadeActivations;
};

// The evidence a habit is judged on (CurrentEvidence): the decayed totals
// with the mission so far added
struct Evidence
{
	var float Kills;
	var float RangeKills[3];      // close / medium / long
	var float HighGroundKills;
	var float FlankKills;
	var float ReactionKills;
	var float ExplosiveKills;
	var float Shots;
	var float OverwatchActivations;
};

// Decayed campaign totals (floats: each mission multiplies them by MemoryDecay first)
var float Kills;
var float RangeKills[3];        // close / medium / long
var float HeightKills[3];       // high ground / level / low ground
var float FlankKills;
var float ReactionKills;
var float ExplosiveKills;
var float Shots;
var float OverwatchActivations;
var float GrenadeActivations;

var int MissionsCompleted;
var int CurrentAdaptationTier;   // 0..3 from MissionsCompleted
var name DominantPattern;        // '' or one of the PATTERN_* names
var float PatternConfidence;     // the share that qualified the pattern, 0..1

// Last mission as counted, undecayed, for the log and debug commands
var MissionTactics LastMission;

// The mission being played, as counted so far; empty between missions
var MissionTactics InProgress;

// Progression
var config int MissionsUntilTier1;
var config int MissionsUntilTier2;
var config int MissionsUntilTier3;

// Detection
var config float MemoryDecay;                 // per-mission multiplier on all totals, 0..1
var config float MinKillsForPatternDetection; // kills needed before any pattern: decayed, plus the mission so far
var config float PatternDetectionThreshold;   // minimum share for the range patterns
var config float ElevationPatternShare;       // high-ground kills / kills
var config float FlankPatternShare;           // flanking kills / kills
var config float OverwatchPatternShare;       // reaction kills / kills, or overwatch activations / shots
var config float ExplosivePatternShare;       // explosive kills / kills
var config int CloseRangeMaxTiles;
var config int MediumRangeMaxTiles;
var config int HighGroundTileZ;               // killer this many tile-Z above the victim counts as high ground

// How hard the aliens counter the squad's habit (CounterStrength): the spread
// penalty and the overwatch threshold scale with it
var config float CounterWeightMultiplier;
var config float CounterTierStep;             // strength added for each tier past the first
var config bool bScaleWithDifficulty;
var config float RookieMultiplier;
var config float VeteranMultiplier;
var config float CommanderMultiplier;
var config float LegendaryMultiplier;

//-----------------------------------------------------------------------------
// Access
//-----------------------------------------------------------------------------

static function XComGameState_AdaptiveMemory GetMemory()
{
	local XComGameState_AdaptiveMemory Memory;
	local XComGameStateHistory History;

	History = `XCOMHISTORY;

	// The history's native per-class lookup finds the memory in the current
	// start state's span (strategy, or a mission it was carried into)
	Memory = XComGameState_AdaptiveMemory(History.GetSingleGameStateObjectForClass(class'XComGameState_AdaptiveMemory', true));
	if (Memory != none)
	{
		return Memory;
	}

	// Not in the current start state: look past it (strategy object seen from an
	// older tactical save, or a save from before OnPreMission carried it over)
	foreach History.IterateByClassType(class'XComGameState_AdaptiveMemory', Memory, eReturnType_Reference, true)
	{
		return Memory;
	}

	return none;
}

static function XComGameState_AdaptiveMemory GetModifiableMemory(XComGameState NewGameState)
{
	local XComGameState_AdaptiveMemory Memory;

	Memory = GetMemory();
	if (Memory == none)
		return none;

	return XComGameState_AdaptiveMemory(NewGameState.ModifyStateObject(class'XComGameState_AdaptiveMemory', Memory.ObjectID));
}

// Adds a new memory to the given game state (a strategy start state or a
// change state that the caller submits)
static function XComGameState_AdaptiveMemory CreateMemory(XComGameState NewGameState)
{
	local XComGameState_AdaptiveMemory Memory;

	Memory = XComGameState_AdaptiveMemory(NewGameState.CreateNewStateObject(class'XComGameState_AdaptiveMemory'));
	Memory.ResetMemory();

	return Memory;
}

// Strategy layer only: creates the memory in its own history frame if the
// campaign has none (campaigns started before the mod, or before this fix)
static function XComGameState_AdaptiveMemory EnsureMemoryInStrategy(string Reason)
{
	local XComGameState_AdaptiveMemory Memory;
	local XComGameState NewGameState;

	Memory = GetMemory();
	if (Memory != none)
	{
		`log("ChronoCOM Adaptive: memory present (" $ Reason $ "): missions=" $ Memory.MissionsCompleted @ "tier=" $ Memory.CurrentAdaptationTier @ "pattern=" $ Memory.DominantPattern);
		return Memory;
	}

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("ChronoCOM: Create Adaptive Memory");
	Memory = CreateMemory(NewGameState);
	`XCOMHISTORY.AddGameStateToHistory(NewGameState);

	`log("ChronoCOM Adaptive: created campaign memory (" $ Reason $ ")");
	return Memory;
}

//-----------------------------------------------------------------------------
// Updates
//-----------------------------------------------------------------------------

function ResetMemory()
{
	local MissionTactics Empty;
	local int i;

	Kills = 0;
	for (i = 0; i < 3; ++i)
	{
		RangeKills[i] = 0;
		HeightKills[i] = 0;
	}
	FlankKills = 0;
	ReactionKills = 0;
	ExplosiveKills = 0;
	Shots = 0;
	OverwatchActivations = 0;
	GrenadeActivations = 0;

	MissionsCompleted = 0;
	CurrentAdaptationTier = 0;
	DominantPattern = '';
	PatternConfidence = 0;
	LastMission = Empty;
	InProgress = Empty;
}

// One event's counts, added to the mission being played
function AddToMission(MissionTactics Delta)
{
	InProgress.Kills += Delta.Kills;
	InProgress.CloseKills += Delta.CloseKills;
	InProgress.MediumKills += Delta.MediumKills;
	InProgress.LongKills += Delta.LongKills;
	InProgress.HighGroundKills += Delta.HighGroundKills;
	InProgress.LevelKills += Delta.LevelKills;
	InProgress.LowGroundKills += Delta.LowGroundKills;
	InProgress.FlankKills += Delta.FlankKills;
	InProgress.ReactionKills += Delta.ReactionKills;
	InProgress.ExplosiveKills += Delta.ExplosiveKills;
	InProgress.Shots += Delta.Shots;
	InProgress.OverwatchActivations += Delta.OverwatchActivations;
	InProgress.GrenadeActivations += Delta.GrenadeActivations;
}

// Decays every total, adds the mission's counts, empties them, and re-evaluates
// the pattern and tier. O(1) regardless of mission length.
function FoldInMission()
{
	local MissionTactics Mission, Empty;
	local int i;

	Mission = InProgress;
	InProgress = Empty;

	Kills *= MemoryDecay;
	for (i = 0; i < 3; ++i)
	{
		RangeKills[i] *= MemoryDecay;
		HeightKills[i] *= MemoryDecay;
	}
	FlankKills *= MemoryDecay;
	ReactionKills *= MemoryDecay;
	ExplosiveKills *= MemoryDecay;
	Shots *= MemoryDecay;
	OverwatchActivations *= MemoryDecay;
	GrenadeActivations *= MemoryDecay;

	Kills += Mission.Kills;
	RangeKills[0] += Mission.CloseKills;
	RangeKills[1] += Mission.MediumKills;
	RangeKills[2] += Mission.LongKills;
	HeightKills[0] += Mission.HighGroundKills;
	HeightKills[1] += Mission.LevelKills;
	HeightKills[2] += Mission.LowGroundKills;
	FlankKills += Mission.FlankKills;
	ReactionKills += Mission.ReactionKills;
	ExplosiveKills += Mission.ExplosiveKills;
	Shots += Mission.Shots;
	OverwatchActivations += Mission.OverwatchActivations;
	GrenadeActivations += Mission.GrenadeActivations;

	LastMission = Mission;
	MissionsCompleted++;

	UpdateAdaptationTier();
	UpdateDominantPattern();

	`log("ChronoCOM Adaptive: mission" @ MissionsCompleted @ "counted: kills=" $ Mission.Kills @ "shots=" $ Mission.Shots
		@ "overwatch=" $ Mission.OverwatchActivations @ "grenades=" $ Mission.GrenadeActivations
		@ "flank_kills=" $ Mission.FlankKills @ "reaction_kills=" $ Mission.ReactionKills @ "explosive_kills=" $ Mission.ExplosiveKills
		@ "range=" $ Mission.CloseKills $ "/" $ Mission.MediumKills $ "/" $ Mission.LongKills
		@ "height=" $ Mission.HighGroundKills $ "/" $ Mission.LevelKills $ "/" $ Mission.LowGroundKills
		@ "| decayed kills=" $ Kills @ "pattern=" $ DominantPattern @ "confidence=" $ int(PatternConfidence * 100) $ "%" @ "tier=" $ CurrentAdaptationTier);
}

// The pattern the campaign ends the mission with, for the mission line and
// the debug commands (InProgress was just folded in, so this is the totals')
function UpdateDominantPattern()
{
	local Evidence E;

	E = CurrentEvidence();
	DominantPattern = PatternOf(E, PatternConfidence);
	`log("ChronoCOM Adaptive: pattern detection needs" @ MinKillsForPatternDetection @ "kills, have" @ E.Kills, E.Kills < MinKillsForPatternDetection);
}

// The decayed totals with the mission so far added at full weight. Constant
// work: a dozen counters.
function Evidence CurrentEvidence()
{
	local Evidence E;

	E.Kills = Kills + InProgress.Kills;
	E.RangeKills[0] = RangeKills[0] + InProgress.CloseKills;
	E.RangeKills[1] = RangeKills[1] + InProgress.MediumKills;
	E.RangeKills[2] = RangeKills[2] + InProgress.LongKills;
	E.HighGroundKills = HeightKills[0] + InProgress.HighGroundKills;
	E.FlankKills = FlankKills + InProgress.FlankKills;
	E.ReactionKills = ReactionKills + InProgress.ReactionKills;
	E.ExplosiveKills = ExplosiveKills + InProgress.ExplosiveKills;
	E.Shots = Shots + InProgress.Shots;
	E.OverwatchActivations = OverwatchActivations + InProgress.OverwatchActivations;
	return E;
}

// The pattern whose share exceeds its threshold by the largest factor, or ''
// below MinKillsForPatternDetection kills. Every rule is a share of kills (or
// of shots), so no rule can win by being evaluated last.
function name PatternOf(const out Evidence E, out float Confidence)
{
	local name Pattern;
	local float Best;
	local int Bracket;

	Confidence = 0;
	if (E.Kills < MinKillsForPatternDetection)
	{
		return '';
	}

	// Range: the dominant bracket's share against the range threshold
	Bracket = DominantRangeBracket(E);
	ConsiderPattern(RangePatternName(Bracket), E.RangeKills[Bracket] / E.Kills, PatternDetectionThreshold, Pattern, Confidence, Best);
	ConsiderPattern('PATTERN_ELEVATION_DEPENDENT', E.HighGroundKills / E.Kills, ElevationPatternShare, Pattern, Confidence, Best);
	ConsiderPattern('PATTERN_FLANKING_AGGRESSIVE', E.FlankKills / E.Kills, FlankPatternShare, Pattern, Confidence, Best);
	ConsiderPattern('PATTERN_OVERWATCH_CRAWL', OverwatchShare(E), OverwatchPatternShare, Pattern, Confidence, Best);
	ConsiderPattern('PATTERN_EXPLOSIVE_HEAVY', E.ExplosiveKills / E.Kills, ExplosivePatternShare, Pattern, Confidence, Best);
	return Pattern;
}

// 0 close, 1 medium, 2 long: the bracket with the most kills
static function int DominantRangeBracket(const out Evidence E)
{
	local int i, Best;

	for (i = 1; i < 3; ++i)
	{
		if (E.RangeKills[i] > E.RangeKills[Best])
			Best = i;
	}

	return Best;
}

// Overwatch reliance: kills by reaction fire, or overwatch use per shot
static function float OverwatchShare(const out Evidence E)
{
	if (E.Shots > 0)
		return FMax(E.ReactionKills / E.Kills, E.OverwatchActivations / E.Shots);

	return E.ReactionKills / E.Kills;
}

static function name RangePatternName(int Bracket)
{
	if (Bracket == 0)
		return 'PATTERN_CLOSE_RANGE';
	if (Bracket == 1)
		return 'PATTERN_MEDIUM_RANGE';
	return 'PATTERN_LONG_RANGE';
}

// A rule wins when its share meets its threshold by a larger factor than the
// current best; the factor makes rules with different thresholds comparable
static function ConsiderPattern(name Candidate, float Share, float Threshold, out name Pattern, out float Confidence, out float Best)
{
	if (Threshold <= 0 || Share < Threshold || Share / Threshold <= Best)
		return;

	Best = Share / Threshold;
	Confidence = Share;
	Pattern = Candidate;
}
function UpdateAdaptationTier()
{
	if (MissionsCompleted >= MissionsUntilTier3)
		CurrentAdaptationTier = 3;
	else if (MissionsCompleted >= MissionsUntilTier2)
		CurrentAdaptationTier = 2;
	else if (MissionsCompleted >= MissionsUntilTier1)
		CurrentAdaptationTier = 1;
	else
		CurrentAdaptationTier = 0;
}

//-----------------------------------------------------------------------------
// Queries (for the AI consumer)
//-----------------------------------------------------------------------------

// The habit the evidence shows now, the mission so far included
function name LivePattern()
{
	local Evidence E;
	local float Confidence;

	E = CurrentEvidence();
	return PatternOf(E, Confidence);
}

// From the first mission on: no tier is needed (until 2026-10-06 a habit
// counted only from tier 1, three missions in, on 15 decayed kills)
function bool IsPatternDetected()
{
	return LivePattern() != '';
}

// The squad's habit for the AI to counter, or '' (switch off, no campaign
// memory, or too few kills so far)
static function name ActiveHabit()
{
	local XComGameState_AdaptiveMemory Memory;

	if (!class'X2ChronoConfig'.static.AdaptiveCounterOn())
	{
		return '';
	}

	Memory = GetMemory();
	return (Memory != none) ? Memory.LivePattern() : '';
}

function float GetAdaptationMultiplier()
{
	if (!bScaleWithDifficulty)
		return CounterWeightMultiplier;

	return CounterWeightMultiplier * DifficultyMultiplier();
}

// The campaign difficulty's multiplier; 1.0 without campaign settings or for an unknown difficulty
function float DifficultyMultiplier()
{
	local XComGameState_CampaignSettings CampaignSettings;
	local array<float> ByDifficulty;

	CampaignSettings = XComGameState_CampaignSettings(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_CampaignSettings', true));
	if (CampaignSettings == none)
		return 1.0;

	ByDifficulty.AddItem(RookieMultiplier);
	ByDifficulty.AddItem(VeteranMultiplier);
	ByDifficulty.AddItem(CommanderMultiplier);
	ByDifficulty.AddItem(LegendaryMultiplier);
	if (CampaignSettings.DifficultySetting < 0 || CampaignSettings.DifficultySetting >= ByDifficulty.Length)
		return 1.0;

	return ByDifficulty[CampaignSettings.DifficultySetting];
}

// 1.0 at the first tier, CounterTierStep more for each tier past it and less
// before it: with the default step, 0.5 for the first missions, then 1.0, 1.5
// and 2.0, so the counter starts gentle and hardens
function float GetTierScaling()
{
	return 1.0 + (CurrentAdaptationTier - 1) * CounterTierStep;
}

// How hard the aliens counter the detected habit: the adaptation multiplier
// (CounterWeightMultiplier, by difficulty) times the tier scaling; 0 without
// a detected habit
function float CounterStrength()
{
	return IsPatternDetected() ? GetAdaptationMultiplier() * GetTierScaling() : 0.0;
}

// The campaign memory's counter strength, under the same switch as the habit
static function float ActiveCounterStrength()
{
	local XComGameState_AdaptiveMemory Memory;

	Memory = GetMemory();
	return (class'X2ChronoConfig'.static.AdaptiveCounterOn() && Memory != none) ? Memory.CounterStrength() : 0.0;
}

//-----------------------------------------------------------------------------
// Debug
//-----------------------------------------------------------------------------

function string GetDebugString()
{
	local string Output;

	Output = "=== Adaptive Memory ===\n";
	Output $= "Missions: " $ MissionsCompleted $ "  Tier: " $ CurrentAdaptationTier $ "  Decay per mission: " $ MemoryDecay $ "\n";
	Output $= "Decayed kills: " $ Kills $ "  shots: " $ Shots $ "\n";
	Output $= "Range close/medium/long: " $ RangeKills[0] $ " / " $ RangeKills[1] $ " / " $ RangeKills[2] $ "\n";
	Output $= "Height high/level/low: " $ HeightKills[0] $ " / " $ HeightKills[1] $ " / " $ HeightKills[2] $ "\n";
	Output $= "Flank kills: " $ FlankKills $ "  reaction kills: " $ ReactionKills $ "  explosive kills: " $ ExplosiveKills $ "\n";
	Output $= "Overwatch activations: " $ OverwatchActivations $ "  grenade activations: " $ GrenadeActivations $ "\n";
	Output $= "This mission so far: kills=" $ InProgress.Kills $ " shots=" $ InProgress.Shots $ " overwatch=" $ InProgress.OverwatchActivations $ " grenades=" $ InProgress.GrenadeActivations $ "\n";
	Output $= "Last mission: kills=" $ LastMission.Kills $ " shots=" $ LastMission.Shots $ " overwatch=" $ LastMission.OverwatchActivations $ " grenades=" $ LastMission.GrenadeActivations $ "\n";
	Output $= "Pattern at the last mission's end: " $ DominantPattern $ "  confidence: " $ int(PatternConfidence * 100) $ "%\n";
	Output $= "Pattern now (mission so far included): " $ LivePattern() $ "  counter strength: " $ CounterStrength() $ "\n";

	return Output;
}

// Config values live in XComGame.ini [ChronoCOM.XComGameState_AdaptiveMemory]
defaultproperties
{
}
