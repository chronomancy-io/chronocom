//=============================================================================
// X2EventListener_AdaptiveMemory
//
// Two tactical listener templates:
//   - KillMail and AbilityActivated feed X2AdaptiveCollector in the pre-submit
//     window, so each event's counts are written into the campaign's
//     XComGameState_AdaptiveMemory inside the game state that triggered it
//   - TacticalGameEnd folds the mission's counts into the campaign totals in
//     one game state
// Template listeners are re-registered by the ruleset on tactical start and on
// load.
//=============================================================================

class X2EventListener_AdaptiveMemory extends X2EventListener;

static function array<X2DataTemplate> CreateTemplates()
{
	local array<X2DataTemplate> Templates;

	Templates.AddItem(CreateTacticsListener());
	Templates.AddItem(CreateMissionEndListener());

	return Templates;
}

static function X2EventListenerTemplate CreateTacticsListener()
{
	local X2EventListenerTemplate_ChronoPreSubmit Template;

	`CREATE_X2TEMPLATE(class'X2EventListenerTemplate_ChronoPreSubmit', Template, 'ChronoCOM_AdaptiveTactics');

	Template.RegisterInTactical = true;
	Template.AddEvent('KillMail', OnKillMail);
	Template.AddEvent('AbilityActivated', OnAbilityActivated);

	return Template;
}

static function X2EventListenerTemplate CreateMissionEndListener()
{
	local X2EventListenerTemplate Template;

	`CREATE_X2TEMPLATE(class'X2EventListenerTemplate', Template, 'ChronoCOM_AdaptiveMissionEnd');

	Template.RegisterInTactical = true;
	Template.AddEvent('TacticalGameEnd', OnMissionEnd);

	return Template;
}

static function EventListenerReturn OnKillMail(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	class'X2EventListenerTemplate_ChronoCOM'.static.GetCollector().OnKill(XComGameState_Unit(EventData), XComGameState_Unit(EventSource), GameState);

	return ELR_NoInterrupt;
}

static function EventListenerReturn OnAbilityActivated(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	class'X2EventListenerTemplate_ChronoCOM'.static.GetCollector().OnAbilityActivated(XComGameState_Ability(EventData), XComGameState_Unit(EventSource), GameState);

	return ELR_NoInterrupt;
}

static function EventListenerReturn OnMissionEnd(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	local XComGameState_AdaptiveMemory Memory;
	local XComGameState NewGameState;

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("ChronoCOM: Adaptive Memory Mission Update");
	Memory = class'XComGameState_AdaptiveMemory'.static.GetModifiableMemory(NewGameState);
	if (Memory == none)
	{
		`XCOMHISTORY.CleanupPendingGameState(NewGameState);
		`log("ChronoCOM Adaptive: no campaign memory in this mission; nothing was counted");
		return ELR_NoInterrupt;
	}

	Memory.FoldInMission();
	`XCOMGAME.GameRuleset.SubmitGameState(NewGameState);

	return ELR_NoInterrupt;
}

defaultproperties
{
}
