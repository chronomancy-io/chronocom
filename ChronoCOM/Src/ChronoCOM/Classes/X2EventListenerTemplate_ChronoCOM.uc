//=============================================================================
// X2EventListenerTemplate_ChronoCOM
//
// ChronoCOM's runtime template: the home of its session objects (the unit
// index, the fire plan, the danger map, the adaptive collector and the
// registered metrics) and of its mission state. The template manager keeps
// templates alive for the whole session and finds them through a native name
// map, so this is a persistent, O(1) home. (UnrealScript cannot hold an object in a class
// default: only config properties may be assigned there, and config
// properties may not be objects.)
//
// Mission state starts over in RegisterForEvents: the ruleset registers the
// tactical listeners when a mission is created and when a save is loaded into
// tactical (X2TacticalGameRuleset CreateTacticalGame, LoadTacticalGame,
// CreateChallengeGame), and nowhere else for a tactical-only template.
//=============================================================================

class X2EventListenerTemplate_ChronoCOM extends X2EventListenerTemplate;

const RUNTIME_TEMPLATE = 'ChronoCOM_Runtime';

var private X2ChronoIndex Index;
var private X2ChronoMetrics Metrics;
var private X2AdaptiveCollector Collector;
var private X2ChronoFirePlan FirePlan;
var private X2ChronoDanger Danger;
var private int LostRevealsSeen;   // Lost reveal actions this mission (X2Action_RevealAIBegin_ChronoCOM)

static function X2EventListenerTemplate_ChronoCOM GetRuntime()
{
	return X2EventListenerTemplate_ChronoCOM(class'X2EventListenerTemplateManager'.static.GetEventListenerTemplateManager().FindEventListenerTemplate(RUNTIME_TEMPLATE));
}

// A mission starts, or a save is loaded into one: turn numbers and ObjectIDs
// recorded before mean nothing now
function RegisterForEvents()
{
	super.RegisterForEvents();
	GetFirePlan().Reset();
	GetDanger().Reset();
	LostRevealsSeen = 0;
}

// The session's collector; a throwaway when templates are not created yet
static function X2AdaptiveCollector GetCollector()
{
	local X2EventListenerTemplate_ChronoCOM Runtime;

	Runtime = GetRuntime();
	if (Runtime == none)
	{
		return new class'X2AdaptiveCollector';
	}

	if (Runtime.Collector == none)
	{
		Runtime.Collector = new class'X2AdaptiveCollector';
	}

	return Runtime.Collector;
}

// Counts one Lost reveal; returns how many this mission has had
static function int CountLostReveal()
{
	local X2EventListenerTemplate_ChronoCOM Runtime;

	Runtime = GetRuntime();
	return (Runtime != none) ? ++Runtime.LostRevealsSeen : 1;
}

// The registered telemetry, or a null X2ChronoMetrics
function X2ChronoMetrics GetMetrics()
{
	if (Metrics == none)
	{
		Metrics = new class'X2ChronoMetrics';
	}

	return Metrics;
}

function SetMetrics(X2ChronoMetrics Sink)
{
	Metrics = Sink;
}

function X2ChronoFirePlan GetFirePlan()
{
	if (FirePlan == none)
	{
		FirePlan = new class'X2ChronoFirePlan';
	}

	return FirePlan;
}

function X2ChronoDanger GetDanger()
{
	if (Danger == none)
	{
		Danger = new class'X2ChronoDanger';
	}

	return Danger;
}

function X2ChronoIndex GetIndex()
{
	if (Index == none)
	{
		Index = new class'X2ChronoIndex';
	}

	return Index;
}

defaultproperties
{
}
