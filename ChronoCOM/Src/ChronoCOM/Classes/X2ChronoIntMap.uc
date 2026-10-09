//=============================================================================
// X2ChronoIntMap
//
// WASP Role: I(c) — an open-addressed int -> int map with linear probing: the
// one probe loop every keyed lookup in ChronoCOM shares (unit records, pods,
// and the Lost's target, cleared-blocking and reserved-tile sets).
//
// Keys are positive ints (ObjectIDs, packed tiles); 0 marks an empty slot.
// The table stays at most half full: Put grows and rehashes before a key
// would cross half load, so every probe chain ends at an empty slot and a
// lookup is O(1) expected. A stored value of INDEX_NONE reads as absent,
// which is how callers retire a key without tombstones.
//
// Holds ints only, so it is safe on session-lived owners.
//=============================================================================

class X2ChronoIntMap extends Object;

const MIN_SIZE = 64;   // power of two

struct IntSlot
{
	var int Key;
	var int Value;
};

var array<IntSlot> Slots;
var int Mask;
var int Count;   // keys in the table

// Empties the map and sizes it to hold Capacity keys at half load or less
function Reset(int Capacity)
{
	Resize(SizeFor(Capacity));
}

static function int SizeFor(int Capacity)
{
	local int Size;

	Size = MIN_SIZE;
	while (Size < Capacity * 2)
	{
		Size *= 2;
	}

	return Size;
}

// A fresh, empty table of Size slots (new array elements are zeroed: Key 0 = empty)
function Resize(int Size)
{
	Slots.Length = 0;
	Slots.Length = Size;
	Mask = Size - 1;
	Count = 0;
}

// The slot holding Key, or the empty slot where it would go
function int SlotFor(int Key)
{
	local int Slot, Probe;

	Slot = (Key * 73856093) & Mask;
	for (Probe = 0; Probe <= Mask; ++Probe)
	{
		if (Slots[Slot].Key == Key || Slots[Slot].Key == 0)
		{
			return Slot;
		}
		Slot = (Slot + 1) & Mask;
	}

	return INDEX_NONE;   // not reached while the table is at most half full
}

// The value stored for Key, or INDEX_NONE
function int Get(int Key)
{
	local int Slot;

	if (Slots.Length == 0)
	{
		return INDEX_NONE;
	}

	Slot = SlotFor(Key);
	return (Slots[Slot].Key == Key) ? Slots[Slot].Value : INDEX_NONE;
}

function Put(int Key, int Value)
{
	local int Slot;

	EnsureRoom();
	Slot = SlotFor(Key);
	if (Slots[Slot].Key != Key)
	{
		Slots[Slot].Key = Key;
		++Count;
	}
	Slots[Slot].Value = Value;
}

// Keeps the table at most half full, counting the key about to be added
function EnsureRoom()
{
	if ((Count + 1) * 2 > Slots.Length)
	{
		Rehash(Max(Slots.Length * 2, MIN_SIZE));
	}
}

function Rehash(int Size)
{
	local array<IntSlot> Old;
	local int i;

	Old = Slots;
	Resize(Size);
	for (i = 0; i < Old.Length; ++i)
	{
		if (Old[i].Key != 0)
		{
			Put(Old[i].Key, Old[i].Value);
		}
	}
}

defaultproperties
{
}
