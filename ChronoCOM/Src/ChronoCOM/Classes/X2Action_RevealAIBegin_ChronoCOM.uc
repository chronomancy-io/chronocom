//=============================================================================
// X2Action_RevealAIBegin_ChronoCOM
//
// Replaces X2Action_RevealAIBegin through ModClassOverride (the visualizer
// spawns reveal actions by class, X2Action.CreateVisualizationActionClass).
//
// The mission's first Lost reveal plays exactly as vanilla. Every later Lost
// reveal in the same mission skips the reveal matinee (ShouldPlayRevealMatinee
// refuses it); everything else, including the swarm tracking camera, stays
// vanilla. WantsToPlayTheLostCamera is deliberately not overridden:
// XComGameState_AIGroup.MergeGroupMoveVisualization asks it to decide how
// the group move's camera nodes are built, and must see vanilla's answer.
// Reveals of every other team are untouched.
//
// "First" counts Lost reveal actions this mission, on ChronoCOM's runtime
// template; loading a save starts the count over, so the first reveal after a
// load plays.
//=============================================================================

class X2Action_RevealAIBegin_ChronoCOM extends X2Action_RevealAIBegin;

var bool bChronoTrimmed;

function Init()
{
	super.Init();

	if (TrimsLostReveals() && IsLostReveal())
	{
		NoteLostReveal();
	}
}

static function bool TrimsLostReveals()
{
	return !class'X2ChronoConfig'.default.bBaselineMode && class'X2ChronoConfig'.default.bLostRevealOnlyFirst;
}

function bool IsLostReveal()
{
	local XComGameState_AIGroup Group;

	Group = GetRevealedGroup();
	return Group != none && Group.TeamName == eTeam_TheLost;
}

// Counts this Lost reveal; every one after the mission's first is trimmed
function NoteLostReveal()
{
	local int Seen;

	Seen = class'X2EventListenerTemplate_ChronoCOM'.static.CountLostReveal();
	if (Seen > 1)
	{
		bChronoTrimmed = true;
		`log("ChronoCOM: Lost reveal" @ Seen @ "trimmed (no reveal matinee); the mission's first was shown", class'X2ChronoMetrics'.static.Get().IsOn());
	}
}

simulated state Executing
{
	function bool ShouldPlayRevealMatinee()
	{
		if (bChronoTrimmed)
		{
			return false;
		}

		return super.ShouldPlayRevealMatinee();
	}
}

defaultproperties
{
}
