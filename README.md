# ChronoCOM

![The ChronoCOM logo: a wizard whose glasses are two clock faces](.github/logo.png)

An AI overhaul for XCOM 2: War of the Chosen. The aliens fight as a hivemind; combat values stay
vanilla.

[![standard-readme compliant](https://img.shields.io/badge/readme%20style-standard-brightgreen.svg)](https://github.com/RichardLitt/standard-readme)
![License](https://img.shields.io/badge/License-Apache_2.0-blue)
![WASP v1.0.0](https://img.shields.io/badge/WASP-v1.0.0-blue)
![CDE v1.0.0](https://img.shields.io/badge/CDE-v1.0.0-green)
![MSS v1.0.0](https://img.shields.io/badge/MSS-v1.0.0-orange)

ChronoCOM changes how the aliens decide, not what their shots do: every hit, crit and cover
number is the base game's. What any alien sees, the hive knows; pods that cannot see the squad
close in, wait out of sight and go in together; and the squad's habit is read and countered from
the first mission. Each behavior can be turned off in config.

## Table of Contents

- [Background](#background)
- [Install](#install)
- [Usage](#usage)
- [Build](#build)
- [Contributing](#contributing)
- [License](#license)

## Background

### What it does

**The hive.** An alien knows every soldier that any alien sees now, and no other. While the
hive sees the squad, every pod that does not is told where it is. Gunfire and explosions
carry farther than in vanilla, and every alien in earshot comes. Vanilla's two limits on
how many aliens may join and attack in one fight are lifted.

**The hunt.** A pod that knows where the squad is but cannot see it closes to its edge, 24 to 30
tiles out, takes cover and holds there. Each pod has a temperament, cautious, steady
or eager, that sets how far out it stops and how long it waits. When one runs out of
patience, or a fight starts elsewhere, the waiting pods go in together from different sides,
each at a point no soldier the hive knows of could see when there is one.

**The fight.** A pod in contact presses, holds when it is weakened and outnumbered, and falls
back once, when it is about to be wiped out. Against a squad on overwatch it assaults: its
lowest rank goes in first to draw the shots, and the rest move to flanking tiles or charge.
While a pod presses, its units move to flank. Grenadiers act first and throw at soldiers in
cover. Fire is focused on one soldier at a time, marked with a "Hunted" flyover, and
smoke breaks the hunt. The aliens weigh high ground and, for a few turns, keep
away from the places where the squad's overwatch fired on them or the squad killed one of them.

**The campaign.** From the first mission the hive reads the squad's habit (flanking, high
ground, long or close range, grenades, the overwatch crawl) and answers it with vanilla's own
tools, harder as the campaign goes on.

**Missions.** On missions where the aliens defend an objective, pods that know of the squad pull
back to it and hold it. On a Rescue Operative mission, once the alarm tells the aliens where the
squad is, every pod goes in: none waits at the edge, holds or falls back. Units on a job vanilla
gives priority, such as the ADVENT general running for its escape point, keep vanilla's behavior.

**The Lost.** Only a mission's first Lost reveal plays its cutscene, and the Lost's melee
attack skips its close-up camera.

**For the squad.** EMP grenades and EMP Bombs also jam every enemy they reach until your next
turn: a jammed alien is not told where the squad is, and what it sees does not reach the hive.

### Design

The mod is built with the chronomancy.io framework: every question the hive asks is a bounded
probe on an index kept up to date from each frame's changes, so no decision scans the game's
history or loops over a whole team to answer a question about part of it.

## Install

### Requirements

- XCOM 2: War of the Chosen
- Recommended: X2WOTCCommunityHighlander (ChronoCOM calls no Highlander API)

### Installation

1. Subscribe on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3816506746).
   Or download `ChronoCOM-1.0.0.zip` from
   [Releases](https://github.com/chronomancy-io/chronocom/releases) and unzip it into
   `XCOM 2\XCom2-WarOfTheChosen\XComGame\Mods\`; with the Alternative Mod Launcher, add that
   `XComGame\Mods\` folder under *Settings → Mod directories*.
2. Enable ChronoCOM in your launcher and run War of the Chosen. A new campaign has everything
   from its first mission; for a campaign in progress see [Saves](#saves).

### Compatibility

ChronoCOM replaces four game classes through the engine's class overrides: `XGAIBehavior` (each
alien's decisions), `XGAIPlayer` (the alien player, which orders who moves first),
`XGAIPlayer_TheLost` (the Lost's group moves) and `X2Action_RevealAIBegin` (the reveal
cutscene). Another mod that overrides one of the same classes conflicts with it. The startup
self-test in `Launch.log` lists the engine's override table and whether each ChronoCOM class
resolves (`ChronoCOM: ModClassOverride[...]`).

Other mods may change the same things in two more places:

- `Config/XComAI.ini` adds the directed behavior tree under new node names; no vanilla node is
  redefined. A directed alien runs `ChronoRoot`, a copy of vanilla's `GenericAIRoot` with
  ChronoCOM's branches in front of the character's own tree, so a mod that edits
  `GenericAIRoot` itself does not reach it, and a mod that edits a character's tree does. The
  same file lifts vanilla's two fight limits.
- Templates: vanilla's EMP grenade and EMP Bomb get the jam, with their descriptions
  rewritten in `Localization/XComGame.int`, and the Lost's melee attack loses its close-up
  camera (`bTrimLostAttackCamera`).

No test with another AI mod has been recorded.

### Saves

- **A new campaign** has everything from its first mission. The campaign memory that reads the
  squad's habit is created with the campaign and saved with it.
- **Adding ChronoCOM to a campaign in progress**: the memory is created, empty, when the save is
  loaded (`ChronoCOM Adaptive: created campaign memory` in `Launch.log`), and the pods are
  created when a mission starts, so the full AI begins with the next mission. A mission already
  in progress runs without the pods: its log reads
  `ChronoCOM: ERROR - TacticalInfluenceManager not found` on each alien turn.
- **Removing ChronoCOM from a campaign**: untested. The mod saves objects of its own (the
  campaign memory; during a mission, the pod manager), and what the game does with them once
  the mod is gone is not known. Keep a save from before you enable it.

## Usage

### Configuration

`Config/XComGame.ini`, section `[ChronoCOM.X2ChronoConfig]`:

| Key | Default | Effect |
| --- | --- | --- |
| `bBaselineMode` | `false` | `true` turns every ChronoCOM gameplay change off: vanilla behavior from the same build |
| `bUseTurnIndex` | `true` | `false` turns off the overwatch count and the per-frame known-enemy list, leaving vanilla's own passes; results are identical, only the work changes |
| `bVerboseLogging` | `false` | Per-call debug logging of AI decisions |
| `bLostRevealOnlyFirst` | `true` | Only the mission's first Lost reveal plays its reveal matinee |
| `bTrimLostAttackCamera` | `true` | Lost melee attacks use the default framing camera instead of a cinescript close-up |
| `bPodIntent` | `true` | Pods press, hold, assault or fall back (decided each alien turn), and their units get directives: bait, assault, flush cover with a grenade, flank, hold, fall back then overwatch |
| `bFlankManeuver` | `true` | While a pod presses, as many of its units per turn as its temperament allows (0, 1 or 2) move to a tile that flanks an XCOM unit and is not itself flanked; a unit that already flanks someone keeps the shot. Needs `bPodIntent` |
| `bFocusFire` | `true` | Alien standard shots prefer the target the squad is already working on |
| `bGrenadiersFirst` | `true` | Within a pod, units holding a grenade act first |
| `bFlankersFirst` | `true` | Within a pod, units that already flank an enemy act next |
| `bIntentFlyover` | `true` | A pod that starts to fall back, hold or assault shows a flyover on a member the squad can see |
| `bAdaptiveCounter` | `true` | The aliens counter the squad's detected campaign habit with vanilla's own tile profiles, spread rule and hold threshold |
| `bSoundPropagation` | `true` | Gunfire and explosions are heard by every alien in earshot, seen or not, farther than vanilla's ranges, and idle aliens come to their own side's fights. Scales in `[ChronoCOM.X2EventListener_ChronoNoise]` |
| `bHiveComms` | `true` | While any alien sees an XCOM unit, every member of every pod that sees no soldier is told where at the start of each alien turn, whatever its alert level |
| `bRushToAlerts` | `true` | A pod that knows where the squad is but cannot see it (told, or it lost sight) closes to the edge of the squad's reach, holds there for its temperament's patience, then goes in with every other waiting pod (`TEMPER_*` and `PINCER_OFFSET_TILES` under the pod section). Needs `bPodIntent` |
| `bGuardObjectives` | `true` | On a mission that marks an objective for its defenders, told pods pull back to it and hold it with up to `GUARD_MAX_POD_OVERWATCH` on overwatch instead of hunting the squad, and hold their ground in contact. Needs `bRushToAlerts` |
| `bDangerMap` | `true` | The hive remembers where the squad shot or killed its aliens, and for a few alien turns its moves avoid those places. Tuning under DANGER MAP |
| `bHiddenApproach` | `true` | Pods going in together pick pincer points no soldier the hive knows of could see |
| `bHeightAware` | `true` | Alien tile searches weigh height, with vanilla's height-aware profiles |
| `bHonestKnowledge` | `true` | An alien acts on the XCOM units that any alien sees now, a hivemind, instead of every unit on the map; `false` is vanilla |

`Config/XComAI.ini` also lifts vanilla's two limits on how many aliens may join and attack in
one fight. `bBaselineMode` does not restore them.

Pod intent is tuned in `[ChronoCOM.X2PodCoordinator_Optimized]` (with `ALL_IN_MISSIONS`, the
missions on which no pod holds back), focus fire, the cover flush and the habit counters in
`[ChronoCOM.X2AIBehaviorDirector_Optimized]`, the danger map in `[ChronoCOM.X2ChronoDanger]`
and the EMP jam's length (`JAM_TURNS`) in `[ChronoCOM.X2Ability_ChronoSupport]`; the directed
tree and the grenade profile are in `Config/XComAI.ini`.

There are no hit-calculation keys: cover, height advantage, flanking, weapon range and every
other term are vanilla's.

## Build

ChronoCOM builds with [X2ModBuildCommon](https://github.com/X2CommunityCore/X2ModBuildCommon),
vendored in `.scripts/`, and the *XCOM 2 War of the Chosen SDK* from Steam: run
`.scripts\build.ps1`. The build fails on any compiler warning in ChronoCOM's source and on any
function above cyclomatic complexity 4.

## Contributing

Report issues via [GitHub Issues](https://github.com/chronomancy-io/chronocom/issues) with the
`ChronoCOM:` lines from `Launch.log`.

## License

Apache-2.0 © 2026 the-chronomancer — See [LICENSE](LICENSE) for details.
