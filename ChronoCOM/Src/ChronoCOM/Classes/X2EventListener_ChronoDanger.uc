//=============================================================================
// X2EventListener_ChronoDanger
//
// Where the squad hurts the hive, recorded for X2ChronoDanger:
//   - AbilityActivated: a reaction shot by the squad (overwatch, Long Watch,
//     any ability whose hit calculation vanilla marks as reaction fire) at an
//     alien marks the tile the alien stood on, hit or miss
//   - KillMail: an alien killed by the squad marks the tile it died on
// Both run in the pre-submit window (X2EventListenerTemplate_ChronoPreSubmit),
// so each mark is written into the shot's or the death's own game state.
// Template listeners are re-registered by the ruleset on tactical start and
// on load.
//=============================================================================

class X2EventListener_ChronoDanger extends X2EventListener;

static function array<X2DataTemplate> CreateTemplates()
{
	local array<X2DataTemplate> Templates;

	Templates.AddItem(CreateDangerListener());
	return Templates;
}

static function X2EventListenerTemplate CreateDangerListener()
{
	local X2EventListenerTemplate_ChronoPreSubmit Template;

	`CREATE_X2TEMPLATE(class'X2EventListenerTemplate_ChronoPreSubmit', Template, 'ChronoCOM_Danger');
	Template.RegisterInTactical = true;
	Template.AddEvent('AbilityActivated', OnAbilityActivated);
	Template.AddEvent('KillMail', OnKillMail);
	return Template;
}

// AbilityActivated: EventData is the ability state, EventSource the unit
static function EventListenerReturn OnAbilityActivated(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	local XComGameState_Unit Target;

	if (class'X2ChronoConfig'.static.DangerMapOn() && IsSquadReactionShot(XComGameState_Ability(EventData), XComGameState_Unit(EventSource), GameState))
	{
		Target = TargetOf(GameState);
		if (IsHiveUnit(Target))
		{
			class'X2ChronoDanger'.static.Mark(GameState, Target.TileLocation, class'X2ChronoDanger'.default.DANGER_REACTION_WEIGHT, "reaction");
		}
	}

	return ELR_NoInterrupt;
}

// KillMail: EventData is the dead unit, EventSource the killer (may be none)
static function EventListenerReturn OnKillMail(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	local XComGameState_Unit Victim;

	Victim = XComGameState_Unit(EventData);
	if (class'X2ChronoConfig'.static.DangerMapOn() && IsHiveUnit(Victim) && class'X2AdaptiveCollector'.static.IsXComActor(XComGameState_Unit(EventSource)))
	{
		class'X2ChronoDanger'.static.Mark(GameState, Victim.TileLocation, class'X2ChronoDanger'.default.DANGER_DEATH_WEIGHT, "death");
	}

	return ELR_NoInterrupt;
}

// The squad's own reaction fire, counted once: an interrupted ability fires
// the event for the interrupt step and again when it resumes
static function bool IsSquadReactionShot(XComGameState_Ability Ability, XComGameState_Unit Shooter, XComGameState GameState)
{
	return Ability != none && class'X2AdaptiveCollector'.static.IsXComActor(Shooter) && !class'X2AdaptiveCollector'.static.IsInterruptStep(GameState)
		&& class'X2AdaptiveCollector'.static.IsReactionFire(Ability.GetMyTemplateName());
}

// The shot's primary target, where it stood when the shot was taken (a
// reaction shot interrupts the target's move, so its committed state is the
// interrupted step)
static function XComGameState_Unit TargetOf(XComGameState GameState)
{
	local XComGameStateContext_Ability Context;

	Context = XComGameStateContext_Ability(GameState.GetContext());
	return (Context != none) ? XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Context.InputContext.PrimaryTarget.ObjectID)) : none;
}

static function bool IsHiveUnit(XComGameState_Unit Unit)
{
	return Unit != none && Unit.GetTeam() == eTeam_Alien;
}

defaultproperties
{
}
