//=============================================================================
// X2Ability_ChronoSupport
//
// ChronoJammed, the squad's answer to the hive's comms. Vanilla's EMP grenade
// and EMP Bomb carry it (X2DownloadableContentInfo_ChronoCOM.AddJamToEMP), as
// does the retired comms jammer (X2Item_ChronoSupport). A jammed alien cannot
// be told anything by the hive, and what it sees does not reach the hive; it
// knows only what it sees itself (X2ChronoComms.IsJammed).
//=============================================================================

class X2Ability_ChronoSupport extends X2Ability config(Game);

const JAMMED_EFFECT = 'ChronoJammed';

var config int JAM_TURNS;                       // the jam lasts until the start of the squad's turn this many turns on

var localized string JammedName;
var localized string JammedDesc;

//-----------------------------------------------------------------------------
// The jam
//-----------------------------------------------------------------------------

static function X2Effect_Persistent CreateJammedEffect()
{
	local X2Effect_Persistent Jammed;
	local X2Condition_UnitProperty Enemies;

	Jammed = new class'X2Effect_Persistent';
	Jammed.EffectName = JAMMED_EFFECT;
	Jammed.DuplicateResponse = eDupe_Refresh;
	Jammed.BuildPersistentEffect(default.JAM_TURNS, false, false, false, eGameRule_PlayerTurnBegin);
	Jammed.SetDisplayInfo(ePerkBuff_Penalty, default.JammedName, default.JammedDesc, "img:///UILibrary_PerkIcons.UIPerk_grenade_emp", true);

	Enemies = new class'X2Condition_UnitProperty';
	Enemies.ExcludeFriendlyToSource = true;
	Enemies.ExcludeDead = true;
	Jammed.TargetConditions.AddItem(Enemies);
	return Jammed;
}

defaultproperties
{
}
