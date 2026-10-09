========================================================================
ChronoCOM - the aliens fight as a hivemind
by the-chronomancer
========================================================================

An AI overhaul for XCOM 2: War of the Chosen. Combat values stay vanilla
(every hit, crit and cover number is the base game's); what changes is
how the aliens decide.

- Every pod knows what any alien sees, hears gunfire and explosions far
  past vanilla's ranges, and is told where the fight is.
- Pods that know where the squad is but cannot see it close to the edge
  of its sight, hold there, and go in together from different sides, at
  points no soldier they know of could see. Each pod has a temperament:
  cautious, steady or eager.
- In a fight, pods press, hold or fall back; against overwatch they
  assault, the lowest rank first; units flank while the others shoot;
  grenades go at soldiers in cover; fire is focused on one soldier at a
  time ("Hunted"), and smoke breaks the hunt.
- The aliens weigh high ground, and for a few turns they keep away from
  where your overwatch fired on them or you killed one of them.
- On defense missions the aliens pull back to the objective and hold it.
- On Rescue Operative missions, once the alarm sounds, every pod comes
  for you: none holds back.
- The ADVENT general still runs for the exit.
- From the first mission the aliens read your squad's habit and counter
  it, harder as the campaign goes on.
- The Lost: only the first reveal of a mission plays its cutscene.

For the squad:
- EMP grenades and EMP bombs also jam the hive's comms.

Every behavior can be turned off: switches in Config\XComGame.ini, and
the fight limits in Config\XComAI.ini.
