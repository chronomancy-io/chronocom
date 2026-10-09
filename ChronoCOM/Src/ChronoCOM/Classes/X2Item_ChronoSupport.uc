//=============================================================================
// X2Item_ChronoSupport
//
// Retired items. Their templates stay so that saves holding them still load.
//
//  ChronoCommsJammer: retired 2026-10-05, when vanilla's EMP grenade and EMP
//  Bomb took over the jam (X2DownloadableContentInfo_ChronoCOM.AddJamToEMP).
//  No longer a starting item or handed out; a campaign that already holds one
//  can still use it.
//
//  ChronoStrikeUplink: the laser designator, removed 2026-10-06 with its
//  orbital strike. Inert (it grants no ability), and a campaign that holds
//  one loses it on its next strategy load
//  (X2DownloadableContentInfo_ChronoCOM.RemoveDesignators).
//=============================================================================

class X2Item_ChronoSupport extends X2Item config(Game);

const RETIRED_DESIGNATOR = 'ChronoStrikeUplink';

var config int JAMMER_RANGE_TILES;
var config int JAMMER_RADIUS_TILES;

static function array<X2DataTemplate> CreateTemplates()
{
	local array<X2DataTemplate> Items;

	Items.AddItem(CommsJammer());
	Items.AddItem(RetiredDesignator());
	return Items;
}

static function X2DataTemplate CommsJammer()
{
	local X2GrenadeTemplate Template;

	`CREATE_X2TEMPLATE(class'X2GrenadeTemplate', Template, 'ChronoCommsJammer');
	Template.strImage = "img:///UILibrary_StrategyImages.X2InventoryIcons.Inv_Emp_Grenade";
	Template.EquipSound = "StrategyUI_Grenade_Equip";
	Template.AddAbilityIconOverride('ThrowGrenade', "img:///UILibrary_PerkIcons.UIPerk_grenade_emp");
	Template.AddAbilityIconOverride('LaunchGrenade', "img:///UILibrary_PerkIcons.UIPerk_grenade_emp");
	Template.iRange = default.JAMMER_RANGE_TILES;
	Template.iRadius = default.JAMMER_RADIUS_TILES;
	Template.iClipSize = 1;
	Template.iSoundRange = 4;
	Template.iEnvironmentDamage = 0;
	Template.Tier = 0;
	Template.Abilities.AddItem('ThrowGrenade');
	Template.Abilities.AddItem('GrenadeFuse');
	Template.GameArchetype = "WP_Grenade_EMP.WP_Grenade_EMP";
	Template.iPhysicsImpulse = 10;

	Template.StartingItem = false;
	Template.CanBeBuilt = false;
	Template.bInfiniteItem = true;

	Template.ThrownGrenadeEffects.AddItem(class'X2Ability_ChronoSupport'.static.CreateJammedEffect());
	Template.LaunchedGrenadeEffects = Template.ThrownGrenadeEffects;
	Template.SetUIStatMarkup(class'XLocalizedData'.default.RangeLabel, , default.JAMMER_RANGE_TILES);
	Template.SetUIStatMarkup(class'XLocalizedData'.default.RadiusLabel, , default.JAMMER_RADIUS_TILES);
	return Template;
}


static function X2DataTemplate RetiredDesignator()
{
	local X2WeaponTemplate Template;

	`CREATE_X2TEMPLATE(class'X2WeaponTemplate', Template, RETIRED_DESIGNATOR);
	Template.strImage = "img:///UILibrary_StrategyImages.X2InventoryIcons.Inv_Battle_Scanner";
	Template.GameArchetype = "WP_Grenade_BattleScanner.WP_Grenade_BattleScanner";
	Template.ItemCat = 'tech';
	Template.WeaponCat = 'utility';
	Template.WeaponTech = 'conventional';
	Template.InventorySlot = eInvSlot_Utility;
	Template.StowedLocation = eSlot_BeltHolster;
	Template.CanBeBuilt = false;
	Template.bInfiniteItem = true;
	return Template;
}

defaultproperties
{
}
