#pragma semicolon 1
#pragma newdecls required

/**
 * ============================================================================
 * L4D2 AI Director — Deterministic State-Machine Edition (v0.3.0_sm)
 * ============================================================================
 * Implements the complete specification from `l4d2_ai_director_system_spec.md` (v1.2.0)
 * as a local deterministic State-Machine (prior to external LLM hookup):
 *
 * 1. Dedicated File Logger (`addons/sourcemod/logs/l4d2_llm_director.log`)
 *    - Logs EVERY Event Hook and Left4DHooks Forward to prevent blind spots.
 *
 * 2. Engine / VScript / CVar Lock Bypass (Reference: `l4dinfectedbots.sp`, `all4dead2.sp`, `abm.sp`)
 *    - Overrides VScript `MaxSpecials`, `DominatorLimit`, `*Limit` via both
 *      `L4D2_OnGetScriptValueInt` and `L4D_OnGetScriptValueInt`, and `SpecialRespawnInterval`
 *      via `L4D2_OnGetScriptValueFloat` and `L4D_OnGetScriptValueFloat`.
 *    - Overrides `L4D_OnIsTeamFull` (`team == 3 -> full = false`) so the engine never
 *      rejects or kicks the 4th+ SI with "Kicked by Console : infected team is full".
 *    - Prepares `NextBotCreatePlayerBot<Smoker/Boomer/Hunter/Spitter/Jockey/Charger/Tank>`
 *      SDKCalls from `all4dead2` / `l4dinfectedbots` gamedata to bypass `ZombieManager::SpawnSpecial`
 *      caps whenever needed.
 *    - Unlocks `z_max_player_zombies` and `z_minion_limit` to 16.
 *    - Promptly kicks dead SI FakeClients on `player_death` (0.5s, 6.0s for Spitter)
 *      so dead bots never clog Team 3 slots waiting for death animation cleanup.
 *
 * 3. Multi-Tier SI Spawning Pipeline + Spec Section 5 Guardrails
 *    - 32-Slot Safety Guard (`GetClientCount(false) + neededSpawns <= 28`).
 *    - Dynamic Multi-Survivor Asymmetric Scaling (`target_si_limit = alive_survivors + 2`).
 *    - Anti-Hard-CC Class Cap (`maxPerClass = RoundToCeil(alive_survivors / 3.0)`),
 *      converting excess pinners to Spitter/Boomer.
 *    - Tier 1: Nav-scored `L4D_GetRandomPZSpawnPosition` around target anchor
 *      matching Spec `SpawnDirection` (`FRONT`, `MIDDLE_FLANK`, `BEHIND`,
 *      `ABOVE_ROOF`, `BELOW_FLOOR`), distance, and LOS.
 *    - Tier 2: Relaxed `L4D_GetRandomPZSpawnPosition` across all alive survivors.
 *    - Tier 3: Radial Nav-Mesh sampling (`L4D2Direct_GetTerrorNavArea`) out of LOS.
 *    - Tier 4: `z_spawn_old <class> auto` cheat fallback.
 *    - Spawner: `L4D2_SpawnSpecial` + `NextBotCreatePlayerBot<T>` SDKCall fallback.
 *
 * 4. Full Spec v1.2.0 Tactical Decision Engine & Zero-Softlock Boss System
 *    - `SituationDiagnosis` + `TacticalIntent` + `TargetRole` + `SpawnDirection`
 *    - Exact Spec Section 3.2 Impact Score:
 *      `Score_i = (SI Kills * 3) + (Teammate Revives * 5) + (Pins Cleared * 4) + (Damage Dealt / 100.0)`
 *    - `HordeDirective` (`KEEP_NATIVE`, `SCALE_0.5X`, `SCALE_1.2X`, `SCALE_1.6X`, `RIOT_SQUAD`)
 *    - `BossDirective` (`RESPECT_NATIVE`, `ADD_1_TANK`, `ADD_2_TANKS`, `BLOCK_EXTRA_RESPAWN`)
 *      hooked via `L4D_OnSpawnTank_Post` with dynamic Tank HP (`5000 + 800 * alive_survivors`)
 *      and staggered non-overlapping multi-Tank spawns — never blocking native Finale Tanks!
 *    - `freeze_ambush` (`FL_FROZEN` ambush until proximity/LOS/damage/timeout)
 *    - `focus_strike_enabled` (Dynamic Focus Squad <= floor(active_si / 2),
 *      `L4D2_OnChooseVictim` diversion, `L4D2_CommandABot` + `L4D2_StartAssault` + `L4D2_RushVictim`,
 *      and close-range guaranteed pin via `L4D_ForceHunterVictim` /
 *      `L4D_ForceSmokerVictim` / `L4D2_ForceJockeyVictim`)
 * ============================================================================
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#undef REQUIRE_PLUGIN
#include <left4dhooks>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION "0.3.0_sm"

// ============================================================================
// Constants & Limits
// ============================================================================

#define ZC_SMOKER               1
#define ZC_BOOMER               2
#define ZC_HUNTER               3
#define ZC_SPITTER              4
#define ZC_JOCKEY               5
#define ZC_CHARGER              6
#define ZC_WITCH                7
#define ZC_TANK                 8

#define TEAM_SPECTATOR          1
#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

#define MAX_SI_SLOTS            16
#define MAX_WAVE_SI             12
#define SAFE_CLIENT_SLOT_LIMIT  28
#define SPAWN_INTERVAL          0.35

#define SPAWN_DIST_MIN          300.0
#define SPAWN_DIST_MAX          1500.0
#define SPAWN_HEIGHT_THRESHOLD  110.0

// Infected models (Reference: all4dead2.sp / l4dinfectedbots.sp)
#define MODEL_SMOKER            "models/infected/smoker.mdl"
#define MODEL_BOOMER            "models/infected/boomer.mdl"
#define MODEL_HUNTER            "models/infected/hunter.mdl"
#define MODEL_SPITTER           "models/infected/spitter.mdl"
#define MODEL_JOCKEY            "models/infected/jockey.mdl"
#define MODEL_CHARGER           "models/infected/charger.mdl"
#define MODEL_TANK              "models/infected/hulk.mdl"
#define MODEL_RIOT              "models/infected/common_male_riot.mdl"
#define MODEL_CEDA              "models/infected/common_male_ceda.mdl"
#define MODEL_CLOWN             "models/infected/common_male_clown.mdl"

// NextBotCreatePlayerBot<T> signature names
#define NAME_CreateSmoker       "NextBotCreatePlayerBot<Smoker>"
#define NAME_CreateBoomer       "NextBotCreatePlayerBot<Boomer>"
#define NAME_CreateHunter       "NextBotCreatePlayerBot<Hunter>"
#define NAME_CreateSpitter      "NextBotCreatePlayerBot<Spitter>"
#define NAME_CreateJockey       "NextBotCreatePlayerBot<Jockey>"
#define NAME_CreateCharger      "NextBotCreatePlayerBot<Charger>"
#define NAME_CreateTank         "NextBotCreatePlayerBot<Tank>"

#define NAV_SPAWN_EMPTY                  0x2
#define NAV_SPAWN_STOP_SCAN              0x4
#define NAV_SPAWN_BATTLESTATION          0x20
#define NAV_SPAWN_FINALE                 0x40
#define NAV_SPAWN_PLAYER_START           0x80
#define NAV_SPAWN_BATTLEFIELD            0x100
#define NAV_SPAWN_IGNORE_VISIBILITY      0x200
#define NAV_SPAWN_NOT_CLEARABLE          0x400
#define NAV_SPAWN_CHECKPOINT             0x800
#define NAV_SPAWN_OBSCURED               0x1000
#define NAV_SPAWN_NO_MOBS                0x2000
#define NAV_SPAWN_THREAT                 0x4000
#define NAV_SPAWN_RESCUE_VEHICLE         0x8000
#define NAV_SPAWN_DESTROYED_DOOR         0x40000
#define NAV_SPAWN_NOTHREAT               0x80000
#define NAV_SPAWN_ESCAPE_ROUTE           0x200000

// ============================================================================
// Spec Enums (`l4d2_ai_director_system_spec.md` v1.2.0 Section 4)
// ============================================================================

enum DirectorState
{
	STATE_DORMANT = 0,  // Safe room / round not started
	STATE_COOLDOWN,     // Mercy / Relax window between waves
	STATE_EVALUATE,     // Running Telemetry -> Diagnosis -> Tactical Plan
	STATE_SPAWNING,     // Executing multi-tier wave spawn queue
	STATE_COMBAT        // Monitoring active wave, focus strike, freeze ambush
};

enum SituationDiagnosis
{
	DIAG_HEALTHY_STEADY_PUSH = 0,
	DIAG_SPEEDRUNNER_ISOLATED,
	DIAG_REAR_STRAGGLER_EXPOSED,
	DIAG_MVP_PLAYER_CARRYING,
	DIAG_CORNER_CAMPING_STRONG,
	DIAG_TEAM_CRITICAL_EXHAUSTED,
	DIAG_NATIVE_INFINITE_RUSH,
	DIAG_FINALE_BOSS_STAGE
};

enum TacticalIntent
{
	INTENT_ESCALATE_CLIMAX = 0,
	INTENT_SNIPE_LONE_WOLF,
	INTENT_ASSASSINATE_MVP,
	INTENT_BREAK_CAMPING_FORMATION,
	INTENT_MERCY_RELAX_ALLOW_HEAL,
	INTENT_MAINTAIN_GAUNTLET_FLOW
};

enum TargetRole
{
	ROLE_NONE = 0,
	ROLE_P1_FRONT,      // Highest flow progress
	ROLE_P4_REAR,       // Lowest flow progress
	ROLE_P_MVP,         // Highest Impact Score (SI Kills*3 + Revives*5 + PinsCleared*4 + Dmg/100)
	ROLE_P_VULNERABLE   // Lowest effective HP / high incap count
};

enum SpawnDirection
{
	DIR_FRONT = 0,      // Ahead along flow / forward vector
	DIR_MIDDLE_FLANK,   // Left/Right side flanks (45..135 deg)
	DIR_BEHIND,         // Rear ambush (> 120 deg)
	DIR_ABOVE_ROOF,     // Elevated vantage (+Z >= 110)
	DIR_BELOW_FLOOR     // Lower floor / trench (-Z <= -110)
};

enum HordeDirective
{
	HORDE_KEEP_NATIVE = 0,
	HORDE_SCALE_05X,
	HORDE_SCALE_12X,
	HORDE_SCALE_16X,
	HORDE_RIOT_SQUAD
};

// Spec v1.2.0 Section 2.2 / 4.1 / 6.2 Additive Boss (Tank) Directive
enum BossDirective
{
	BOSS_RESPECT_NATIVE = 0,     // Keep native 1 Tank (dynamic HP scaled by alive_survivors)
	BOSS_ADD_1_TANK,             // Add +1 extra Tank (total 2 Tanks) via staggered timer
	BOSS_ADD_2_TANKS,            // Add +2 extra Tanks (total 3 Tanks, 0.75x HP each)
	BOSS_BLOCK_EXTRA_RESPAWN     // Mercy / Finale: never add extra Tanks, 100% respect native Tank
};

// ============================================================================
// String Tables for Logging & HUD
// ============================================================================

static const char g_sStateNames[][] =
{
	"DORMANT",
	"COOLDOWN",
	"EVALUATE",
	"SPAWNING",
	"COMBAT"
};

static const char g_sDiagnosisNames[][] =
{
	"HEALTHY_STEADY_PUSH",
	"SPEEDRUNNER_ISOLATED",
	"REAR_STRAGGLER_EXPOSED",
	"MVP_PLAYER_CARRYING",
	"CORNER_CAMPING_STRONG",
	"TEAM_CRITICAL_EXHAUSTED",
	"NATIVE_INFINITE_RUSH",
	"FINALE_BOSS_STAGE"
};

static const char g_sIntentNames[][] =
{
	"ESCALATE_CLIMAX",
	"SNIPE_LONE_WOLF",
	"ASSASSINATE_MVP",
	"BREAK_CAMPING_FORMATION",
	"MERCY_RELAX_ALLOW_HEAL",
	"MAINTAIN_GAUNTLET_FLOW"
};

static const char g_sRoleNames[][] =
{
	"NONE",
	"P1_FRONT",
	"P4_REAR",
	"P_MVP",
	"P_VULNERABLE"
};

static const char g_sDirNames[][] =
{
	"FRONT",
	"MIDDLE_FLANK",
	"BEHIND",
	"ABOVE_ROOF",
	"BELOW_FLOOR"
};

static const char g_sHordeNames[][] =
{
	"KEEP_NATIVE",
	"SCALE_0.5X",
	"SCALE_1.2X",
	"SCALE_1.6X",
	"RIOT_SQUAD"
};

static const char g_sBossNames[][] =
{
	"RESPECT_NATIVE",
	"ADD_1_TANK",
	"ADD_2_TANKS",
	"BLOCK_EXTRA_RESPAWN"
};

static const char g_sSINames[][] =
{
	"None",
	"Smoker",
	"Boomer",
	"Hunter",
	"Spitter",
	"Jockey",
	"Charger",
	"Witch",
	"Tank"
};

static const char g_sSICmdNames[][] =
{
	"",
	"smoker",
	"boomer",
	"hunter",
	"spitter",
	"jockey",
	"charger",
	"witch",
	"tank"
};

// ============================================================================
// Global State Variables
// ============================================================================

// Logging
char g_sLogPath[PLATFORM_MAX_PATH];

// Direct Bot Creation SDKCalls (`NextBotCreatePlayerBot<T>`)
Handle g_hCreateSmoker  = null;
Handle g_hCreateBoomer  = null;
Handle g_hCreateHunter  = null;
Handle g_hCreateSpitter = null;
Handle g_hCreateJockey  = null;
Handle g_hCreateCharger = null;
Handle g_hCreateTank    = null;
bool   g_bSDKCallsReady = false;

// ConVars
ConVar g_hCvarEnabled;
ConVar g_hCvarChatReport;
ConVar g_hCvarVerboseHookLog;
ConVar g_hCvarMinCooldown;
ConVar g_hCvarMaxCooldown;
ConVar g_hCvarMaxWaveSI;
ConVar g_hCvarHordeScale;

// Engine ConVars we manage
ConVar g_hDirectorNoSpecials;
ConVar g_hDirectorAllowInfectedBots;
ConVar g_hZMaxPlayerZombies;
ConVar g_hZMinionLimit;
ConVar g_hZSpawnSafetyRange;
ConVar g_hZSmokerLimit;
ConVar g_hZBoomerLimit;
ConVar g_hZHunterLimit;
ConVar g_hZSpitterLimit;
ConVar g_hZJockeyLimit;
ConVar g_hZChargerLimit;
ConVar g_hSurvivorMaxIncapCount;

// State Machine
DirectorState      g_eState = STATE_DORMANT;
SituationDiagnosis g_eDiagnosis = DIAG_HEALTHY_STEADY_PUSH;
TacticalIntent     g_eIntent = INTENT_ESCALATE_CLIMAX;
TacticalIntent     g_eLastWaveIntent = INTENT_MAINTAIN_GAUNTLET_FLOW;
TargetRole         g_eTargetRole = ROLE_NONE;
SpawnDirection     g_eSpawnDir = DIR_FRONT;
HordeDirective     g_eHordeDir = HORDE_KEEP_NATIVE;
BossDirective      g_eBossDir = BOSS_RESPECT_NATIVE;

bool  g_bLeftSafeArea = false;
bool  g_bOurSpawn = false;
bool  g_bSpawningExtraTank = false;
bool  g_bFreezeAmbush = false;
bool  g_bFocusStrike = false;
bool  g_bPanicEventActive = false;
bool  g_bFinaleActive = false;

int   g_iWaveNumber = 0;
int   g_iWaveTargetCount = 0;
int   g_iWaveCursor = 0;
int   g_iWaveSuccessCount = 0;
int   g_iWaveQueue[MAX_WAVE_SI];
int   g_iTargetSurvivor = 0;
int   g_iCurrentCooldown = 28;
int   g_iWipeCount = 0;
int   g_iNativeFinaleStage = 18; // FINALE_NONE = 18

float g_fStateEnterTime = 0.0;
float g_fCombatTimeout = 25.0;
float g_fPeakFlowRatio = 0.0;
float g_fPrevPeakFlowRatio = 0.0;
float g_fLastFlowSampleTime = 0.0;
float g_fFlowVelocity = 0.0;          // % flow per minute
float g_fStagnationSeconds = 0.0;     // Seconds team stayed in <250 radius
float g_fStagnationAnchor[3];
float g_fWaveCombatStartTime = 0.0;   // When current wave entered combat (or ambush unfroze)
float g_fLastWaveClearDuration = 0.0; // Seconds it took survivors to wipe the previous SI wave
float g_fLastAdditiveTankTime = 0.0;  // Prevents double-multiplying when map spawns 2 native Tanks in 1 wave
bool  g_bWaveWaitingForAmbush = false;
float g_fLastPinForceTime[MAXPLAYERS + 1];
float g_fLastChooseVictimLogTime[MAXPLAYERS + 1];
float g_fLastScriptValueLogTime = 0.0;
float g_fLastTeamFullLogTime = 0.0;

// Focus Squad & Freeze Ambush per-client tracking
bool  g_bIsFocusSquad[MAXPLAYERS + 1];
bool  g_bIsFrozenAmbush[MAXPLAYERS + 1];
float g_fFreezeExpireTime[MAXPLAYERS + 1];

// Active Pin Tracking (to credit `Pins Cleared` in Spec Section 3.2)
int   g_iPinningVictim[MAXPLAYERS + 1];

// Per-Survivor Telemetry (Spec Section 3.1 & 3.2)
int   g_iKillsSI[MAXPLAYERS + 1];
int   g_iKillsCI[MAXPLAYERS + 1];
int   g_iHeadshots[MAXPLAYERS + 1];
int   g_iRevivesDone[MAXPLAYERS + 1];
int   g_iPinsCleared[MAXPLAYERS + 1];
int   g_iDamageDealtSI[MAXPLAYERS + 1];
int   g_iDamageTaken[MAXPLAYERS + 1];
int   g_iFriendlyFireDone[MAXPLAYERS + 1];
int   g_iIncapCount[MAXPLAYERS + 1];
int   g_iWaveDamageTaken = 0;
int   g_iWaveIncapCount = 0;

// Timers
Handle g_hMainTickTimer = null;
Handle g_hSpawnQueueTimer = null;

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
	name        = "[L4D2] AI Director (State Machine Edition)",
	author      = "Hua Server AI Director Team",
	description = "Deterministic State-Machine AI Director implementing l4d2_ai_director_system_spec.md v1.2.0",
	version     = PLUGIN_VERSION,
	url         = ""
};

// ============================================================================
// Dedicated Logger
// ============================================================================

void InitLogFile()
{
	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/l4d2_llm_director.log");
}

void DirLog(const char[] format, any ...)
{
	if (g_sLogPath[0] == '\0')
	{
		InitLogFile();
	}

	char buffer[1024];
	VFormat(buffer, sizeof(buffer), format, 2);

	char mapName[64];
	GetCurrentMap(mapName, sizeof(mapName));

	LogToFileEx(g_sLogPath, "[%s | %s | W#%d | t=%.1f] %s",
		mapName,
		g_sStateNames[g_eState],
		g_iWaveNumber,
		GetGameTime(),
		buffer);
}

void HookLog(const char[] hookName, const char[] format, any ...)
{
	if (g_sLogPath[0] == '\0')
	{
		InitLogFile();
	}

	char details[768];
	VFormat(details, sizeof(details), format, 3);

	LogToFileEx(g_sLogPath, "[HOOK:%s | %s | W#%d | t=%.1f] %s",
		hookName,
		g_sStateNames[g_eState],
		g_iWaveNumber,
		GetGameTime(),
		details);
}

// ============================================================================
// Lifecycle: AskPluginLoad2 / OnPluginStart / OnPluginEnd / OnMapStart / OnMapEnd
// ============================================================================

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// Silvers omitted these two from __pl_l4dh_SetNTVOptional in left4dhooks.inc
	MarkNativeAsOptional("L4D2_RushVictim");
	MarkNativeAsOptional("L4D2_StartAssault");
	return APLRes_Success;
}

public void OnPluginStart()
{
	InitLogFile();
	DirLog("================================================================");
	DirLog("OnPluginStart: Loading L4D2 AI Director v%s (State-Machine Edition)", PLUGIN_VERSION);

	// Initialize NextBotCreatePlayerBot<T> SDKCalls (Ref: all4dead2.sp / l4dinfectedbots.sp)
	InitSDKCalls();

	// Plugin ConVars (Spec Section 2.2 / 5.1: wave SI scales up to 12 for 10 survivors)
	g_hCvarEnabled        = CreateConVar("l4d2_dir_enabled", "1", "Enable L4D2 State-Machine AI Director (0=Off, 1=On)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarChatReport     = CreateConVar("l4d2_dir_chat_report", "1", "Show tactical wave summary in chat (0=Off, 1=On)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarVerboseHookLog = CreateConVar("l4d2_dir_verbose_hook_log", "1", "Log high-frequency hooks like OnChooseVictim/OnGetScriptValue (throttled)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarMinCooldown    = CreateConVar("l4d2_dir_min_cooldown", "10", "Minimum cooldown seconds between waves", FCVAR_NOTIFY, true, 5.0, true, 60.0);
	g_hCvarMaxCooldown    = CreateConVar("l4d2_dir_max_cooldown", "35", "Maximum cooldown seconds between waves", FCVAR_NOTIFY, true, 10.0, true, 90.0);
	g_hCvarMaxWaveSI      = CreateConVar("l4d2_dir_max_wave_si", "12", "Maximum Special Infected per wave (Spec Section 5.1: up to 12)", FCVAR_NOTIFY, true, 1.0, true, 12.0);
	g_hCvarHordeScale     = CreateConVar("l4d2_dir_horde_scale", "0.6", "Multiplier for common infected horde spawns (0.0=No hordes, 0.5=Half, 1.0=Native)", FCVAR_NOTIFY, true, 0.0, true, 2.0);

	// Cache & unlock Engine ConVars (Reference: l4dinfectedbots.sp & abm.sp)
	SetupEngineConVars();

	// Hook Game Events
	// Note: player_spawn and ability_use use EventHookMode_Pre because AI_HardSI.smx
	// hooks them in Pre mode and returns Plugin_Handled!
	HookEvent("round_start",            Event_RoundStart,           EventHookMode_PostNoCopy);
	HookEvent("round_end",              Event_RoundEnd,             EventHookMode_PostNoCopy);
	HookEvent("mission_lost",           Event_MissionLost,          EventHookMode_PostNoCopy);
	HookEvent("map_transition",         Event_MapTransition,        EventHookMode_PostNoCopy);
	HookEvent("finale_vehicle_leaving", Event_FinaleVehicleLeaving, EventHookMode_PostNoCopy);
	HookEvent("finale_start",           Event_FinaleStart,          EventHookMode_PostNoCopy);
	HookEvent("finale_radio_start",     Event_FinaleRadioStart,     EventHookMode_PostNoCopy);
	HookEvent("gauntlet_finale_start",  Event_GauntletFinaleStart,  EventHookMode_PostNoCopy);
	HookEvent("create_panic_event",     Event_CreatePanicEvent,     EventHookMode_Post);

	HookEvent("player_left_safe_area",  Event_PlayerLeftSafeArea,   EventHookMode_Post);
	HookEvent("door_open",              Event_DoorOpen,             EventHookMode_Post);

	HookEvent("player_spawn",           Event_PlayerSpawn_Pre,      EventHookMode_Pre);
	HookEvent("ability_use",            Event_AbilityUse_Pre,       EventHookMode_Pre);
	HookEvent("player_hurt",            Event_PlayerHurt,           EventHookMode_Post);
	HookEvent("player_shoved",          Event_PlayerShoved,         EventHookMode_Post);
	HookEvent("player_incapacitated",   Event_PlayerIncap,          EventHookMode_Post);
	HookEvent("revive_success",         Event_ReviveSuccess,        EventHookMode_Post);
	HookEvent("heal_success",           Event_HealSuccess,          EventHookMode_Post);
	HookEvent("player_death",           Event_PlayerDeath,          EventHookMode_Post);
	HookEvent("infected_death",         Event_InfectedDeath,        EventHookMode_Post);

	// Pinning / Control Start & Release Events (for Spec Section 3.2 Pins Cleared tracking)
	HookEvent("lunge_shove",            Event_PinStarted,           EventHookMode_Post);
	HookEvent("tongue_grab",            Event_PinStarted,           EventHookMode_Post);
	HookEvent("jockey_ride",            Event_PinStarted,           EventHookMode_Post);
	HookEvent("charger_pummel_start",   Event_PinStarted,           EventHookMode_Post);
	HookEvent("charger_carry_start",    Event_PinStarted,           EventHookMode_Post);

	HookEvent("pounce_stopped",         Event_PinCleared,           EventHookMode_Post);
	HookEvent("tongue_pull_stopped",    Event_PinCleared,           EventHookMode_Post);
	HookEvent("jockey_ride_end",        Event_PinCleared,           EventHookMode_Post);
	HookEvent("charger_pummel_end",     Event_PinCleared,           EventHookMode_Post);

	// Admin / Debug Commands
	RegAdminCmd("sm_dir_status",  Cmd_DirStatus,  ADMFLAG_GENERIC, "Print current AI Director state and telemetry");
	RegAdminCmd("sm_dir_wave",    Cmd_DirWave,    ADMFLAG_CHEATS,  "Force an immediate AI Director evaluation & wave");
	RegAdminCmd("sm_dir_spawnsi", Cmd_DirSpawnSI, ADMFLAG_CHEATS,  "Test spawning a specific SI class (1..6)");

	// Late-load support: only check if map has fully initialized (Left4DHooks g_pDirector pointer is valid)
	if (L4D_HasMapStarted() && IsAnySurvivorOutsideSafeRoom())
	{
		DirLog("OnPluginStart: Detected survivors already outside safe area (late load). Activating in 3.0s.");
		ActivateDirector(3.0, "LateLoad_OutsideSafeArea");
	}
}

public void OnPluginEnd()
{
	DirLog("OnPluginEnd: Unloading L4D2 AI Director v%s. Restoring state.", PLUGIN_VERSION);
	ResetDirectorState("OnPluginEnd");

	// Unfreeze any frozen SI
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED)
		{
			SetEntityFlags(i, GetEntityFlags(i) & ~FL_FROZEN);
		}
	}

	RestoreEngineConVars();
}

public void OnMapStart()
{
	InitLogFile();
	char mapName[64];
	GetCurrentMap(mapName, sizeof(mapName));
	DirLog("OnMapStart: Map started -> %s", mapName);

	// Precache SI / Tank / Uncommon models for NextBotCreatePlayerBot<T> SDKCalls
	PrecacheModel(MODEL_SMOKER, true);
	PrecacheModel(MODEL_BOOMER, true);
	PrecacheModel(MODEL_HUNTER, true);
	PrecacheModel(MODEL_SPITTER, true);
	PrecacheModel(MODEL_JOCKEY, true);
	PrecacheModel(MODEL_CHARGER, true);
	PrecacheModel(MODEL_TANK, true);
	PrecacheModel(MODEL_RIOT, true);
	PrecacheModel(MODEL_CEDA, true);
	PrecacheModel(MODEL_CLOWN, true);

	g_iWipeCount = 0;
	EnforceEngineConVars();
	ResetDirectorState("OnMapStart");
}

public void OnMapEnd()
{
	char mapName[64];
	GetCurrentMap(mapName, sizeof(mapName));
	DirLog("OnMapEnd: Map ended -> %s", mapName);

	ResetDirectorState("OnMapEnd");
}

// ============================================================================
// Direct Infected Bot Creation SDKCalls (`NextBotCreatePlayerBot<T>`)
// Reference: `all4dead2.sp` lines 1605-1779 & `l4dinfectedbots.sp` lines 3762-3962
// ============================================================================

void InitSDKCalls()
{
	GameData hGameConf = LoadGameConfigFile("all4dead2");
	char usedConfig[32] = "all4dead2";
	if (hGameConf == null)
	{
		hGameConf = LoadGameConfigFile("l4dinfectedbots");
		strcopy(usedConfig, sizeof(usedConfig), "l4dinfectedbots");
	}

	if (hGameConf == null)
	{
		DirLog("WARNING: Neither all4dead2.txt nor l4dinfectedbots.txt gamedata found; NextBotCreatePlayerBot SDKCalls disabled.");
		g_bSDKCallsReady = false;
		return;
	}

	Address replaceWithBot = GameConfGetAddress(hGameConf, "NextBotCreatePlayerBot.jumptable");
	if (replaceWithBot != Address_Null && LoadFromAddress(replaceWithBot, NumberType_Int8) == 0x68)
	{
		PrepWindowsCreateBotCalls(replaceWithBot);
	}
	else
	{
		PrepSignatureCreateBotCalls(hGameConf);
	}

	delete hGameConf;

	g_bSDKCallsReady = (
		g_hCreateSmoker  != null &&
		g_hCreateBoomer  != null &&
		g_hCreateHunter  != null &&
		g_hCreateSpitter != null &&
		g_hCreateJockey  != null &&
		g_hCreateCharger != null &&
		g_hCreateTank    != null);

	DirLog("InitSDKCalls: Loaded NextBotCreatePlayerBot<T> from %s.txt -> ready=%d",
		usedConfig, g_bSDKCallsReady ? 1 : 0);
}

void LoadStringFromAddress(Address addr, char[] buffer, int maxlength)
{
	int i = 0;
	while (i < maxlength - 1)
	{
		int val = LoadFromAddress(addr + view_as<Address>(i), NumberType_Int8);
		if (val == 0)
		{
			break;
		}
		buffer[i] = view_as<char>(val);
		i++;
	}
	buffer[i] = '\0';
}

Handle PrepCreateBotCallFromAddress(StringMap hSiFuncMap, const char[] siName)
{
	Address addr;
	if (!hSiFuncMap.GetValue(siName, addr) || addr == Address_Null)
	{
		DirLog("ERROR: NextBotCreatePlayerBot<%s> address missing in jumptable.", siName);
		return null;
	}

	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetAddress(addr))
	{
		DirLog("ERROR: PrepSDKCall_SetAddress failed for NextBotCreatePlayerBot<%s>.", siName);
		return null;
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_CBasePlayer, SDKPass_Pointer);
	return EndPrepSDKCall();
}

void PrepWindowsCreateBotCalls(Address jumpTableAddr)
{
	StringMap hInfectedFuncs = new StringMap();
	for (int i = 0; i < 7; i++)
	{
		Address caseBase = jumpTableAddr + view_as<Address>(i * 12);
		Address siStringAddr = view_as<Address>(LoadFromAddress(caseBase + view_as<Address>(1), NumberType_Int32));
		char siName[32];
		LoadStringFromAddress(siStringAddr, siName, sizeof(siName));

		Address funcRefAddr = caseBase + view_as<Address>(6);
		int funcRelOffset = LoadFromAddress(funcRefAddr, NumberType_Int32);
		Address callOffsetBase = caseBase + view_as<Address>(10);
		Address nextBotCreatePlayerBotTAddr = callOffsetBase + view_as<Address>(funcRelOffset);
		hInfectedFuncs.SetValue(siName, nextBotCreatePlayerBotTAddr);
	}

	g_hCreateSmoker  = PrepCreateBotCallFromAddress(hInfectedFuncs, "Smoker");
	g_hCreateBoomer  = PrepCreateBotCallFromAddress(hInfectedFuncs, "Boomer");
	g_hCreateHunter  = PrepCreateBotCallFromAddress(hInfectedFuncs, "Hunter");
	g_hCreateSpitter = PrepCreateBotCallFromAddress(hInfectedFuncs, "Spitter");
	g_hCreateJockey  = PrepCreateBotCallFromAddress(hInfectedFuncs, "Jockey");
	g_hCreateCharger = PrepCreateBotCallFromAddress(hInfectedFuncs, "Charger");
	g_hCreateTank    = PrepCreateBotCallFromAddress(hInfectedFuncs, "Tank");

	delete hInfectedFuncs;
}

Handle PrepSingleSignatureBotCall(GameData hGameConf, const char[] sigName)
{
	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, sigName))
	{
		DirLog("ERROR: Signature %s not found in gamedata.", sigName);
		return null;
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_CBasePlayer, SDKPass_Pointer);
	return EndPrepSDKCall();
}

void PrepSignatureCreateBotCalls(GameData hGameConf)
{
	g_hCreateSmoker  = PrepSingleSignatureBotCall(hGameConf, NAME_CreateSmoker);
	g_hCreateBoomer  = PrepSingleSignatureBotCall(hGameConf, NAME_CreateBoomer);
	g_hCreateHunter  = PrepSingleSignatureBotCall(hGameConf, NAME_CreateHunter);
	g_hCreateSpitter = PrepSingleSignatureBotCall(hGameConf, NAME_CreateSpitter);
	g_hCreateJockey  = PrepSingleSignatureBotCall(hGameConf, NAME_CreateJockey);
	g_hCreateCharger = PrepSingleSignatureBotCall(hGameConf, NAME_CreateCharger);
	g_hCreateTank    = PrepSingleSignatureBotCall(hGameConf, NAME_CreateTank);
}

/**
 * Spawns an SI or Tank bot directly via `NextBotCreatePlayerBot<T>` SDKCall
 * (Reference: `all4dead2.sp` lines 604-684, `l4dinfectedbots.sp` lines 5427-5563).
 * Completely bypasses `ZombieManager::SpawnSpecial` internal class/dominator limits.
 */
int SpawnInfectedBotViaSDKCall(int zc, const float spawnPos[3], const float spawnAng[3])
{
	if (!g_bSDKCallsReady || !HasSafeClientSlotMargin(1))
	{
		return 0;
	}

	int bot = 0;
	char modelPath[64];

	g_bOurSpawn = true;
	switch (zc)
	{
		case ZC_SMOKER:
		{
			bot = SDKCall(g_hCreateSmoker, "Smoker");
			strcopy(modelPath, sizeof(modelPath), MODEL_SMOKER);
		}
		case ZC_BOOMER:
		{
			bot = SDKCall(g_hCreateBoomer, "Boomer");
			strcopy(modelPath, sizeof(modelPath), MODEL_BOOMER);
		}
		case ZC_HUNTER:
		{
			bot = SDKCall(g_hCreateHunter, "Hunter");
			strcopy(modelPath, sizeof(modelPath), MODEL_HUNTER);
		}
		case ZC_SPITTER:
		{
			bot = SDKCall(g_hCreateSpitter, "Spitter");
			strcopy(modelPath, sizeof(modelPath), MODEL_SPITTER);
		}
		case ZC_JOCKEY:
		{
			bot = SDKCall(g_hCreateJockey, "Jockey");
			strcopy(modelPath, sizeof(modelPath), MODEL_JOCKEY);
		}
		case ZC_CHARGER:
		{
			bot = SDKCall(g_hCreateCharger, "Charger");
			strcopy(modelPath, sizeof(modelPath), MODEL_CHARGER);
		}
		case ZC_TANK:
		{
			bot = SDKCall(g_hCreateTank, "Tank");
			strcopy(modelPath, sizeof(modelPath), MODEL_TANK);
		}
	}
	g_bOurSpawn = false;

	if (bot > 0 && bot <= MaxClients && IsClientInGame(bot))
	{
		SetEntityModel(bot, modelPath);
		ChangeClientTeam(bot, TEAM_INFECTED);
		SetEntProp(bot, Prop_Send, "m_usSolidFlags", 16);
		SetEntProp(bot, Prop_Send, "movetype", 2);
		SetEntProp(bot, Prop_Send, "deadflag", 0);
		SetEntProp(bot, Prop_Send, "m_lifeState", 0);
		SetEntProp(bot, Prop_Send, "m_iObserverMode", 0);
		SetEntProp(bot, Prop_Send, "m_iPlayerState", 0);
		SetEntProp(bot, Prop_Send, "m_zombieState", 0);
		DispatchSpawn(bot);
		ActivateEntity(bot);
		TeleportEntity(bot, spawnPos, spawnAng, NULL_VECTOR);
		return bot;
	}

	return 0;
}

// ============================================================================
// Engine ConVar Unlocking & Enforcement (Ref: l4dinfectedbots.sp, abm.sp)
// ============================================================================

void SetupEngineConVars()
{
	g_hDirectorNoSpecials        = FindConVar("director_no_specials");
	g_hDirectorAllowInfectedBots = FindConVar("director_allow_infected_bots");
	g_hZMaxPlayerZombies         = FindConVar("z_max_player_zombies");
	g_hZMinionLimit              = FindConVar("z_minion_limit");
	g_hZSpawnSafetyRange         = FindConVar("z_spawn_safety_range");
	g_hZSmokerLimit              = FindConVar("z_smoker_limit");
	g_hZBoomerLimit              = FindConVar("z_boomer_limit");
	g_hZHunterLimit              = FindConVar("z_hunter_limit");
	g_hZSpitterLimit             = FindConVar("z_spitter_limit");
	g_hZJockeyLimit              = FindConVar("z_jockey_limit");
	g_hZChargerLimit             = FindConVar("z_charger_limit");
	g_hSurvivorMaxIncapCount     = FindConVar("survivor_max_incapacitated_count");

	// Remove bounds on z_max_player_zombies and z_minion_limit so >3 SI are never kicked!
	if (g_hZMaxPlayerZombies != null)
	{
		SetConVarBounds(g_hZMaxPlayerZombies, ConVarBound_Upper, false);
		SetConVarBounds(g_hZMaxPlayerZombies, ConVarBound_Lower, false);
	}
	if (g_hZMinionLimit != null)
	{
		SetConVarBounds(g_hZMinionLimit, ConVarBound_Upper, false);
		SetConVarBounds(g_hZMinionLimit, ConVarBound_Lower, false);
	}

	EnforceEngineConVars();
}

void EnforceEngineConVars()
{
	if (g_hCvarEnabled != null && !g_hCvarEnabled.BoolValue)
	{
		return;
	}

	// Keep director_no_specials = 0 so engine PZ spawn queries remain active,
	// while overriding SpecialRespawnInterval = 999999.0 and blocking native SI in L4D_OnSpawnSpecial.
	if (g_hDirectorNoSpecials != null)        g_hDirectorNoSpecials.IntValue = 0;
	if (g_hDirectorAllowInfectedBots != null) g_hDirectorAllowInfectedBots.IntValue = 1;
	if (g_hZMaxPlayerZombies != null)         g_hZMaxPlayerZombies.IntValue = MAX_SI_SLOTS;
	if (g_hZMinionLimit != null)              g_hZMinionLimit.IntValue = MAX_SI_SLOTS;
	if (g_hZSpawnSafetyRange != null)         g_hZSpawnSafetyRange.IntValue = 250;

	if (g_hZSmokerLimit != null)              g_hZSmokerLimit.IntValue = 8;
	if (g_hZBoomerLimit != null)              g_hZBoomerLimit.IntValue = 8;
	if (g_hZHunterLimit != null)              g_hZHunterLimit.IntValue = 8;
	if (g_hZSpitterLimit != null)             g_hZSpitterLimit.IntValue = 8;
	if (g_hZJockeyLimit != null)              g_hZJockeyLimit.IntValue = 8;
	if (g_hZChargerLimit != null)             g_hZChargerLimit.IntValue = 8;

	DirLog("EnforceEngineConVars: z_max_player_zombies=%d, z_minion_limit=%d, director_no_specials=0, z_spawn_safety_range=250",
		MAX_SI_SLOTS, MAX_SI_SLOTS);
}

void RestoreEngineConVars()
{
	if (g_hDirectorNoSpecials != null)        g_hDirectorNoSpecials.RestoreDefault();
	if (g_hDirectorAllowInfectedBots != null) g_hDirectorAllowInfectedBots.RestoreDefault();
	if (g_hZMaxPlayerZombies != null)         g_hZMaxPlayerZombies.RestoreDefault();
	if (g_hZMinionLimit != null)              g_hZMinionLimit.RestoreDefault();
	if (g_hZSpawnSafetyRange != null)         g_hZSpawnSafetyRange.RestoreDefault();
	if (g_hZSmokerLimit != null)              g_hZSmokerLimit.RestoreDefault();
	if (g_hZBoomerLimit != null)              g_hZBoomerLimit.RestoreDefault();
	if (g_hZHunterLimit != null)              g_hZHunterLimit.RestoreDefault();
	if (g_hZSpitterLimit != null)             g_hZSpitterLimit.RestoreDefault();
	if (g_hZJockeyLimit != null)              g_hZJockeyLimit.RestoreDefault();
	if (g_hZChargerLimit != null)             g_hZChargerLimit.RestoreDefault();
}

// ============================================================================
// State Management & Reset
// ============================================================================

void ChangeState(DirectorState newState, const char[] reason)
{
	DirectorState oldState = g_eState;
	g_eState = newState;
	g_fStateEnterTime = GetGameTime();

	DirLog("STATE_TRANSITION: %s -> %s (Reason: %s)",
		g_sStateNames[oldState], g_sStateNames[newState], reason);
}

void ResetDirectorState(const char[] reason)
{
	if (g_hMainTickTimer != null)
	{
		delete g_hMainTickTimer;
		g_hMainTickTimer = null;
	}
	if (g_hSpawnQueueTimer != null)
	{
		delete g_hSpawnQueueTimer;
		g_hSpawnQueueTimer = null;
	}

	g_bLeftSafeArea      = false;
	g_bOurSpawn          = false;
	g_bSpawningExtraTank = false;
	g_bFreezeAmbush      = false;
	g_bFocusStrike       = false;
	g_bPanicEventActive  = false;
	g_bFinaleActive      = false;

	g_iWaveNumber        = 0;
	g_iWaveTargetCount   = 0;
	g_iWaveCursor        = 0;
	g_iWaveSuccessCount  = 0;
	g_iTargetSurvivor    = 0;
	g_iCurrentCooldown   = 20;
	g_iNativeFinaleStage = 18; // FINALE_NONE

	g_eDiagnosis        = DIAG_HEALTHY_STEADY_PUSH;
	g_eIntent           = INTENT_ESCALATE_CLIMAX;
	g_eLastWaveIntent   = INTENT_MAINTAIN_GAUNTLET_FLOW;
	g_eTargetRole       = ROLE_NONE;
	g_eSpawnDir         = DIR_FRONT;
	g_eHordeDir         = HORDE_KEEP_NATIVE;
	g_eBossDir          = BOSS_RESPECT_NATIVE;

	g_fPeakFlowRatio      = 0.0;
	g_fPrevPeakFlowRatio  = 0.0;
	g_fLastFlowSampleTime = 0.0;
	g_fFlowVelocity       = 0.0;
	g_fStagnationSeconds  = 0.0;
	g_fStagnationAnchor[0] = 0.0;
	g_fStagnationAnchor[1] = 0.0;
	g_fStagnationAnchor[2] = 0.0;
	g_fWaveCombatStartTime = 0.0;
	g_fLastWaveClearDuration = 0.0;
	g_fLastAdditiveTankTime = 0.0;
	g_bWaveWaitingForAmbush = false;

	g_iWaveDamageTaken = 0;
	g_iWaveIncapCount  = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		g_bIsFocusSquad[i]    = false;
		g_bIsFrozenAmbush[i]  = false;
		g_fFreezeExpireTime[i] = 0.0;
		g_fLastPinForceTime[i] = 0.0;
		g_fLastChooseVictimLogTime[i] = 0.0;
		g_iPinningVictim[i]    = 0;

		g_iKillsSI[i]          = 0;
		g_iKillsCI[i]          = 0;
		g_iHeadshots[i]        = 0;
		g_iRevivesDone[i]      = 0;
		g_iPinsCleared[i]      = 0;
		g_iDamageDealtSI[i]    = 0;
		g_iDamageTaken[i]      = 0;
		g_iFriendlyFireDone[i] = 0;
		g_iIncapCount[i]       = 0;
	}

	ChangeState(STATE_DORMANT, reason);
}

void ActivateDirector(float initialCooldown, const char[] triggerSource)
{
	if (g_bLeftSafeArea)
	{
		return;
	}
	if (!g_hCvarEnabled.BoolValue)
	{
		DirLog("ActivateDirector ignored because l4d2_dir_enabled = 0");
		return;
	}

	g_bLeftSafeArea = true;
	EnforceEngineConVars();

	g_fLastFlowSampleTime = GetGameTime();
	SampleTeamFlowAndStagnation();

	g_iCurrentCooldown = RoundToNearest(initialCooldown);
	ChangeState(STATE_COOLDOWN, triggerSource);

	if (g_hMainTickTimer != null)
	{
		delete g_hMainTickTimer;
	}
	g_hMainTickTimer = CreateTimer(1.0, Timer_MainDirectorTick, _, TIMER_REPEAT);

	DirLog("ActivateDirector: Trigger=%s | Initial warmup cooldown=%ds", triggerSource, g_iCurrentCooldown);
	if (g_hCvarChatReport.BoolValue)
	{
		PrintToChatAll("\x04[AI Director]\x01 狀態機導演已啟動 (觸發: \x03%s\x01) — 首波攻勢將於 \x05%d秒\x01 後展開。",
			triggerSource, g_iCurrentCooldown);
	}
}

// ============================================================================
// Game Event Hooks (Every Hook Logs to Dedicated File)
// ============================================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	HookLog(name, "Round started");
	EnforceEngineConVars();
	ResetDirectorState("Event_RoundStart");
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	int winner = event.GetInt("winner");
	int reason = event.GetInt("reason");
	HookLog(name, "Round ended (winner=%d, reason=%d)", winner, reason);
	ResetDirectorState("Event_RoundEnd");
}

public void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
	g_iWipeCount++;
	HookLog(name, "Mission lost (wipe_count=%d)", g_iWipeCount);
	ResetDirectorState("Event_MissionLost");
}

public void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
	HookLog(name, "Map transition triggered");
	ResetDirectorState("Event_MapTransition");
}

public void Event_FinaleVehicleLeaving(Event event, const char[] name, bool dontBroadcast)
{
	HookLog(name, "Finale rescue vehicle leaving");
	ResetDirectorState("Event_FinaleVehicleLeaving");
}

public void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bFinaleActive = true;
	HookLog(name, "Finale started -> g_bFinaleActive=true");
}

public void Event_FinaleRadioStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bFinaleActive = true;
	HookLog(name, "Finale radio started -> g_bFinaleActive=true");
}

public void Event_GauntletFinaleStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bFinaleActive = true;
	g_bPanicEventActive = true;
	HookLog(name, "Gauntlet finale started -> g_bFinaleActive=true, g_bPanicEventActive=true");
}

public void Event_CreatePanicEvent(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	g_bPanicEventActive = true;
	HookLog(name, "Panic event created by client=%d (%N)", client, (client > 0 && IsClientInGame(client)) ? client : 0);
}

public void Event_PlayerLeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	HookLog(name, "Player left safe area: client=%d (%N)", client, (client > 0 && IsClientInGame(client)) ? client : 0);

	if (!g_bLeftSafeArea)
	{
		// Start first wave 10 seconds after leaving safe room (instead of 35s!)
		ActivateDirector(10.0, "Event_PlayerLeftSafeArea");
	}
}

public void Event_DoorOpen(Event event, const char[] name, bool dontBroadcast)
{
	bool checkpoint = event.GetBool("checkpoint");
	int client = GetClientOfUserId(event.GetInt("userid"));
	HookLog(name, "Door opened: checkpoint=%d, client=%d", checkpoint ? 1 : 0, client);

	if (checkpoint && !g_bLeftSafeArea && client > 0 && IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR)
	{
		// If checkpoint exit door opened and survivor steps out
		CreateTimer(2.5, Timer_CheckSafeRoomExit, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_CheckSafeRoomExit(Handle timer)
{
	if (!g_bLeftSafeArea && IsAnySurvivorOutsideSafeRoom())
	{
		ActivateDirector(8.0, "DoorOpen_OutsideSafeRoom");
	}
	return Plugin_Stop;
}

public Action Event_PlayerSpawn_Pre(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		int team = GetClientTeam(client);
		if (team == TEAM_INFECTED)
		{
			int zc = GetEntProp(client, Prop_Send, "m_zombieClass");
			HookLog(name, "SI Spawned: client=%d (%N) class=%s(%d) isFake=%d",
				client, client, (zc >= 1 && zc <= 8) ? g_sSINames[zc] : "Unknown", zc, IsFakeClient(client) ? 1 : 0);
		}
		else if (team == TEAM_SURVIVOR)
		{
			HookLog(name, "Survivor Spawned: client=%d (%N)", client, client);
		}
	}
	return Plugin_Continue;
}

public Action Event_AbilityUse_Pre(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	char ability[64];
	event.GetString("ability", ability, sizeof(ability));

	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		HookLog(name, "Ability used: client=%d (%N) ability=%s", client, client, ability);
	}
	return Plugin_Continue;
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int dmg      = event.GetInt("dmg_health");

	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim))
	{
		return;
	}

	int victimTeam = GetClientTeam(victim);
	if (victimTeam == TEAM_SURVIVOR && dmg > 0)
	{
		g_iDamageTaken[victim] += dmg;
		// Do not accumulate incapacitation bleed-out decay (-3 HP/s natural decay) into wave combat damage
		if (!IsSurvivorIncapOrHanging(victim))
		{
			g_iWaveDamageTaken += dmg;
		}

		if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR && attacker != victim)
		{
			g_iFriendlyFireDone[attacker] += dmg;
		}

		HookLog(name, "Survivor hurt: victim=%N dmg=%d remHP=%d attacker=%d (waveDmg=%d)",
			victim, dmg, event.GetInt("health"), attacker, g_iWaveDamageTaken);
	}
	else if (victimTeam == TEAM_INFECTED)
	{
		// Track survivor damage dealt to SI/Tank for Spec Section 3.2 Impact Score (`Damage Dealt / 100.0`)
		if (dmg > 0 && attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR)
		{
			g_iDamageDealtSI[attacker] += dmg;
		}

		if (g_bIsFrozenAmbush[victim])
		{
			// Immediately unfreeze ambushing SI if damaged!
			UnfreezeSI(victim, "DamagedBySurvivor");
		}
	}
}

public void Event_PlayerShoved(Event event, const char[] name, bool dontBroadcast)
{
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim) && GetClientTeam(victim) == TEAM_INFECTED)
	{
		// If this SI was pinning a teammate and got shoved off by `attacker`, credit `Pins Cleared`
		if (g_iPinningVictim[victim] > 0 && attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR)
		{
			g_iPinsCleared[attacker]++;
			HookLog(name, "Pin cleared by shove! Savior=%N shoved SI=%N off Victim=%d (totalPinsCleared=%d)",
				attacker, victim, g_iPinningVictim[victim], g_iPinsCleared[attacker]);
			g_iPinningVictim[victim] = 0;
		}
	}
}

public void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
	int client   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR)
	{
		g_iIncapCount[client]++;
		g_iWaveIncapCount++;
		HookLog(name, "Survivor incapacitated: %N (totalIncaps=%d, waveIncaps=%d, attacker=%d)",
			client, g_iIncapCount[client], g_iWaveIncapCount, attacker);
	}
}

public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
	int subject = GetClientOfUserId(event.GetInt("subject"));
	int helper  = GetClientOfUserId(event.GetInt("userid"));
	if (helper > 0 && helper <= MaxClients && IsClientInGame(helper) && GetClientTeam(helper) == TEAM_SURVIVOR && helper != subject)
	{
		g_iRevivesDone[helper]++;
	}
	if (subject > 0 && subject <= MaxClients && IsClientInGame(subject))
	{
		HookLog(name, "Survivor revived: subject=%N by helper=%d (helperRevives=%d)",
			subject, helper, (helper > 0 && helper <= MaxClients) ? g_iRevivesDone[helper] : 0);
	}
}

public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
	int subject = GetClientOfUserId(event.GetInt("subject"));
	int healer  = GetClientOfUserId(event.GetInt("userid"));
	int restored = event.GetInt("health_restored");
	if (subject > 0 && subject <= MaxClients && IsClientInGame(subject))
	{
		HookLog(name, "Heal success: subject=%N healer=%d restored=%d", subject, healer, restored);
	}
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	bool headshot = event.GetBool("headshot");

	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim))
	{
		return;
	}

	int victimTeam = GetClientTeam(victim);
	if (victimTeam == TEAM_INFECTED)
	{
		int zc = GetEntProp(victim, Prop_Send, "m_zombieClass");
		g_bIsFocusSquad[victim]   = false;
		g_bIsFrozenAmbush[victim] = false;
		SetEntityFlags(victim, GetEntityFlags(victim) & ~FL_FROZEN);

		if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR)
		{
			g_iKillsSI[attacker]++;
			if (headshot)
			{
				g_iHeadshots[attacker]++;
			}

			// If this SI was actively pinning a survivor when killed, credit `Pins Cleared` (Spec Section 3.2)
			if (g_iPinningVictim[victim] > 0 && attacker != g_iPinningVictim[victim])
			{
				g_iPinsCleared[attacker]++;
				HookLog(name, "Pin cleared by kill! Savior=%N killed pinning SI=%N (totalPinsCleared=%d)",
					attacker, victim, g_iPinsCleared[attacker]);
			}
		}
		g_iPinningVictim[victim] = 0;

		if (CountActiveNonTankSI() == 0)
		{
			if (g_eState == STATE_COMBAT && g_fWaveCombatStartTime > 0.0)
			{
				g_fLastWaveClearDuration = GetGameTime() - g_fWaveCombatStartTime;
				if (g_fLastWaveClearDuration < 0.1)
				{
					g_fLastWaveClearDuration = 0.1;
				}
				g_fWaveCombatStartTime = 0.0;
				DirLog("WAVE_CLEARED [W#%d]: All active SI killed in %.1fs", g_iWaveNumber, g_fLastWaveClearDuration);
			}
		}

		HookLog(name, "SI died: victim=%N class=%s(%d) killer=%d headshot=%d",
			victim, (zc >= 1 && zc <= 8) ? g_sSINames[zc] : "Unknown", zc, attacker, headshot ? 1 : 0);

		// CRITICAL FIX (Reference: l4dinfectedbots.sp line 2441):
		// Kick dead SI FakeClients promptly so they don't occupy Team 3 slots
		// for 7+ seconds waiting for "death anim finished".
		// Spitter gets 6.0s delay so her acid puddle still deals full damage.
		if (IsFakeClient(victim) && zc != ZC_TANK)
		{
			float kickDelay = (zc == ZC_SPITTER) ? 6.0 : 0.5;
			CreateTimer(kickDelay, Timer_KickDeadSIBot, GetClientUserId(victim), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	else if (victimTeam == TEAM_SURVIVOR)
	{
		g_iWaveIncapCount++;
		HookLog(name, "Survivor died: %N (killer=%d)", victim, attacker);
	}
}

public Action Timer_KickDeadSIBot(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && client <= MaxClients && IsClientInGame(client) && IsFakeClient(client) && !IsClientInKickQueue(client))
	{
		if (GetClientTeam(client) == TEAM_INFECTED && !IsPlayerAlive(client))
		{
			KickClient(client, "SI dead slot recycle");
		}
	}
	return Plugin_Stop;
}

public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	bool headshot = event.GetBool("headshot");

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR)
	{
		g_iKillsCI[attacker]++;
		if (headshot)
		{
			g_iHeadshots[attacker]++;
		}

		// Log every 15 CI kills per player to avoid log bloat while preserving hook visibility
		if (g_iKillsCI[attacker] % 15 == 1)
		{
			HookLog(name, "Common Infected killed by %N (totalCI=%d, headshots=%d)",
				attacker, g_iKillsCI[attacker], g_iHeadshots[attacker]);
		}
	}
}

public void Event_PinStarted(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("userid"));
	int victim   = GetClientOfUserId(event.GetInt("victim"));

	if (attacker > 0 && attacker <= MaxClients && victim > 0 && victim <= MaxClients)
	{
		g_iPinningVictim[attacker] = victim;
	}

	HookLog(name, "Pin succeeded! SI=%d (%N) pinned Victim=%d (%N)",
		attacker, (attacker > 0 && IsClientInGame(attacker)) ? attacker : 0,
		victim,   (victim > 0 && IsClientInGame(victim)) ? victim : 0);
}

public void Event_PinCleared(Event event, const char[] name, bool dontBroadcast)
{
	int savior = GetClientOfUserId(event.GetInt("userid"));
	int victim = GetClientOfUserId(event.GetInt("victim"));

	if (savior > 0 && savior <= MaxClients && IsClientInGame(savior) && GetClientTeam(savior) == TEAM_SURVIVOR && savior != victim)
	{
		g_iPinsCleared[savior]++;
		HookLog(name, "Pin cleared! Savior=%N freed Victim=%d (totalPinsCleared=%d)",
			savior, victim, g_iPinsCleared[savior]);
	}
	else
	{
		HookLog(name, "Pin ended (savior=%d, victim=%d)", savior, victim);
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_iPinningVictim[i] == victim && victim > 0)
		{
			g_iPinningVictim[i] = 0;
		}
	}
}

// ============================================================================
// Left4DHooks Forwards (Verified against left4dhooks.inc)
// ============================================================================

/**
 * Override `CDirector::IsTeamFull` (`left4dhooks.inc` line 1726, `l4dd_forwards.sp` line 1777).
 * Prevents the engine from rejecting Team 3 bot assignments or kicking >3 SI in Coop!
 */
public Action L4D_OnIsTeamFull(int team, bool &full)
{
	if (!g_hCvarEnabled.BoolValue)
	{
		return Plugin_Continue;
	}

	if (team == TEAM_INFECTED && full && HasSafeClientSlotMargin(1))
	{
		full = false;
		float now = GetGameTime();
		if (g_hCvarVerboseHookLog.BoolValue && now - g_fLastTeamFullLogTime >= 10.0)
		{
			g_fLastTeamFullLogTime = now;
			HookLog("L4D_OnIsTeamFull", "Overrode team=3 full=true -> full=false (throttled 10s)");
		}
		return Plugin_Changed;
	}

	return Plugin_Continue;
}

bool TryOverrideDirectorScriptInt(const char[] key, int &retVal)
{
	if (StrEqual(key, "MaxSpecials", false) ||
		StrEqual(key, "cm_MaxSpecials", false) ||
		StrEqual(key, "cm_BaseSpecialLimit", false) ||
		StrEqual(key, "DominatorLimit", false) ||
		StrEqual(key, "cm_DominatorLimit", false) ||
		StrEqual(key, "SmokerLimit", false) ||
		StrEqual(key, "BoomerLimit", false) ||
		StrEqual(key, "HunterLimit", false) ||
		StrEqual(key, "SpitterLimit", false) ||
		StrEqual(key, "JockeyLimit", false) ||
		StrEqual(key, "ChargerLimit", false) ||
		StrEqual(key, "cm_SmokerLimit", false) ||
		StrEqual(key, "cm_BoomerLimit", false) ||
		StrEqual(key, "cm_HunterLimit", false) ||
		StrEqual(key, "cm_SpitterLimit", false) ||
		StrEqual(key, "cm_JockeyLimit", false) ||
		StrEqual(key, "cm_ChargerLimit", false))
	{
		retVal = MAX_SI_SLOTS;
		return true;
	}

	if (StrEqual(key, "ShouldAllowSpecialsWithTank", false) ||
		StrEqual(key, "ShouldAllowMobsWithTank", false))
	{
		retVal = 1;
		return true;
	}

	// Spec Section 1.1 #6 / Section 6.1: NEVER set ProhibitBosses = 1!
	// Native Finale & map-scripted Bosses must 100% be allowed to spawn.
	return false;
}

/**
 * Override VScript integer director variables (`CDirector::GetScriptValue`).
 */
public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal)
{
	if (!g_hCvarEnabled.BoolValue)
	{
		return Plugin_Continue;
	}

	int oldVal = retVal;
	if (TryOverrideDirectorScriptInt(key, retVal))
	{
		float now = GetGameTime();
		if (g_hCvarVerboseHookLog.BoolValue && now - g_fLastScriptValueLogTime >= 10.0)
		{
			g_fLastScriptValueLogTime = now;
			HookLog("L4D_OnGetScriptValueInt", "key=%s old=%d -> new=%d (throttled 10s)", key, oldVal, retVal);
		}
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

/**
 * Override Squirrel VM integer script queries (`CSquirrelVM::GetValue`, `left4dhooks.inc` line 1954).
 * `left4dhooks.inc` line 1874 explicitly notes that `L4D_OnGetScriptValueInt` can be skipped due to C++ inlining,
 * so hooking `L4D2_OnGetScriptValueInt` ensures VScript limits are always overridden.
 */
public Action L4D2_OnGetScriptValueInt(const char[] key, int &retVal, int hScope)
{
	if (!g_hCvarEnabled.BoolValue)
	{
		return Plugin_Continue;
	}

	int oldVal = retVal;
	if (TryOverrideDirectorScriptInt(key, retVal))
	{
		float now = GetGameTime();
		if (g_hCvarVerboseHookLog.BoolValue && now - g_fLastScriptValueLogTime >= 10.0)
		{
			g_fLastScriptValueLogTime = now;
			HookLog("L4D2_OnGetScriptValueInt", "key=%s scope=%d old=%d -> new=%d (throttled 10s)", key, hScope, oldVal, retVal);
		}
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

/**
 * Delay native VScript SpecialRespawnInterval so only our State-Machine spawns SI.
 */
public Action L4D_OnGetScriptValueFloat(const char[] key, float &retVal)
{
	if (!g_hCvarEnabled.BoolValue)
	{
		return Plugin_Continue;
	}

	if (StrEqual(key, "SpecialRespawnInterval", false) ||
		StrEqual(key, "cm_SpecialRespawnInterval", false))
	{
		retVal = 999999.0;
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public Action L4D2_OnGetScriptValueFloat(const char[] key, float &retVal, int hScope)
{
	if (!g_hCvarEnabled.BoolValue)
	{
		return Plugin_Continue;
	}

	if (StrEqual(key, "SpecialRespawnInterval", false) ||
		StrEqual(key, "cm_SpecialRespawnInterval", false))
	{
		retVal = 999999.0;
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

/**
 * Intercept First Survivor Left Safe Area (`left4dhooks.inc` line 1790)
 */
public Action L4D_OnFirstSurvivorLeftSafeArea(int client)
{
	HookLog("L4D_OnFirstSurvivorLeftSafeArea", "First survivor left safe area: client=%d (%N)",
		client, (client > 0 && IsClientInGame(client)) ? client : 0);

	if (!g_bLeftSafeArea)
	{
		ActivateDirector(10.0, "L4D_OnFirstSurvivorLeftSafeArea");
	}
	return Plugin_Continue;
}

/**
 * Intercept Finale Stage Changes (`left4dhooks.inc` line 2331, Spec Section 6.1 & 6.2)
 * Immediately re-evaluates `g_eBossDir` when transitioning into a Finale Boss stage
 * BEFORE the native Finale Tank finishes spawning so `L4D_OnSpawnTank_Post` has the
 * up-to-date `DIAG_FINALE_BOSS_STAGE` directive, and locks `BOSS_RESPECT_NATIVE`
 * on non-Boss finale stages per Spec Section 6.2 Rule #1.
 */
public Action L4D2_OnChangeFinaleStage(int &finaleType, const char[] arg)
{
	g_bFinaleActive = true;
	g_iNativeFinaleStage = finaleType;

	bool isBossStage = (
		finaleType == FINALE_HALFTIME_BOSS ||
		finaleType == FINALE_FINAL_BOSS ||
		finaleType == FINALE_CUSTOM_TANK ||
		finaleType == FINALE_GAUNTLET_BOSS_INCOMING ||
		finaleType == FINALE_GAUNTLET_BOSS);

	if (isBossStage)
	{
		EvaluateFinaleBossStageDirective(finaleType);
	}
	else
	{
		// Spec Section 6.2 Rule #1: Lock boss = RESPECT_NATIVE during non-Boss finale stages
		g_eBossDir = BOSS_RESPECT_NATIVE;
	}

	HookLog("L4D2_OnChangeFinaleStage", "Finale stage changed -> finaleType=%d arg=%s isBossStage=%d BossDirective=%s",
		finaleType, arg, isBossStage ? 1 : 0, g_sBossNames[g_eBossDir]);
	return Plugin_Continue;
}

void EvaluateFinaleBossStageDirective(int finaleType)
{
	int aliveCount, downOrDeadCount;
	float avgEffHP, maxSpreadDist, frontGapDist, rearGapDist, mvpScoreRatio;
	int p1Front, p4Rear, pMVP, pVulnerable;

	EvaluateTeamTelemetry(
		aliveCount,
		downOrDeadCount,
		avgEffHP,
		maxSpreadDist,
		frontGapDist,
		rearGapDist,
		p1Front,
		p4Rear,
		pMVP,
		pVulnerable,
		mvpScoreRatio);

	int blackAndWhiteCount, medkitsTotal, throwablesTotal;
	float teamAmmoAvgPct;
	CollectTeamResourceTelemetry(blackAndWhiteCount, teamAmmoAvgPct, medkitsTotal, throwablesTotal);

	g_eDiagnosis = DIAG_FINALE_BOSS_STAGE;

	if (downOrDeadCount >= 2 || avgEffHP < 35.0 || blackAndWhiteCount >= 2 || teamAmmoAvgPct < 25.0)
	{
		g_eBossDir = BOSS_BLOCK_EXTRA_RESPAWN;
	}
	else if (g_iWipeCount >= 2 || avgEffHP < 55.0 || downOrDeadCount >= 1)
	{
		g_eBossDir = BOSS_RESPECT_NATIVE;
	}
	else if (avgEffHP > 75.0 && g_iWipeCount == 0 && (teamAmmoAvgPct > 80.0 || medkitsTotal >= 1 || (g_fLastWaveClearDuration > 0.0 && g_fLastWaveClearDuration <= 4.0)))
	{
		g_eBossDir = BOSS_ADD_2_TANKS;
	}
	else if (avgEffHP >= 55.0)
	{
		g_eBossDir = BOSS_ADD_1_TANK;
	}
	else
	{
		g_eBossDir = BOSS_RESPECT_NATIVE;
	}

	DirLog("FINALE_BOSS_STAGE_EVAL: stage=%d alive=%d down=%d bw=%d wipes=%d avgHP=%.1f ammo=%.0f%% medkits=%d -> BossDirective=%s",
		finaleType, aliveCount, downOrDeadCount, blackAndWhiteCount, g_iWipeCount, avgEffHP, teamAmmoAvgPct, medkitsTotal, g_sBossNames[g_eBossDir]);
}

/**
 * Intercept Mob Rush Start (`left4dhooks.inc` line 1589)
 */
public Action L4D_OnMobRushStart()
{
	HookLog("L4D_OnMobRushStart", "Mob rush started (HordeDirective=%s)", g_sHordeNames[g_eHordeDir]);
	return Plugin_Continue;
}

/**
 * Intercept Special Infected spawns (`left4dhooks.inc` line 1528)
 * Allow only spawns initiated by our plugin (`g_bOurSpawn == true`).
 */
public Action L4D_OnSpawnSpecial(int &zombieClass, const float vecPos[3], const float vecAng[3])
{
	if (!g_hCvarEnabled.BoolValue || !g_bLeftSafeArea)
	{
		HookLog("L4D_OnSpawnSpecial", "Allowed native spawn (plugin inactive/safearea): class=%s(%d) pos=(%.0f,%.0f,%.0f)",
			(zombieClass >= 1 && zombieClass <= 8) ? g_sSINames[zombieClass] : "Unknown", zombieClass,
			vecPos[0], vecPos[1], vecPos[2]);
		return Plugin_Continue;
	}

	if (!g_bOurSpawn)
	{
		HookLog("L4D_OnSpawnSpecial", "BLOCKED native Director SI spawn: class=%s(%d) pos=(%.0f,%.0f,%.0f)",
			(zombieClass >= 1 && zombieClass <= 8) ? g_sSINames[zombieClass] : "Unknown", zombieClass,
			vecPos[0], vecPos[1], vecPos[2]);
		return Plugin_Handled;
	}

	HookLog("L4D_OnSpawnSpecial", "ALLOWED our Director SI spawn: class=%s(%d) pos=(%.0f,%.0f,%.0f)",
		(zombieClass >= 1 && zombieClass <= 8) ? g_sSINames[zombieClass] : "Unknown", zombieClass,
		vecPos[0], vecPos[1], vecPos[2]);
	return Plugin_Continue;
}

public void L4D_OnSpawnSpecial_Post(int client, int zombieClass, const float vecPos[3], const float vecAng[3])
{
	HookLog("L4D_OnSpawnSpecial_Post", "client=%d class=%s(%d) pos=(%.0f,%.0f,%.0f)",
		client, (zombieClass >= 1 && zombieClass <= 8) ? g_sSINames[zombieClass] : "Unknown", zombieClass,
		vecPos[0], vecPos[1], vecPos[2]);
}

/**
 * Intercept Natural Mob Spawns (`left4dhooks.inc` line 1619)
 * Scales common infected count according to `g_eHordeDir`.
 */
public Action L4D_OnSpawnMob(int &amount)
{
	if (!g_hCvarEnabled.BoolValue || !g_bLeftSafeArea)
	{
		HookLog("L4D_OnSpawnMob", "Native mob spawn (safearea/disabled): amount=%d", amount);
		return Plugin_Continue;
	}

	int origAmount = amount;
	ApplyHordeScaling(amount);

	HookLog("L4D_OnSpawnMob", "HordeDirective=%s | origAmount=%d -> newAmount=%d",
		g_sHordeNames[g_eHordeDir], origAmount, amount);

	return (amount != origAmount) ? Plugin_Changed : Plugin_Continue;
}

/**
 * Intercept Boomer Bile / IT Mob Spawns (`left4dhooks.inc` line 1603)
 */
public Action L4D_OnSpawnITMob(int &amount)
{
	if (!g_hCvarEnabled.BoolValue || !g_bLeftSafeArea)
	{
		HookLog("L4D_OnSpawnITMob", "Native IT mob spawn (safearea/disabled): amount=%d", amount);
		return Plugin_Continue;
	}

	int origAmount = amount;
	ApplyHordeScaling(amount);

	HookLog("L4D_OnSpawnITMob", "HordeDirective=%s | origAmount=%d -> newAmount=%d",
		g_sHordeNames[g_eHordeDir], origAmount, amount);

	return (amount != origAmount) ? Plugin_Changed : Plugin_Continue;
}

void ApplyHordeScaling(int &amount)
{
	float userScale = g_hCvarHordeScale.FloatValue;
	if (userScale <= 0.0)
	{
		amount = 0;
		return;
	}

	float mult = 1.0;
	switch (g_eHordeDir)
	{
		case HORDE_SCALE_05X:
		{
			mult = 0.5;
		}
		case HORDE_SCALE_12X:
		{
			mult = 1.0;
		}
		case HORDE_SCALE_16X:
		{
			mult = 1.25;
		}
		case HORDE_RIOT_SQUAD:
		{
			mult = 1.0;
		}
		default:
		{
			mult = 0.8;
		}
	}

	amount = RoundToNearest(float(amount) * mult * userScale);
	if (amount < 0)
	{
		amount = 0;
	}
}

/**
 * Intercept Tank Spawns (`left4dhooks.inc` line 1544)
 * Spec Section 1.1 #6 / Section 6.1–6.2:
 * NEVER block native map Tank spawns (`Plugin_Continue` always), preventing Finale softlocks!
 */
public Action L4D_OnSpawnTank(const float vecPos[3], const float vecAng[3])
{
	HookLog("L4D_OnSpawnTank", "ALLOWED Tank spawn (BossDirective=%s, extraTank=%d) at (%.0f,%.0f,%.0f)",
		g_sBossNames[g_eBossDir], g_bSpawningExtraTank ? 1 : 0, vecPos[0], vecPos[1], vecPos[2]);
	return Plugin_Continue;
}

/**
 * Post-Hook Tank Spawns (`left4dhooks.inc` line 1545)
 * Implements Spec Section 5.4 & Section 6.2:
 * 1. Dynamic Tank HP scaling (`5000 + 800 * alive_survivors`, `0.75x` if `ADD_2_TANKS`) applied via 0.1s timer.
 * 2. When a native Tank spawns (`!g_bSpawningExtraTank`) and `BossDirective` is `ADD_1_TANK` or `ADD_2_TANKS`,
 *    schedules staggered non-overlapping extra Tank spawns (`+- 120.0` unit offset) while respecting the 28-slot safety guard.
 */
public void L4D_OnSpawnTank_Post(int client, const float vecPos[3], const float vecAng[3])
{
	HookLog("L4D_OnSpawnTank_Post", "Tank spawned: client=%d (%N) BossDirective=%s extraTank=%d pos=(%.0f,%.0f,%.0f)",
		client, (client > 0 && IsClientInGame(client)) ? client : 0,
		g_sBossNames[g_eBossDir], g_bSpawningExtraTank ? 1 : 0,
		vecPos[0], vecPos[1], vecPos[2]);

	if (!g_hCvarEnabled.BoolValue)
	{
		return;
	}

	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		CreateTimer(0.1, Timer_ApplyDynamicTankHP, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}

	// Only trigger additive multi-Tank spawns when the native Director spawns the primary Tank,
	// and guard against double-multiplying when a Finale stage natively spawns 2 Tanks back-to-back (Spec Section 6.2 Rule #2: 1->2, 2->3).
	float now = GetGameTime();
	if (!g_bSpawningExtraTank && (g_eBossDir == BOSS_ADD_1_TANK || g_eBossDir == BOSS_ADD_2_TANKS) && (now - g_fLastAdditiveTankTime >= 15.0))
	{
		g_fLastAdditiveTankTime = now;
		int extraTanks = (g_eBossDir == BOSS_ADD_2_TANKS) ? 2 : 1;
		for (int idx = 1; idx <= extraTanks; idx++)
		{
			DataPack pack = new DataPack();
			pack.WriteFloat(vecPos[0]);
			pack.WriteFloat(vecPos[1]);
			pack.WriteFloat(vecPos[2]);
			pack.WriteFloat(vecAng[0]);
			pack.WriteFloat(vecAng[1]);
			pack.WriteFloat(vecAng[2]);
			pack.WriteCell(idx);

			// Staggered spawn timers (0.15s, 0.30s) per Spec Section 5.4
			CreateTimer(0.15 * float(idx), Timer_SpawnStaggeredExtraTank, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
		}
	}
}

public Action Timer_ApplyDynamicTankHP(Handle timer, int userid)
{
	int tank = GetClientOfUserId(userid);
	if (tank <= 0 || tank > MaxClients || !IsClientInGame(tank) || GetClientTeam(tank) != TEAM_INFECTED || !IsPlayerAlive(tank))
	{
		return Plugin_Stop;
	}

	int aliveSurvivors = CountAliveSurvivors();
	if (aliveSurvivors < 1)
	{
		aliveSurvivors = 4;
	}

	// Spec Section 6.2 formula: Base HP = 5000 + (alive_survivors * 800)
	int targetHP = 5000 + (aliveSurvivors * 800);
	if (g_eBossDir == BOSS_ADD_2_TANKS)
	{
		// Spec Section 4.1: 3-Tank climax applies 0.75x HP per Tank
		targetHP = RoundToNearest(float(targetHP) * 0.75);
	}

	SetEntProp(tank, Prop_Data, "m_iMaxHealth", targetHP);
	SetEntProp(tank, Prop_Data, "m_iHealth", targetHP);
	SetEntityHealth(tank, targetHP);

	DirLog("TANK_HP_SCALED: tank=%d (%N) aliveSurvivors=%d BossDirective=%s -> HP=%d",
		tank, tank, aliveSurvivors, g_sBossNames[g_eBossDir], targetHP);

	return Plugin_Stop;
}

public Action Timer_SpawnStaggeredExtraTank(Handle timer, DataPack pack)
{
	pack.Reset();
	float basePos[3], baseAng[3];
	basePos[0] = pack.ReadFloat();
	basePos[1] = pack.ReadFloat();
	basePos[2] = pack.ReadFloat();
	baseAng[0] = pack.ReadFloat();
	baseAng[1] = pack.ReadFloat();
	baseAng[2] = pack.ReadFloat();
	int tankIndex = pack.ReadCell();

	if (!g_hCvarEnabled.BoolValue || !HasSafeClientSlotMargin(1))
	{
		DirLog("Timer_SpawnStaggeredExtraTank: Aborted extra Tank #%d due to 28-slot safety guard.", tankIndex);
		return Plugin_Stop;
	}

	// Spec Section 5.4: Apply +-120.0 unit coordinate offset (or nearby PZ/Nav position) so Tank hulls never overlap
	float spawnPos[3];
	float offsetSign = (tankIndex % 2 == 1) ? 1.0 : -1.0;
	spawnPos[0] = basePos[0] + (120.0 * offsetSign);
	spawnPos[1] = basePos[1] + (120.0 * offsetSign);
	spawnPos[2] = basePos[2] + 15.0;

	if (!IsHullClearForSI(spawnPos))
	{
		int anchor = L4D_GetHighestFlowSurvivor();
		if (!IsValidAliveSurvivor(anchor))
		{
			anchor = GetAnyAliveSurvivor();
		}
		if (!IsValidAliveSurvivor(anchor) || !FindTier2AnySurvivorPZPos(anchor, ZC_TANK, spawnPos))
		{
			spawnPos[0] = basePos[0];
			spawnPos[1] = basePos[1];
			spawnPos[2] = basePos[2] + 25.0;
		}
	}

	g_bSpawningExtraTank = true;
	g_bOurSpawn = true;
	int extraTank = L4D2_SpawnTank(spawnPos, baseAng);
	g_bOurSpawn = false;

	if (extraTank <= 0 || !IsClientInGame(extraTank))
	{
		extraTank = SpawnInfectedBotViaSDKCall(ZC_TANK, spawnPos, baseAng);
		if (extraTank > 0)
		{
			CreateTimer(0.1, Timer_ApplyDynamicTankHP, GetClientUserId(extraTank), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	g_bSpawningExtraTank = false;

	DirLog("ADDITIVE_TANK_SPAWN: Extra Tank #%d (BossDirective=%s) -> client=%d at (%.0f,%.0f,%.0f)",
		tankIndex, g_sBossNames[g_eBossDir], extraTank, spawnPos[0], spawnPos[1], spawnPos[2]);

	if (extraTank > 0 && g_hCvarChatReport.BoolValue)
	{
		PrintToChatAll("\x04[AI Director]\x01 增援 Boss 指令 (\x03%s\x01) — 額外生成第 \x05#%d\x01 隻 Tank！",
			g_sBossNames[g_eBossDir], tankIndex + 1);
	}

	return Plugin_Stop;
}

/**
 * Intercept Witch Spawns (`left4dhooks.inc` line 1559)
 */
public Action L4D_OnSpawnWitch(const float vecPos[3], const float vecAng[3])
{
	HookLog("L4D_OnSpawnWitch", "ALLOWED Witch spawn at (%.0f,%.0f,%.0f)", vecPos[0], vecPos[1], vecPos[2]);
	return Plugin_Continue;
}

public void L4D_OnSpawnWitch_Post(int entity, const float vecPos[3], const float vecAng[3])
{
	HookLog("L4D_OnSpawnWitch_Post", "Witch spawned: entity=%d at (%.0f,%.0f,%.0f)", entity, vecPos[0], vecPos[1], vecPos[2]);
}

/**
 * Intercept Bride Witch Spawns (`left4dhooks.inc` line 1575)
 */
public Action L4D2_OnSpawnWitchBride(const float vecPos[3], const float vecAng[3])
{
	HookLog("L4D2_OnSpawnWitchBride", "ALLOWED WitchBride spawn at (%.0f,%.0f,%.0f)", vecPos[0], vecPos[1], vecPos[2]);
	return Plugin_Continue;
}

/**
 * Intercept Ghost State Entry (`left4dhooks.inc` line 1664)
 */
public Action L4D_OnEnterGhostStatePre(int client)
{
	HookLog("L4D_OnEnterGhostStatePre", "client=%d (%N)", client, (client > 0 && IsClientInGame(client)) ? client : 0);
	return Plugin_Continue;
}

/**
 * Intercept Victim Selection (`left4dhooks.inc` line 326)
 * Implements Spec Section 4.1 & 5.3 (`focus_strike_enabled`):
 * - Focus Squad SI (`<= floor(active_si / 2)`) lock onto `g_iTargetSurvivor`.
 * - Non-Focus Squad SI are diverted to OTHER alive survivors so the target isn't
 *   unfairly dogpiled by 100% of active SI while teammates are unpressured.
 */
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
	if (!g_hCvarEnabled.BoolValue || !g_bLeftSafeArea)
	{
		return Plugin_Continue;
	}

	if (specialInfected <= 0 || specialInfected > MaxClients || !IsClientInGame(specialInfected) || !IsPlayerAlive(specialInfected))
	{
		return Plugin_Continue;
	}

	// Keep frozen ambush bots passive until triggered
	if (g_bIsFrozenAmbush[specialInfected])
	{
		return Plugin_Continue;
	}

	if (!g_bFocusStrike || !IsValidAliveSurvivor(g_iTargetSurvivor))
	{
		return Plugin_Continue;
	}

	int newTarget = curTarget;
	bool changed = false;

	if (g_bIsFocusSquad[specialInfected])
	{
		// Focus Squad locks onto the designated tactical target
		if (curTarget != g_iTargetSurvivor)
		{
			newTarget = g_iTargetSurvivor;
			changed = true;
		}
	}
	else
	{
		// Non-Focus Squad: divert to nearest OTHER alive survivor if available
		if (curTarget == g_iTargetSurvivor)
		{
			int altSurvivor = FindNearestOtherSurvivor(specialInfected, g_iTargetSurvivor);
			if (altSurvivor > 0)
			{
				newTarget = altSurvivor;
				changed = true;
			}
		}
	}

	if (changed && IsValidAliveSurvivor(newTarget))
	{
		curTarget = newTarget;

		float now = GetGameTime();
		if (g_hCvarVerboseHookLog.BoolValue && now - g_fLastChooseVictimLogTime[specialInfected] >= 5.0)
		{
			g_fLastChooseVictimLogTime[specialInfected] = now;
			if (g_bIsFocusSquad[specialInfected])
			{
				HookLog("L4D2_OnChooseVictim", "SI=%N (FocusSquad=1) focused target -> %N (role=%s)",
					specialInfected, curTarget, g_sRoleNames[g_eTargetRole]);
			}
			else
			{
				HookLog("L4D2_OnChooseVictim", "SI=%N (FocusSquad=0) diverted target away from %s -> %N (non-focus)",
					specialInfected, g_sRoleNames[g_eTargetRole], curTarget);
			}
		}
		return Plugin_Changed;
	}

	return Plugin_Continue;
}

// ============================================================================
// Main 1-Second State-Machine Heartbeat Timer
// ============================================================================

public Action Timer_MainDirectorTick(Handle timer)
{
	if (!g_hCvarEnabled.BoolValue || !g_bLeftSafeArea)
	{
		return Plugin_Continue;
	}

	// Update flow progress, velocity, and anti-camping stagnation every second
	SampleTeamFlowAndStagnation();

	float now = GetGameTime();
	float stateElapsed = now - g_fStateEnterTime;

	switch (g_eState)
	{
		case STATE_COOLDOWN:
		{
			// If Mercy intent is active, keep native mob timer suppressed
			if (g_eIntent == INTENT_MERCY_RELAX_ALLOW_HEAL)
			{
				L4D_ResetMobTimer();
			}

			if (stateElapsed >= float(g_iCurrentCooldown))
			{
				ChangeState(STATE_EVALUATE, "Cooldown timer elapsed");
				ExecuteEvaluationAndPlanWave();
			}
		}

		case STATE_EVALUATE:
		{
			// Safety catch if STATE_EVALUATE didn't immediately transition
			ExecuteEvaluationAndPlanWave();
		}

		case STATE_SPAWNING:
		{
			// Maintain freeze ambush checks even while wave is still spawning
			UpdateFrozenAmbushSI();
			UpdateFocusStrikeEnforcement();

			// Safety timeout if spawn queue timer somehow stalled
			if (stateElapsed > 20.0)
			{
				DirLog("WARNING: STATE_SPAWNING exceeded 20.0s! Forcing transition to STATE_COMBAT.");
				if (g_hSpawnQueueTimer != null)
				{
					delete g_hSpawnQueueTimer;
					g_hSpawnQueueTimer = null;
				}
				ChangeState(STATE_COMBAT, "Spawning safety timeout");
			}
		}

		case STATE_COMBAT:
		{
			UpdateFrozenAmbushSI();
			UpdateFocusStrikeEnforcement();

			int activeSI = CountActiveNonTankSI();
			if (activeSI == 0)
			{
				FinishCombatWave("All active SI eliminated");
			}
			else if (stateElapsed >= g_fCombatTimeout)
			{
				// Recycle stuck/far-behind SI before ending combat wave
				int recycled = RecycleStuckOrFarSI();
				DirLog("STATE_COMBAT timeout (%.1fs): activeSI=%d, recycledStuckSI=%d",
					stateElapsed, activeSI, recycled);
				FinishCombatWave("Combat wave timeout reached");
			}
		}
	}

	return Plugin_Continue;
}

// ============================================================================
// Telemetry Sampler (Flow, Velocity, Spread, Camping Stagnation, Roles)
// ============================================================================

void SampleTeamFlowAndStagnation()
{
	float maxFlowDist = L4D2Direct_GetMapMaxFlowDistance();
	if (maxFlowDist <= 1.0)
	{
		maxFlowDist = 1.0;
	}

	float highestFlow = 0.0;
	float centroid[3];
	int aliveCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidAliveSurvivor(i))
		{
			continue;
		}

		aliveCount++;
		float flow = L4D2Direct_GetFlowDistance(i);
		if (flow > highestFlow)
		{
			highestFlow = flow;
		}

		float pos[3];
		GetClientAbsOrigin(i, pos);
		centroid[0] += pos[0];
		centroid[1] += pos[1];
		centroid[2] += pos[2];
	}

	if (aliveCount == 0)
	{
		return;
	}

	centroid[0] /= float(aliveCount);
	centroid[1] /= float(aliveCount);
	centroid[2] /= float(aliveCount);

	// Update peak flow ratio (0.0 .. 100.0)
	float curFlowRatio = (highestFlow / maxFlowDist) * 100.0;
	if (curFlowRatio > g_fPeakFlowRatio)
	{
		g_fPeakFlowRatio = curFlowRatio;
	}

	// Update flow velocity (% per minute) every 5 seconds
	float now = GetGameTime();
	float dt = now - g_fLastFlowSampleTime;
	if (dt >= 5.0)
	{
		g_fFlowVelocity = ((g_fPeakFlowRatio - g_fPrevPeakFlowRatio) / dt) * 60.0;
		g_fPrevPeakFlowRatio = g_fPeakFlowRatio;
		g_fLastFlowSampleTime = now;
	}

	// Update Camping Stagnation Timer (Spec Section 3.1: < 250 units movement)
	float distFromStagnationAnchor = GetVectorDistance(centroid, g_fStagnationAnchor);
	if (distFromStagnationAnchor <= 250.0)
	{
		g_fStagnationSeconds += 1.0;
	}
	else
	{
		g_fStagnationSeconds = 0.0;
		g_fStagnationAnchor[0] = centroid[0];
		g_fStagnationAnchor[1] = centroid[1];
		g_fStagnationAnchor[2] = centroid[2];
	}
}

/**
 * Computes survivor effective HP (permanent HP + 0.5 * temporary buffer HP).
 * Incapacitated or ledge-hanging survivors count as 10 effective HP.
 */
float GetSurvivorEffectiveHP(int client)
{
	if (!IsValidAliveSurvivor(client))
	{
		return 0.0;
	}
	if (IsSurvivorIncapOrHanging(client))
	{
		return 10.0;
	}

	int permHP = GetClientHealth(client);
	float tempHP = L4D_GetTempHealth(client);
	if (tempHP < 0.0)
	{
		tempHP = 0.0;
	}

	return float(permHP) + (tempHP * 0.5);
}

bool IsSurvivorIncapOrHanging(int client)
{
	if (GetEntProp(client, Prop_Send, "m_isIncapacitated", 1) != 0)
	{
		return true;
	}
	if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge", 1) != 0)
	{
		return true;
	}
	return false;
}

bool IsSurvivorPinned(int client)
{
	if (!IsValidAliveSurvivor(client))
	{
		return false;
	}
	if (GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0) return true;
	if (GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0) return true;
	if (GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0) return true;
	if (GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0) return true;
	if (GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0) return true;
	return false;
}

/**
 * Computes whether a survivor is in Black-and-White state (third strike / next incap = death).
 */
bool IsSurvivorBlackAndWhite(int client)
{
	if (!IsValidAliveSurvivor(client))
	{
		return false;
	}
	if (HasEntProp(client, Prop_Send, "m_bIsOnThirdStrike") && GetEntProp(client, Prop_Send, "m_bIsOnThirdStrike", 1) != 0)
	{
		return true;
	}
	int maxIncaps = (g_hSurvivorMaxIncapCount != null) ? g_hSurvivorMaxIncapCount.IntValue : 2;
	if (HasEntProp(client, Prop_Send, "m_currentReviveCount") && GetEntProp(client, Prop_Send, "m_currentReviveCount") >= maxIncaps)
	{
		return true;
	}
	return false;
}

/**
 * Returns expected maximum reserve ammo for standard L4D2 primary weapons.
 */
int GetWeaponMaxReserveAmmo(int weapon)
{
	char cls[64];
	GetEntityClassname(weapon, cls, sizeof(cls));
	if (StrEqual(cls, "weapon_smg") || StrEqual(cls, "weapon_smg_silenced") || StrEqual(cls, "weapon_smg_mp5"))
	{
		return 650;
	}
	if (StrEqual(cls, "weapon_pumpshotgun") || StrEqual(cls, "weapon_shotgun_chrome"))
	{
		return 56;
	}
	if (StrEqual(cls, "weapon_autoshotgun") || StrEqual(cls, "weapon_shotgun_spas"))
	{
		return 90;
	}
	if (StrEqual(cls, "weapon_hunting_rifle"))
	{
		return 150;
	}
	if (StrEqual(cls, "weapon_sniper_military") || StrEqual(cls, "weapon_sniper_awp") || StrEqual(cls, "weapon_sniper_scout"))
	{
		return 180;
	}
	if (StrEqual(cls, "weapon_rifle_m60"))
	{
		return 150;
	}
	if (StrEqual(cls, "weapon_grenade_launcher"))
	{
		return 30;
	}
	// Default assault rifles (weapon_rifle, weapon_rifle_ak47, weapon_rifle_desert, weapon_rifle_sg552)
	return 360;
}

/**
 * Computes a survivor's primary weapon reserve ammo percentage (0.0 .. 100.0).
 * Melee / Chainsaw / no primary counts as 100.0%.
 */
float GetSurvivorPrimaryAmmoPct(int client)
{
	int weapon = GetPlayerWeaponSlot(client, 0);
	if (weapon <= MaxClients || !IsValidEntity(weapon))
	{
		return 100.0;
	}

	char cls[64];
	GetEntityClassname(weapon, cls, sizeof(cls));

	int clipAmmo = HasEntProp(weapon, Prop_Send, "m_iClip1") ? GetEntProp(weapon, Prop_Send, "m_iClip1") : 0;
	if (clipAmmo < 0) clipAmmo = 0;

	if (StrEqual(cls, "weapon_rifle_m60"))
	{
		return (float(clipAmmo) / 150.0) * 100.0;
	}

	int reserveAmmo = 0;
	if (GetFeatureStatus(FeatureType_Native, "L4D_GetReserveAmmo") == FeatureStatus_Available)
	{
		reserveAmmo = L4D_GetReserveAmmo(client, weapon);
	}
	else if (HasEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType"))
	{
		int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
		if (ammoType >= 0 && ammoType < 32)
		{
			reserveAmmo = GetEntProp(client, Prop_Send, "m_iAmmo", 4, ammoType);
		}
	}
	if (reserveAmmo < 0) reserveAmmo = 0;

	int maxReserve = GetWeaponMaxReserveAmmo(weapon);
	if (maxReserve <= 0) return 100.0;

	float pct = (float(reserveAmmo + clipAmmo) / float(maxReserve)) * 100.0;
	if (pct > 100.0) pct = 100.0;
	return pct;
}

/**
 * Counts team resources (`team_ammo_avg_pct`, `medkits_total`, `throwables_total`, `black_and_white_count`)
 * per Spec Section 3.1.
 */
void CollectTeamResourceTelemetry(
	int &outBlackAndWhiteCount,
	float &outTeamAmmoAvgPct,
	int &outMedkitsTotal,
	int &outThrowablesTotal)
{
	outBlackAndWhiteCount = 0;
	outTeamAmmoAvgPct     = 100.0;
	outMedkitsTotal       = 0;
	outThrowablesTotal    = 0;

	int aliveCount = 0;
	float totalAmmoPct = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidAliveSurvivor(i))
		{
			continue;
		}

		aliveCount++;
		if (IsSurvivorBlackAndWhite(i))
		{
			outBlackAndWhiteCount++;
		}

		totalAmmoPct += GetSurvivorPrimaryAmmoPct(i);

		// Slot 2: Throwables (molotov, pipe_bomb, vomitjar)
		int slot2 = GetPlayerWeaponSlot(i, 2);
		if (slot2 > MaxClients && IsValidEntity(slot2))
		{
			outThrowablesTotal++;
		}

		// Slot 3: Medkit / Defib / Upgrade pack
		int slot3 = GetPlayerWeaponSlot(i, 3);
		if (slot3 > MaxClients && IsValidEntity(slot3))
		{
			char clsName[64];
			GetEntityClassname(slot3, clsName, sizeof(clsName));
			if (StrEqual(clsName, "weapon_first_aid_kit", false))
			{
				outMedkitsTotal++;
			}
		}

		// Slot 4: Pills / Adrenaline (count 2 pills as 1 medkit equivalent if desired, or keep exact)
	}

	if (aliveCount > 0)
	{
		outTeamAmmoAvgPct = totalAmmoPct / float(aliveCount);
	}
}

/**
 * Compute Survivor Roles & Team Telemetry Snapshot (Spec Section 3.1 & 3.2)
 */
void EvaluateTeamTelemetry(
	int &outAliveCount,
	int &outDownOrDeadCount,
	float &outAvgEffHP,
	float &outMaxSpreadDist,
	float &outFrontGapDist,
	float &outRearGapDist,
	int &outP1Front,
	int &outP4Rear,
	int &outPMVP,
	int &outPVulnerable,
	float &outMVPScoreRatio)
{
	outAliveCount      = 0;
	outDownOrDeadCount = 0;
	outAvgEffHP        = 0.0;
	outMaxSpreadDist   = 0.0;
	outFrontGapDist    = 0.0;
	outRearGapDist     = 0.0;
	outP1Front         = 0;
	outP4Rear          = 0;
	outPMVP            = 0;
	outPVulnerable     = 0;
	outMVPScoreRatio   = 1.0;

	int survivors[MAXPLAYERS + 1];
	float flows[MAXPLAYERS + 1];
	float effHPs[MAXPLAYERS + 1];
	float combatScores[MAXPLAYERS + 1];
	int count = 0;

	float totalEffHP = 0.0;
	float totalCombatScore = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
		{
			continue;
		}

		if (!IsPlayerAlive(i) || IsSurvivorIncapOrHanging(i))
		{
			outDownOrDeadCount++;
			if (!IsPlayerAlive(i))
			{
				continue;
			}
		}

		survivors[count] = i;
		flows[count]     = L4D2Direct_GetFlowDistance(i);
		effHPs[count]    = GetSurvivorEffectiveHP(i);

		// Exact Spec Section 3.2 Impact Score Formula:
		// Score_i = (SI Kills * 3) + (Teammate Revives * 5) + (Pins Cleared * 4) + (Damage Dealt / 100.0)
		float score = float(g_iKillsSI[i] * 3 + g_iRevivesDone[i] * 5 + g_iPinsCleared[i] * 4)
			+ (float(g_iDamageDealtSI[i]) / 100.0);
		if (score < 1.0)
		{
			score = 1.0;
		}
		combatScores[count] = score;

		totalEffHP += effHPs[count];
		totalCombatScore += score;
		count++;
	}

	outAliveCount = count;
	if (count == 0)
	{
		return;
	}

	outAvgEffHP = totalEffHP / float(count);

	// Sort survivors by flow descending: index 0 = P1_FRONT, index count-1 = P4_REAR
	for (int a = 0; a < count - 1; a++)
	{
		for (int b = a + 1; b < count; b++)
		{
			if (flows[b] > flows[a])
			{
				int tmpClient = survivors[a]; survivors[a] = survivors[b]; survivors[b] = tmpClient;
				float tmpFlow = flows[a];     flows[a]     = flows[b];     flows[b]     = tmpFlow;
				float tmpHP   = effHPs[a];    effHPs[a]    = effHPs[b];    effHPs[b]    = tmpHP;
				float tmpSc   = combatScores[a]; combatScores[a] = combatScores[b]; combatScores[b] = tmpSc;
			}
		}
	}

	outP1Front = survivors[0];
	outP4Rear  = survivors[count - 1];

	// Flow gap between P1 and P2, and between P(n-1) and P(n)
	if (count >= 2)
	{
		float p1Pos[3], p2Pos[3], pRearPos[3], pPrevRearPos[3];
		GetClientAbsOrigin(survivors[0], p1Pos);
		GetClientAbsOrigin(survivors[1], p2Pos);
		outFrontGapDist = FloatMax(flows[0] - flows[1], GetVectorDistance(p1Pos, p2Pos));

		GetClientAbsOrigin(survivors[count - 1], pRearPos);
		GetClientAbsOrigin(survivors[count - 2], pPrevRearPos);
		outRearGapDist = FloatMax(flows[count - 2] - flows[count - 1], GetVectorDistance(pRearPos, pPrevRearPos));

		for (int a = 0; a < count - 1; a++)
		{
			float posA[3];
			GetClientAbsOrigin(survivors[a], posA);
			for (int b = a + 1; b < count; b++)
			{
				float posB[3];
				GetClientAbsOrigin(survivors[b], posB);
				float d = GetVectorDistance(posA, posB);
				if (d > outMaxSpreadDist)
				{
					outMaxSpreadDist = d;
				}
			}
		}
	}

	// Find P_MVP (highest Impact Score) and P_VULNERABLE (lowest effective HP - 20 * incapCount)
	float bestMVPScore = -999999.0;
	float lowestVulnScore = 999999.0;

	for (int idx = 0; idx < count; idx++)
	{
		int client = survivors[idx];
		if (combatScores[idx] > bestMVPScore)
		{
			bestMVPScore = combatScores[idx];
			outPMVP = client;
		}

		float vulnScore = effHPs[idx] - float(g_iIncapCount[client] * 20);
		if (IsSurvivorBlackAndWhite(client))
		{
			vulnScore -= 30.0;
		}
		if (vulnScore < lowestVulnScore)
		{
			lowestVulnScore = vulnScore;
			outPVulnerable = client;
		}
	}

	float avgCombatScore = totalCombatScore / float(count);
	if (avgCombatScore > 0.1)
	{
		outMVPScoreRatio = bestMVPScore / avgCombatScore;
	}
}

float FloatMax(float a, float b)
{
	return (a >= b) ? a : b;
}

float GetSurvivorSIDamageShare(int survivor)
{
	if (!IsValidAliveSurvivor(survivor))
	{
		return 0.0;
	}

	int totalDmg = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR)
		{
			totalDmg += g_iDamageDealtSI[i];
		}
	}

	if (totalDmg <= 0)
	{
		return 0.0;
	}

	return float(g_iDamageDealtSI[survivor]) / float(totalDmg);
}

// ============================================================================
// State-Machine Brain: Diagnosis & Tactical Decision (Spec v1.2.0 Section 4)
// ============================================================================

void ExecuteEvaluationAndPlanWave()
{
	int aliveCount, downOrDeadCount;
	float avgEffHP, maxSpreadDist, frontGapDist, rearGapDist, mvpScoreRatio;
	int p1Front, p4Rear, pMVP, pVulnerable;

	EvaluateTeamTelemetry(
		aliveCount,
		downOrDeadCount,
		avgEffHP,
		maxSpreadDist,
		frontGapDist,
		rearGapDist,
		p1Front,
		p4Rear,
		pMVP,
		pVulnerable,
		mvpScoreRatio);

	if (aliveCount == 0)
	{
		DirLog("ExecuteEvaluationAndPlanWave: 0 alive survivors -> entering cooldown 10s");
		g_iCurrentCooldown = 10;
		ChangeState(STATE_COOLDOWN, "No alive survivors");
		return;
	}

	int blackAndWhiteCount, medkitsTotal, throwablesTotal;
	float teamAmmoAvgPct;
	CollectTeamResourceTelemetry(blackAndWhiteCount, teamAmmoAvgPct, medkitsTotal, throwablesTotal);

	// Check current native Finale stage (verified in left4dhooks.inc line 4304)
	int curFinaleStage = L4D2_GetCurrentFinaleStage();
	g_iNativeFinaleStage = curFinaleStage;
	bool isNativeBossFinaleStage = (
		curFinaleStage == FINALE_HALFTIME_BOSS ||
		curFinaleStage == FINALE_FINAL_BOSS ||
		curFinaleStage == FINALE_CUSTOM_TANK ||
		curFinaleStage == FINALE_GAUNTLET_BOSS_INCOMING ||
		curFinaleStage == FINALE_GAUNTLET_BOSS);
	bool isNativeHordeFinaleStage = (
		curFinaleStage == FINALE_GAUNTLET_1 ||
		curFinaleStage == FINALE_HORDE_ATTACK_1 ||
		curFinaleStage == FINALE_GAUNTLET_2 ||
		curFinaleStage == FINALE_HORDE_ATTACK_2 ||
		curFinaleStage == FINALE_HORDE_ESCAPE ||
		curFinaleStage == FINALE_CUSTOM_PANIC ||
		curFinaleStage == FINALE_GAUNTLET_HORDE ||
		curFinaleStage == FINALE_GAUNTLET_ESCAPE);

	bool tankAlive = IsTankAliveInPlay();
	float siWipedDurationSec = g_fLastWaveClearDuration;
	float mvpDamageShare = GetSurvivorSIDamageShare(pMVP);

	// Spec Section 1.1 #1 & Section 5.1: Dynamic Multi-Survivor Asymmetric Scaling
	// target_si_limit = alive_survivors + 2 (e.g., 4 -> 6, 8 -> 10, 10 -> 12)
	int baseTargetSI = aliveCount + 2;
	int maxAllowedSI = g_hCvarMaxWaveSI.IntValue;
	if (maxAllowedSI > MAX_WAVE_SI) maxAllowedSI = MAX_WAVE_SI;
	if (baseTargetSI > maxAllowedSI) baseTargetSI = maxAllowedSI;

	// Reset wave tactical flags
	g_bFreezeAmbush          = false;
	g_bWaveWaitingForAmbush  = false;
	g_bFocusStrike           = false;
	g_eBossDir               = BOSS_RESPECT_NATIVE;
	g_eHordeDir              = HORDE_KEEP_NATIVE;

	// ------------------------------------------------------------------------
	// Step 1: Situation Diagnosis & Tactical Intent Selection (Spec Section 4.1)
	// ------------------------------------------------------------------------
	bool isCriticalFatigue = (
		downOrDeadCount >= 2 ||
		avgEffHP < 35.0 ||
		blackAndWhiteCount >= 2 ||
		(g_iWipeCount >= 2 && avgEffHP < 55.0) ||
		(g_iWaveIncapCount >= 2 && avgEffHP < 50.0) ||
		(g_iWaveDamageTaken >= 260 && avgEffHP < 50.0) ||
		(teamAmmoAvgPct < 20.0 && avgEffHP < 50.0)
	);

	if (isCriticalFatigue && g_eLastWaveIntent != INTENT_MERCY_RELAX_ALLOW_HEAL)
	{
		// Team is critically battered -> Mercy / Relax (Spec Section 2.2 Row 4 & Section 4.1 #6)
		// NOTE: BOSS_BLOCK_EXTRA_RESPAWN 100% allows native Finale/map Tanks while blocking extra plugin Tanks!
		g_eDiagnosis       = DIAG_TEAM_CRITICAL_EXHAUSTED;
		g_eIntent          = INTENT_MERCY_RELAX_ALLOW_HEAL;
		g_eTargetRole      = ROLE_P_VULNERABLE;
		g_iTargetSurvivor  = pVulnerable;
		g_eSpawnDir        = DIR_FRONT;
		g_eHordeDir        = HORDE_SCALE_05X;
		g_eBossDir         = BOSS_BLOCK_EXTRA_RESPAWN;
		g_bFreezeAmbush    = false;
		g_bFocusStrike     = false;
		g_iWaveTargetCount = (downOrDeadCount >= 2 || avgEffHP < 25.0) ? 1 : 2;
		g_iCurrentCooldown = (downOrDeadCount >= 2 || g_iWipeCount >= 2) ? 35 : 26; // Tightened from 55|45s
	}
	else if (isCriticalFatigue && g_eLastWaveIntent == INTENT_MERCY_RELAX_ALLOW_HEAL)
	{
		// User rule: Do not allow consecutive Mercy Relax to keep tension up!
		// Resumes standard gauntlet flow instead of letting survivors cruise through multiple relax waves
		DirLog("MERCY_CHAIN_PREVENTED: Previous wave was already MERCY_RELAX_ALLOW_HEAL. Resuming standard challenge wave.");
		g_eDiagnosis       = DIAG_HEALTHY_STEADY_PUSH;
		g_eIntent          = INTENT_MAINTAIN_GAUNTLET_FLOW;
		g_eTargetRole      = ROLE_P1_FRONT;
		g_iTargetSurvivor  = p1Front;
		g_eSpawnDir        = DIR_MIDDLE_FLANK;
		g_eHordeDir        = HORDE_SCALE_05X;
		g_eBossDir         = BOSS_RESPECT_NATIVE;
		g_bFreezeAmbush    = false;
		g_bFocusStrike     = false;
		g_iWaveTargetCount = ClampInt(aliveCount + 1, 2, maxAllowedSI);
		g_iCurrentCooldown = 20;
	}
	else if (isNativeBossFinaleStage || tankAlive)
	{
		// Finale Boss Stage or active Tank -> Spec Section 4.1 #8 & Section 6.2
		g_eDiagnosis       = DIAG_FINALE_BOSS_STAGE;
		g_eIntent          = (avgEffHP >= 70.0 && downOrDeadCount == 0) ? INTENT_ESCALATE_CLIMAX : INTENT_MAINTAIN_GAUNTLET_FLOW;
		g_eTargetRole      = ROLE_P_MVP;
		g_iTargetSurvivor  = pMVP;
		g_eSpawnDir        = DIR_MIDDLE_FLANK;
		g_eHordeDir        = tankAlive ? HORDE_SCALE_05X : HORDE_KEEP_NATIVE;

		// Dynamic Boss Directive based on team strength & wipe count (Spec Section 2.2 & 6.2)
		if (g_iWipeCount >= 2 || avgEffHP < 55.0 || downOrDeadCount >= 1)
		{
			g_eBossDir = BOSS_RESPECT_NATIVE;
		}
		else if (avgEffHP > 75.0 && g_iWipeCount == 0 && (teamAmmoAvgPct > 80.0 || medkitsTotal >= 1 || (g_fLastWaveClearDuration > 0.0 && g_fLastWaveClearDuration <= 4.0)))
		{
			g_eBossDir = BOSS_ADD_2_TANKS;
		}
		else if (avgEffHP >= 55.0)
		{
			g_eBossDir = BOSS_ADD_1_TANK;
		}
		else
		{
			g_eBossDir = BOSS_RESPECT_NATIVE;
		}

		g_bFreezeAmbush    = false;
		g_bFocusStrike     = (avgEffHP >= 60.0 && downOrDeadCount == 0);
		g_iWaveTargetCount = ClampInt(aliveCount, 2, maxAllowedSI);
		g_iCurrentCooldown = 22; // Tightened from 28s
	}
	else if (g_bPanicEventActive || isNativeHordeFinaleStage || g_bFinaleActive)
	{
		// Native Infinite Rush / Gauntlet / Finale Horde Stage -> Spec Section 4.1 #7 & Section 6.2 Rule #1
		g_eDiagnosis       = DIAG_NATIVE_INFINITE_RUSH;
		g_eIntent          = INTENT_MAINTAIN_GAUNTLET_FLOW;
		g_eTargetRole      = ROLE_P1_FRONT;
		g_iTargetSurvivor  = p1Front;
		g_eSpawnDir        = DIR_MIDDLE_FLANK;
		g_eHordeDir        = (avgEffHP < 55.0) ? HORDE_SCALE_05X : HORDE_KEEP_NATIVE;
		// Spec Section 6.2 Rule #1: Lock BOSS_RESPECT_NATIVE during non-Boss Finale stages
		g_eBossDir         = (isNativeHordeFinaleStage || g_bFinaleActive)
			? BOSS_RESPECT_NATIVE
			: ((avgEffHP >= 72.0 && g_iWipeCount == 0) ? BOSS_ADD_1_TANK : BOSS_RESPECT_NATIVE);
		g_bFreezeAmbush    = false;
		g_bFocusStrike     = true;
		g_iWaveTargetCount = ClampInt(aliveCount + 1, 3, maxAllowedSI);
		g_iCurrentCooldown = 22; // Tightened from 35s
		g_bPanicEventActive = false; // Reset one-shot panic flag after handling
	}
	else if (frontGapDist >= 600.0 && aliveCount >= 2)
	{
		// Speedrunner isolated in front (> 600 units, Spec Section 4.1 #2) -> Snipe Lone Wolf
		g_eDiagnosis       = DIAG_SPEEDRUNNER_ISOLATED;
		g_eIntent          = INTENT_SNIPE_LONE_WOLF;
		g_eTargetRole      = ROLE_P1_FRONT;
		g_iTargetSurvivor  = p1Front;
		g_eSpawnDir        = DIR_FRONT;
		g_eHordeDir        = HORDE_KEEP_NATIVE;
		g_eBossDir         = BOSS_RESPECT_NATIVE;
		g_bFreezeAmbush    = true;
		g_bFocusStrike     = true;
		g_iWaveTargetCount = baseTargetSI;
		g_iCurrentCooldown = 15; // Tightened from 20s
	}
	else if (rearGapDist >= 600.0 && aliveCount >= 2)
	{
		// Rear straggler left behind (> 600 units, Spec Section 4.1 #3) -> Rear Ambush Snipe
		g_eDiagnosis       = DIAG_REAR_STRAGGLER_EXPOSED;
		g_eIntent          = INTENT_SNIPE_LONE_WOLF;
		g_eTargetRole      = ROLE_P4_REAR;
		g_iTargetSurvivor  = p4Rear;
		g_eSpawnDir        = DIR_BEHIND;
		g_eHordeDir        = HORDE_KEEP_NATIVE;
		g_eBossDir         = BOSS_RESPECT_NATIVE;
		g_bFreezeAmbush    = false;
		g_bFocusStrike     = true;
		g_iWaveTargetCount = baseTargetSI;
		g_iCurrentCooldown = 15; // Tightened from 20s
	}
	else if (g_fStagnationSeconds >= 25.0 || (g_fFlowVelocity < 1.5 && g_iWaveNumber >= 1 && maxSpreadDist < 380.0))
	{
		// Corner camping / turtle formation (Spec Section 4.1 #5) -> Break Camping Formation
		g_eDiagnosis       = DIAG_CORNER_CAMPING_STRONG;
		g_eIntent          = INTENT_BREAK_CAMPING_FORMATION;
		g_eTargetRole      = ROLE_P_VULNERABLE;
		g_iTargetSurvivor  = pVulnerable;
		g_eSpawnDir        = (GetRandomInt(0, 1) == 0) ? DIR_ABOVE_ROOF : DIR_MIDDLE_FLANK;
		g_eHordeDir        = HORDE_SCALE_12X;
		g_eBossDir         = BOSS_RESPECT_NATIVE;
		g_bFreezeAmbush    = false;
		g_bFocusStrike     = true;
		g_iWaveTargetCount = baseTargetSI;
		g_iCurrentCooldown = 15; // Tightened from 20s
	}
	else if ((mvpScoreRatio >= 1.55 || (mvpDamageShare > 0.40 && g_iKillsSI[pMVP] >= 2)) && g_iWaveNumber >= 1 && avgEffHP >= 55.0)
	{
		// One player is hard-carrying: Impact Score ratio >= 1.55x or SI damage share > 40% (Spec Section 2.2 & 4.1 #4) -> Assassinate MVP
		g_eDiagnosis       = DIAG_MVP_PLAYER_CARRYING;
		g_eIntent          = INTENT_ASSASSINATE_MVP;
		g_eTargetRole      = ROLE_P_MVP;
		g_iTargetSurvivor  = pMVP;
		g_eSpawnDir        = DIR_MIDDLE_FLANK;
		g_eHordeDir        = HORDE_SCALE_12X;
		g_eBossDir         = (avgEffHP >= 78.0 && g_iWipeCount == 0 && !g_bFinaleActive) ? BOSS_ADD_1_TANK : BOSS_RESPECT_NATIVE;
		g_bFreezeAmbush    = true;
		g_bFocusStrike     = true;
		g_iWaveTargetCount = baseTargetSI;
		g_iCurrentCooldown = 20; // Tightened from 28s
	}
	else if (avgEffHP > 75.0 && (teamAmmoAvgPct > 80.0 || (g_fLastWaveClearDuration > 0.0 && g_fLastWaveClearDuration <= 4.0)))
	{
		// Climax Pressure (Spec Section 2.2 Row 1 & Section 4.1):
		// Team HP > 75% and (Ammo > 80% or previous SI wave wiped within <= 4.0s) -> ESCALATE_CLIMAX
		g_eDiagnosis       = DIAG_HEALTHY_STEADY_PUSH;
		g_eIntent          = INTENT_ESCALATE_CLIMAX;
		g_eTargetRole      = ROLE_P1_FRONT;
		g_iTargetSurvivor  = p1Front;

		int dirRoll = g_iWaveNumber % 4;
		if (dirRoll == 0)      g_eSpawnDir = DIR_FRONT;
		else if (dirRoll == 1) g_eSpawnDir = DIR_MIDDLE_FLANK;
		else if (dirRoll == 2) g_eSpawnDir = DIR_ABOVE_ROOF;
		else                   g_eSpawnDir = DIR_BEHIND;

		g_eHordeDir        = (avgEffHP >= 80.0 && (g_iWaveNumber % 3 == 2)) ? HORDE_RIOT_SQUAD : HORDE_SCALE_16X;
		g_eBossDir         = (g_iWipeCount == 0 && !g_bFinaleActive) ? BOSS_ADD_2_TANKS : BOSS_RESPECT_NATIVE;
		g_bFreezeAmbush    = true; // Spec Section 2.2: freeze=true synchronized corner ambush
		g_bFocusStrike     = true;
		g_iWaveTargetCount = baseTargetSI;
		g_iCurrentCooldown = 14;   // Tightened from 20s
	}
	else
	{
		// Standard Flow (Spec Section 2.2 Row 3 & Section 4.1):
		// Normal progression (Team HP 35%~75% or normal ammo / clear speed) -> MAINTAIN_GAUNTLET_FLOW
		g_eDiagnosis       = DIAG_HEALTHY_STEADY_PUSH;
		g_eIntent          = INTENT_MAINTAIN_GAUNTLET_FLOW;
		g_eTargetRole      = ROLE_P1_FRONT;
		g_iTargetSurvivor  = p1Front;

		int dirRoll = g_iWaveNumber % 4;
		if (dirRoll == 0)      g_eSpawnDir = DIR_FRONT;
		else if (dirRoll == 1) g_eSpawnDir = DIR_MIDDLE_FLANK;
		else if (dirRoll == 2) g_eSpawnDir = DIR_ABOVE_ROOF;
		else                   g_eSpawnDir = DIR_BEHIND;

		g_eHordeDir        = HORDE_SCALE_12X;
		g_eBossDir         = (avgEffHP >= 55.0 && g_iWipeCount == 0 && !g_bFinaleActive) ? BOSS_ADD_1_TANK : BOSS_RESPECT_NATIVE;
		g_bFreezeAmbush    = (g_eSpawnDir == DIR_FRONT || g_eSpawnDir == DIR_ABOVE_ROOF);
		g_bFocusStrike     = (avgEffHP >= 60.0);
		g_iWaveTargetCount = baseTargetSI;
		g_iCurrentCooldown = 20;   // Tightened from 35s!
	}

	// Clamp cooldown to configured ConVar bounds
	g_iCurrentCooldown = ClampInt(g_iCurrentCooldown, g_hCvarMinCooldown.IntValue, g_hCvarMaxCooldown.IntValue);

	if (g_iWaveTargetCount > maxAllowedSI)
	{
		g_iWaveTargetCount = maxAllowedSI;
	}

	// Reset per-wave damage & incap counters now that we've consumed them
	int prevWaveDmg    = g_iWaveDamageTaken;
	int prevWaveIncaps = g_iWaveIncapCount;
	g_iWaveDamageTaken = 0;
	g_iWaveIncapCount  = 0;

	// Rolling score decay (50%) to prevent cumulative MVP monopoly across waves
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iKillsSI[i]       = g_iKillsSI[i] / 2;
		g_iPinsCleared[i]   = g_iPinsCleared[i] / 2;
		g_iRevivesDone[i]   = g_iRevivesDone[i] / 2;
		g_iDamageDealtSI[i] = g_iDamageDealtSI[i] / 2;
	}

	// Build SI composition for the chosen TacticalIntent with Spec Section 5.2 Anti-Hard-CC Cap
	BuildWaveComposition(g_eIntent, g_iWaveTargetCount, aliveCount);
	g_eLastWaveIntent = g_eIntent;

	g_iWaveNumber++;
	g_iWaveCursor       = 0;
	g_iWaveSuccessCount = 0;

	char targetName[64] = "None";
	if (IsValidAliveSurvivor(g_iTargetSurvivor))
	{
		GetClientName(g_iTargetSurvivor, targetName, sizeof(targetName));
	}

	char compSummary[192];
	FormatWaveComposition(compSummary, sizeof(compSummary));

	DirLog("WAVE_PLAN [W#%d]: Diag=%s | Intent=%s | Target=%s(%s) | Dir=%s | Count=%d [%s] | Freeze=%d | Focus=%d | Horde=%s | Boss=%s | Cooldown=%ds | Telemetry(alive=%d, down=%d, bw=%d, wipes=%d, avgHP=%.1f, ammo=%.0f%%, medkits=%d, throws=%d, flow=%.1f%%, vel=%.1f%%/m, spread=%.0f, frontGap=%.0f, rearGap=%.0f, stag=%.0fs, wipedSec=%.1f, stage=%d, prevDmg=%d, prevInc=%d)",
		g_iWaveNumber,
		g_sDiagnosisNames[g_eDiagnosis],
		g_sIntentNames[g_eIntent],
		g_sRoleNames[g_eTargetRole],
		targetName,
		g_sDirNames[g_eSpawnDir],
		g_iWaveTargetCount,
		compSummary,
		g_bFreezeAmbush ? 1 : 0,
		g_bFocusStrike ? 1 : 0,
		g_sHordeNames[g_eHordeDir],
		g_sBossNames[g_eBossDir],
		g_iCurrentCooldown,
		aliveCount,
		downOrDeadCount,
		blackAndWhiteCount,
		g_iWipeCount,
		avgEffHP,
		teamAmmoAvgPct,
		medkitsTotal,
		throwablesTotal,
		g_fPeakFlowRatio,
		g_fFlowVelocity,
		maxSpreadDist,
		frontGapDist,
		rearGapDist,
		g_fStagnationSeconds,
		siWipedDurationSec,
		curFinaleStage,
		prevWaveDmg,
		prevWaveIncaps);

	// Apply immediate horde / mercy / rush side-effects (Spec Section 4.1 & 5.3)
	if (g_eIntent == INTENT_MERCY_RELAX_ALLOW_HEAL)
	{
		L4D_ResetMobTimer();
	}
	else if (g_eIntent == INTENT_BREAK_CAMPING_FORMATION && IsValidAliveSurvivor(g_iTargetSurvivor))
	{
		// Spec Section 5.3: Only flush survivors with L4D2_RushVictim when they turtle/camp in corners
		if (GetFeatureStatus(FeatureType_Native, "L4D2_RushVictim") == FeatureStatus_Available)
		{
			L4D2_RushVictim(g_iTargetSurvivor, 1200.0);
			DirLog("Executed L4D2_RushVictim on %N (range=1200.0)", g_iTargetSurvivor);
		}
	}
	else
	{
		// Space out natural mob rushes during Special Infected waves so players aren't overwhelmed by hordes
		L4D_ResetMobTimer();
	}

	ExecuteRiotAndMercyUncommonSideEffects(g_iTargetSurvivor);

	if (g_hCvarChatReport.BoolValue)
	{
		PrintToChatAll("\x04[AI Director]\x01 波次 \x05#%d\x01 | 診斷: \x03%s\x01 | 意圖: \x03%s\x01 | 目標: \x05%s (%s)\x01 | 方位: \x03%s\x01 | 編制: \x05%d隻\x01 (%s)",
			g_iWaveNumber,
			g_sDiagnosisNames[g_eDiagnosis],
			g_sIntentNames[g_eIntent],
			g_sRoleNames[g_eTargetRole],
			targetName,
			g_sDirNames[g_eSpawnDir],
			g_iWaveTargetCount,
			compSummary);
	}

	// Start wave spawning queue & record wave start time
	g_fWaveCombatStartTime = GetGameTime();
	ChangeState(STATE_SPAWNING, "Wave planned, starting spawn queue");
	if (g_hSpawnQueueTimer != null)
	{
		delete g_hSpawnQueueTimer;
	}
	g_hSpawnQueueTimer = CreateTimer(SPAWN_INTERVAL, Timer_SpawnQueueTick, _, TIMER_REPEAT);
}

int ClampInt(int val, int minVal, int maxVal)
{
	if (val < minVal) return minVal;
	if (val > maxVal) return maxVal;
	return val;
}

bool IsHardCCClass(int zc)
{
	return (zc == ZC_SMOKER || zc == ZC_HUNTER || zc == ZC_JOCKEY || zc == ZC_CHARGER);
}

int CountActiveSIClass(int zc)
{
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i))
		{
			if (GetEntProp(i, Prop_Send, "m_zombieClass") == zc)
			{
				count++;
			}
		}
	}
	return count;
}

/**
 * Spec Section 1.1 #3 & Section 5.2 Anti-Hard-CC Class Cap:
 * Max per Hard-CC class (`Hunter`, `Smoker`, `Jockey`, `Charger`) = `RoundToCeil(float(aliveSurvivors) / 3.0)`.
 * If the requested Hard-CC class already reached `maxPerClass` (counting both active on-field SI and
 * earlier slots in `g_iWaveQueue`), converts it to `ZC_SPITTER` or `ZC_BOOMER` (or another non-capped class).
 */
int EnforceAntiHardCCCap(int requestedClass, int aliveSurvivors, int currentQueueLen)
{
	if (!IsHardCCClass(requestedClass))
	{
		return requestedClass;
	}

	int maxPerClass = RoundToCeil(float(aliveSurvivors) / 3.0);
	if (maxPerClass < 1)
	{
		maxPerClass = 1;
	}

	int currentCount = CountActiveSIClass(requestedClass);
	for (int j = 0; j < currentQueueLen; j++)
	{
		if (g_iWaveQueue[j] == requestedClass)
		{
			currentCount++;
		}
	}

	if (currentCount < maxPerClass)
	{
		return requestedClass;
	}

	// Try another Hard-CC class that hasn't hit maxPerClass first if we need pinners,
	// or convert to Spitter / Boomer per Spec Section 5.2 once Hard-CC slots are full.
	int fallbackClasses[] = { ZC_SPITTER, ZC_BOOMER, ZC_HUNTER, ZC_JOCKEY, ZC_SMOKER, ZC_CHARGER };
	for (int k = 0; k < sizeof(fallbackClasses); k++)
	{
		int cand = fallbackClasses[k];
		if (!IsHardCCClass(cand))
		{
			// Alternate between Spitter and Boomer
			return ((currentQueueLen % 2) == 0) ? ZC_SPITTER : ZC_BOOMER;
		}
	}

	return ZC_SPITTER;
}

/**
 * Populates `g_iWaveQueue` based on `TacticalIntent` and enforces Spec Section 5.2 Anti-Hard-CC Cap:
 * - SNIPE_LONE_WOLF / ASSASSINATE_MVP: Pinners (Hunter, Jockey, Charger, Smoker) + Spitter/Boomer overflow
 * - BREAK_CAMPING_FORMATION: Area disruption + displacement (Charger, Spitter, Boomer, Jockey, Smoker)
 * - MERCY_RELAX_ALLOW_HEAL: Pause Hard-CC pinners! Only Boomer + Spitter (Spec Section 4.1 #6)
 * - ESCALATE_CLIMAX / MAINTAIN_GAUNTLET_FLOW: Balanced combined arms
 */
void BuildWaveComposition(TacticalIntent intent, int count, int aliveSurvivors)
{
	for (int i = 0; i < count; i++)
	{
		int desiredClass = ZC_HUNTER;
		switch (intent)
		{
			case INTENT_SNIPE_LONE_WOLF, INTENT_ASSASSINATE_MVP:
			{
				// Prioritize diverse pinners first so Focus Squad gets pinners without exceeding maxPerClass
				int pool[] = { ZC_HUNTER, ZC_JOCKEY, ZC_CHARGER, ZC_SMOKER, ZC_SPITTER, ZC_BOOMER };
				desiredClass = pool[i % sizeof(pool)];
			}
			case INTENT_BREAK_CAMPING_FORMATION:
			{
				// Prioritize Charger + Spitter + Boomer + Jockey + Smoker to break corners
				int pool[] = { ZC_CHARGER, ZC_SPITTER, ZC_BOOMER, ZC_JOCKEY, ZC_SMOKER, ZC_SPITTER };
				desiredClass = pool[i % sizeof(pool)];
			}
			case INTENT_MERCY_RELAX_ALLOW_HEAL:
			{
				// Spec Section 4.1 #6: Pause Hard-CC pinners; only Boomer / Spitter
				int pool[] = { ZC_BOOMER, ZC_SPITTER };
				desiredClass = pool[i % sizeof(pool)];
			}
			case INTENT_ESCALATE_CLIMAX:
			{
				// Spec Section 2.2: Charger + Spitter to break group + Hunter/Jockey/Smoker/Boomer
				int pool[] = { ZC_CHARGER, ZC_SPITTER, ZC_HUNTER, ZC_JOCKEY, ZC_SMOKER, ZC_BOOMER };
				desiredClass = pool[i % sizeof(pool)];
			}
			default:
			{
				// Spec Section 2.2 Standard Flow (MAINTAIN_GAUNTLET_FLOW): 1 Control + 1 Harass + 1 Support
				int pool[] = { ZC_HUNTER, ZC_SPITTER, ZC_BOOMER, ZC_JOCKEY, ZC_SMOKER, ZC_CHARGER };
				int idx = (i + GetRandomInt(0, 1)) % sizeof(pool);
				desiredClass = pool[idx];
			}
		}

		g_iWaveQueue[i] = EnforceAntiHardCCCap(desiredClass, aliveSurvivors, i);
	}
}

void FormatWaveComposition(char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	for (int i = 0; i < g_iWaveTargetCount; i++)
	{
		int zc = g_iWaveQueue[i];
		if (i > 0)
		{
			StrCat(buffer, maxlen, "+");
		}
		StrCat(buffer, maxlen, (zc >= 1 && zc <= 8) ? g_sSINames[zc] : "?");
	}
}

void ExecuteRiotAndMercyUncommonSideEffects(int preferredAnchor)
{
	int anchor = IsValidAliveSurvivor(preferredAnchor) ? preferredAnchor : L4D_GetHighestFlowSurvivor();
	if (!IsValidAliveSurvivor(anchor))
	{
		anchor = GetAnyAliveSurvivor();
	}
	if (!IsValidAliveSurvivor(anchor))
	{
		return;
	}

	// 1. HORDE_RIOT_SQUAD: Spawn a small squad of uncommon riot/ceda infected (Spec Section 4.1)
	if (g_eHordeDir == HORDE_RIOT_SQUAD)
	{
		for (int i = 0; i < 4; i++)
		{
			ExecuteCheatCommand(anchor, "z_spawn_old", (i % 2 == 0) ? "riot auto" : "ceda auto");
		}
		DirLog("Executed HORDE_RIOT_SQUAD: spawned 4 riot/ceda uncommon infected near %N", anchor);
	}
	// 2. INTENT_MERCY_RELAX_ALLOW_HEAL: Spawn 1 clown uncommon for light atmospheric pressure (Spec Section 4.1 #6)
	else if (g_eIntent == INTENT_MERCY_RELAX_ALLOW_HEAL)
	{
		ExecuteCheatCommand(anchor, "z_spawn_old", "clown auto");
		DirLog("Executed MERCY_RELAX_ALLOW_HEAL: spawned 1 clown uncommon infected near %N", anchor);
	}
}

// ============================================================================
// Multi-Tier SI Spawning Pipeline (Ref: all4dead2.sp, l4dinfectedbots.sp, abm.sp)
// ============================================================================

/**
 * Spec Section 5.1: 32-Slot Safety Guard (`Ed_Alloc: no free edicts` / FakeClient overflow prevention).
 * Always preserve at least 4 safety slots (`GetClientCount(false) + neededSpawns <= 28`).
 */
bool HasSafeClientSlotMargin(int neededSpawns)
{
	int currentClients = GetClientCount(false);
	if (currentClients + neededSpawns > SAFE_CLIENT_SLOT_LIMIT)
	{
		DirLog("SLOT_GUARD_ABORT: GetClientCount(false)=%d + needed=%d > SAFE_CLIENT_SLOT_LIMIT(%d)",
			currentClients, neededSpawns, SAFE_CLIENT_SLOT_LIMIT);
		return false;
	}
	return true;
}

public Action Timer_SpawnQueueTick(Handle timer)
{
	if (g_eState != STATE_SPAWNING || !g_hCvarEnabled.BoolValue || !g_bLeftSafeArea)
	{
		g_hSpawnQueueTimer = null;
		return Plugin_Stop;
	}

	if (g_iWaveCursor >= g_iWaveTargetCount)
	{
		g_hSpawnQueueTimer = null;
		OnWaveSpawningFinished();
		return Plugin_Stop;
	}

	// Spec Section 5.1: 28-Slot Safety Guard check before spawning
	if (!HasSafeClientSlotMargin(1))
	{
		g_hSpawnQueueTimer = null;
		OnWaveSpawningFinished();
		return Plugin_Stop;
	}

	int aliveSurvivors = CountAliveSurvivors();
	if (aliveSurvivors < 1)
	{
		aliveSurvivors = 4;
	}

	// Re-verify Anti-Hard-CC cap against currently alive SI on the field at spawn moment
	int zc = EnforceAntiHardCCCap(g_iWaveQueue[g_iWaveCursor], aliveSurvivors, 0);
	int spawnSlotIndex = g_iWaveCursor;
	g_iWaveCursor++;

	// Determine if this SI belongs to the Focus Squad (`<= floor(target_si / 2)`)
	int maxFocusSquadSize = g_iWaveTargetCount / 2;
	if (maxFocusSquadSize < 1 && g_bFocusStrike)
	{
		maxFocusSquadSize = 1;
	}
	bool assignFocusSquad = (g_bFocusStrike && spawnSlotIndex < maxFocusSquadSize);

	int spawnedClient = SpawnSpecialInfectedMultiTier(zc, g_iTargetSurvivor, g_eSpawnDir, assignFocusSquad);
	if (spawnedClient > 0)
	{
		g_iWaveSuccessCount++;
	}

	if (g_iWaveCursor >= g_iWaveTargetCount)
	{
		g_hSpawnQueueTimer = null;
		OnWaveSpawningFinished();
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

void OnWaveSpawningFinished()
{
	DirLog("OnWaveSpawningFinished [W#%d]: Spawned %d / %d SI successfully.",
		g_iWaveNumber, g_iWaveSuccessCount, g_iWaveTargetCount);

	if (g_iWaveSuccessCount == 0)
	{
		// CRITICAL FIX: If 0 SI spawned (e.g., survivors in a weird transition tunnel),
		// do NOT enter a 35-55s cooldown! Retry in 5 seconds!
		g_fWaveCombatStartTime = 0.0;
		g_iCurrentCooldown = 5;
		ChangeState(STATE_COOLDOWN, "0 SI spawned in wave -> fast 5s retry");
		return;
	}

	// Trigger L4D2_StartAssault() so SI bots coordinate their attack immediately
	if (GetFeatureStatus(FeatureType_Native, "L4D2_StartAssault") == FeatureStatus_Available)
	{
		L4D2_StartAssault();
	}

	// If survivors already wiped all spawned SI while the queue was still spawning,
	// record the ultra-fast clear duration (<= 4.0s) and transition straight to cooldown!
	if (CountActiveNonTankSI() == 0)
	{
		g_fLastWaveClearDuration = (g_fWaveCombatStartTime > 0.0) ? (GetGameTime() - g_fWaveCombatStartTime) : 1.0;
		if (g_fLastWaveClearDuration < 0.1)
		{
			g_fLastWaveClearDuration = 0.1;
		}
		g_fWaveCombatStartTime = 0.0;
		DirLog("OnWaveSpawningFinished [W#%d]: Wave was speed-wiped during spawn queue in %.1fs!",
			g_iWaveNumber, g_fLastWaveClearDuration);
		ChangeState(STATE_COOLDOWN, "Wave speed-wiped during spawn queue");
		return;
	}

	g_fWaveCombatStartTime = GetGameTime();
	g_fCombatTimeout = 28.0;
	ChangeState(STATE_COMBAT, "Wave spawning complete");
}

void FinishCombatWave(const char[] reason)
{
	// Unfreeze any remaining frozen SI before ending wave
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bIsFrozenAmbush[i])
		{
			UnfreezeSI(i, "CombatWaveEnd");
		}
		g_bIsFocusSquad[i] = false;
	}

	if (CountActiveNonTankSI() == 0)
	{
		if (g_fWaveCombatStartTime > 0.0)
		{
			g_fLastWaveClearDuration = GetGameTime() - g_fWaveCombatStartTime;
			if (g_fLastWaveClearDuration < 0.1)
			{
				g_fLastWaveClearDuration = 0.1;
			}
			g_fWaveCombatStartTime = 0.0;
		}
	}
	else if (g_fWaveCombatStartTime > 0.0)
	{
		// Wave timed out with SI still alive -> not a fast wipe
		g_fLastWaveClearDuration = g_fCombatTimeout;
		g_fWaveCombatStartTime = 0.0;
	}

	DirLog("FinishCombatWave [W#%d]: Reason=%s | LastClearDuration=%.1fs | Next cooldown=%ds",
		g_iWaveNumber, reason, g_fLastWaveClearDuration, g_iCurrentCooldown);

	ChangeState(STATE_COOLDOWN, reason);
}

/**
 * Multi-Tier Special Infected Spawner:
 * - Position Tier 1: Tactical Nav-Scored `L4D_GetRandomPZSpawnPosition` around target anchor
 *   scored by `SpawnDirection`, distance, and no-LOS.
 * - Position Tier 2: Relaxed `L4D_GetRandomPZSpawnPosition` across ALL alive survivors
 *   (starting from highest-flow survivor).
 * - Position Tier 3: Direct Radial Nav-Mesh Ray Sampling around anchor (`350..850` units)
 *   verified on a valid `TerrorNavArea` and out of survivor LOS.
 * - Spawner Priority at Tier 1/2/3 coordinates:
 *   1. When `g_bSDKCallsReady` is true, Tier 1 spawner is `SpawnInfectedBotViaSDKCall` (`NextBotCreatePlayerBot<T>`,
 *      as used by `all4dead2.sp` and `l4dinfectedbots.sp`) so C++ inlined `ZombieManager::SpawnSpecial` class/dominator
 *      checks never throttle 6-12 SI waves in Coop.
 *   2. Tier 2 spawner fallback is `L4D2_SpawnSpecial` (`ZombieManager::SpawnSpecial`).
 * - Position/Spawner Tier 4: `z_spawn_old <class> auto` cheat command fallback (like `all4dead2.sp` / `abm.sp`).
 */
int SpawnSpecialInfectedMultiTier(int zc, int preferredAnchor, SpawnDirection dir, bool isFocusSquad)
{
	if (!HasSafeClientSlotMargin(1))
	{
		return 0;
	}

	int activeSI = CountActiveNonTankSI();
	if (activeSI >= MAX_SI_SLOTS - 2)
	{
		DirLog("SpawnSpecialInfectedMultiTier: Active SI (%d) near MAX_SI_SLOTS (%d), skipping.", activeSI, MAX_SI_SLOTS);
		return 0;
	}

	int anchor = preferredAnchor;
	if (!IsValidAliveSurvivor(anchor))
	{
		anchor = L4D_GetHighestFlowSurvivor();
	}
	if (!IsValidAliveSurvivor(anchor))
	{
		anchor = GetAnyAliveSurvivor();
	}
	if (!IsValidAliveSurvivor(anchor))
	{
		return 0;
	}

	float spawnPos[3];
	float spawnAng[3];
	int tierUsed = 0;

	// Position Tier 1: Direction-scored Nav spawn around anchor
	if (FindTier1ScoredSpawnPos(anchor, zc, dir, spawnPos))
	{
		tierUsed = 1;
	}
	// Position Tier 2: Any valid PZ spawn position across all alive survivors
	else if (FindTier2AnySurvivorPZPos(anchor, zc, spawnPos))
	{
		tierUsed = 2;
	}
	// Position Tier 3: Radial Nav-Mesh sampling out of LOS around anchor
	else if (FindTier3RadialNavPos(anchor, dir, spawnPos))
	{
		tierUsed = 3;
	}

	int bot = 0;
	if (tierUsed > 0)
	{
		float anchorPos[3];
		GetClientAbsOrigin(anchor, anchorPos);
		MakeVectorFromPoints(spawnPos, anchorPos, spawnAng);
		GetVectorAngles(spawnAng, spawnAng);
		spawnAng[0] = 0.0;
		spawnAng[2] = 0.0;

		// Spawner Priority 1: NextBotCreatePlayerBot<T> SDKCall (bypasses C++ inlined ZombieManager caps)
		if (g_bSDKCallsReady)
		{
			bot = SpawnInfectedBotViaSDKCall(zc, spawnPos, spawnAng);
		}

		// Spawner Priority 2: L4D2_SpawnSpecial (ZombieManager::SpawnSpecial) fallback
		if (bot <= 0 || !IsClientInGame(bot) || !IsPlayerAlive(bot))
		{
			g_bOurSpawn = true;
			bot = L4D2_SpawnSpecial(zc, spawnPos, spawnAng);
			g_bOurSpawn = false;
		}
	}

	// Spawner Priority 3 / Position Tier 4: `z_spawn_old <class> auto` fallback (TempFakeClient / anchor)
	if (bot <= 0 || !IsClientInGame(bot) || !IsPlayerAlive(bot))
	{
		bot = SpawnViaZSpawnOldAuto(anchor, zc);
		if (bot > 0 && IsClientInGame(bot) && IsPlayerAlive(bot))
		{
			if (tierUsed > 0)
			{
				// Preserve our tactical Tier 1-3 coordinate if we already found one
				TeleportEntity(bot, spawnPos, spawnAng, NULL_VECTOR);
			}
			else
			{
				tierUsed = 4;
				GetClientAbsOrigin(bot, spawnPos);
			}
		}
	}

	if (bot > 0 && IsClientInGame(bot) && IsPlayerAlive(bot))
	{
		ConfigureSpawnedSIBot(bot, zc, anchor, isFocusSquad, tierUsed, spawnPos);
		return bot;
	}

	DirLog("ERROR: All 4 spawn tiers failed for class=%s(%d) anchor=%N",
		g_sSINames[zc], zc, anchor);
	return 0;
}

/**
 * Tier 1: Sample candidate positions via `L4D_GetRandomPZSpawnPosition` and score them
 * according to the Spec's `SpawnDirection` (`FRONT`, `MIDDLE_FLANK`, `BEHIND`, `ABOVE_ROOF`, `BELOW_FLOOR`).
 */
bool FindTier1ScoredSpawnPos(int anchor, int zc, SpawnDirection dir, float outPos[3])
{
	float anchorPos[3], anchorEyeAng[3], anchorFwd[3];
	GetClientAbsOrigin(anchor, anchorPos);
	GetClientEyeAngles(anchor, anchorEyeAng);
	anchorEyeAng[0] = 0.0;
	anchorEyeAng[2] = 0.0;
	GetAngleVectors(anchorEyeAng, anchorFwd, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(anchorFwd, anchorFwd);

	float anchorFlow = L4D2Direct_GetFlowDistance(anchor);

	float bestScore = -999999.0;
	bool found = false;

	for (int i = 0; i < 12; i++)
	{
		float cand[3];
		if (!L4D_GetRandomPZSpawnPosition(anchor, zc, 5, cand))
		{
			continue;
		}

		float dist = GetVectorDistance(anchorPos, cand);
		if (dist < 180.0 || dist > SPAWN_DIST_MAX)
		{
			continue;
		}

		// Reject if visible to any survivor
		if (IsPointVisibleToAnySurvivor(cand))
		{
			continue;
		}

		float score = ScoreCandidatePosition(anchorPos, anchorFwd, anchorFlow, cand, dist, dir);
		if (score > bestScore)
		{
			bestScore = score;
			outPos[0] = cand[0];
			outPos[1] = cand[1];
			outPos[2] = cand[2];
			found = true;
		}
	}

	return found;
}

float ScoreCandidatePosition(
	const float anchorPos[3],
	const float anchorFwd[3],
	float anchorFlow,
	float candPos[3],
	float dist,
	SpawnDirection dir)
{
	float score = 100.0;

	// Prefer 350..900 distance
	if (dist >= SPAWN_DIST_MIN && dist <= 900.0)
	{
		score += 35.0;
	}
	else if (dist > 900.0)
	{
		score -= (dist - 900.0) * 0.05;
	}

	float dz = candPos[2] - anchorPos[2];
	float toCand[3];
	toCand[0] = candPos[0] - anchorPos[0];
	toCand[1] = candPos[1] - anchorPos[1];
	toCand[2] = 0.0;
	NormalizeVector(toCand, toCand);
	float dot = GetVectorDotProduct(anchorFwd, toCand); // +1 = dead ahead, 0 = 90deg flank, -1 = behind

	// Check NavArea flow if available
	Address navArea = L4D2Direct_GetTerrorNavArea(candPos);
	float candFlow = anchorFlow;
	if (navArea != Address_Null)
	{
		candFlow = L4D2Direct_GetTerrorNavAreaFlow(navArea);
		int spawnAttrs = L4D_GetNavArea_SpawnAttributes(navArea);
		if (spawnAttrs & NAV_SPAWN_OBSCURED)
		{
			score += 20.0;
		}
	}

	switch (dir)
	{
		case DIR_FRONT:
		{
			if (candFlow > anchorFlow + 50.0) score += 45.0;
			if (dot > 0.35)                   score += 35.0;
			else if (dot < -0.2)              score -= 40.0;
		}
		case DIR_MIDDLE_FLANK:
		{
			float absDot = FloatAbs(dot);
			if (absDot <= 0.65) score += 50.0; // 45..135 degrees
			else                score -= 25.0;
		}
		case DIR_BEHIND:
		{
			if (candFlow < anchorFlow - 50.0) score += 45.0;
			if (dot < -0.30)                  score += 35.0;
			else if (dot > 0.25)              score -= 40.0;
		}
		case DIR_ABOVE_ROOF:
		{
			if (dz >= SPAWN_HEIGHT_THRESHOLD) score += 70.0;
			else if (dz >= 45.0)              score += 25.0;
			else                              score -= 30.0;
		}
		case DIR_BELOW_FLOOR:
		{
			if (dz <= -SPAWN_HEIGHT_THRESHOLD) score += 70.0;
			else if (dz <= -45.0)              score += 25.0;
			else                               score -= 30.0;
		}
	}

	return score;
}

/**
 * Tier 2: Iterate through all alive survivors and request `L4D_GetRandomPZSpawnPosition`
 * with higher try counts, trying both the requested class and Hunter/Smoker fallback classes.
 */
bool FindTier2AnySurvivorPZPos(int primaryAnchor, int zc, float outPos[3])
{
	// First try primaryAnchor with 20 tries
	if (L4D_GetRandomPZSpawnPosition(primaryAnchor, zc, 20, outPos))
	{
		return true;
	}

	// Next try highest flow survivor
	int ahead = L4D_GetHighestFlowSurvivor();
	if (IsValidAliveSurvivor(ahead) && ahead != primaryAnchor)
	{
		if (L4D_GetRandomPZSpawnPosition(ahead, zc, 20, outPos))
		{
			return true;
		}
	}

	// Next try every other alive survivor
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidAliveSurvivor(i) || i == primaryAnchor || i == ahead)
		{
			continue;
		}
		if (L4D_GetRandomPZSpawnPosition(i, zc, 15, outPos))
		{
			return true;
		}
	}

	// Finally try with ZC_HUNTER on primaryAnchor (in case class-specific nav rules failed)
	if (zc != ZC_HUNTER && L4D_GetRandomPZSpawnPosition(primaryAnchor, ZC_HUNTER, 15, outPos))
	{
		return true;
	}

	return false;
}

/**
 * Tier 3: Radial Nav-Mesh Ray Sampler (for narrow/elevated coaster tracks where
 * `L4D_GetRandomPZSpawnPosition` returns false).
 * Samples radial offsets around alive survivors, traces down to ground, verifies
 * `L4D2Direct_GetTerrorNavArea(cand) != Address_Null`, and checks no-LOS.
 */
bool FindTier3RadialNavPos(int primaryAnchor, SpawnDirection dir, float outPos[3])
{
	float anchorPos[3], eyeAng[3];
	GetClientAbsOrigin(primaryAnchor, anchorPos);
	GetClientEyeAngles(primaryAnchor, eyeAng);

	float baseYaw = eyeAng[1];
	if (dir == DIR_BEHIND)            baseYaw += 180.0;
	else if (dir == DIR_MIDDLE_FLANK) baseYaw += (GetRandomInt(0, 1) == 0) ? 90.0 : -90.0;

	float radii[] = { 450.0, 650.0, 850.0, 350.0 };
	float zOffsets[] = { 120.0, 260.0, -40.0 };

	for (int r = 0; r < sizeof(radii); r++)
	{
		float radius = radii[r];
		for (int step = 0; step < 12; step++)
		{
			float yaw = baseYaw + float(step * 30);
			float rad = DegToRad(yaw);

			for (int zIdx = 0; zIdx < sizeof(zOffsets); zIdx++)
			{
				float startPt[3], endPt[3], groundPt[3];
				startPt[0] = anchorPos[0] + Cosine(rad) * radius;
				startPt[1] = anchorPos[1] + Sine(rad) * radius;
				startPt[2] = anchorPos[2] + zOffsets[zIdx];

				endPt[0] = startPt[0];
				endPt[1] = startPt[1];
				endPt[2] = anchorPos[2] - 400.0;

				Handle trace = TR_TraceRayFilterEx(startPt, endPt, MASK_PLAYERSOLID_BRUSHONLY, RayType_EndPoint, TraceFilter_WorldOnly);
				bool hit = TR_DidHit(trace);
				if (hit)
				{
					TR_GetEndPosition(groundPt, trace);
				}
				delete trace;

				if (!hit)
				{
					continue;
				}

				groundPt[2] += 10.0;

				// Must be on a valid TerrorNavArea and not in a checkpoint
				Address navArea = L4D2Direct_GetTerrorNavArea(groundPt);
				if (navArea == Address_Null)
				{
					continue;
				}
				int spawnAttrs = L4D_GetNavArea_SpawnAttributes(navArea);
				if (spawnAttrs & NAV_SPAWN_CHECKPOINT)
				{
					continue;
				}

				// Must have enough headroom (hull trace)
				if (!IsHullClearForSI(groundPt))
				{
					continue;
				}

				// Must not be within 220 units of any survivor or directly visible
				if (IsTooCloseOrVisibleToSurvivors(groundPt, 220.0))
				{
					continue;
				}

				outPos[0] = groundPt[0];
				outPos[1] = groundPt[1];
				outPos[2] = groundPt[2];
				return true;
			}
		}
	}

	return false;
}

/**
 * Tier 4: `z_spawn_old <class> auto` Cheat Command Fallback
 * (Reference: `all4dead2.sp` `Do_SpawnInfected_Old` & `abm.sp` `AddInfected`)
 */
int SpawnViaZSpawnOldAuto(int survivorClient, int zc)
{
	if (zc < 1 || zc > 6 || !IsValidAliveSurvivor(survivorClient))
	{
		return 0;
	}

	bool existedBefore[MAXPLAYERS + 1];
	for (int i = 1; i <= MaxClients; i++)
	{
		existedBefore[i] = (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i));
	}

	char args[64];
	FormatEx(args, sizeof(args), "%s auto", g_sSICmdNames[zc]);

	// Method A (all4dead2.sp style): Execute z_spawn_old <class> auto on anchor survivor
	g_bOurSpawn = true;
	ExecuteCheatCommand(survivorClient, "z_spawn_old", args);
	g_bOurSpawn = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!existedBefore[i] && IsClientInGame(i) && !IsClientInKickQueue(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i))
		{
			return i;
		}
	}

	// Method B (abm.sp AddInfected style): Create a temporary Team 3 FakeClient, execute z_spawn_old <class> auto area, and kick dummy
	if (HasSafeClientSlotMargin(2))
	{
		int tempBot = CreateFakeClient("DirTempSI");
		if (tempBot > 0 && IsClientInGame(tempBot))
		{
			ChangeClientTeam(tempBot, TEAM_INFECTED);
			FormatEx(args, sizeof(args), "%s auto area", g_sSICmdNames[zc]);
			g_bOurSpawn = true;
			ExecuteCheatCommand(tempBot, "z_spawn_old", args);
			g_bOurSpawn = false;
			KickClient(tempBot, "Temp SI spawner cleanup");

			for (int i = 1; i <= MaxClients; i++)
			{
				if (i != tempBot && !existedBefore[i] && IsClientInGame(i) && !IsClientInKickQueue(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i))
				{
					return i;
				}
			}
		}
	}

	return 0;
}

void ExecuteCheatCommand(int client, const char[] command, const char[] args)
{
	int flags = GetCommandFlags(command);
	SetCommandFlags(command, flags & ~FCVAR_CHEAT);
	FakeClientCommand(client, "%s %s", command, args);
	SetCommandFlags(command, flags);
}

/**
 * Post-Spawn Configuration for a newly spawned SI Bot:
 * - Assigns Focus Squad membership (`g_bIsFocusSquad[bot]`).
 * - Applies `freeze_ambush` (`FL_FROZEN`) if enabled.
 * - Issues initial `L4D2_CommandABot` attack/move order.
 */
void ConfigureSpawnedSIBot(int bot, int zc, int anchor, bool isFocusSquad, int tierUsed, const float spawnPos[3])
{
	g_bIsFocusSquad[bot]   = isFocusSquad;
	g_bIsFrozenAmbush[bot] = false;

	float anchorPos[3];
	GetClientAbsOrigin(anchor, anchorPos);
	float dist = GetVectorDistance(spawnPos, anchorPos);

	// Apply freeze_ambush if enabled and SI is out of immediate sight
	if (g_bFreezeAmbush && dist > 380.0 && !IsClientVisibleToAnySurvivor(bot))
	{
		g_bIsFrozenAmbush[bot]  = true;
		g_bWaveWaitingForAmbush = true;
		g_fFreezeExpireTime[bot] = GetGameTime() + 8.0; // Max 8s freeze hold
		SetEntityFlags(bot, GetEntityFlags(bot) | FL_FROZEN);
	}
	else if (isFocusSquad && IsValidAliveSurvivor(g_iTargetSurvivor))
	{
		// Command Focus Squad directly onto the designated target (Spec Section 5.3)
		L4D2_CommandABot(bot, g_iTargetSurvivor, BOT_CMD_ATTACK);
	}

	DirLog("SPAWN_SI_OK [W#%d]: bot=%d (%N) class=%s(%d) Tier=%d FocusSquad=%d FrozenAmbush=%d dist=%.0f pos=(%.0f,%.0f,%.0f) anchor=%N",
		g_iWaveNumber,
		bot,
		bot,
		g_sSINames[zc],
		zc,
		tierUsed,
		isFocusSquad ? 1 : 0,
		g_bIsFrozenAmbush[bot] ? 1 : 0,
		dist,
		spawnPos[0], spawnPos[1], spawnPos[2],
		anchor);
}

// ============================================================================
// Freeze Ambush & Focus Strike Combat Updates (Spec Section 5.3)
// ============================================================================

void UpdateFrozenAmbushSI()
{
	float now = GetGameTime();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bIsFrozenAmbush[i])
		{
			continue;
		}

		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
		{
			g_bIsFrozenAmbush[i] = false;
			continue;
		}

		// Unfreeze if timeout expired, survivor is within 550 units, or survivor has LOS
		float nearestDist = GetNearestSurvivorDistance(i);
		if (now >= g_fFreezeExpireTime[i])
		{
			UnfreezeSI(i, "AmbushTimerExpired");
		}
		else if (nearestDist <= 550.0)
		{
			UnfreezeSI(i, "SurvivorProximity<=550");
		}
		else if (IsClientVisibleToAnySurvivor(i))
		{
			UnfreezeSI(i, "SurvivorGainedLOS");
		}
	}
}

void UnfreezeSI(int bot, const char[] reason)
{
	g_bIsFrozenAmbush[bot] = false;
	if (g_bWaveWaitingForAmbush)
	{
		// Start the wave combat clear timer when the ambush actually unfreezes to engage survivors
		g_bWaveWaitingForAmbush = false;
		if (g_fWaveCombatStartTime > 0.0)
		{
			g_fWaveCombatStartTime = GetGameTime();
		}
	}
	if (IsClientInGame(bot))
	{
		SetEntityFlags(bot, GetEntityFlags(bot) & ~FL_FROZEN);
		if (IsPlayerAlive(bot))
		{
			if (GetFeatureStatus(FeatureType_Native, "L4D2_StartAssault") == FeatureStatus_Available)
			{
				L4D2_StartAssault();
			}
			if (g_bIsFocusSquad[bot] && IsValidAliveSurvivor(g_iTargetSurvivor))
			{
				L4D2_CommandABot(bot, g_iTargetSurvivor, BOT_CMD_ATTACK);
			}
		}
		DirLog("AMBUSH_RELEASE: SI=%N released (%s)", bot, reason);
	}
}

/**
 * Enforces Focus Strike during STATE_SPAWNING & STATE_COMBAT (Spec Section 5.3):
 * 1. Dynamically enforces `activeFocusSquad <= floor(activeSI / 2)` (at least 1 if activeSI >= 2)
 *    so if non-focus SI die early, excess Focus Squad SI are demoted to non-focus so the MVP/target
 *    is never dogpiled by 100% of remaining SI.
 * 2. Re-issues `L4D2_CommandABot(bot, g_iTargetSurvivor, BOT_CMD_ATTACK)` to Focus Squad.
 * 3. Executes Close-Range Guaranteed Pin (`L4D_ForceHunterVictim`, `L4D_ForceSmokerVictim`,
 *    `L4D2_ForceJockeyVictim`) ONLY when:
 *    - Focus Squad SI is alive, not frozen, and has clear LOS to `g_iTargetSurvivor`.
 *    - `g_iTargetSurvivor` is alive, not already pinned, and within strict range
 *      (Hunter <= 135, Jockey <= 125, Smoker <= 220 units).
 */
void UpdateFocusStrikeEnforcement()
{
	if (!g_bFocusStrike || !IsValidAliveSurvivor(g_iTargetSurvivor))
	{
		return;
	}

	// Step 1: Dynamically enforce Focus Squad cap <= floor(activeSI / 2)
	int activeSI = CountActiveNonTankSI();
	int maxDynamicFocus = activeSI / 2;
	if (maxDynamicFocus < 1 && activeSI >= 1)
	{
		maxDynamicFocus = 1;
	}

	int curFocusCount = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bIsFocusSquad[i])
		{
			continue;
		}
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
		{
			g_bIsFocusSquad[i] = false;
			continue;
		}
		curFocusCount++;
		if (curFocusCount > maxDynamicFocus)
		{
			g_bIsFocusSquad[i] = false;
			int altTarget = FindNearestOtherSurvivor(i, g_iTargetSurvivor);
			if (altTarget > 0)
			{
				L4D2_CommandABot(i, altTarget, BOT_CMD_ATTACK);
			}
			DirLog("FOCUS_SQUAD_DEMOTE: Demoted SI=%N from Focus Squad to maintain <=50%% cap (activeSI=%d, maxFocus=%d)",
				i, activeSI, maxDynamicFocus);
		}
	}

	if (IsSurvivorPinned(g_iTargetSurvivor) || IsSurvivorIncapOrHanging(g_iTargetSurvivor))
	{
		return;
	}

	float targetPos[3];
	GetClientAbsOrigin(g_iTargetSurvivor, targetPos);
	float now = GetGameTime();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bIsFocusSquad[i] || g_bIsFrozenAmbush[i])
		{
			continue;
		}
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
		{
			g_bIsFocusSquad[i] = false;
			continue;
		}

		// Keep AI bot focused on target
		L4D2_CommandABot(i, g_iTargetSurvivor, BOT_CMD_ATTACK);

		// Throttle pin-force checks per SI to once every 4.0s
		if (now - g_fLastPinForceTime[i] < 4.0)
		{
			continue;
		}

		float siPos[3];
		GetClientAbsOrigin(i, siPos);
		float dist = GetVectorDistance(siPos, targetPos);
		int zc = GetEntProp(i, Prop_Send, "m_zombieClass");

		if (zc == ZC_HUNTER && dist <= 135.0 && HasClearLOSBetweenClients(i, g_iTargetSurvivor))
		{
			g_fLastPinForceTime[i] = now;
			L4D_ForceHunterVictim(g_iTargetSurvivor, i);
			DirLog("FOCUS_FORCE_PIN: L4D_ForceHunterVictim(victim=%N, hunter=%N) at dist=%.0f",
				g_iTargetSurvivor, i, dist);
			break;
		}
		else if (zc == ZC_JOCKEY && dist <= 125.0 && HasClearLOSBetweenClients(i, g_iTargetSurvivor))
		{
			g_fLastPinForceTime[i] = now;
			L4D2_ForceJockeyVictim(g_iTargetSurvivor, i);
			DirLog("FOCUS_FORCE_PIN: L4D2_ForceJockeyVictim(victim=%N, jockey=%N) at dist=%.0f",
				g_iTargetSurvivor, i, dist);
			break;
		}
		else if (zc == ZC_SMOKER && dist <= 220.0 && HasClearLOSBetweenClients(i, g_iTargetSurvivor))
		{
			g_fLastPinForceTime[i] = now;
			L4D_ForceSmokerVictim(g_iTargetSurvivor, i);
			DirLog("FOCUS_FORCE_PIN: L4D_ForceSmokerVictim(victim=%N, smoker=%N) at dist=%.0f",
				g_iTargetSurvivor, i, dist);
			break;
		}
	}
}

/**
 * Recycles stuck or far-behind (>1800 units & out of LOS) SI bots at wave timeout.
 */
int RecycleStuckOrFarSI()
{
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsFakeClient(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
		{
			continue;
		}

		int zc = GetEntProp(i, Prop_Send, "m_zombieClass");
		if (zc == ZC_TANK)
		{
			continue;
		}

		// Never recycle an SI that is actively pinning a survivor
		if (IsSIPinningAnySurvivor(i))
		{
			continue;
		}

		float nearestDist = GetNearestSurvivorDistance(i);
		if (nearestDist > 1800.0 && !IsClientVisibleToAnySurvivor(i))
		{
			ForcePlayerSuicide(i);
			count++;
		}
	}
	return count;
}

bool IsSIPinningAnySurvivor(int siClient)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidAliveSurvivor(i))
		{
			continue;
		}
		if (GetEntPropEnt(i, Prop_Send, "m_pounceAttacker") == siClient) return true;
		if (GetEntPropEnt(i, Prop_Send, "m_tongueOwner") == siClient) return true;
		if (GetEntPropEnt(i, Prop_Send, "m_jockeyAttacker") == siClient) return true;
		if (GetEntPropEnt(i, Prop_Send, "m_pummelAttacker") == siClient) return true;
		if (GetEntPropEnt(i, Prop_Send, "m_carryAttacker") == siClient) return true;
	}
	return false;
}

// ============================================================================
// Visibility, Geometry, and Utility Helpers
// ============================================================================

bool IsValidAliveSurvivor(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client));
}

int CountAliveSurvivors()
{
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidAliveSurvivor(i))
		{
			count++;
		}
	}
	return count;
}

int GetAnyAliveSurvivor()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidAliveSurvivor(i))
		{
			return i;
		}
	}
	return 0;
}

int FindNearestOtherSurvivor(int fromClient, int excludeSurvivor)
{
	float fromPos[3];
	GetClientAbsOrigin(fromClient, fromPos);

	int bestClient = 0;
	float bestDist = 999999.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidAliveSurvivor(i) || i == excludeSurvivor)
		{
			continue;
		}
		float pos[3];
		GetClientAbsOrigin(i, pos);
		float d = GetVectorDistance(fromPos, pos);
		if (d < bestDist)
		{
			bestDist = d;
			bestClient = i;
		}
	}
	return bestClient;
}

float GetNearestSurvivorDistance(int fromClient)
{
	float fromPos[3];
	GetClientAbsOrigin(fromClient, fromPos);

	float minDist = 999999.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidAliveSurvivor(i))
		{
			continue;
		}
		float pos[3];
		GetClientAbsOrigin(i, pos);
		float d = GetVectorDistance(fromPos, pos);
		if (d < minDist)
		{
			minDist = d;
		}
	}
	return minDist;
}

int CountActiveNonTankSI()
{
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i))
		{
			int zc = GetEntProp(i, Prop_Send, "m_zombieClass");
			if (zc >= ZC_SMOKER && zc <= ZC_CHARGER)
			{
				count++;
			}
		}
	}
	return count;
}

bool IsTankAliveInPlay()
{
	if (L4D2_IsTankInPlay() || L4D2_GetTankCount() > 0)
	{
		return true;
	}
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i))
		{
			if (GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK)
			{
				return true;
			}
		}
	}
	return false;
}

bool IsAnySurvivorOutsideSafeRoom()
{
	if (!L4D_HasMapStarted())
	{
		return false;
	}

	// First check Left4DHooks native if round has started
	if (L4D_HasAnySurvivorLeftSafeArea())
	{
		return true;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidAliveSurvivor(i))
		{
			continue;
		}
		Address nav = L4D_GetLastKnownArea(i);
		if (nav != Address_Null)
		{
			int attrs = L4D_GetNavArea_SpawnAttributes(nav);
			if (!(attrs & NAV_SPAWN_CHECKPOINT) && !(attrs & NAV_SPAWN_PLAYER_START))
			{
				return true;
			}
		}
	}
	return false;
}

bool IsPointVisibleToAnySurvivor(const float pt[3])
{
	float targetChest[3];
	targetChest[0] = pt[0];
	targetChest[1] = pt[1];
	targetChest[2] = pt[2] + 45.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidAliveSurvivor(i))
		{
			continue;
		}

		float eyePos[3];
		GetClientEyePosition(i, eyePos);

		if (GetVectorDistance(eyePos, targetChest) > 2000.0)
		{
			continue;
		}

		Handle trace = TR_TraceRayFilterEx(eyePos, targetChest, MASK_VISIBLE, RayType_EndPoint, TraceFilter_NoPlayers);
		bool hit = TR_DidHit(trace);
		delete trace;

		if (!hit)
		{
			return true; // Clear line of sight!
		}
	}
	return false;
}

bool IsClientVisibleToAnySurvivor(int client)
{
	float pos[3];
	GetClientAbsOrigin(client, pos);
	return IsPointVisibleToAnySurvivor(pos);
}

bool IsTooCloseOrVisibleToSurvivors(const float pt[3], float minAllowedDist)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidAliveSurvivor(i))
		{
			continue;
		}

		float survPos[3];
		GetClientAbsOrigin(i, survPos);
		if (GetVectorDistance(pt, survPos) < minAllowedDist)
		{
			return true;
		}
	}

	return IsPointVisibleToAnySurvivor(pt);
}

bool HasClearLOSBetweenClients(int clientA, int clientB)
{
	float eyeA[3], eyeB[3];
	GetClientEyePosition(clientA, eyeA);
	GetClientEyePosition(clientB, eyeB);

	Handle trace = TR_TraceRayFilterEx(eyeA, eyeB, MASK_SHOT, RayType_EndPoint, TraceFilter_NoPlayers);
	bool hit = TR_DidHit(trace);
	delete trace;

	return !hit;
}

bool IsHullClearForSI(const float pos[3])
{
	float mins[3] = { -16.0, -16.0, 0.0 };
	float maxs[3] = {  16.0,  16.0, 72.0 };

	Handle trace = TR_TraceHullFilterEx(pos, pos, mins, maxs, MASK_PLAYERSOLID, TraceFilter_NoPlayers);
	bool hit = TR_DidHit(trace);
	delete trace;

	return !hit;
}

public bool TraceFilter_WorldOnly(int entity, int contentsMask)
{
	return (entity == 0);
}

public bool TraceFilter_NoPlayers(int entity, int contentsMask)
{
	return (entity <= 0 || entity > MaxClients);
}

// ============================================================================
// Admin / Debug Commands
// ============================================================================

public Action Cmd_DirStatus(int client, int args)
{
	int aliveCount, downOrDeadCount;
	float avgEffHP, maxSpreadDist, frontGapDist, rearGapDist, mvpScoreRatio;
	int p1Front, p4Rear, pMVP, pVulnerable;

	EvaluateTeamTelemetry(
		aliveCount,
		downOrDeadCount,
		avgEffHP,
		maxSpreadDist,
		frontGapDist,
		rearGapDist,
		p1Front,
		p4Rear,
		pMVP,
		pVulnerable,
		mvpScoreRatio);

	int blackAndWhiteCount, medkitsTotal, throwablesTotal;
	float teamAmmoAvgPct;
	CollectTeamResourceTelemetry(blackAndWhiteCount, teamAmmoAvgPct, medkitsTotal, throwablesTotal);

	ReplyToCommand(client, "=== [L4D2 AI Director v%s Status] ===", PLUGIN_VERSION);
	ReplyToCommand(client, "State: %s | Wave: #%d | ActiveSI: %d | Clients: %d/%d | SDKCalls: %d",
		g_sStateNames[g_eState], g_iWaveNumber, CountActiveNonTankSI(), GetClientCount(false), SAFE_CLIENT_SLOT_LIMIT, g_bSDKCallsReady ? 1 : 0);
	ReplyToCommand(client, "Diag: %s | Intent: %s | Dir: %s | Horde: %s | Boss: %s",
		g_sDiagnosisNames[g_eDiagnosis], g_sIntentNames[g_eIntent], g_sDirNames[g_eSpawnDir],
		g_sHordeNames[g_eHordeDir], g_sBossNames[g_eBossDir]);
	ReplyToCommand(client, "Telemetry: Alive=%d Down=%d BW=%d Wipes=%d AvgEffHP=%.1f Ammo=%.0f%% Medkits=%d Throws=%d Flow=%.1f%% Vel=%.1f%%/m Spread=%.0f Stag=%.0fs Stage=%d",
		aliveCount, downOrDeadCount, blackAndWhiteCount, g_iWipeCount, avgEffHP, teamAmmoAvgPct, medkitsTotal, throwablesTotal,
		g_fPeakFlowRatio, g_fFlowVelocity, maxSpreadDist, g_fStagnationSeconds, g_iNativeFinaleStage);
	return Plugin_Handled;
}

public Action Cmd_DirWave(int client, int args)
{
	if (!g_bLeftSafeArea)
	{
		ActivateDirector(1.0, "Cmd_DirWave");
	}
	ChangeState(STATE_EVALUATE, "Manual sm_dir_wave command");
	ExecuteEvaluationAndPlanWave();
	ReplyToCommand(client, "[AI Director] Forced immediate wave evaluation (#%d).", g_iWaveNumber);
	return Plugin_Handled;
}

public Action Cmd_DirSpawnSI(int client, int args)
{
	int zc = ZC_HUNTER;
	if (args >= 1)
	{
		char arg[16];
		GetCmdArg(1, arg, sizeof(arg));
		zc = StringToInt(arg);
		if (zc < ZC_SMOKER || zc > ZC_CHARGER)
		{
			zc = ZC_HUNTER;
		}
	}

	int anchor = (client > 0 && IsValidAliveSurvivor(client)) ? client : GetAnyAliveSurvivor();
	int bot = SpawnSpecialInfectedMultiTier(zc, anchor, DIR_FRONT, false);
	ReplyToCommand(client, "[AI Director] Test spawn %s(%d) -> bot=%d", g_sSINames[zc], zc, bot);
	return Plugin_Handled;
}
