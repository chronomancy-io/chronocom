// XComGameState_TacticalInfluenceManager
// The mission's pod records, one game-state object per mission, saved with it.
// (The name is historical: until 2026-10-06 it also held four influence
// fields, written every alien turn and read only on a path ordinary alien
// trees never take; they were removed with X2TacticalInfluence_Optimized.)

class XComGameState_TacticalInfluenceManager extends XComGameState_BaseObject;

// Pod coordination state
var array<X2DownloadableContentInfo_ChronoCOM.PodData> MissionPods;

// Where the squad has hurt the hive on this map: one mark per reaction shot at
// an alien and per alien killed (X2EventListener_ChronoDanger), written inside
// the game state of the shot or the death, so the marks are history and a
// save carries them; X2ChronoDanger folds them into the map the aliens read.
// The last DANGER_RING marks are kept in a ring, so this object, which the
// game copies whole whenever it changes, stays the same size all mission. A
// mark matters for DANGER_TURNS alien turns; one pushed out sooner (more than
// DANGER_RING marks in that time) is forgotten early.
const DANGER_RING = 64;
struct DangerMark
{
	var int Cell;        // X2ChronoDanger.CellOf the alien's tile
	var int AlienTurn;   // the alien turn it happened in
	var int Weight;      // DANGER_REACTION_WEIGHT or DANGER_DEATH_WEIGHT
};
var DangerMark DangerMarks[DANGER_RING];
var int DangerMarkCount;    // marks written on this map; the newest is at (DangerMarkCount - 1) % DANGER_RING

// The mission's manager, through the history's native per-class lookup
static function XComGameState_TacticalInfluenceManager GetManager()
{
	return XComGameState_TacticalInfluenceManager(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_TacticalInfluenceManager', true));
}

// Create new manager instance in a game state
static function XComGameState_TacticalInfluenceManager CreateManager(XComGameState NewGameState)
{
	local XComGameState_TacticalInfluenceManager Manager;
	
	Manager = XComGameState_TacticalInfluenceManager(NewGameState.CreateNewStateObject(class'XComGameState_TacticalInfluenceManager'));
	
	return Manager;
}

// A mission that continues on another map (a tactical transfer) carries the
// previous map's manager along, and every manager in the history registers for
// the alien turn. The carried one is reused, emptied, so the mission keeps one.
static function XComGameState_TacticalInfluenceManager CreateOrReuseManager(XComGameState StartState)
{
	local XComGameState_TacticalInfluenceManager Manager;

	foreach StartState.IterateByClassType(class'XComGameState_TacticalInfluenceManager', Manager)
	{
		Manager.ResetForNewMap();
		return Manager;
	}

	return CreateManager(StartState);
}

// The pods and the danger marks describe the previous map
function ResetForNewMap()
{
	MissionPods.Length = 0;
	DangerMarkCount = 0;
}

// Writes a mark over the oldest once the ring is full
function AddDangerMark(DangerMark NewMark)
{
	DangerMarks[DangerMarkCount % DANGER_RING] = NewMark;
	DangerMarkCount++;
}

// Get modifiable copy in a new game state
static function XComGameState_TacticalInfluenceManager GetModifiableManager(XComGameState NewGameState)
{
	local XComGameState_TacticalInfluenceManager Manager, ModifiableManager;
	
	Manager = GetManager();
	
	if (Manager != none)
	{
		ModifiableManager = XComGameState_TacticalInfluenceManager(NewGameState.ModifyStateObject(class'XComGameState_TacticalInfluenceManager', Manager.ObjectID));
		return ModifiableManager;
	}
	
	return none;
}

// Called when tactical play begins - register for events
function OnBeginTacticalPlay(XComGameState NewGameState)
{
	local X2EventManager EventManager;
	local Object ThisObj;
	
	super.OnBeginTacticalPlay(NewGameState);
	
	ThisObj = self;
	EventManager = `XEVENTMGR;
	
	// Register for PlayerTurnBegun to track alien turns
	EventManager.RegisterForEvent(ThisObj, 'PlayerTurnBegun', class'X2DownloadableContentInfo_ChronoCOM'.static.OnPlayerTurnBegun, ELD_OnStateSubmitted);

	`log("ChronoCOM: TacticalInfluenceManager registered for PlayerTurnBegun events in OnBeginTacticalPlay");
}

defaultproperties
{
}

