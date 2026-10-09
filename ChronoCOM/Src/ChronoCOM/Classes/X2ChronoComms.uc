//=============================================================================
// X2ChronoComms
//
// The aliens are a hivemind with instant comms: what one of them sees, all of
// them know, and what one of them learns, the others are told.
//
//   k  XCOM unit (ObjectID), alien unit (ObjectID), history frame / alien turn
//   E  XCOM unit -> "some living unit of the alien player has it in gameplay
//      sight", from the engine's visibility cache
//   I  the unit index: its XCOM team list (one engine "who sees this unit"
//      query per living XCOM unit, once per committed frame, kept as an
//      epoch-stamped set), and the pod records
//   T  HiveSees: is this XCOM unit seen by the hive now (known enemies,
//      XGAIBehavior_ChronoCOM). ReportContacts: once per alien turn, every
//      member of every pod that sees no soldier is told where the nearest
//      sighted XCOM unit is, whatever its alert level. Relay: the delivery,
//      also used for sounds (X2EventListener_ChronoNoise)
//   F  only units with AI data, never a Chosen (their activation is their own
//      system), never a jammed unit
//
// The delivery is vanilla's own alert call with vanilla's comm-link cause
// (eAC_AlertedByCommLink). Vanilla drops every other indirect cause (sound,
// yell) for an alien no XCOM unit can see
// (XComGameState_AIUnitData.AddAlertData), which is why vanilla pods off
// screen never react to a firefight; the comm-link cause is the one vanilla
// lets through. It puts the unit's pod on yellow alert and gives it the
// position to go to.
//
// Work: hive sight is one loop over the living XCOM units per committed frame
// and one probe per question after that; a contact report is one loop over
// the members of every pod that sees nobody, each of which is told.
//=============================================================================

class X2ChronoComms extends Object dependson(X2DownloadableContentInfo_ChronoCOM);

const ALERT_LEVEL_IN_THE_FIGHT = 2;   // eStat_AlertLevel of a unit on red alert
const SQUAD_SIGHT_TILES = 18;          // a soldier's sight radius: vanilla's 27 m (eStat_SightRadius, DefaultGameData_CharacterStats.ini), 1.5 m a tile

// The unit index holding this frame's hive sight. The sightings are computed
// once per committed frame, whoever asks first, and shared by every alien:
// one engine query per living XCOM unit, then one probe per question.
static function X2ChronoIndex SightIndex()
{
	local X2ChronoIndex Index;
	local array<int> SeenIDs;

	Index = class'X2ChronoIndex'.static.GetIndex();
	if (!Index.HasHiveSight())
	{
		CollectSightings(Index, SeenIDs);
		Index.SetHiveSight(SeenIDs);
	}

	return Index;
}

// The living XCOM units that any living unit of the alien player sees
static function CollectSightings(X2ChronoIndex Index, out array<int> SeenIDs)
{
	local XComGameState_Player AlienPlayer;
	local array<int> XComIDs;
	local int i;

	AlienPlayer = Index.AlienPlayer();
	Index.GetLiveUnits(eTeam_XCom, XComIDs);
	for (i = 0; AlienPlayer != none && i < XComIDs.Length; ++i)
	{
		if (HiveSeesUnit(AlienPlayer.ObjectID, XComIDs[i]))
		{
			SeenIDs.AddItem(XComIDs[i]);
		}
	}
}

// A concealed unit is never seen, whatever the visibility cache says
static function bool HiveSeesUnit(int AlienPlayerID, int UnitID)
{
	local XComGameState_Unit Unit;

	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitID));
	return Unit != none && !Unit.IsConcealed() && class'X2TacticalVisibilityHelpers'.static.CanSquadSeeTarget(AlienPlayerID, UnitID)
		&& SeenByUnjammed(AlienPlayerID, UnitID);
}

// Some alien that sees the unit is not jammed: a jammed alien's sightings do
// not reach the hive. One pass over the unit's enemy viewers.
static function bool SeenByUnjammed(int AlienPlayerID, int UnitID)
{
	local array<StateObjectReference> Viewers;
	local int i;

	class'X2TacticalVisibilityHelpers'.static.GetEnemyViewersOfTarget(UnitID, Viewers);
	for (i = 0; i < Viewers.Length; i++)
	{
		if (IsUnjammedAlien(Viewers[i].ObjectID, AlienPlayerID))
		{
			return true;
		}
	}

	return false;
}

static function bool IsUnjammedAlien(int ViewerID, int AlienPlayerID)
{
	local XComGameState_Unit Viewer;

	Viewer = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(ViewerID));
	return Viewer != none && Viewer.ControllingPlayer.ObjectID == AlienPlayerID && !IsJammed(Viewer);
}

// Does any alien see this unit right now? One probe.
static function bool HiveSees(int UnitID)
{
	return SightIndex().HiveSees(UnitID);
}

static function bool CanBeTold(XComGameState_Unit Hearer)
{
	return Hearer != none && Hearer.GetAIUnitDataID() > 0 && !Hearer.GetMyTemplate().bIsChosen && !IsJammed(Hearer);
}

// Jammed by the squad's EMP (X2Ability_ChronoSupport.CreateJammedEffect): cut
// off from the hive both ways
static function bool IsJammed(XComGameState_Unit Unit)
{
	return Unit.IsUnitAffectedByEffectName(class'X2Ability_ChronoSupport'.const.JAMMED_EFFECT);
}

static function bool IsOutOfTheFight(XComGameState_Unit Hearer)
{
	return Hearer.GetCurrentStat(eStat_AlertLevel) < ALERT_LEVEL_IN_THE_FIGHT;
}

// Hearer is told where About is: an alert at About's position, yellow alert
// for Hearer's pod if it was idle. Only an enemy's position becomes where the
// pod believes the squad is: an ally's sound brings the hearer to the fight
// through vanilla's alert data and tells its pod nothing about the squad.
// (Until 2026-10-06 it did, and pods that had never seen the squad held at
// the edge of their own ally's position.)
static function Relay(XComGameState_Unit Hearer, XComGameState_Unit About, XComGameState GameState)
{
	class'XComGameState_Unit'.static.UnitAGainsKnowledgeOfUnitB(Hearer, About, GameState, eAC_AlertedByCommLink, false);
	if (Hearer.IsEnemyUnit(About))
	{
		NoteHeardByPod(Hearer, About);
	}
}

// The hearer's pod remembers where: one probe of the group -> pod map
static function NoteHeardByPod(XComGameState_Unit Hearer, XComGameState_Unit About)
{
	local XComGameState_AIGroup Group;
	local int PodIdx;

	Group = Hearer.GetGroupMembership();
	PodIdx = (Group != none) ? class'X2ChronoIndex'.static.GetIndex().GetPodOfGroup(Group.ObjectID) : INDEX_NONE;
	if (PodIdx != INDEX_NONE)
	{
		class'X2ChronoFirePlan'.static.GetPlan().NoteHeard(PodIdx, About.TileLocation);
	}
}

// Once per alien turn: while the hive sees XCOM, every alien that is not in
// the fight is told where the nearest sighted XCOM unit is, and comes
static function ReportContacts(XComGameState TurnState)
{
	local array<int> SeenIDs;

	if (!class'X2ChronoConfig'.static.HiveCommsOn())
	{
		return;
	}

	// A copy: telling the aliens submits frames, which starts a new sight frame
	SeenIDs = SightIndex().HiveSeenIDs;
	if (SeenIDs.Length > 0)
	{
		TellBlindPods(SeenIDs, TurnState);
	}
}

// Every member of every pod that saw no soldier at this turn's pod update is
// told: a probe over the pod records (a handful per mission), then that pod's
// members. A pod with contact is in the fight and needs no report.
static function TellBlindPods(const out array<int> SeenIDs, XComGameState TurnState)
{
	local XComGameState_TacticalInfluenceManager InfluenceMgr;
	local int i, Told;

	InfluenceMgr = class'XComGameState_TacticalInfluenceManager'.static.GetManager();
	if (InfluenceMgr == none)
	{
		return;
	}

	for (i = 0; i < InfluenceMgr.MissionPods.Length; ++i)
	{
		Told += TellPodIfBlind(InfluenceMgr.MissionPods[i], SeenIDs, TurnState);
	}

	class'X2ChronoMetrics'.static.Get().Count(eCount_ContactReports, Told);
}

static function int TellPodIfBlind(PodData Pod, const out array<int> SeenIDs, XComGameState TurnState)
{
	local int i, Told;

	if (Pod.bHasVisualContact)
	{
		return 0;
	}

	for (i = 0; i < Pod.MemberUnitIDs.Length; ++i)
	{
		Told += int(ReportTo(Pod.MemberUnitIDs[i], SeenIDs, TurnState));
	}

	return Told;
}

static function bool ReportTo(int AlienID, const out array<int> SeenIDs, XComGameState TurnState)
{
	local XComGameState_Unit Hearer;

	Hearer = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(AlienID));
	if (!CanBeTold(Hearer) || !Hearer.IsAlive())
	{
		return false;
	}

	Relay(Hearer, NearestOf(Hearer, SeenIDs), TurnState);
	return true;
}

static function XComGameState_Unit NearestOf(XComGameState_Unit Hearer, const out array<int> UnitIDs)
{
	local XComGameState_Unit Unit, Nearest;
	local float Dist, BestDist;
	local int i;

	Nearest = none;
	for (i = 0; i < UnitIDs.Length; ++i)
	{
		Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitIDs[i]));
		Dist = class'Helpers'.static.DistanceBetweenTiles(Hearer.TileLocation, Unit.TileLocation);
		if (Nearest == none || Dist < BestDist)
		{
			Nearest = Unit;
			BestDist = Dist;
		}
	}

	return Nearest;
}

//-----------------------------------------------------------------------------
// What the squad could see, for points the hive picks (pincer points)
//-----------------------------------------------------------------------------

// Whether a soldier the hive knows of could see Point: one standing at the
// believed position From, or any soldier some alien sees now. One sight test,
// then one per sighted soldier (at most a squad).
static function bool SquadCouldSee(vector From, vector Point)
{
	local X2ChronoIndex Index;
	local int i;

	if (SeesPoint(From, Point))
	{
		return true;
	}

	Index = SightIndex();
	for (i = 0; i < Index.HiveSeenIDs.Length; ++i)
	{
		if (UnitSeesPoint(Index.HiveSeenIDs[i], Point))
		{
			return true;
		}
	}

	return false;
}

static function bool UnitSeesPoint(int UnitID, vector Point)
{
	local XComGameState_Unit Unit;

	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitID));
	return Unit != none && SeesPoint(`XWORLD.GetPositionFromTileCoordinates(Unit.TileLocation), Point);
}

// A sight line by the engine's own tile test (XComWorldData.CanSeeTileToTile)
// within a soldier's sight radius
static function bool SeesPoint(vector From, vector To)
{
	local TTile FromTile, ToTile;
	local GameRulesCache_VisibilityInfo Info;

	if (VSize2D(From - To) > SQUAD_SIGHT_TILES * class'XComWorldData'.const.WORLD_StepSize)
	{
		return false;
	}

	FromTile = `XWORLD.GetTileCoordinatesFromPosition(From);
	ToTile = FloorTileBelow(To);
	return `XWORLD.CanSeeTileToTile(FromTile, ToTile, Info);
}

// The points are computed at the believed position's height: the first floor
// at or below one building level above it, else the point's own tile
static function TTile FloorTileBelow(vector Position)
{
	local TTile Tile;

	Position.Z += class'XComWorldData'.const.WORLD_FloorHeight * 4;
	if (!`XWORLD.GetFloorTileForPosition(Position, Tile, true))
	{
		Position.Z -= class'XComWorldData'.const.WORLD_FloorHeight * 4;
		Tile = `XWORLD.GetTileCoordinatesFromPosition(Position);
	}

	return Tile;
}

defaultproperties
{
}
