// X2PodCoordinator_Optimized
// What each alien pod knows about the squad and what it does about it, once
// per alien turn. A pod sees the squad, or believes it is where it last saw,
// heard or was told of it (LastKnownEnemyPosition, LastKnownTurn).
// A pod also has an intent for the turn (press, hold, fall back, assault).
// With the squad in sight it is decided from what the pod's own members see:
// how many of them are left, how many XCOM units they see and how many of
// those are on overwatch. Without, from what the hive knows: where the pod
// believes the squad is, how long it has held at the edge, and whether any
// alien has a soldier in sight.
// The types (PodData, EPodIntent) are defined
// in X2DownloadableContentInfo_ChronoCOM; the pods live on
// XComGameState_TacticalInfluenceManager and are updated once per alien turn.

class X2PodCoordinator_Optimized extends Object config(Game);

const PINCER_CANDIDATES = 3;   // the straight pincer point and one turn either way
const SEEN_COST = 1000;        // a pincer point a soldier could see costs more than any danger

const SEEN_SLOTS = 256;        // open-addressed set of sighted ObjectIDs (power of two)
const SEEN_MASK = 255;
const TEMPER_STEADY = 2;

var config int FALLBACK_MAX_SURVIVORS;        // a pod falls back only when it is down to this many members or fewer ...
var config int FALLBACK_ENEMIES_PER_SURVIVOR; // ... and sees this many XCOM units per member left
var config int WEAKENED_STRENGTH_PERCENT;     // a pod at or below this share of its starting members holds its position when outnumbered
var config int HOLD_MIN_ENEMY_OVERWATCH;   // visible XCOM units on overwatch that make a pod assault (bait, flank, charge) instead of pressing
var config int HOLD_MAX_POD_OVERWATCH;     // members of a holding or retreating pod allowed on overwatch at once
var config array<name> HOLD_LINE_GROUPS;   // character groups that take the directed tree's hold branch (line infantry)
var config int HABIT_OVERWATCH_HOLD_REDUCTION; // HOLD_MIN_ENEMY_OVERWATCH is lowered by this against an overwatch-crawl squad
var config array<int> TEMPER_ODDS;          // weight of each temperament (cautious, steady, eager) when a pod is created
var config array<int> TEMPER_PATIENCE_TURNS; // per temperament (cautious, steady, eager): alien turns a pod holds at the edge before it goes in
var config array<int> TEMPER_EDGE_TILES;     // ... tiles from where it believes the squad is at which it stops and holds
var config array<int> TEMPER_FLANKERS;       // ... units of a pressing pod that may move to flank in one alien turn
var config int GUARD_RADIUS_TILES;           // a guarding pod pulls back to within this many tiles of its objective and holds there
var config int GUARD_MAX_POD_OVERWATCH;      // members of a guarding pod allowed on overwatch at once
var config int PINCER_OFFSET_TILES;          // pods going in together swing this many tiles to either side of the believed position
var config float PINCER_SWING_DEGREES;       // a pincer point may turn this far toward or away from the squad's line instead
var config array<name> BAIT_ORDER;         // character groups from most to least expendable: an assaulting pod's bait is its living member of the lowest rank
var config array<name> ALL_IN_MISSIONS;    // missions (MissionName) on which no pod holds or falls back: told where the squad is, every pod goes in

// Flyover texts, in Localization/ChronoCOM.int
var localized string FallBackFlyover;
var localized string HoldFlyover;
var localized string AssaultFlyover;

// What one pass over a pod's living members finds
struct PodSurvey
{
	var XComGameState_Unit Representative;   // the first living member
	var int Living;
	var int Directed;                        // living members the hive directs (XGAIBehavior_ChronoCOM.IsHiveDirected)
	var int HighestAlert;                    // 0 green, 1 yellow, 2 red
	var int BaitID;                          // the member of the lowest rank
	var int BaitRank;
	var int TotalHP;
	var int CurrentHP;
	var array<TTile> Tiles;                  // where the living members stand
	var bool bHiveGoesIn;                    // some pod's patience at the edge has run out: every holding pod goes in this turn
	var bool bAllIn;                         // the mission is in ALL_IN_MISSIONS (IsAllInMission)
};

//-----------------------------------------------------------------------------
// Pods from the game's AI groups
//-----------------------------------------------------------------------------

// AI groups are XCOM 2's own pods. Once per alien turn, one pass over the
// group objects: a group without a pod (the mission's first turn, or
// reinforcements that arrived since) gets one, and every pod takes its group's
// current members (vanilla moves a fallback survivor into another group).
static function SyncPodsWithGroups(out array<PodData> Pods)
{
	local XComGameState_AIGroup AIGroup;

	DropLegacyPods(Pods);
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_AIGroup', AIGroup)
	{
		if (IsPodGroup(AIGroup))
		{
			AdoptGroup(Pods, AIGroup);
		}
	}
}

// Pods saved by a build that did not record their group cannot be matched to
// one; they are rebuilt
static function DropLegacyPods(out array<PodData> Pods)
{
	if (Pods.Length > 0 && Pods[0].GroupID <= 0)
	{
		Pods.Length = 0;
	}
}

static function bool IsPodGroup(XComGameState_AIGroup AIGroup)
{
	return AIGroup.TeamName == eTeam_Alien && AIGroup.m_arrMembers.Length > 0;
}

static function AdoptGroup(out array<PodData> Pods, XComGameState_AIGroup AIGroup)
{
	local PodData Pod;
	local int PodIdx;

	PodIdx = PodIndexOfGroup(Pods, AIGroup.ObjectID);
	if (PodIdx == INDEX_NONE)
	{
		PodIdx = Pods.Length;
		Pods.AddItem(CreatePodFromGroup(AIGroup, PodIdx));
		`log("ChronoCOM: pod" @ PodIdx @ "created for AI group" @ AIGroup.ObjectID @ "(" $ AIGroup.m_arrMembers.Length @ "members)"
			@ TemperName(Pods[PodIdx].Temper) @ "patience=" $ PatienceOf(Pods[PodIdx].Temper) @ "edge=" $ EdgeTilesOf(Pods[PodIdx].Temper)
			@ "flankers=" $ FlankersOf(Pods[PodIdx].Temper));
	}

	Pod = Pods[PodIdx];
	TakeGroupMembers(Pod, AIGroup);
	Pods[PodIdx] = Pod;
}

static function PodData CreatePodFromGroup(XComGameState_AIGroup AIGroup, int PodID)
{
	local X2DownloadableContentInfo_ChronoCOM.PodData Pod;

	Pod.PodID = PodID;
	Pod.GroupID = AIGroup.ObjectID;
	Pod.SquadHealthPercent = 100;
	Pod.Temper = RollTemper();
	return Pod;
}

//-----------------------------------------------------------------------------
// Temperament: a pod's own patience, edge and appetite for flanking, rolled
// once when the pod is created (TEMPER_* lists: cautious, steady, eager), so
// no two pods need play alike
//-----------------------------------------------------------------------------

// TEMPER_ODDS weighs the three (cautious, steady, eager); one draw of
// vanilla's synchronised random, so a replay rolls the same
static function int RollTemper()
{
	local int Total, Roll, i;

	for (i = 0; i < default.TEMPER_ODDS.Length; i++)
	{
		Total += Max(0, default.TEMPER_ODDS[i]);
	}

	Roll = `SYNC_RAND_STATIC(Max(1, Total));
	return TemperOfRoll(Roll);
}

static function int TemperOfRoll(int Roll)
{
	local int i;

	for (i = 0; i < default.TEMPER_ODDS.Length; i++)
	{
		Roll -= Max(0, default.TEMPER_ODDS[i]);
		if (Roll < 0)
		{
			return i + 1;
		}
	}

	return TEMPER_STEADY;
}

static function int TemperIndex(int Temper)
{
	return ((Temper > 0) ? Temper : TEMPER_STEADY) - 1;
}

static function int PatienceOf(int Temper)
{
	return default.TEMPER_PATIENCE_TURNS[TemperIndex(Temper)];
}

static function int EdgeTilesOf(int Temper)
{
	return default.TEMPER_EDGE_TILES[TemperIndex(Temper)];
}

static function int FlankersOf(int Temper)
{
	return default.TEMPER_FLANKERS[TemperIndex(Temper)];
}

static function string TemperName(int Temper)
{
	if (TemperIndex(Temper) == 0)
	{
		return "cautious";
	}

	return (TemperIndex(Temper) == 1) ? "steady" : "eager";
}

// The group's current members; the largest membership seen is the pod's
// starting strength
static function TakeGroupMembers(out PodData Pod, XComGameState_AIGroup AIGroup)
{
	local int i;

	Pod.MemberUnitIDs.Length = 0;
	for (i = 0; i < AIGroup.m_arrMembers.Length; i++)
	{
		Pod.MemberUnitIDs.AddItem(AIGroup.m_arrMembers[i].ObjectID);
	}

	Pod.StartingMembers = Max(Pod.StartingMembers, Pod.MemberUnitIDs.Length);
}

//-----------------------------------------------------------------------------
// Awareness state machine, once per alien turn
//-----------------------------------------------------------------------------

static function UpdateAllPods(out array<PodData> Pods)
{
	local PodData TempPod;
	local int i;

	local bool bHiveGoesIn, bAllIn;

	bHiveGoesIn = SomePodGoesIn(Pods);
	bAllIn = IsAllInMission();
	for (i = 0; i < Pods.Length; i++)
	{
		TempPod = Pods[i];
		UpdatePodState(TempPod, bHiveGoesIn, bAllIn);
		Pods[i] = TempPod;
	}
	AssignPincers(Pods);
}

//-----------------------------------------------------------------------------
// Pincers: pods going in together without sight of the squad split up. Each
// swings PINCER_OFFSET_TILES to the side of the believed position away from
// the other pods going in, so the squad is entered from more than one side,
// at the point on that side the squad could not see and has not hurt the
// hive at (PincerPoint). One pass to sum the positions of the pods going in,
// one to assign; with fewer than two going in, every pod goes straight in.
//-----------------------------------------------------------------------------

static function AssignPincers(out array<PodData> Pods)
{
	local PodData TempPod;
	local vector Sum;
	local int i, Count;

	class'X2ChronoDanger'.static.GetDanger().Sync();
	Count = SumGoingIn(Pods, Sum);
	for (i = 0; i < Pods.Length; i++)
	{
		TempPod = Pods[i];
		SetPincer(TempPod, Sum, Count);
		Pods[i] = TempPod;
	}
}

static function int SumGoingIn(const out array<PodData> Pods, out vector Sum)
{
	local int i, Count;

	for (i = 0; i < Pods.Length; i++)
	{
		if (Pods[i].Intent == ePodIntent_Assault && !Pods[i].bHasVisualContact)
		{
			Sum += Pods[i].Position;
			Count++;
		}
	}

	return Count;
}

static function SetPincer(out PodData Pod, vector Sum, int Count)
{
	Pod.PincerSide = 0;
	Pod.GoInTarget = Pod.LastKnownEnemyPosition;
	if (Count < 2 || !IsGoingInBlind(Pod))
	{
		return;
	}

	Pod.PincerSide = PincerSideOf(Pod, (Sum - Pod.Position) / (Count - 1));
	Pod.GoInTarget = PincerPoint(Pod);
}

// Of the points PINCER_OFFSET_TILES to the pod's side of the believed
// position, straight across or turned PINCER_SWING_DEGREES toward or away from
// the squad's line, the first with the lowest cost (PincerCost). A free
// straight point ends the search at once.
static function vector PincerPoint(const out PodData Pod)
{
	local vector Side, Straight, Best, Candidate;
	local int i, BestCost, Cost;

	Side = Across(Pod) * Pod.PincerSide;
	Straight = PincerCandidate(Pod, Side, 0);
	Best = Straight;
	BestCost = PincerCost(Pod, Best);
	for (i = 1; i < PINCER_CANDIDATES && BestCost > 0; i++)
	{
		Candidate = PincerCandidate(Pod, Side, i);
		Cost = PincerCost(Pod, Candidate);
		if (Cost < BestCost)
		{
			Best = Candidate;
			BestCost = Cost;
		}
	}

	class'X2ChronoMetrics'.static.Get().Count(eCount_PincerShifts, int(Best != Straight));
	return Best;
}

static function vector PincerCandidate(const out PodData Pod, vector Side, int i)
{
	return Pod.LastKnownEnemyPosition + class'X2ChronoDanger'.static.Turned(Side, default.PINCER_SWING_DEGREES * class'X2ChronoDanger'.static.BearingStep(i))
		* (default.PINCER_OFFSET_TILES * class'XComWorldData'.const.WORLD_StepSize);
}

// A point a soldier the hive knows of could see (X2ChronoComms.SquadCouldSee)
// costs more than any danger; then the danger of its cell (X2ChronoDanger)
static function int PincerCost(const out PodData Pod, vector Point)
{
	return SEEN_COST * int(class'X2ChronoConfig'.static.HiddenApproachOn() && class'X2ChronoComms'.static.SquadCouldSee(Pod.LastKnownEnemyPosition, Point))
		+ class'X2ChronoDanger'.static.GetDanger().WeightNear(Point);
}

static function bool IsGoingInBlind(const out PodData Pod)
{
	return Pod.Intent == ePodIntent_Assault && !Pod.bHasVisualContact;
}

// The unit vector across the pod's line of approach to the believed position
static function vector Across(const out PodData Pod)
{
	local vector Along, Side;

	Along = Pod.Position - Pod.LastKnownEnemyPosition;
	Along.Z = 0;
	Along = Normal(Along);
	Side.X = -Along.Y;
	Side.Y = Along.X;
	return Side;
}

// The side away from where the other pods going in stand; on the line itself
// the pod's ID decides, so two pods in one spot still split
static function int PincerSideOf(const out PodData Pod, vector OthersCenter)
{
	local float Lean;

	Lean = Across(Pod) Dot (OthersCenter - Pod.LastKnownEnemyPosition);
	if (Lean == 0)
	{
		return (Pod.PodID % 2 == 0) ? 1 : -1;
	}

	return (Lean > 0) ? -1 : 1;
}

// A pod ended the last alien turn having held at the edge for its full
// patience (it assaults now if it still holds) or past it (it is already
// assaulting). One pass over the pods.
// All in: on the missions in ALL_IN_MISSIONS no pod waits. As shipped that is
// the compound rescue (Rescue Operative), whose security alarm tells every
// alien where the squad is at once (vanilla's map-wide hostile alert at
// SecurityOnAlert); with the hunt's patience every pod then held at the edge
// on overwatch (2026-10-08, Plot_WLD_Compound_Road_Stream: all five pods
// yellow on alien turn 8, holding on turns 9 and 10). There a told pod goes in
// at once, and in contact it presses: it neither holds nor falls back. One
// read of the battle data per alien turn.
static function bool IsAllInMission()
{
	local XComGameState_BattleData BattleData;

	BattleData = XComGameState_BattleData(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_BattleData'));
	return BattleData != none && default.ALL_IN_MISSIONS.Find(BattleData.MapData.ActiveMission.MissionName) != INDEX_NONE;
}

static function bool SomePodGoesIn(const out array<PodData> Pods)
{
	local int i;

	for (i = 0; i < Pods.Length; i++)
	{
		if (Pods[i].StalkTurns >= Max(1, PatienceOf(Pods[i].Temper)))
		{
			return true;
		}
	}

	return false;
}

// bHiveGoesIn (SomePodGoesIn): every other pod that is holding, or still
// closing, goes in on the same turn: the pods wait for each other and go in
// together.
static function UpdatePodState(out PodData Pod, bool bHiveGoesIn, bool bAllIn)
{
	local array<XComGameState_Unit> VisibleThreats;
	local PodSurvey Survey;

	Survey.bHiveGoesIn = bHiveGoesIn;
	Survey.bAllIn = bAllIn;
	SurveyPod(Pod, Survey, VisibleThreats);
	if (Survey.Representative == none)
	{
		Pod.StalkTurns = 0;
		Pod.Intent = ePodIntent_None;
		return;  // the pod is dead: its patience calls nobody in and it goes in nowhere
	}

	TakeSurvey(Pod, Survey, VisibleThreats.Length > 0);
	Pod.Position = `XWORLD.GetPositionFromTileCoordinates(Survey.Representative.TileLocation);
	NoteGuard(Pod);
	if (Pod.bHasVisualContact)
	{
		Pod.LastKnownEnemyPosition = CalculateAveragePosition(VisibleThreats);
	}

	UpdateKnownPosition(Pod, Survey.Representative);
	CountHoldTurn(Pod, Survey);
	NoteSituation(Pod, VisibleThreats, Survey);
	LogPod(Pod, Survey);
}

// One pass over the members: who lives, the highest alert level, the bait,
// the health, and what they see between them (the union of every living
// member's sightings, deduplicated through an open-addressed set of ObjectIDs)
static function SurveyPod(const out PodData Pod, out PodSurvey Survey, out array<XComGameState_Unit> VisibleThreats)
{
	local XComGameState_Unit Member;
	local array<int> Seen;
	local int i;

	Seen.Length = SEEN_SLOTS;
	for (i = 0; i < Pod.MemberUnitIDs.Length; i++)
	{
		Member = LivingUnit(Pod.MemberUnitIDs[i]);
		if (Member != none)
		{
			SurveyMember(Member, Survey);
			AddSightings(Member, Seen, VisibleThreats);
		}
	}
}

// The bait is the living member of the lowest rank: the character group's
// place in BAIT_ORDER (troopers before lancers before the pod's leaders and
// specialists; a group not listed ranks last), and among equals the one with
// the least health
static function SurveyMember(XComGameState_Unit Member, out PodSurvey Survey)
{
	local int Rank;

	Survey.Living++;
	Survey.Directed += int(class'XGAIBehavior_ChronoCOM'.static.IsHiveDirected(Member));
	Survey.HighestAlert = Max(Survey.HighestAlert, ActingAlert(Member));
	Survey.TotalHP += Member.GetMaxStat(eStat_HP);
	Survey.CurrentHP += Member.GetCurrentStat(eStat_HP);
	Survey.Tiles.AddItem(Member.TileLocation);
	if (Survey.Representative == none)
	{
		Survey.Representative = Member;
	}

	Rank = BaitRank(Member);
	if (Survey.BaitID == 0 || Rank < Survey.BaitRank)
	{
		Survey.BaitID = Member.ObjectID;
		Survey.BaitRank = Rank;
	}
}

// The alert level the member will act with this turn. Vanilla drops a red
// unit to yellow when its player's turn begins if it has no absolute
// knowledge left: no alert entry made by seeing an enemy
// (XComGameState_Unit.OnPlayerTurnBegun). That runs on the same event as this
// survey and not always before it: in test mission launch 11 a pod shot from
// out of sight read red here, and its leader ran yellow a moment later.
static function int ActingAlert(XComGameState_Unit Member)
{
	local int Alert;

	Alert = Member.GetCurrentStat(eStat_AlertLevel);
	return (Alert == 2 && LosesRedAlert(Member)) ? 1 : Alert;
}

// Vanilla's own conditions for the drop: AI data without absolute knowledge,
// and a red-alert effect to remove
static function bool LosesRedAlert(XComGameState_Unit Member)
{
	local XComGameState_AIUnitData Data;
	local StateObjectReference Known;
	local int DataID;

	DataID = Member.GetAIUnitDataID();
	if (DataID <= 0)
	{
		return false;
	}

	Data = XComGameState_AIUnitData(`XCOMHISTORY.GetGameStateForObjectID(DataID));
	return Data != none && !Data.HasAbsoluteKnowledge(Known) && Member.IsUnitAffectedByEffectName('RedAlert');
}

static function TakeSurvey(out PodData Pod, const out PodSurvey Survey, bool bSeesSquad)
{
	Pod.bHasVisualContact = bSeesSquad;
	Pod.LivingMembers = Survey.Living;
	Pod.BaitUnitID = Survey.BaitID;
	Pod.SquadHealthPercent = (Survey.TotalHP > 0) ? (Survey.CurrentHP * 100) / Survey.TotalHP : 0;
}

//-----------------------------------------------------------------------------
// Guarding (bGuardObjectives): on a defense mission, vanilla's own sense of
// one (the job list it hands out for this mission type includes Defender:
// hacks, recovers, sabotage, relays, UFOs, rescues and the rest), every pod
// guards the mission's objective, where vanilla's own AI finds it
// (XComGameState_BattleData.MapData.ObjectiveLocation, the end of the line of
// play). Told about the squad, a pod pulls back to it and holds it instead of
// hunting (XGAIBehavior_ChronoCOM.GuardMoveKind); with the squad in sight it
// holds its ground (ContactIntent). Until 2026-10-05 the trigger was an alert
// tagged "Defend", which the sabotage and recover missions played that day
// never dropped (every pod read guards=False).
//-----------------------------------------------------------------------------

static function NoteGuard(out PodData Pod)
{
	Pod.bGuards = IsDefenseMission(Pod.GuardPosition);
}

// True, with the objective, when guarding is on, the active job list holds a
// Defender and the battle has an objective location. One probe of the job
// list (a dozen names) and one read of the battle data.
static function bool IsDefenseMission(out vector Objective)
{
	local XComGameState_BattleData BattleData;

	if (!class'X2ChronoConfig'.static.GuardObjectivesOn() || `AIJOBMGR.ActiveJobList.Job.Find('Defender') == INDEX_NONE)
	{
		return false;
	}

	BattleData = XComGameState_BattleData(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_BattleData'));
	Objective = (BattleData != none) ? BattleData.MapData.ObjectiveLocation : vect(0, 0, 0);
	return Objective != vect(0, 0, 0);
}

// The pod's patience (its temperament's) counts the alien turns it starts
// holding at the edge (HoldsBlind). Turns spent closing to the edge do not
// count (until 2026-10-03 they did, so a pod that needed three turns to arrive
// assaulted without holding); contact resets the count. Called after the
// believed position is updated.
static function CountHoldTurn(out PodData Pod, const out PodSurvey Survey)
{
	if (Pod.bHasVisualContact || Survey.Directed == 0)
	{
		Pod.StalkTurns = 0;
	}
	else if (HoldsBlind(Pod, Survey))
	{
		Pod.StalkTurns++;
	}
}

// Alerted (told, or red after losing the squad), a member within the pod's
// edge (EdgeTilesOf its temperament) of where the pod believes the squad is, and no alien
// anywhere with a soldier in sight: the hold is for a squad nobody can see.
// With eyes on it the pod goes in (GoesIn). Until 2026-10-04 only a red pod
// held, and vanilla keeps a pod red only after it has seen the squad, so the
// pods that came to a squad overwatching out of sight were told ones and
// rushed straight in.
static function bool HoldsBlind(const out PodData Pod, const out PodSurvey Survey)
{
	return Hunts(Pod, Survey) && Survey.HighestAlert >= 1 && !HiveSeesSquad() && IsAtEdge(Pod, Survey);
}

// Neither guarding an objective nor on an all-in mission: the pod hunts, and
// holds at the edge until its patience runs out
static function bool Hunts(const out PodData Pod, const out PodSurvey Survey)
{
	return !Pod.bGuards && !Survey.bAllIn;
}

// Some alien has a soldier in sight right now: one read of the hive-sight set
static function bool HiveSeesSquad()
{
	local X2ChronoIndex Index;

	Index = class'X2ChronoComms'.static.SightIndex();
	return Index.HiveSeenIDs.Length > 0;
}

// The pod knows where the squad is and a living member stands within the
// edge of it; at most a pod's members compared
static function bool IsAtEdge(const out PodData Pod, const out PodSurvey Survey)
{
	local int i;

	for (i = 0; Pod.LastKnownTurn > 0 && i < Survey.Tiles.Length; i++)
	{
		if (TilesFromKnown(Pod, Survey.Tiles[i]) <= EdgeTilesOf(Pod.Temper))
		{
			return true;
		}
	}

	return false;
}

// Tiles from a tile to where the pod believes the squad is
static function int TilesFromKnown(const out PodData Pod, TTile Tile)
{
	return TilesBetween(Pod.LastKnownEnemyPosition, Tile);
}

static function int TilesBetween(vector Position, TTile Tile)
{
	return Round(VSize(Position - `XWORLD.GetPositionFromTileCoordinates(Tile)) / class'XComWorldData'.const.WORLD_StepSize);
}

// Where the hive believes the squad is, for a pod that cannot see it: the
// nearest soldier any alien sees now; else where the pod last heard one;
// else what it last saw (UpdatePodState). One probe of the hive-sight set, at most
// the sighted soldiers compared.
static function UpdateKnownPosition(out PodData Pod, XComGameState_Unit Representative)
{
	local TTile Heard;

	if (Pod.bHasVisualContact)
	{
		Pod.LastKnownTurn = class'X2ChronoIndex'.static.GetIndex().GetAlienTurn();
	}
	else if (NearestSighted(Representative, Pod.LastKnownEnemyPosition))
	{
		Pod.LastKnownTurn = class'X2ChronoIndex'.static.GetIndex().GetAlienTurn();
	}
	else if (class'X2ChronoFirePlan'.static.GetPlan().HeardSince(Pod.PodID, Pod.LastKnownTurn, Heard))
	{
		Pod.LastKnownEnemyPosition = `XWORLD.GetPositionFromTileCoordinates(Heard);
		Pod.LastKnownTurn = class'X2ChronoFirePlan'.static.GetPlan().HeardTurnOf(Pod.PodID);
	}
}

// The soldier the hive sees nearest to the pod; false when it sees none
static function bool NearestSighted(XComGameState_Unit Representative, out vector Position)
{
	local XComGameState_Unit Nearest;
	local array<int> SeenIDs;

	SeenIDs = class'X2ChronoComms'.static.SightIndex().HiveSeenIDs;
	if (SeenIDs.Length == 0)
	{
		return false;
	}

	Nearest = class'X2ChronoComms'.static.NearestOf(Representative, SeenIDs);
	Position = `XWORLD.GetPositionFromTileCoordinates(Nearest.TileLocation);
	return true;
}

// BAIT_ORDER index first, health second; an unlisted group ranks after every listed one
static function int BaitRank(XComGameState_Unit Member)
{
	local int Order;

	Order = default.BAIT_ORDER.Find(Member.GetMyTemplate().CharacterGroupName);
	if (Order == INDEX_NONE)
	{
		Order = default.BAIT_ORDER.Length;
	}

	return Order * 1000 + Member.GetCurrentStat(eStat_HP);
}

// One line per living pod per alien turn: where it stands against the squad.
// "dist" is the fewest tiles from any member to any living XCOM unit, "alert"
// the highest alert level among the members (0 green, 1 yellow, 2 red). Over
// the turns the line shows whether a pod that was told about the fight is
// closing on it.
static function LogPod(const out PodData Pod, const out PodSurvey Survey)
{
	`log("ChronoCOM Pod: turn=" $ class'X2ChronoIndex'.static.GetIndex().GetAlienTurn() @ "pod=" $ Pod.PodID @ "intent=" $ Pod.Intent
		@ "members=" $ Pod.LivingMembers $ "/" $ Pod.MemberUnitIDs.Length @ "alert=" $ Survey.HighestAlert @ "dist=" $ TilesToSquad(Pod)
		@ "sees=" $ Pod.VisibleEnemies @ "enemy_overwatch=" $ Pod.EnemyOverwatchers @ "stalk=" $ Pod.StalkTurns @ "known_turn=" $ Pod.LastKnownTurn @ "bait=" $ Pod.BaitUnitID
		@ "temper=" $ TemperName(Pod.Temper) @ "guards=" $ Pod.bGuards @ "all_in=" $ Survey.bAllIn,
		class'X2ChronoMetrics'.static.Get().IsOn());
}

// Fewest tiles between a living member and a living XCOM unit; -1 when either side has none
static function int TilesToSquad(const out PodData Pod)
{
	local array<int> XComIDs;
	local XComGameState_Unit Member;
	local int i, Nearest, Fewest;

	class'X2ChronoIndex'.static.GetIndex().GetLiveUnits(eTeam_XCom, XComIDs);
	Fewest = -1;
	for (i = 0; i < Pod.MemberUnitIDs.Length; i++)
	{
		Member = LivingUnit(Pod.MemberUnitIDs[i]);
		Nearest = (Member != none) ? TilesToNearest(Member, XComIDs) : -1;
		Fewest = Closer(Fewest, Nearest);
	}

	return Fewest;
}

static function int TilesToNearest(XComGameState_Unit Member, const out array<int> UnitIDs)
{
	local XComGameState_Unit Unit;
	local int i, Fewest;

	Fewest = -1;
	for (i = 0; i < UnitIDs.Length; i++)
	{
		Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitIDs[i]));
		Fewest = Closer(Fewest, (Unit != none) ? Member.TileDistanceBetween(Unit) : -1);
	}

	return Fewest;
}

// The smaller of two distances, where -1 means none
static function int Closer(int A, int B)
{
	if (A < 0)
	{
		return B;
	}
	if (B < 0)
	{
		return A;
	}

	return Min(A, B);
}

//-----------------------------------------------------------------------------
// Intent, once per alien turn
//-----------------------------------------------------------------------------

// The pod's own picture of the fight and what it intends to do about it
static function NoteSituation(out PodData Pod, const out array<XComGameState_Unit> VisibleThreats, const out PodSurvey Survey)
{
	Pod.VisibleEnemies = VisibleThreats.Length;
	Pod.EnemyOverwatchers = CountOverwatchers(VisibleThreats);
	TakeIntent(Pod, DecideIntent(Pod, Survey));
	Pod.bHasFallenBack = Pod.bHasFallenBack || Pod.Intent == ePodIntent_FallBack;
	class'X2ChronoMetrics'.static.Get().NotePodIntent(Pod.Intent);
}

// A pod announces the turn it starts to fall back, hold or assault, not every
// turn it keeps doing so
static function TakeIntent(out PodData Pod, EPodIntent NewIntent)
{
	Pod.bAnnounceIntent = NewIntent != Pod.Intent && IsAnnounced(NewIntent);
	Pod.Intent = NewIntent;
}

static function bool IsAnnounced(EPodIntent Intent)
{
	return Intent == ePodIntent_FallBack || Intent == ePodIntent_Hold || Intent == ePodIntent_Assault;
}

//-----------------------------------------------------------------------------
// Intent flyover: the pod's change of mind, shown on a member XCOM can see
//-----------------------------------------------------------------------------

static function bool HasAnnouncement(const out array<PodData> Pods)
{
	return class'X2ChronoConfig'.static.IntentFlyoverOn() && Pods.Find('bAnnounceIntent', true) != INDEX_NONE;
}

// BuildVisualizationFn of the alien-turn update's game state
static function VisualizeIntent(XComGameState VisualizeGameState)
{
	local XComGameState_TacticalInfluenceManager InfluenceMgr;
	local PodData Pod;
	local int i;

	InfluenceMgr = ManagerIn(VisualizeGameState);
	for (i = 0; InfluenceMgr != none && i < InfluenceMgr.MissionPods.Length; ++i)
	{
		Pod = InfluenceMgr.MissionPods[i];
		AnnouncePod(VisualizeGameState, Pod);
	}
}

static function XComGameState_TacticalInfluenceManager ManagerIn(XComGameState GameState)
{
	local XComGameState_TacticalInfluenceManager InfluenceMgr;

	foreach GameState.IterateByClassType(class'XComGameState_TacticalInfluenceManager', InfluenceMgr)
	{
		return InfluenceMgr;
	}

	return none;
}

// Nothing is shown for a pod XCOM cannot see: the flyover goes on the first
// living member the squad has eyes on
static function AnnouncePod(XComGameState VisualizeGameState, const out PodData Pod)
{
	local int SpeakerID;

	if (!Pod.bAnnounceIntent)
	{
		return;
	}

	SpeakerID = VisibleMember(Pod);
	if (SpeakerID > 0)
	{
		AddFlyover(VisualizeGameState, SpeakerID, IntentText(Pod.Intent));
	}
}

static function int VisibleMember(const out PodData Pod)
{
	local int i;

	for (i = 0; i < Pod.MemberUnitIDs.Length; i++)
	{
		if (IsSeenAlive(Pod.MemberUnitIDs[i]))
		{
			return Pod.MemberUnitIDs[i];
		}
	}

	return 0;
}

static function bool IsSeenAlive(int UnitID)
{
	return LivingUnit(UnitID) != none && class'X2TacticalVisibilityHelpers'.static.CanXComSquadSeeTarget(UnitID);
}

static function string IntentText(EPodIntent Intent)
{
	if (Intent == ePodIntent_FallBack)
	{
		return default.FallBackFlyover;
	}

	return (Intent == ePodIntent_Assault) ? default.AssaultFlyover : default.HoldFlyover;
}

// Vanilla's own flyover action on the unit, no sound, no camera
static function AddFlyover(XComGameState VisualizeGameState, int UnitID, string Text)
{
	local VisualizationActionMetadata ActionMetadata;
	local X2Action_PlaySoundAndFlyOver Flyover;

	ActionMetadata.StateObject_NewState = `XCOMHISTORY.GetGameStateForObjectID(UnitID);
	ActionMetadata.StateObject_OldState = ActionMetadata.StateObject_NewState;
	ActionMetadata.VisualizeActor = `XCOMHISTORY.GetVisualizer(UnitID);

	Flyover = X2Action_PlaySoundAndFlyOver(class'X2Action_PlaySoundAndFlyOver'.static.AddToVisualizationTree(
		ActionMetadata, VisualizeGameState.GetContext(), false, ActionMetadata.LastActionAdded));
	Flyover.SetSoundAndFlyOverParameters(none, Text, '', eColor_Bad);
}

// Definition: a unit is on overwatch when it holds reserve action points
// (vanilla's own test for overwatching allies)
static function int CountOverwatchers(const out array<XComGameState_Unit> Units)
{
	local int i, Overwatchers;

	for (i = 0; i < Units.Length; ++i)
	{
		Overwatchers += int(Units[i].NumAllReserveActionPoints() > 0);
	}

	return Overwatchers;
}

// Without contact, the blind intent (BlindIntent). With it, a pod fights: it
// presses, holds its position when it is weakened and outnumbered or guards an
// objective, and assaults a wall of overwatch. It falls back only when defeat
// is imminent, and only once; after that it stands and fights from where it is.
static function EPodIntent DecideIntent(const out PodData Pod, const out PodSurvey Survey)
{
	if (Survey.Directed == 0)
	{
		return ePodIntent_None;   // nobody the hive directs: its members follow vanilla, and the pod is in no plan
	}
	if (!Pod.bHasVisualContact)
	{
		return BlindIntent(Pod, Survey);
	}
	if (FallsBackNow(Pod, Survey))
	{
		return ePodIntent_FallBack;
	}

	return ContactIntent(Pod, Survey);
}

// With the squad in sight: a weakened pod holds; a pod facing the squad's
// overwatch assaults it; otherwise it presses
static function EPodIntent ContactIntent(const out PodData Pod, const out PodSurvey Survey)
{
	if (HoldsInContact(Pod, Survey))
	{
		return ePodIntent_Hold;
	}

	return (Pod.EnemyOverwatchers >= HoldThreshold()) ? ePodIntent_Assault : ePodIntent_Press;
}

// Weakened and outnumbered, or guarding an objective; never on an all-in mission
static function bool HoldsInContact(const out PodData Pod, const out PodSurvey Survey)
{
	return !Survey.bAllIn && (IsWeakened(Pod) || Pod.bGuards);
}

// An alerted pod that sees nobody and knows where the squad is assaults that
// position when it goes in (GoesIn). Otherwise it has no intent: its members
// close to the edge and hold there (XGAIBehavior_ChronoCOM.SetUpKind).
static function EPodIntent BlindIntent(const out PodData Pod, const out PodSurvey Survey)
{
	if (MayGoIn(Pod, Survey) && GoesIn(Pod, Survey))
	{
		return ePodIntent_Assault;
	}

	return ePodIntent_None;
}

// A pod that guards an objective never goes in; any other alerted pod that
// knows where the squad is may
static function bool MayGoIn(const out PodData Pod, const out PodSurvey Survey)
{
	return !Pod.bGuards && Pod.LastKnownTurn > 0 && Survey.HighestAlert >= 1;
}

// The mission is all in; or the pod's patience is spent (PatienceSpent); or
// some alien has a soldier in sight, so a fight is on and there is nothing to
// wait for
static function bool GoesIn(const out PodData Pod, const out PodSurvey Survey)
{
	return Survey.bAllIn || PatienceSpent(Pod, Survey) || HiveSeesSquad();
}

// Its own patience at the edge has run out; or another pod's has, and the
// pods go in together
static function bool PatienceSpent(const out PodData Pod, const out PodSurvey Survey)
{
	return Pod.StalkTurns > PatienceOf(Pod.Temper) || Survey.bHiveGoesIn;
}

// A withdrawal, not a rout: one fall back per pod per mission, and none on an
// all-in mission
static function bool FallsBackNow(const out PodData Pod, const out PodSurvey Survey)
{
	return IsDefeatImminent(Pod) && !Pod.bHasFallenBack && !Survey.bAllIn;
}

// Visible XCOM overwatchers that make a pod assault (until 2026-10-02 they
// made it hold, hence the name). Against a squad whose habit is the overwatch
// crawl, pods assault sooner: by HABIT_OVERWATCH_HOLD_REDUCTION times the
// counter's strength (XComGameState_AdaptiveMemory.CounterStrength), rounded.
static function int HoldThreshold()
{
	if (class'X2ChronoFirePlan'.static.GetPlan().HabitThisTurn() != 'PATTERN_OVERWATCH_CRAWL')
	{
		return default.HOLD_MIN_ENEMY_OVERWATCH;
	}

	return Max(1, default.HOLD_MIN_ENEMY_OVERWATCH - Round(default.HABIT_OVERWATCH_HOLD_REDUCTION * class'X2ChronoFirePlan'.static.GetPlan().HabitStrengthThisTurn()));
}

// The last FALLBACK_MAX_SURVIVORS of a pod that has lost members, seeing
// FALLBACK_ENEMIES_PER_SURVIVOR or more XCOM units each. A pod that has lost
// nobody is never in imminent defeat by this rule.
static function bool IsDefeatImminent(const out PodData Pod)
{
	return Pod.LivingMembers <= default.FALLBACK_MAX_SURVIVORS && Pod.LivingMembers < Pod.StartingMembers
		&& Pod.VisibleEnemies >= Pod.LivingMembers * default.FALLBACK_ENEMIES_PER_SURVIVOR;
}

// Down to WEAKENED_STRENGTH_PERCENT of its starting members or fewer, and
// seeing more XCOM units than it has members left
static function bool IsWeakened(const out PodData Pod)
{
	return Pod.LivingMembers * 100 <= Pod.StartingMembers * default.WEAKENED_STRENGTH_PERCENT
		&& Pod.VisibleEnemies > Pod.LivingMembers;
}

static function int CountPodOverwatch(const out PodData Pod)
{
	local XComGameState_Unit Member;
	local int i, Overwatchers;

	for (i = 0; i < Pod.MemberUnitIDs.Length; i++)
	{
		Member = LivingUnit(Pod.MemberUnitIDs[i]);
		Overwatchers += int(Member != none && Member.NumAllReserveActionPoints() > 0);
	}

	return Overwatchers;
}

// True while fewer than HOLD_MAX_POD_OVERWATCH members of the pod are on
// overwatch: the cap that keeps a pod from turning into an overwatch wall
static function bool IsUnderOverwatchCap(const out PodData Pod)
{
	return CountPodOverwatch(Pod) < (Pod.bGuards ? default.GUARD_MAX_POD_OVERWATCH : default.HOLD_MAX_POD_OVERWATCH);
}

// The pod of UnitID's AI group as it stood at this alien turn's update: one
// lookup of the manager, one probe of the group -> pod map, one copy. A
// behavior-tree run fetches it once and reads everything from the copy.
static function bool GetPodOfUnit(int UnitID, out PodData Pod, out int PodIdx)
{
	local XComGameState_TacticalInfluenceManager InfluenceMgr;

	PodIdx = INDEX_NONE;
	InfluenceMgr = class'XComGameState_TacticalInfluenceManager'.static.GetManager();
	if (InfluenceMgr != none)
	{
		PodIdx = FindPodIndexForUnit(UnitID, InfluenceMgr.MissionPods);
	}
	if (PodIdx == INDEX_NONE)
	{
		return false;
	}

	Pod = InfluenceMgr.MissionPods[PodIdx];
	return true;
}


//-----------------------------------------------------------------------------
// Pod members
//-----------------------------------------------------------------------------

// The committed unit with this ID when it is alive, otherwise none
static function XComGameState_Unit LivingUnit(int ObjectID)
{
	local XComGameState_Unit Unit;

	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(ObjectID));
	if (Unit != none && Unit.IsAlive())
	{
		return Unit;
	}

	return none;
}

static function AddSightings(XComGameState_Unit Member, out array<int> Seen, out array<XComGameState_Unit> UniqueThreats)
{
	local array<XComGameState_Unit> Threats;
	local int i;

	Threats = class'X2AIBehaviorDirector_Optimized'.static.GetVisibleThreats(Member);
	for (i = 0; i < Threats.Length; ++i)
	{
		if (MarkSeen(Seen, Threats[i].ObjectID))
		{
			UniqueThreats.AddItem(Threats[i]);
		}
	}
}

// Adds ObjectID to the set; true when it was not there. A full set reads as
// "already seen", so the caller's list stays bounded by SEEN_SLOTS.
static function bool MarkSeen(out array<int> Seen, int ObjectID)
{
	local int Slot, Probe;

	Slot = (ObjectID * 73856093) & SEEN_MASK;
	for (Probe = 0; Probe < SEEN_SLOTS; ++Probe)
	{
		if (Seen[Slot] == ObjectID)
		{
			return false;
		}
		if (Seen[Slot] == 0)
		{
			Seen[Slot] = ObjectID;
			return true;
		}
		Slot = (Slot + 1) & SEEN_MASK;
	}

	return false;
}

static function vector CalculateAveragePosition(const out array<XComGameState_Unit> Threats)
{
	local vector AvgPos;
	local int i;

	for (i = 0; i < Threats.Length; ++i)
	{
		AvgPos += `XWORLD.GetPositionFromTileCoordinates(Threats[i].TileLocation);
	}

	if (Threats.Length > 0)
	{
		AvgPos = AvgPos / float(Threats.Length);
	}

	return AvgPos;
}

//-----------------------------------------------------------------------------
// Lookups for the AI's decisions
//-----------------------------------------------------------------------------

// Index of the pod of UnitID's AI group. The unit's group comes from the
// engine (the unit state's own group membership), the group's pod from one
// probe of the group -> pod map, so a unit that changes group is found in its
// new pod with no member list to search.
static function int FindPodIndexForUnit(int UnitID, const out array<PodData> Pods)
{
	local XComGameState_Unit Unit;
	local XComGameState_AIGroup Group;

	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitID));
	if (Unit != none)
	{
		Group = Unit.GetGroupMembership();
	}
	if (Group == none)
	{
		return INDEX_NONE;
	}

	return PodIndexOfGroup(Pods, Group.ObjectID);
}

// One probe of the group -> pod map the alien-turn update writes, checked
// against the pod's own group. A stale or empty map (a save loaded mid-turn)
// falls back to a walk over the pods, counted, so the result is always exact.
static function int PodIndexOfGroup(const out array<PodData> Pods, int GroupID)
{
	local int PodIdx;

	PodIdx = class'X2ChronoIndex'.static.GetIndex().GetPodOfGroup(GroupID);
	if (PodIsOfGroup(Pods, PodIdx, GroupID))
	{
		return PodIdx;
	}

	class'X2ChronoMetrics'.static.Get().Count(eCount_PodWalks);
	return Pods.Find('GroupID', GroupID);
}

static function bool PodIsOfGroup(const out array<PodData> Pods, int PodIdx, int GroupID)
{
	return PodIdx >= 0 && PodIdx < Pods.Length && Pods[PodIdx].GroupID == GroupID;
}

defaultproperties
{
}
