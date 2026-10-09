//=============================================================================
// XGAIPlayer_ChronoCOM
//
// Replaces XGAIPlayer (the alien player) through ModClassOverride.
//
// Vanilla orders a pod's units by their character template's AIOrderPriority
// and nothing else (XGAIPlayer.GatherUnitsToMove carries the note "TODO: Sort
// units to move here"); every alien template has the same priority, so the
// order is the group's member order. Here the pod acts in four ranks:
//
//   1. an assaulting pod's bait, so it draws the overwatch before the others
//      go in
//   2. units that hold a grenade, so a grenade that strips cover lands before
//      the pod's shots, not after them
//   3. units that already flank an enemy: they have the pod's best shots, and
//      the target they shoot is the one the rest then pile onto (focus fire)
//   4. everyone else
//
// The order within a rank is vanilla's.
//
// Work: one pass over the pod's units to move (at most a pod); per unit one
// pod-record probe, two history lookups and one query of the engine's
// visibility cache.
//=============================================================================

class XGAIPlayer_ChronoCOM extends XGAIPlayer dependson(X2DownloadableContentInfo_ChronoCOM);

const GRENADE_ABILITY = 'ThrowGrenade';

simulated function GatherUnitsToMove()
{
	super.GatherUnitsToMove();

	if (ReordersUnits())
	{
		OrderByRank();
	}
}

// Only the sequential (red alert) phase: patrols and scampers keep their order
function bool ReordersUnits()
{
	return m_ePhase == eAAP_SequentialMovement && UnitsToMove.Length > 1 && RanksUnits();
}

static function bool RanksUnits()
{
	return class'X2ChronoConfig'.static.GrenadiersFirstOn() || class'X2ChronoConfig'.static.FlankersFirstOn() || class'X2ChronoConfig'.static.PodIntentOn();
}

// Stable four-way partition: an assaulting pod's bait, then grenadiers, then
// units already flanking, then the rest
function OrderByRank()
{
	local array<GameRulesCache_Unit> Baits, Grenadiers, Flankers, Others;
	local int i;

	for (i = 0; i < UnitsToMove.Length; ++i)
	{
		AddByRank(UnitsToMove[i], Baits, Grenadiers, Flankers, Others);
	}

	UnitsToMove = Baits;
	Append(Grenadiers);
	Append(Flankers);
	Append(Others);
}

function AddByRank(GameRulesCache_Unit Unit, out array<GameRulesCache_Unit> Baits, out array<GameRulesCache_Unit> Grenadiers, out array<GameRulesCache_Unit> Flankers, out array<GameRulesCache_Unit> Others)
{
	if (LeadsAsBait(Unit.UnitObjectRef.ObjectID))
	{
		Baits.AddItem(Unit);
	}
	else if (LeadsAsGrenadier(Unit.UnitObjectRef.ObjectID))
	{
		Grenadiers.AddItem(Unit);
	}
	else if (LeadsAsFlanker(Unit.UnitObjectRef.ObjectID))
	{
		Flankers.AddItem(Unit);
	}
	else
	{
		Others.AddItem(Unit);
	}
}

function Append(const out array<GameRulesCache_Unit> Units)
{
	local int i;

	for (i = 0; i < Units.Length; ++i)
	{
		UnitsToMove.AddItem(Units[i]);
	}
}

// The unit's pod assaults this turn and the unit is its bait (one fetch of the
// pod record)
static function bool LeadsAsBait(int UnitID)
{
	local X2DownloadableContentInfo_ChronoCOM.PodData Pod;
	local int PodIdx;

	return class'X2PodCoordinator_Optimized'.static.GetPodOfUnit(UnitID, Pod, PodIdx) && Pod.Intent == ePodIntent_Assault && Pod.BaitUnitID == UnitID;
}

static function bool LeadsAsGrenadier(int UnitID)
{
	return class'X2ChronoConfig'.static.GrenadiersFirstOn() && HoldsGrenade(UnitID);
}

// The unit sees an enemy that takes cover and has none against it (the
// engine's own flanking query)
static function bool LeadsAsFlanker(int UnitID)
{
	return class'X2ChronoConfig'.static.FlankersFirstOn()
		&& class'X2TacticalVisibilityHelpers'.static.GetNumEnemiesFlankedBySource(UnitID) > 0;
}

// The unit has the grenade ability and its grenade item still has a charge
static function bool HoldsGrenade(int UnitID)
{
	local XComGameState_Ability Ability;
	local XComGameState_Item Grenade;

	Ability = GrenadeAbilityOf(UnitID);
	if (Ability == none)
	{
		return false;
	}

	Grenade = Ability.GetSourceWeapon();
	return Grenade != none && Grenade.Ammo > 0;
}

static function XComGameState_Ability GrenadeAbilityOf(int UnitID)
{
	local XComGameState_Unit Unit;
	local StateObjectReference AbilityRef;

	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitID));
	if (Unit != none)
	{
		AbilityRef = Unit.FindAbility(GRENADE_ABILITY);
	}
	if (AbilityRef.ObjectID <= 0)
	{
		return none;
	}

	return XComGameState_Ability(`XCOMHISTORY.GetGameStateForObjectID(AbilityRef.ObjectID));
}

defaultproperties
{
}
