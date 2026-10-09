//=============================================================================
// X2EventListener_ChronoNoise
//
// Sound carries. Vanilla alerts by sound when an ability is activated: the
// source's enemies within the source weapon's sound range of the sound's
// origin get eAC_DetectedSound (XComGameState_Unit.OnAbilityActivated), which
// puts their pod on yellow alert and sends it to investigate. Four things
// are missing for an enemy that listens for the slightest hint:
//
//   - vanilla's ranges are about the sight range (rifles 27 m, grenades 30 m),
//     so a pod that cannot see the fight rarely hears it
//   - a launched grenade counts as the launcher, whose sound range is 0
//   - aliens never hear their own side's gunfire or grenades
//   - vanilla drops a sound alert for any alien no XCOM unit can see
//     (XComGameState_AIUnitData.AddAlertData), so only pods already on
//     screen ever react to noise
//
// This listener adds the part vanilla leaves out, through vanilla's own alert
// call (X2ChronoComms.Relay, the alert vanilla lets through to unseen units):
//
//   k  sound event (origin tile, loudness in meters), hearer (alien unit)
//   E  loudness = the loud item's own vanilla sound range x a scale: gunfire
//      (the sound is at the shooter) or explosion (the sound is at the
//      impact, vanilla's own flag for it); a silent launcher is as loud as
//      the grenade it fired
//   I  the unit index's spatial cells (X2ChronoIndex.CollectNear)
//   T  every alien in earshot that is not in a fight learns where the sound's
//      source is, enemy or ally, and comes. An alien already in the fight is
//      told only about an enemy the hive cannot see (it knows the others)
//   F  vanilla's own earshot test (distance against range plus the hearer's
//      hearing radius); units with AI data, never a Chosen
//
// Work per sound-making ability activation: the cells of the window around
// the sound (at most a few dozen) plus the aliens standing in them.
//=============================================================================

class X2EventListener_ChronoNoise extends X2EventListener config(Game);

var config float GUNFIRE_SOUND_SCALE;    // how much farther than vanilla a sound made at the shooter carries
var config float EXPLOSION_SOUND_SCALE;  // how much farther than vanilla a sound made at the impact carries

static function array<X2DataTemplate> CreateTemplates()
{
	local array<X2DataTemplate> Templates;

	Templates.AddItem(CreateNoiseListener());

	return Templates;
}

static function X2EventListenerTemplate CreateNoiseListener()
{
	local X2EventListenerTemplate Template;

	`CREATE_X2TEMPLATE(class'X2EventListenerTemplate', Template, 'ChronoCOM_Noise');

	Template.RegisterInTactical = true;
	Template.AddEvent('AbilityActivated', OnAbilityActivated);

	return Template;
}

// AbilityActivated: EventData is the ability state, EventSource the unit
static function EventListenerReturn OnAbilityActivated(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	local XComGameState_Ability Ability;
	local XComGameStateContext_Ability Context;

	Ability = XComGameState_Ability(EventData);
	Context = XComGameStateContext_Ability(GameState.GetContext());
	if (MakesNoise(Ability, Context))
	{
		Propagate(XComGameState_Unit(EventSource), Ability, Context, GameState);
	}
	LogAlertChange(Ability, XComGameState_Unit(EventSource), Context);

	return ELR_NoInterrupt;
}

// Vanilla raises an alien's alert level through its YellowAlert and RedAlert
// abilities and stores the cause in the context, so one line per activation
// says why each unit went yellow or red (the cause is logged by name)
static function LogAlertChange(XComGameState_Ability Ability, XComGameState_Unit Unit, XComGameStateContext_Ability Context)
{
	if (Unit == none || !IsAlertActivation(Ability, Context))
	{
		return;
	}

	`log("ChronoCOM Alert: turn=" $ class'X2ChronoIndex'.static.GetIndex().GetAlienTurn() @ "unit=" $ Unit.ObjectID @ "template=" $ Unit.GetMyTemplateName()
		@ "level=" $ Ability.GetMyTemplateName() @ "cause=" $ EAlertCause(Context.ResultContext.iCustomAbilityData) @ "tile=" $ Unit.TileLocation.X $ "," $ Unit.TileLocation.Y,
		class'X2ChronoMetrics'.static.Get().IsOn());
}

static function bool IsAlertActivation(XComGameState_Ability Ability, XComGameStateContext_Ability Context)
{
	return Ability != none && Context != none && IsAlertAbility(Ability.GetMyTemplateName());
}

static function bool IsAlertAbility(name AbilityName)
{
	return AbilityName == 'YellowAlert' || AbilityName == 'RedAlert';
}

static function bool MakesNoise(XComGameState_Ability Ability, XComGameStateContext_Ability Context)
{
	return class'X2ChronoConfig'.static.SoundPropagationOn() && IsCompletedActivation(Ability, Context) && Ability.DoesAbilityCauseSound();
}

// The interrupt step of an ability is not the ability happening
static function bool IsCompletedActivation(XComGameState_Ability Ability, XComGameStateContext_Ability Context)
{
	return Ability != none && Context != none && Context.InterruptionStatus != eInterruptionStatus_Interrupt;
}

static function Propagate(XComGameState_Unit Source, XComGameState_Ability Ability, XComGameStateContext_Ability Context, XComGameState GameState)
{
	local XComGameState_Item Item;
	local int HeardMeters;

	Item = LoudItem(Ability);
	if (Source == none || Item == none)
	{
		return;
	}

	HeardMeters = Round(Item.GetItemSoundRange() * SoundScale(Item));
	if (HeardMeters > 0)
	{
		AlertHearers(Source, GameState, SoundOrigin(Source, Item, Context), HeardMeters);
	}
}

// The item whose sound range counts: the weapon, or the ammo it fired when the
// weapon itself is silent (a grenade launcher's range is 0)
static function XComGameState_Item LoudItem(XComGameState_Ability Ability)
{
	local XComGameState_Item Weapon, Ammo;

	Weapon = Ability.GetSourceWeapon();
	Ammo = Ability.GetSourceAmmo();
	if (Weapon != none && Weapon.GetItemSoundRange() > 0)
	{
		return Weapon;
	}

	return (Ammo != none) ? Ammo : Weapon;
}

// Vanilla marks a weapon whose sound is made where it lands
static function float SoundScale(XComGameState_Item Item)
{
	return Item.SoundOriginatesFromOwnerLocation() ? default.GUNFIRE_SOUND_SCALE : default.EXPLOSION_SOUND_SCALE;
}

// Where the sound is, as vanilla places it: the impact for a weapon that says
// so, else the source unit
static function TTile SoundOrigin(XComGameState_Unit Source, XComGameState_Item Item, XComGameStateContext_Ability Context)
{
	local TTile Tile;
	local vector Impact;

	if (!Item.SoundOriginatesFromOwnerLocation() && Context.InputContext.TargetLocations.Length > 0)
	{
		Impact = Context.InputContext.TargetLocations[0];
		return `XWORLD.GetTileCoordinatesFromPosition(Impact);
	}

	Source.GetKeystoneVisibilityLocation(Tile);
	return Tile;
}

// Every living alien that hears the sound is told where the source is (the
// alert data records the source's position). The candidates are the aliens in
// the unit index's spatial cells around the sound, out to its range plus the
// largest hearing radius any unit has: a superset of the hearers, never the
// whole team.
static function AlertHearers(XComGameState_Unit Source, XComGameState GameState, TTile Origin, int HeardRange)
{
	local X2ChronoIndex Index;
	local array<int> AlienIDs;
	local XComGameState_Unit Hearer;
	local vector Center;
	local bool bSourceSeen;
	local int i, Enemies, Allies;

	Index = class'X2ChronoComms'.static.SightIndex();
	bSourceSeen = Index.HiveSees(Source.ObjectID);
	Index.CollectNear(Origin, `METERSTOUNITS(HeardRange) + Index.MaxHearing, eTeam_Alien, AlienIDs);
	Center = `XWORLD.GetPositionFromTileCoordinates(Origin);
	for (i = 0; i < AlienIDs.Length; ++i)
	{
		Hearer = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(AlienIDs[i]));
		if (Hears(Hearer, Source, bSourceSeen) && WithinEarshot(Hearer, Center, HeardRange))
		{
			class'X2ChronoComms'.static.Relay(Hearer, Source, GameState);
			Enemies += int(Hearer.IsEnemyUnit(Source));
			Allies += int(!Hearer.IsEnemyUnit(Source));
		}
	}

	class'X2ChronoMetrics'.static.Get().NoteNoise(AlienIDs.Length, Enemies, Allies);
}

static function bool Hears(XComGameState_Unit Hearer, XComGameState_Unit Source, bool bSourceSeen)
{
	return class'X2ChronoComms'.static.CanBeTold(Hearer) && Hearer.ObjectID != Source.ObjectID && ListensTo(Hearer, Source, bSourceSeen);
}

// A unit that is not in the fight comes to any sound of fighting, an enemy's
// or an ally's. A unit already in the fight only needs an enemy's sound when
// the hive cannot see that enemy (otherwise it already knows where it is).
static function bool ListensTo(XComGameState_Unit Hearer, XComGameState_Unit Source, bool bSourceSeen)
{
	if (class'X2ChronoComms'.static.IsOutOfTheFight(Hearer))
	{
		return Hearer.IsEnemyUnit(Source) || Hearer.IsFriendlyUnit(Source);
	}

	return Hearer.IsEnemyUnit(Source) && !bSourceSeen;
}

// Vanilla's earshot test (XComGameState_Unit.GetEnemiesInRange): the distance
// against the sound's range plus the hearer's own hearing radius
static function bool WithinEarshot(XComGameState_Unit Hearer, vector Center, int Meters)
{
	local float Radius;

	if (Meters <= 0)
	{
		return false;
	}

	Radius = `METERSTOUNITS(Meters) + Hearer.GetCurrentStat(eStat_HearingRadius);
	return VSizeSq(`XWORLD.GetPositionFromTileCoordinates(Hearer.TileLocation) - Center) < Square(Radius);
}

defaultproperties
{
}
