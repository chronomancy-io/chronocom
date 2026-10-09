//=============================================================================
// X2EventListener_ChronoRuntime
//
// Creates ChronoCOM's runtime template (X2EventListenerTemplate_ChronoCOM).
// It listens to no event: it is registered in tactical only so the ruleset's
// registration marks the start of each mission and each load.
//=============================================================================

class X2EventListener_ChronoRuntime extends X2EventListener;

static function array<X2DataTemplate> CreateTemplates()
{
	local array<X2DataTemplate> Templates;

	Templates.AddItem(CreateRuntime());
	return Templates;
}

static function X2EventListenerTemplate CreateRuntime()
{
	local X2EventListenerTemplate_ChronoCOM Template;

	`CREATE_X2TEMPLATE(class'X2EventListenerTemplate_ChronoCOM', Template, class'X2EventListenerTemplate_ChronoCOM'.const.RUNTIME_TEMPLATE);
	Template.RegisterInTactical = true;
	return Template;
}

defaultproperties
{
}
