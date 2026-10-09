// X2AIBehaviorDirector_Optimized
// The visibility helper shared by the AI subsystems, and the tuning of the
// focus-fire, cover-flushing, habit-counter and height rules
// XGAIBehavior_ChronoCOM applies. (Until 2026-10-06 it also chose a move for
// a pod "investigating" its last contact, on a path ordinary alien trees never
// take; it went with that old pod state.)

class X2AIBehaviorDirector_Optimized extends Object config(Game);

// Focus fire: points added to a standard shot's target score (vanilla's own
// terms: hit chance tier 10/40/70, flank 50, marked 45, kill shot 15)
var config int FOCUS_HIT_WEIGHT;      // points at 100% hit chance, scaled linearly below
var config int FOCUS_PILE_ON_BONUS;   // per earlier attack on the target this alien turn
var config int FOCUS_PILE_ON_MAX;     // earlier attacks counted
var config int FOCUS_FLUSHED_BONUS;   // target was hit by a cover-flushing grenade this turn
var config int FOCUS_TARGET_BONUS;    // target is the hive's focus target (X2ChronoFirePlan.FocusTarget)

// Cover flush: a unit whose own shot at a covered target is below this chance
// throws its grenade at that target instead
var config int FLUSH_MAX_HIT_CHANCE;

// Habit counters: while the squad's detected habit is Pattern, a destination
// search asked for with vanilla tile profile FromProfile uses vanilla profile
// ToProfile instead
struct HabitCounter
{
	var name Pattern;
	var name FromProfile;
	var name ToProfile;
};
var config array<HabitCounter> HABIT_PROFILE_COUNTERS;

// Against a grenade-heavy squad, vanilla's own penalty for a tile close to a
// teammate is multiplied by this (below 1 = spread out more)
var config float HABIT_SPREAD_SCALE;

// A vanilla tile profile and its height-aware twin (DefaultAI.ini), which
// every alien search runs with instead when bHeightAware is on
struct ProfilePair
{
	var name FromProfile;
	var name ToProfile;
};
var config array<ProfilePair> HEIGHT_PROFILES;

// The vanilla profile that counters Habit when FromProfile is asked for, or
// FromProfile itself. At most a handful of entries.
static function name CounterProfile(name Habit, name FromProfile)
{
	local int i;

	for (i = 0; i < default.HABIT_PROFILE_COUNTERS.Length; ++i)
	{
		if (default.HABIT_PROFILE_COUNTERS[i].Pattern == Habit && default.HABIT_PROFILE_COUNTERS[i].FromProfile == FromProfile)
		{
			return default.HABIT_PROFILE_COUNTERS[i].ToProfile;
		}
	}

	return FromProfile;
}

// The living XCOM units this unit can see (gameplay visibility, so fog of war
// and concealment apply), from the engine's visibility cache: one native
// query instead of a visibility lookup per unit in the history.
// Definition: "enemy" is the engine's relation, so a mind-controlled alien
// (team XCom) sees no XCOM threats.
static function array<XComGameState_Unit> GetVisibleThreats(XComGameState_Unit AIUnit)
{
	local array<XComGameState_Unit> Threats;
	local array<StateObjectReference> Visible;
	local int i;

	if (AIUnit == none)
	{
		return Threats;
	}

	class'X2ChronoMetrics'.static.Get().Count(eCount_NativeVisQueries);
	class'X2TacticalVisibilityHelpers'.static.GetAllVisibleEnemyUnitsForUnit(AIUnit.ObjectID, Visible);

	for (i = 0; i < Visible.Length; ++i)
	{
		AddIfXCom(Visible[i].ObjectID, Threats);
	}

	return Threats;
}

static function AddIfXCom(int ObjectID, out array<XComGameState_Unit> Threats)
{
	local XComGameState_Unit Enemy;

	Enemy = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(ObjectID));
	if (Enemy != none && Enemy.GetTeam() == eTeam_XCom && !Enemy.GetMyTemplate().bIsCosmetic)
	{
		Threats.AddItem(Enemy);
	}
}

defaultproperties
{
}
