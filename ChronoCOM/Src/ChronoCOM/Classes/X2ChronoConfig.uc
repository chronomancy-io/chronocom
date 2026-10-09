//=============================================================================
// X2ChronoConfig
//
// Runtime switches for ChronoCOM, read from XComGame.ini [ChronoCOM.X2ChronoConfig].
//
// bBaselineMode turns every ChronoCOM gameplay change off while leaving the
// registered metrics running (X2ChronoMetrics), so one build can measure vanilla and
// ChronoCOM from the same save. bUseTurnIndex toggles only the per-turn index, which returns
// bit-identical results, so turning it off isolates the index's cost/benefit.
// The AI switches (pod intent, focus fire, grenadier order, honest knowledge)
// are independent of each other so each can be played and tuned on its own.
//=============================================================================

class X2ChronoConfig extends Object config(Game);

var config bool bBaselineMode;    // true = vanilla gameplay (measured, when metrics are registered)
var config bool bUseTurnIndex;    // false = no overwatch count or known-enemy list from the index: vanilla's own passes
var config bool bVerboseLogging;  // per-call debug logging (AI decisions)
var config bool bLostRevealOnlyFirst; // true = only the mission's first Lost reveal plays its reveal matinee
var config bool bTrimLostAttackCamera; // true = Lost melee attacks use the default framing instead of a cinescript close-up
var config bool bPodIntent;       // true = engaged pods hold, fall back and flush cover with grenades (X2PodCoordinator_Optimized intent)
var config bool bFlankManeuver;   // true = while a pod presses, as many of its units per turn as its temperament allows (0-2) move to tiles that flank an enemy (needs bPodIntent)
var config bool bFocusFire;       // true = alien standard shots prefer the target the squad is already working on
var config bool bGrenadiersFirst; // true = within a pod, units holding a grenade act before the others
var config bool bFlankersFirst;   // true = within a pod, units that already flank an enemy act after the grenadiers and before the rest
var config bool bIntentFlyover;   // true = a visible pod member shows a flyover when its pod starts to fall back, hold or assault
var config bool bAdaptiveCounter; // true = the squad's detected habit (adaptive memory) picks among vanilla's move profiles and thresholds
var config bool bSoundPropagation; // true = gunfire and explosions carry farther than vanilla's sound ranges, and aliens hear their own side's fights
var config bool bHiveComms;       // true = while any alien sees XCOM, every member of every pod that sees no soldier is told where each alien turn, and comes
var config bool bRushToAlerts;    // true = a pod that has been told about a fight (yellow alert) dashes toward it until it engages (needs bPodIntent)
var config bool bGuardObjectives; // true = on a defense mission (vanilla hands out Defender jobs), told pods pull back to the mission objective and hold it instead of hunting the squad (needs bRushToAlerts)
var config bool bHonestKnowledge; // true = aliens know only the XCOM units some alien sees right now (a hivemind), not every unit on the map
var config bool bDangerMap;       // true = the hive remembers where the squad shot or killed its aliens and its moves avoid those places (X2ChronoDanger)
var config bool bHiddenApproach;  // true = pods going in together pick pincer points no soldier the hive knows of can see
var config bool bHeightAware;     // true = alien tile searches use vanilla's height-aware twin of their profile (HEIGHT_PROFILES)

// The two switches every measurement depends on, as log lines print them
static function string FormatMode()
{
	return "| mode=" $ (default.bBaselineMode ? "baseline" : "chronocom") @ "index=" $ (default.bUseTurnIndex ? "on" : "off");
}

static function bool PodIntentOn()
{
	return !default.bBaselineMode && default.bPodIntent;
}

static function bool FlankManeuverOn()
{
	return !default.bBaselineMode && default.bFlankManeuver;
}

static function bool FocusFireOn()
{
	return !default.bBaselineMode && default.bFocusFire;
}

static function bool GrenadiersFirstOn()
{
	return !default.bBaselineMode && default.bGrenadiersFirst;
}

static function bool FlankersFirstOn()
{
	return !default.bBaselineMode && default.bFlankersFirst;
}

static function bool IntentFlyoverOn()
{
	return !default.bBaselineMode && default.bIntentFlyover;
}

static function bool AdaptiveCounterOn()
{
	return !default.bBaselineMode && default.bAdaptiveCounter;
}

static function bool HiveCommsOn()
{
	return !default.bBaselineMode && default.bHiveComms;
}

static function bool SoundPropagationOn()
{
	return !default.bBaselineMode && default.bSoundPropagation;
}

static function bool RushToAlertsOn()
{
	return PodIntentOn() && default.bRushToAlerts;
}

static function bool GuardObjectivesOn()
{
	return RushToAlertsOn() && default.bGuardObjectives;
}

static function bool HonestKnowledgeOn()
{
	return !default.bBaselineMode && default.bHonestKnowledge;
}

static function bool DangerMapOn()
{
	return !default.bBaselineMode && default.bDangerMap;
}

static function bool HiddenApproachOn()
{
	return !default.bBaselineMode && default.bHiddenApproach;
}

static function bool HeightAwareOn()
{
	return !default.bBaselineMode && default.bHeightAware;
}

defaultproperties
{
}
