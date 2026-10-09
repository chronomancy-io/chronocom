//=============================================================================
// X2ChronoDanger
//
// WASP Role: I(c) — the hive's memory of where the squad has hurt it on this
// map: the kill zones the aliens learn to stay out of.
//
//   k  map cell (DANGER_CELL_TILES x DANGER_CELL_TILES tiles), alien turn
//   E  cell -> (the alien turn of its last mark, the weight of its marks):
//      DANGER_REACTION_WEIGHT per reaction shot at an alien standing in it,
//      DANGER_DEATH_WEIGHT per alien the squad killed in it
//   I  one X2ChronoIntMap over the cells that have marks; a read is one probe
//   T  "how dangerous is this tile": every alien tile score
//      (XGAIBehavior_ChronoCOM.GetWeightedTileScore), the bearing of a hold
//      at the edge (EdgePoint, SafestBearing) and the pincer points
//      (X2PodCoordinator_Optimized.PincerPoint)
//   F  a cell whose last mark is DANGER_TURNS alien turns old or more reads as
//      safe: the squad has moved on
//
// The marks are history: X2EventListener_ChronoDanger writes each one into
// the mission's pod manager inside the game state of the shot or the death
// (XComGameState_TacticalInfluenceManager.DangerMarks, a ring of the last
// DANGER_RING). This map folds them in, the new ones at each Sync, the whole
// ring again after a reset (a new mission, a loaded save:
// X2EventListenerTemplate_ChronoCOM.RegisterForEvents).
// Holds ints only, so it is safe on the session-lived runtime template.
//=============================================================================

class X2ChronoDanger extends Object config(Game) dependson(XComGameState_TacticalInfluenceManager);

const CELL_SPAN = 1024;       // cells per row in a packed cell key (maps are under 1,024 tiles wide)
const WEIGHT_SPAN = 65536;    // a cell's value: alien turn * WEIGHT_SPAN + weight
const BEARINGS = 5;           // the straight bearing and two turns either way

var config int DANGER_CELL_TILES;      // edge of a danger cell, in tiles
var config int DANGER_REACTION_WEIGHT; // a reaction shot at an alien
var config int DANGER_DEATH_WEIGHT;    // an alien killed
var config int DANGER_TURNS;           // a cell is forgotten this many alien turns after its last mark
var config float DANGER_TILE_PENALTY;  // a positive tile score is divided by 1 + this x the tile's weight
var config float DANGER_SWING_DEGREES; // a hold's bearing turns in steps of this, at most two either way

var X2ChronoIntMap Cells;
var int FoldedMarks;   // the manager's marks already in Cells
var int ReadTurn;      // the alien turn reads are judged against, taken at Sync

// The session's map; a throwaway when templates are not created yet
static function X2ChronoDanger GetDanger()
{
	local X2EventListenerTemplate_ChronoCOM Runtime;

	Runtime = class'X2EventListenerTemplate_ChronoCOM'.static.GetRuntime();
	return (Runtime != none) ? Runtime.GetDanger() : new class'X2ChronoDanger';
}

// A new mission or a loaded save: the manager's marks are folded in again
function Reset()
{
	Cells = none;
	FoldedMarks = 0;
}

// Keys are positive (0 is the map's empty slot)
static function int CellOf(TTile Tile)
{
	return Tile.X / default.DANGER_CELL_TILES + (Tile.Y / default.DANGER_CELL_TILES) * CELL_SPAN + 1;
}

//-----------------------------------------------------------------------------
// Recording, in the pre-submit window of the shot or the death
//-----------------------------------------------------------------------------

// Appends a mark for Tile to the mission's pod manager in GameState, the
// pending state of the shot or the death
static function Mark(XComGameState GameState, TTile Tile, int Weight, string Cause)
{
	local XComGameState_TacticalInfluenceManager Manager;
	local XComGameState_TacticalInfluenceManager.DangerMark NewMark;

	Manager = class'XComGameState_TacticalInfluenceManager'.static.GetModifiableManager(GameState);
	if (Manager == none)
	{
		return;
	}

	NewMark.Cell = CellOf(Tile);
	NewMark.AlienTurn = class'X2ChronoIndex'.static.GetIndex().GetAlienTurn();
	NewMark.Weight = Weight;
	Manager.AddDangerMark(NewMark);
	class'X2ChronoMetrics'.static.Get().Count(eCount_DangerMarks);
	`log("ChronoCOM Danger: turn=" $ NewMark.AlienTurn @ "cause=" $ Cause @ "tile=" $ Tile.X $ "," $ Tile.Y @ "cell=" $ NewMark.Cell @ "weight=" $ Weight,
		class'X2ChronoMetrics'.static.Get().IsOn());
}

//-----------------------------------------------------------------------------
// Folding the marks in
//-----------------------------------------------------------------------------

// Brings the map up to the mission's marks and takes the alien turn reads are
// judged against. One history lookup, then the marks recorded since the last
// call.
function Sync()
{
	local XComGameState_TacticalInfluenceManager Manager;

	ReadTurn = class'X2ChronoIndex'.static.GetIndex().GetAlienTurn();
	Manager = class'XComGameState_TacticalInfluenceManager'.static.GetManager();
	if (Manager != none)
	{
		FoldFrom(Manager);
	}
}

// The marks are written in order, so the ones not yet folded are the newest:
// at most the ring. A count below what was folded is another map's: start
// over.
function FoldFrom(XComGameState_TacticalInfluenceManager Manager)
{
	local int i;

	if (Cells == none || Manager.DangerMarkCount < FoldedMarks)
	{
		Cells = new class'X2ChronoIntMap';
		FoldedMarks = 0;
	}

	for (i = Max(FoldedMarks, Manager.DangerMarkCount - class'XComGameState_TacticalInfluenceManager'.const.DANGER_RING); i < Manager.DangerMarkCount; i++)
	{
		Fold(Manager.DangerMarks[i % class'XComGameState_TacticalInfluenceManager'.const.DANGER_RING]);
	}
	FoldedMarks = Manager.DangerMarkCount;
}

// A mark adds to its cell's weight while the cell is still remembered at the
// mark's turn; otherwise the cell starts over from the mark
function Fold(XComGameState_TacticalInfluenceManager.DangerMark NewMark)
{
	Cells.Put(NewMark.Cell, NewMark.AlienTurn * WEIGHT_SPAN + NewMark.Weight + RememberedWeight(Cells.Get(NewMark.Cell), NewMark.AlienTurn));
}

// The weight a cell's value still carries at alien turn Turn (absent: INDEX_NONE)
static function int RememberedWeight(int Value, int Turn)
{
	return (Value >= 0 && Turn - Value / WEIGHT_SPAN < default.DANGER_TURNS) ? Value % WEIGHT_SPAN : 0;
}

//-----------------------------------------------------------------------------
// Reading
//-----------------------------------------------------------------------------

function int WeightAt(TTile Tile)
{
	return (Cells != none) ? RememberedWeight(Cells.Get(CellOf(Tile)), ReadTurn) : 0;
}

function int WeightNear(vector Position)
{
	local TTile Tile;

	Tile = `XWORLD.GetTileCoordinatesFromPosition(Position);
	return WeightAt(Tile);
}

// The share of a positive tile score a unit keeps on Tile
function float TileScale(TTile Tile)
{
	return 1.0 / (1.0 + default.DANGER_TILE_PENALTY * WeightAt(Tile));
}

// Of the bearings Dir turned by 0, +1, -1, +2 and -2 steps of
// DANGER_SWING_DEGREES, the first whose point at Reach from Center has the
// least danger. A safe straight bearing ends the search at once.
function vector SafestBearing(vector Center, vector Dir, float Reach)
{
	local vector Best, Candidate;
	local int i, BestWeight, Weight;

	Best = Dir;
	BestWeight = WeightNear(Center + Dir * Reach);
	for (i = 1; i < BEARINGS && BestWeight > 0; i++)
	{
		Candidate = Turned(Dir, default.DANGER_SWING_DEGREES * BearingStep(i));
		Weight = WeightNear(Center + Candidate * Reach);
		if (Weight < BestWeight)
		{
			Best = Candidate;
			BestWeight = Weight;
		}
	}

	class'X2ChronoMetrics'.static.Get().Count(eCount_DangerBearings, int(Best != Dir));
	return Best;
}

// 0, +1, -1, +2, -2 for i = 0..4
static function int BearingStep(int i)
{
	return ((i + 1) / 2) * ((i % 2 == 1) ? 1 : -1);
}

// Dir turned about the vertical by Degrees (Z dropped)
static function vector Turned(vector Dir, float Degrees)
{
	local vector Out;
	local float Radians;

	Radians = Degrees * Pi / 180.0;
	Out.X = Dir.X * Cos(Radians) - Dir.Y * Sin(Radians);
	Out.Y = Dir.X * Sin(Radians) + Dir.Y * Cos(Radians);
	return Out;
}

defaultproperties
{
}
