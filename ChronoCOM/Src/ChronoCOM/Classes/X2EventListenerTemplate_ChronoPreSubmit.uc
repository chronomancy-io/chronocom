//=============================================================================
// X2EventListenerTemplate_ChronoPreSubmit
//
// A listener template whose callbacks run in the ELD_PreStateSubmitted window:
// immediately before the game state that triggered the event is added to the
// history, while a listener may still add to that state (X2EventManager).
// Vanilla's template registers every callback in ELD_OnStateSubmitted, after
// the state is final. Vanilla uses the pre-submit window the same way for
// AbilityActivated (XComGameState_Unit.PreAbilityActivated).
//=============================================================================

class X2EventListenerTemplate_ChronoPreSubmit extends X2EventListenerTemplate;

function RegisterForEvents()
{
	local X2EventManager EventManager;
	local X2EventListenerTemplate_EventCallbackPair EventPair;
	local Object selfObject;

	EventManager = `XEVENTMGR;
	selfObject = self;

	foreach EventsToRegister(EventPair)
	{
		EventManager.RegisterForEvent(selfObject, EventPair.EventName, EventPair.Callback, ELD_PreStateSubmitted);
	}
}

defaultproperties
{
}
