//=============================================================================
// X2AdaptiveCollector
//
// Counts XCOM's tactics from real events:
//   KillMail          -> range, height, flanking, reaction fire, explosive
//   AbilityActivated  -> shots, overwatch activations, grenade activations
//
// Each event is counted in the pre-submit window and its counts are added to
// XComGameState_AdaptiveMemory.InProgress inside the game state that triggered
// the event. The mission's running counts are therefore history: a save holds
// exactly the events of the frames it holds, and a state that is never
// submitted is never counted. This object keeps nothing between events (Delta
// is the scratch for the event being handled).
//=============================================================================

class X2AdaptiveCollector extends Object config(Game) dependson(XComGameState_AdaptiveMemory);

var config array<name> OverwatchAbilityNames;      // activations that count as overwatch use
var config array<name> GrenadeAbilityNames;        // activations that count as grenade use
var config array<name> ExplosiveWeaponCategories;  // kills with these weapon categories count as explosive
var config bool bCountLostKills;                   // count kills of The Lost (off: alien team only)

var XComGameState_AdaptiveMemory.MissionTactics Delta;

function ClearDelta()
{
	local XComGameState_AdaptiveMemory.MissionTactics Empty;

	Delta = Empty;
}

// Adds the event's counts to the campaign memory in the event's own game
// state, which is still pending. An event that counted nothing leaves the
// state alone.
function Commit(XComGameState GameState)
{
	local XComGameState_AdaptiveMemory Memory;

	if (!HasCounts())
		return;

	Memory = class'XComGameState_AdaptiveMemory'.static.GetModifiableMemory(GameState);
	if (Memory != none)
		Memory.AddToMission(Delta);
}

// A kill event always counts a kill; an activation counts at least one of the others
function bool HasCounts()
{
	return Delta.Kills + Delta.Shots + Delta.OverwatchActivations + Delta.GrenadeActivations > 0;
}

//-----------------------------------------------------------------------------
// Who counts
//-----------------------------------------------------------------------------

// A real XCOM unit (cosmetic units such as gremlins act through their owner)
static function bool IsXComActor(XComGameState_Unit Unit)
{
	return Unit != none && Unit.GetTeam() == eTeam_XCom && !Unit.GetMyTemplate().bIsCosmetic;
}

function bool IsCountedVictim(XComGameState_Unit Victim)
{
	return Victim != none && (Victim.GetTeam() == eTeam_Alien || IsCountedLost(Victim));
}

function bool IsCountedLost(XComGameState_Unit Victim)
{
	return bCountLostKills && Victim.GetTeam() == eTeam_TheLost;
}

//-----------------------------------------------------------------------------
// Kills
//-----------------------------------------------------------------------------

// KillMail: EventData is the dead unit, EventSource the killer (may be none)
function OnKill(XComGameState_Unit Victim, XComGameState_Unit Killer, XComGameState GameState)
{
	local int Distance, HeightDiff;
	local bool bFlank;

	if (!IsXComActor(Killer) || !IsCountedVictim(Victim))
		return;

	ClearDelta();
	Delta.Kills++;
	bFlank = CountKillGeometry(Victim, Killer, Distance, HeightDiff);
	CountKillAbility(XComGameStateContext_Ability(GameState.GetContext()), Killer, Distance, HeightDiff, bFlank);
	Commit(GameState);
}

// Range bracket, height bracket and flanking; returns whether the kill was a flank
function bool CountKillGeometry(XComGameState_Unit Victim, XComGameState_Unit Killer, out int Distance, out int HeightDiff)
{
	local bool bFlank;

	Distance = Killer.TileDistanceBetween(Victim);
	HeightDiff = Killer.TileLocation.Z - Victim.TileLocation.Z;
	CountRange(Distance);
	CountHeight(HeightDiff);

	bFlank = IsFlankKill(Victim, Killer);
	Delta.FlankKills += int(bFlank);
	return bFlank;
}

function CountRange(int Distance)
{
	if (Distance <= class'XComGameState_AdaptiveMemory'.default.CloseRangeMaxTiles)
		Delta.CloseKills++;
	else if (Distance <= class'XComGameState_AdaptiveMemory'.default.MediumRangeMaxTiles)
		Delta.MediumKills++;
	else
		Delta.LongKills++;
}

function CountHeight(int HeightDiff)
{
	local int HighGroundZ;

	HighGroundZ = class'XComGameState_AdaptiveMemory'.default.HighGroundTileZ;
	if (HeightDiff >= HighGroundZ)
		Delta.HighGroundKills++;
	else if (HeightDiff <= -HighGroundZ)
		Delta.LowGroundKills++;
	else
		Delta.LevelKills++;
}

// The same flanking test the hit calculation uses
static function bool IsFlankKill(XComGameState_Unit Victim, XComGameState_Unit Killer)
{
	local GameRulesCache_VisibilityInfo VisInfo;

	return Killer.CanFlank() && Victim.GetMyTemplate().bCanTakeCover
		&& `TACTICALRULES.VisibilityMgr.GetVisibilityInfo(Killer.ObjectID, Victim.ObjectID, VisInfo)
		&& VisInfo.TargetCover == CT_None;
}

// The killing ability, from the context that submitted the kill's state
function CountKillAbility(XComGameStateContext_Ability AbilityContext, XComGameState_Unit Killer, int Distance, int HeightDiff, bool bFlank)
{
	local name AbilityName;

	if (AbilityContext == none)
		return;

	AbilityName = AbilityContext.InputContext.AbilityTemplateName;
	Delta.ReactionKills += int(IsReactionFire(AbilityName));
	Delta.ExplosiveKills += int(IsExplosive(AbilityName, AbilityContext.InputContext.ItemObject));

	`log("ChronoCOM Adaptive: kill by" @ Killer.GetFullName() @ "at" @ Distance @ "tiles, dz=" $ HeightDiff
		@ "flank=" $ bFlank @ "ability=" $ AbilityName, `CHRONO_VERBOSE);
}

static function bool IsReactionFire(name AbilityName)
{
	local X2AbilityTemplate AbilityTemplate;
	local X2AbilityToHitCalc_StandardAim StandardAim;

	AbilityTemplate = class'X2AbilityTemplateManager'.static.GetAbilityTemplateManager().FindAbilityTemplate(AbilityName);
	if (AbilityTemplate == none)
		return false;

	StandardAim = X2AbilityToHitCalc_StandardAim(AbilityTemplate.AbilityToHitCalc);
	return StandardAim != none && StandardAim.bReactionFire;
}

function bool IsExplosive(name AbilityName, StateObjectReference ItemRef)
{
	local XComGameState_Item Item;

	Item = XComGameState_Item(`XCOMHISTORY.GetGameStateForObjectID(ItemRef.ObjectID));
	return IsGrenadeUse(AbilityName, Item) || IsExplosiveWeapon(Item);
}

function bool IsGrenadeUse(name AbilityName, XComGameState_Item Item)
{
	return GrenadeAbilityNames.Find(AbilityName) != INDEX_NONE || IsGrenadeItem(Item);
}

static function bool IsGrenadeItem(XComGameState_Item Item)
{
	return Item != none && X2GrenadeTemplate(Item.GetMyTemplate()) != none;
}

function bool IsExplosiveWeapon(XComGameState_Item Item)
{
	local X2WeaponTemplate WeaponTemplate;

	if (Item == none)
		return false;

	WeaponTemplate = X2WeaponTemplate(Item.GetMyTemplate());
	return WeaponTemplate != none && ExplosiveWeaponCategories.Find(WeaponTemplate.WeaponCat) != INDEX_NONE;
}

//-----------------------------------------------------------------------------
// Ability activations
//-----------------------------------------------------------------------------

// AbilityActivated: EventData is the ability state, EventSource the unit
function OnAbilityActivated(XComGameState_Ability AbilityState, XComGameState_Unit SourceUnit, XComGameState GameState)
{
	local X2AbilityTemplate AbilityTemplate;

	if (!IsCountedActivation(AbilityState, SourceUnit, GameState))
		return;

	AbilityTemplate = AbilityState.GetMyTemplate();
	if (AbilityTemplate != none)
	{
		ClearDelta();
		CountActivation(AbilityTemplate, AbilityState.GetSourceWeapon());
		Commit(GameState);
	}
}

// XCOM's own activations, counted once: an interrupted ability fires the event
// for the interrupt step and again when it resumes
function bool IsCountedActivation(XComGameState_Ability AbilityState, XComGameState_Unit SourceUnit, XComGameState GameState)
{
	return AbilityState != none && IsXComActor(SourceUnit) && !IsInterruptStep(GameState);
}

static function bool IsInterruptStep(XComGameState GameState)
{
	local XComGameStateContext_Ability AbilityContext;

	AbilityContext = XComGameStateContext_Ability(GameState.GetContext());
	return AbilityContext != none && AbilityContext.InterruptionStatus == eInterruptionStatus_Interrupt;
}

function CountActivation(X2AbilityTemplate AbilityTemplate, XComGameState_Item Weapon)
{
	Delta.Shots += int(AbilityTemplate.Hostility == eHostility_Offensive);
	Delta.OverwatchActivations += int(OverwatchAbilityNames.Find(AbilityTemplate.DataName) != INDEX_NONE);
	Delta.GrenadeActivations += int(IsGrenadeUse(AbilityTemplate.DataName, Weapon));
}

// Config values live in XComGame.ini [ChronoCOM.X2AdaptiveCollector]
defaultproperties
{
}
