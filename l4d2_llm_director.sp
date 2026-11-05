/**
 * L4D2 AI Director (Phase 1, single file)
 * Spec: l4d2_ai_director_system_spec.md v1.2.0
 *
 * 本階段範圍：
 *   - 同步波次 + 換氣期（波次清空後才開始倒數）
 *   - 特感數量 = 存活生還者 + 2，28 槽位安全紅線
 *   - 控場特感每種 <= ceil(生還者/3)，超出轉為 Spitter/Boomer
 *   - MVP 影響力評分 + 特攻小隊（<= floor(特感/2)），其餘特感分流
 *   - 原生 Tank 出現時順應加碼（同批只加一次），Tank 血量 5000 + 800*N
 *   - 本地規則版 DDA 決策（對應規格 2.2 矩陣），尚未串接外部 AI 服務
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "0.1.3_dev5"


#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

#define ZC_SMOKER  1
#define ZC_BOOMER  2
#define ZC_HUNTER  3
#define ZC_SPITTER 4
#define ZC_JOCKEY  5
#define ZC_CHARGER 6
#define ZC_TANK    8

#define SLOT_SAFE_LIMIT   28     // 5.1：保留至少 4 個安全槽位
#define WAVE_TIMEOUT      45.0   // 縮減波次最大等待時間為 45 秒（避免特感在遠處卡住導致下一波等太久）
#define SPAWN_STAGGER     0.2    // 同一波內逐隻生成間隔設為 0.2s，給予引擎建立 FakeClient 充分餘裕避免搶槽位
#define TANK_HP_BASE      5000
#define TANK_HP_PER_SURV  800
#define TANK_BATCH_WINDOW 10.0   // 同一批原生 Tank 只加碼一次（尾關 2 → 3）
#define TANK_OFFSET       120.0
#define CLIMAX_WIPE_SEC   4.0
#define MVP_DAMAGE_SHARE  0.40
#define MVP_MIN_DAMAGE    500    // 視窗總傷害太低時不判定 MVP 統治
#define RUSH_RANGE        2000.0
#define DIVERT_INTERVAL   1.0    // OnChooseVictim 分流目標快取秒數

enum
{
	INTENT_MAINTAIN_FLOW,
	INTENT_ASSASSINATE_MVP,
	INTENT_ESCALATE_CLIMAX,
	INTENT_MERCY
};
char g_sIntent[][] = { "MAINTAIN_GAUNTLET_FLOW", "ASSASSINATE_MVP", "ESCALATE_CLIMAX", "MERCY_RELAX_ALLOW_HEAL" };

enum
{
	TARGET_NONE,
	TARGET_MVP,
	TARGET_FRONT
};
char g_sTarget[][] = { "NONE", "P_MVP", "P1_FRONT" };

enum
{
	BOSS_RESPECT_NATIVE,
	BOSS_ADD_1_TANK,
	BOSS_ADD_2_TANKS,
	BOSS_BLOCK_EXTRA
};
char g_sBoss[][] = { "RESPECT_NATIVE", "ADD_1_TANK", "ADD_2_TANKS", "BLOCK_EXTRA_RESPAWN" };

char g_sClass[][] = { "NONE", "SMOKER", "BOOMER", "HUNTER", "SPITTER", "JOCKEY", "CHARGER" };

enum
{
	STATE_IDLE,
	STATE_COOLDOWN,
	STATE_WAVE
};

enum struct Decision
{
	int intent;
	float delay;
	int target;
	bool focusStrike;
	int primary;
	int secondary; // 0 = NONE
	int boss;
}

enum struct Telemetry
{
	int aliveSurvivors;
	float avgHp;
	float ammoPct;
	int incapped;
	int blackWhite;
}

Decision g_Decision;

int   g_iState;
int   g_iWaveNum;
int   g_iWipeCount;
float g_fNextWaveTime;
float g_fWaveStart;
float g_fWaveSpawnDone;
float g_fWaveEngage;
float g_fLastWipeSec = 999.0;
float g_fLastTankBatch;

int  g_iMvpUserId;      // 決策當下的 MVP
int  g_iFocusUserId;    // 本波特攻目標（0 = 本波無特攻）
int  g_iFocusLeft;      // 本波剩餘可指派的特攻名額
int  g_iAnchorUserId;   // 本波生成位置參考的生還者
bool g_bFocus[MAXPLAYERS + 1];
int   g_iDivertTarget[MAXPLAYERS + 1]; // userid
float g_fDivertExpire[MAXPLAYERS + 1];
ConVar g_cvMaxPlayerZombies;
ConVar g_cvSmokerLimit;
ConVar g_cvBoomerLimit;
ConVar g_cvHunterLimit;
ConVar g_cvSpitterLimit;
ConVar g_cvJockeyLimit;
ConVar g_cvChargerLimit;

int   g_iWaveSpawned;
int   g_iBlockedSpawns;
bool g_bOurSpawn;
bool g_bOurTank;
bool g_bLateLoad;

// MVP 影響力統計
int g_iKills[MAXPLAYERS + 1];
int g_iRevives[MAXPLAYERS + 1];
int g_iPins[MAXPLAYERS + 1];
int g_iDamage[MAXPLAYERS + 1];
int g_iWindowDamage[MAXPLAYERS + 1]; // 自上次決策以來的傷害，用於輸出佔比

public Plugin myinfo =
{
	name = "[L4D2] LLM Director",
	author = "",
	description = "Wave-based dynamic director with MVP focus strike (phase 1, local rules)",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("mission_lost", Event_MissionLost, EventHookMode_PostNoCopy);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_hurt", Event_PlayerHurt);
	HookEvent("revive_success", Event_ReviveSuccess);
	HookEvent("pounce_stopped", Event_PinClearedByUserid);
	HookEvent("tongue_pull_stopped", Event_PinClearedByUserid);
	HookEvent("choke_stopped", Event_PinClearedByUserid);
	HookEvent("jockey_ride_end", Event_PinClearedByRescuer);
	HookEvent("charger_pummel_end", Event_PinClearedByRescuer);

	RegAdminCmd("sm_aidirector", Cmd_Status, ADMFLAG_GENERIC, "Show AI director telemetry and decision");

	InitConVars();

	CreateTimer(1.0, Timer_Think, _, TIMER_REPEAT);

	ResetDecision();
	if (g_bLateLoad && L4D_HasAnySurvivorLeftSafeArea())
		Activate();
}

public void OnMapStart()
{
	g_iWipeCount = 0;
	g_iWaveNum = 0;
	g_fLastTankBatch = 0.0;
	g_iBlockedSpawns = 0;
	ResetRound();
}

public void OnClientPutInServer(int client)
{
	g_bFocus[client] = false;
	g_iDivertTarget[client] = 0;
	ResetStats(client);
}

// ====================================================================================================
// Round lifecycle
// ====================================================================================================
void ResetRound()
{
	g_iState = STATE_IDLE;
	g_iFocusUserId = 0;
	g_iFocusLeft = 0;
	g_fLastWipeSec = 999.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bFocus[i] = false;
		ResetStats(i);
	}
	ResetDecision();
}

void ResetStats(int client)
{
	g_iKills[client] = 0;
	g_iRevives[client] = 0;
	g_iPins[client] = 0;
	g_iDamage[client] = 0;
	g_iWindowDamage[client] = 0;
}

void InitConVars()
{
	g_cvMaxPlayerZombies = FindConVar("z_max_player_zombies");
	if (g_cvMaxPlayerZombies)
	{
		int flags = g_cvMaxPlayerZombies.Flags;
		g_cvMaxPlayerZombies.SetBounds(ConVarBound_Upper, false);
		g_cvMaxPlayerZombies.Flags = flags & ~FCVAR_NOTIFY;
		g_cvMaxPlayerZombies.SetInt(16); // 預先常駐分配 16 個特感槽位，防止分幀生成時槽位來不及註冊導致搶 slot
	}

	g_cvSmokerLimit = FindConVar("z_smoker_limit");
	g_cvBoomerLimit = FindConVar("z_boomer_limit");
	g_cvHunterLimit = FindConVar("z_hunter_limit");
	g_cvSpitterLimit = FindConVar("z_spitter_limit");
	g_cvJockeyLimit = FindConVar("z_jockey_limit");
	g_cvChargerLimit = FindConVar("z_charger_limit");

	// 解除個別兵種邊界並常駐設為 8
	UnlockClassBound(g_cvSmokerLimit);
	UnlockClassBound(g_cvBoomerLimit);
	UnlockClassBound(g_cvHunterLimit);
	UnlockClassBound(g_cvSpitterLimit);
	UnlockClassBound(g_cvJockeyLimit);
	UnlockClassBound(g_cvChargerLimit);
}

void UnlockClassBound(ConVar cv)
{
	if (!cv) return;
	int flags = cv.Flags;
	cv.SetBounds(ConVarBound_Upper, false);
	cv.Flags = flags & ~FCVAR_NOTIFY;
	cv.SetInt(8);
}

void ApplyWaveLimits(int targetSi)
{
	if (g_cvMaxPlayerZombies)
	{
		int safeLimit = targetSi > 16 ? targetSi : 16;
		if (safeLimit > 24) safeLimit = 24;
		g_cvMaxPlayerZombies.SetInt(safeLimit);
	}
}

void ResetDecision()
{
	g_Decision.intent = INTENT_MAINTAIN_FLOW;
	g_Decision.delay = 35.0;
	g_Decision.target = TARGET_NONE;
	g_Decision.focusStrike = false;
	g_Decision.primary = ZC_HUNTER;
	g_Decision.secondary = ZC_BOOMER;
	g_Decision.boss = BOSS_RESPECT_NATIVE;
}

void Activate()
{
	MakeDecision();
	g_iState = STATE_COOLDOWN;
	g_fNextWaveTime = GetGameTime() + g_Decision.delay;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_iState = STATE_IDLE;
}

public void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
	g_iWipeCount++;
}

public Action L4D_OnFirstSurvivorLeftSafeArea(int client)
{
	if (g_iState == STATE_IDLE)
		Activate();
	return Plugin_Continue;
}

// ====================================================================================================
// Wave state machine
// ====================================================================================================
public Action Timer_Think(Handle timer)
{
	if (g_iState == STATE_IDLE)
		return Plugin_Continue;

	float now = GetGameTime();

	if (g_iState == STATE_COOLDOWN)
	{
		if (now >= g_fNextWaveTime)
			StartWave();
		return Plugin_Continue;
	}

	// STATE_WAVE
	if (now < g_fWaveSpawnDone)
		return Plugin_Continue;

	int activeSi = CountAliveSI();
	bool cleared = (activeSi == 0);
	if (!cleared && now - g_fWaveStart < WAVE_TIMEOUT)
	{
		// 每 5 秒輸出一次存活特感數量與波次進行狀態
		static float lastLogTime;
		if (now - lastLogTime >= 5.0)
		{
			lastLogTime = now;
			PrintToServer("[AIDirector][DEBUG] Wave #%d active: alive_si=%d elapsed=%.1fs (timeout in %.1fs)",
				g_iWaveNum, activeSi, now - g_fWaveStart, WAVE_TIMEOUT - (now - g_fWaveStart));
		}
		return Plugin_Continue;
	}

	// 本波沒真正生出特感（找不到位置/槽位滿）時不算「光速清空」，避免誤判 ESCALATE_CLIMAX
	g_fLastWipeSec = (cleared && g_iWaveSpawned > 0) ? now - (g_fWaveEngage > 0.0 ? g_fWaveEngage : g_fWaveStart) : 999.0;
	if (!cleared)
	{
		PrintToServer("[AIDirector][DEBUG] Wave #%d TIMED OUT (%.1fs elapsed, %d SI still alive). Slaying distant SI to clear wave.",
			g_iWaveNum, now - g_fWaveStart, activeSi);
		CleanStuckSI();
	}
	EndWave();
	return Plugin_Continue;
}

void StartWave()
{
	g_iWaveNum++;

	int counts[7];
	int alive = CountAliveSurvivors();
	int active = CountAliveSI(counts);
	int target = alive + 2;
	int need = target - active;
	if (need < 0)
		need = 0;

	int mvp = GetClientOfUserId(g_iMvpUserId);

	// 生成位置參考點：預設以最前鋒（Highest Flow）為主，確保怪生在推進路徑前方而非遠處身後
	int anchor = 0;
	if (g_Decision.target == TARGET_FRONT || g_Decision.target == TARGET_NONE)
		anchor = L4D_GetHighestFlowSurvivor();
	else if (g_Decision.target == TARGET_MVP)
		anchor = mvp;

	if (!IsAliveSurvivor(anchor))
		anchor = L4D_GetHighestFlowSurvivor();
	if (!IsAliveSurvivor(anchor))
		anchor = GetRandomAliveSurvivor();

	g_iAnchorUserId = IsAliveSurvivor(anchor) ? GetClientUserId(anchor) : 0;

	// 特攻小隊：最多 floor(活體特感 / 2)
	g_iFocusUserId = 0;
	g_iFocusLeft = 0;
	if (g_Decision.focusStrike && IsAliveSurvivor(mvp))
	{
		g_iFocusUserId = GetClientUserId(mvp);
		g_iFocusLeft = target / 2;
	}

	// 規劃本波兵種（1/3 控場上限）
	int maxPerClass = RoundToCeil(float(alive) / 3.0);
	ApplyWaveLimits(target);
	char plan[256];
	for (int i = 0; i < need; i++)
	{
		int zc;
		if (g_Decision.intent == INTENT_MERCY)
			zc = ZC_BOOMER;
		else if (i % 3 == 0)
			zc = g_Decision.primary;
		else if (i % 3 == 1 && g_Decision.secondary != 0)
			zc = g_Decision.secondary;
		else
			zc = GetRandomInt(ZC_SMOKER, ZC_CHARGER);

		if (IsControlClass(zc) && counts[zc] >= maxPerClass)
			zc = GetRandomInt(0, 1) == 0 ? ZC_SPITTER : ZC_BOOMER;

		counts[zc]++;
		CreateTimer(i * SPAWN_STAGGER, Timer_SpawnOne, g_iWaveNum * 16 + zc, TIMER_FLAG_NO_MAPCHANGE);
		Format(plan, sizeof(plan), "%s%s ", plan, g_sClass[zc]);
	}

	float now = GetGameTime();
	g_fWaveStart = now;
	g_fWaveEngage = 0.0;
	g_iWaveSpawned = 0;
	g_fWaveSpawnDone = now + need * SPAWN_STAGGER + 1.0;
	g_iState = STATE_WAVE;

	PrintToServer("[AIDirector] Wave #%d intent=%s alive=%d target_si=%d spawn=%d focus=%d [%s]",
		g_iWaveNum, g_sIntent[g_Decision.intent], alive, target, need, g_iFocusLeft, plan);
}

void EndWave()
{
	for (int i = 1; i <= MaxClients; i++)
		g_bFocus[i] = false;
	g_iFocusUserId = 0;
	g_iFocusLeft = 0;

	MakeDecision();
	g_iState = STATE_COOLDOWN;
	g_fNextWaveTime = GetGameTime() + g_Decision.delay;

	PrintToServer("[AIDirector] Wave #%d ended (wipe %.1fs). Next: intent=%s delay=%.0fs boss=%s",
		g_iWaveNum, g_fLastWipeSec, g_sIntent[g_Decision.intent], g_Decision.delay, g_sBoss[g_Decision.boss]);
}

public Action Timer_SpawnOne(Handle timer, int data)
{
	if (g_iState != STATE_WAVE || data / 16 != g_iWaveNum)
		return Plugin_Stop;

	int zc = data % 16;

	if (GetClientCount(false) + 1 > SLOT_SAFE_LIMIT)
	{
		PrintToServer("[AIDirector][DEBUG] Spawn #%d %s aborted: slot limit reached (%d)", g_iWaveNum, g_sClass[zc], GetClientCount(false));
		return Plugin_Stop;
	}

	int anchor = GetClientOfUserId(g_iAnchorUserId);
	if (!IsAliveSurvivor(anchor))
		anchor = L4D_GetHighestFlowSurvivor();
	if (!IsAliveSurvivor(anchor))
		anchor = GetRandomAliveSurvivor();
	if (anchor == 0)
	{
		PrintToServer("[AIDirector][DEBUG] Spawn #%d %s aborted: no living survivor anchor found", g_iWaveNum, g_sClass[zc]);
		return Plugin_Stop;
	}

	float pos[3], ang[3];
	// 優先嘗試在 anchor 周遭找點，提高至 30 次嘗試；若失敗則隨機換另一位生還者再試 20 次
	bool found = L4D_GetRandomPZSpawnPosition(anchor, zc, 30, pos);
	if (!found)
	{
		int fallbackAnchor = GetRandomAliveSurvivor();
		if (fallbackAnchor && fallbackAnchor != anchor)
			found = L4D_GetRandomPZSpawnPosition(fallbackAnchor, zc, 20, pos);
	}

	if (!found)
	{
		// 再次保底：以 0 (任意生還者附近或隨機有效區域) 嘗試 20 次
		found = L4D_GetRandomPZSpawnPosition(0, zc, 20, pos);
	}

	if (!found)
	{
		PrintToServer("[AIDirector][DEBUG] Spawn #%d failed: L4D_GetRandomPZSpawnPosition returned false for %s (anchor=%N)", g_iWaveNum, g_sClass[zc], anchor);
		return Plugin_Stop;
	}

	g_bOurSpawn = true;
	int bot = L4D2_SpawnSpecial(zc, pos, ang);
	g_bOurSpawn = false;

	if (bot <= 0 || bot > MaxClients)
	{
		PrintToServer("[AIDirector][DEBUG] Spawn #%d failed: L4D2_SpawnSpecial returned %d for %s at (%.1f, %.1f, %.1f)", g_iWaveNum, bot, g_sClass[zc], pos[0], pos[1], pos[2]);
		return Plugin_Stop;
	}

	PrintToServer("[AIDirector][DEBUG] Spawn #%d SUCCESS: %s (bot client index %d, %N) at (%.1f, %.1f, %.1f)", g_iWaveNum, g_sClass[zc], bot, bot, pos[0], pos[1], pos[2]);

	g_iWaveSpawned++;
	g_bFocus[bot] = false;
	g_iDivertTarget[bot] = 0;

	// 無論是否為特攻目標，生成時都下達主動進攻指令，避免 Bot 蹲在遠處發呆
	RequestFrame(Frame_CommandAttack, GetClientUserId(bot));
	return Plugin_Stop;
}

void Frame_CommandAttack(int userid)
{
	int bot = GetClientOfUserId(userid);
	if (!bot || !IsPlayerAlive(bot))
		return;

	int target = 0;
	if (g_iFocusLeft > 0 && IsAliveSurvivor(GetClientOfUserId(g_iFocusUserId)))
	{
		g_bFocus[bot] = true;
		g_iFocusLeft--;
		target = GetClientOfUserId(g_iFocusUserId);
	}
	else
	{
		// 非特攻隊員，隨機挑選或指派給最近生還者進行強襲
		target = GetNearestSurvivorExcept(bot, GetClientOfUserId(g_iFocusUserId));
		if (!target)
			target = GetRandomAliveSurvivor();
	}

	if (IsAliveSurvivor(target))
	{
		L4D2_CommandABot(bot, target, BOT_CMD_ATTACK);
		L4D2_StartAssault();
		// 啟用視線威脅標記，喚醒 NextBot AI
		if (HasEntProp(bot, Prop_Send, "m_hasVisibleThreats"))
			SetEntProp(bot, Prop_Send, "m_hasVisibleThreats", 1);
	}
}

// 原生導演的小特感生成一律攔截，只放行本插件的波次生成
public Action L4D_OnSpawnSpecial(int &zombieClass, const float vecPos[3], const float vecAng[3])
{
	if (g_bOurSpawn)
	{
		PrintToServer("[AIDirector][DEBUG] Hook L4D_OnSpawnSpecial: ALLOWED our spawn %s at (%.1f, %.1f, %.1f)", g_sClass[zombieClass], vecPos[0], vecPos[1], vecPos[2]);
		return Plugin_Continue;
	}
	g_iBlockedSpawns++; // 供 sm_aidirector 觀察原生導演被攔截的重試頻率
	return Plugin_Handled;
}

public void L4D_OnSpawnSpecial_Post(int client, int zombieClass, const float vecPos[3], const float vecAng[3])
{
	PrintToServer("[AIDirector][DEBUG] Hook L4D_OnSpawnSpecial_Post: client=%d (%N) class=%s spawned at (%.1f, %.1f, %.1f)",
		client, client, g_sClass[zombieClass], vecPos[0], vecPos[1], vecPos[2]);
}

// ====================================================================================================
// Focus strike targeting
// ====================================================================================================
// 此 forward 是熱路徑（每隻特感每次索敵都會呼叫），只允許 O(1) 檢查；
// 需要掃描全部玩家的分流計算以 DIVERT_INTERVAL 為單位快取
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
	if (g_iFocusUserId == 0 || specialInfected < 1 || specialInfected > MaxClients)
		return Plugin_Continue;

	int mvp = GetClientOfUserId(g_iFocusUserId);
	if (!IsAliveSurvivor(mvp) || L4D_IsPlayerIncapacitated(mvp))
		return Plugin_Continue;

	if (g_bFocus[specialInfected])
	{
		if (curTarget == mvp)
			return Plugin_Continue;
		curTarget = mvp;
		return Plugin_Changed;
	}

	// 非特攻隊員的小特感強制分流，不准也去追 MVP
	if (curTarget != mvp || !IsControlOrSupportClass(GetZombieClass(specialInfected)))
		return Plugin_Continue;

	float now = GetGameTime();
	int other = GetClientOfUserId(g_iDivertTarget[specialInfected]);
	if (now >= g_fDivertExpire[specialInfected] || !IsAliveSurvivor(other) || other == mvp)
	{
		other = GetNearestSurvivorExcept(specialInfected, mvp);
		g_iDivertTarget[specialInfected] = other ? GetClientUserId(other) : 0;
		g_fDivertExpire[specialInfected] = now + DIVERT_INTERVAL;
	}
	if (!other)
		return Plugin_Continue;

	curTarget = other;
	return Plugin_Changed;
}

// ====================================================================================================
// Tank handling
// ====================================================================================================
public void L4D_OnSpawnTank_Post(int client, const float vecPos[3], const float vecAng[3])
{
	if (client > 0 && client <= MaxClients)
		RequestFrame(Frame_SetTankHp, GetClientUserId(client));

	if (g_bOurTank)
		return;

	// 原生 Tank：同一批只順應加碼一次
	float now = GetGameTime();
	bool newBatch = now - g_fLastTankBatch >= TANK_BATCH_WINDOW;
	g_fLastTankBatch = now;
	if (!newBatch)
		return;

	int extra = 0;
	if (g_Decision.boss == BOSS_ADD_1_TANK)
		extra = 1;
	else if (g_Decision.boss == BOSS_ADD_2_TANKS)
		extra = 2;

	for (int i = 1; i <= extra; i++)
	{
		DataPack dp;
		CreateDataTimer(i * SPAWN_STAGGER, Timer_SpawnExtraTank, dp, TIMER_FLAG_NO_MAPCHANGE);
		dp.WriteFloat(vecPos[0] + GetRandomFloat(-TANK_OFFSET, TANK_OFFSET));
		dp.WriteFloat(vecPos[1] + GetRandomFloat(-TANK_OFFSET, TANK_OFFSET));
		dp.WriteFloat(vecPos[2]);
		dp.WriteFloat(vecAng[1]);
	}

	if (extra > 0)
		PrintToServer("[AIDirector] Native tank spawned, adding %d (%s)", extra, g_sBoss[g_Decision.boss]);
}

public Action Timer_SpawnExtraTank(Handle timer, DataPack dp)
{
	if (GetClientCount(false) + 1 > SLOT_SAFE_LIMIT)
		return Plugin_Stop;

	float pos[3], ang[3];
	dp.Reset();
	pos[0] = dp.ReadFloat();
	pos[1] = dp.ReadFloat();
	pos[2] = dp.ReadFloat();
	ang[1] = dp.ReadFloat();

	g_bOurTank = true;
	L4D2_SpawnTank(pos, ang);
	g_bOurTank = false;
	return Plugin_Stop;
}

void Frame_SetTankHp(int userid)
{
	int tank = GetClientOfUserId(userid);
	if (!tank || !IsPlayerAlive(tank))
		return;

	// 只設定一次：L4D_OnSpawnTank_Post 在某些地圖會重複觸發，不可每次把血補滿
	int hp = TANK_HP_BASE + TANK_HP_PER_SURV * CountAliveSurvivors();
	if (GetEntProp(tank, Prop_Data, "m_iMaxHealth") == hp)
		return;
	SetEntProp(tank, Prop_Data, "m_iMaxHealth", hp);
	SetEntityHealth(tank, hp);
}

// ====================================================================================================
// DDA decision (local rules, spec 2.2)
// ====================================================================================================
void MakeDecision()
{
	Telemetry t;
	CollectTelemetry(t);

	int mvp = GetMvp();
	float share = GetWindowDamageShare(mvp);

	Decision d;
	if (t.incapped >= 2 || t.blackWhite >= 2 || t.ammoPct < 25.0 || g_iWipeCount >= 2)
	{
		d.intent = INTENT_MERCY;
		d.delay = 55.0;
		d.target = TARGET_NONE;
		d.primary = ZC_BOOMER;
		d.secondary = 0;
		d.boss = BOSS_BLOCK_EXTRA;
	}
	else if (t.avgHp > 75.0 && t.ammoPct > 80.0 && g_fLastWipeSec <= CLIMAX_WIPE_SEC)
	{
		d.intent = INTENT_ESCALATE_CLIMAX;
		d.delay = 20.0;
		d.target = TARGET_NONE;
		d.primary = ZC_SPITTER;
		d.secondary = ZC_CHARGER;
		d.boss = BOSS_ADD_2_TANKS;
	}
	else if (mvp && t.aliveSurvivors >= 2 && share > MVP_DAMAGE_SHARE)
	{
		d.intent = INTENT_ASSASSINATE_MVP;
		d.delay = 28.0;
		d.target = TARGET_MVP;
		d.focusStrike = true;
		d.primary = ZC_CHARGER;
		d.secondary = ZC_SMOKER;
		d.boss = BOSS_RESPECT_NATIVE;
	}
	else
	{
		static const int cc[] = { ZC_SMOKER, ZC_HUNTER, ZC_JOCKEY, ZC_CHARGER };
		d.intent = INTENT_MAINTAIN_FLOW;
		d.delay = 35.0;
		d.target = TARGET_FRONT;
		d.primary = cc[GetRandomInt(0, sizeof(cc) - 1)];
		d.secondary = GetRandomInt(0, 1) == 0 ? ZC_BOOMER : ZC_SPITTER;
		d.boss = BOSS_ADD_1_TANK;
	}

	g_Decision = d;
	g_iMvpUserId = mvp ? GetClientUserId(mvp) : 0;
	for (int i = 1; i <= MaxClients; i++)
		g_iWindowDamage[i] = 0;
}

void CollectTelemetry(Telemetry t)
{
	float hpSum, ammoSum;
	int ammoCount;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsAliveSurvivor(i))
			continue;

		t.aliveSurvivors++;

		if (L4D_IsPlayerIncapacitated(i))
			t.incapped++;
		else
			hpSum += fMin(100.0, float(GetClientHealth(i)) + L4D_GetTempHealth(i));

		if (L4D_IsPlayerOnThirdStrike(i))
			t.blackWhite++;

		float ammo = GetPrimaryAmmoPct(i);
		if (ammo >= 0.0)
		{
			ammoSum += ammo;
			ammoCount++;
		}
	}

	t.avgHp = t.aliveSurvivors ? hpSum / float(t.aliveSurvivors) : 0.0;
	t.ammoPct = ammoCount ? ammoSum / float(ammoCount) : 100.0; // 沒人拿主武器時不觸發彈藥判斷
}

// 回傳 -1.0 表示沒有主武器
float GetPrimaryAmmoPct(int client)
{
	int weapon = GetPlayerWeaponSlot(client, 0);
	if (weapon == -1)
		return -1.0;

	char cls[64];
	GetEntityClassname(weapon, cls, sizeof(cls));

	int maxTotal = L4D2_GetIntWeaponAttribute(cls, L4D2IWA_ClipSize) + GetReserveMax(cls);
	if (maxTotal <= 0)
		return -1.0;

	int cur = GetEntProp(weapon, Prop_Send, "m_iClip1") + L4D_GetReserveAmmo(client, weapon);
	return fMin(100.0, 100.0 * float(cur) / float(maxTotal));
}

int GetReserveMax(const char[] cls)
{
	char cvar[32];
	if (StrContains(cls, "smg") != -1)
		strcopy(cvar, sizeof(cvar), "ammo_smg_max");
	else if (StrContains(cls, "autoshotgun") != -1 || StrContains(cls, "shotgun_spas") != -1)
		strcopy(cvar, sizeof(cvar), "ammo_autoshotgun_max");
	else if (StrContains(cls, "shotgun") != -1)
		strcopy(cvar, sizeof(cvar), "ammo_shotgun_max");
	else if (StrContains(cls, "hunting_rifle") != -1)
		strcopy(cvar, sizeof(cvar), "ammo_huntingrifle_max");
	else if (StrContains(cls, "sniper") != -1)
		strcopy(cvar, sizeof(cvar), "ammo_sniperrifle_max");
	else if (StrContains(cls, "grenade_launcher") != -1)
		strcopy(cvar, sizeof(cvar), "ammo_grenadelauncher_max");
	else if (StrContains(cls, "m60") != -1)
		strcopy(cvar, sizeof(cvar), "ammo_m60_max");
	else if (StrContains(cls, "rifle") != -1)
		strcopy(cvar, sizeof(cvar), "ammo_assaultrifle_max");
	else
		return 0;

	ConVar cv = FindConVar(cvar);
	return cv ? cv.IntValue : 0;
}

// ====================================================================================================
// MVP impact score (spec 5.3)
// ====================================================================================================
float GetImpactScore(int client)
{
	return g_iKills[client] * 3.0 + g_iRevives[client] * 5.0 + g_iPins[client] * 4.0 + g_iDamage[client] / 100.0;
}

int GetMvp()
{
	int best = 0;
	float bestScore = 0.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsAliveSurvivor(i))
			continue;
		float s = GetImpactScore(i);
		if (s > bestScore)
		{
			bestScore = s;
			best = i;
		}
	}
	return best;
}

float GetWindowDamageShare(int client)
{
	if (!client)
		return 0.0;

	int total = 0;
	for (int i = 1; i <= MaxClients; i++)
		total += g_iWindowDamage[i];

	if (total < MVP_MIN_DAMAGE)
		return 0.0;
	return float(g_iWindowDamage[client]) / float(total);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (victim)
		g_bFocus[victim] = false;

	if (victim && IsClientInGame(victim) && GetClientTeam(victim) == TEAM_INFECTED)
	{
		int zc = GetZombieClass(victim);
		if (IsControlOrSupportClass(zc))
		{
			char killer[64];
			if (IsSurvivor(attacker))
				GetClientName(attacker, killer, sizeof(killer));
			else
				strcopy(killer, sizeof(killer), "Environment/Self");

			PrintToServer("[AIDirector][EVENT] SI %s (client %d) KILLED by %s (remaining SI: %d)",
				g_sClass[zc], victim, killer, CountAliveSI() - 1);
		}

		if (IsSurvivor(attacker))
			g_iKills[attacker]++;
	}
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!victim || !attacker || !IsClientInGame(victim) || !IsClientInGame(attacker))
		return;

	int vTeam = GetClientTeam(victim);
	int aTeam = GetClientTeam(attacker);

	if (vTeam == TEAM_INFECTED && aTeam == TEAM_SURVIVOR)
	{
		int dmg = event.GetInt("dmg_health");
		g_iDamage[attacker] += dmg;
		g_iWindowDamage[attacker] += dmg;
	}

	// 記錄本波首次交火時間，用於「光速清空」判定
	if (g_iState == STATE_WAVE && g_fWaveEngage == 0.0)
	{
		if ((vTeam == TEAM_INFECTED && aTeam == TEAM_SURVIVOR && IsControlOrSupportClass(GetZombieClass(victim)))
			|| (vTeam == TEAM_SURVIVOR && aTeam == TEAM_INFECTED && IsControlOrSupportClass(GetZombieClass(attacker))))
			g_fWaveEngage = GetGameTime();
	}
}

public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
	int reviver = GetClientOfUserId(event.GetInt("userid"));
	if (IsSurvivor(reviver))
		g_iRevives[reviver]++;
}

public void Event_PinClearedByUserid(Event event, const char[] name, bool dontBroadcast)
{
	int rescuer = GetClientOfUserId(event.GetInt("userid"));
	if (IsSurvivor(rescuer))
		g_iPins[rescuer]++;
}

public void Event_PinClearedByRescuer(Event event, const char[] name, bool dontBroadcast)
{
	int rescuer = GetClientOfUserId(event.GetInt("rescuer"));
	if (IsSurvivor(rescuer))
		g_iPins[rescuer]++;
}

// ====================================================================================================
// Status command
// ====================================================================================================
public Action Cmd_Status(int client, int args)
{
	Telemetry t;
	CollectTelemetry(t);
	int mvp = GetMvp();

	static const char states[][] = { "IDLE", "COOLDOWN", "WAVE" };
	ReplyToCommand(client, "[AIDirector] state=%s wave=%d wipes=%d last_wipe=%.1fs next_in=%.0fs",
		states[g_iState], g_iWaveNum, g_iWipeCount, g_fLastWipeSec,
		g_iState == STATE_COOLDOWN ? g_fNextWaveTime - GetGameTime() : 0.0);
	ReplyToCommand(client, "[AIDirector] alive=%d target_si=%d active_si=%d hp=%.0f ammo=%.0f%% incap=%d bw=%d",
		t.aliveSurvivors, t.aliveSurvivors + 2, CountAliveSI(), t.avgHp, t.ammoPct, t.incapped, t.blackWhite);
	if (mvp)
		ReplyToCommand(client, "[AIDirector] MVP=%N score=%.1f window_share=%.0f%%", mvp, GetImpactScore(mvp), GetWindowDamageShare(mvp) * 100.0);
	ReplyToCommand(client, "[AIDirector] native SI spawns blocked since map start: %d", g_iBlockedSpawns);
	ReplyToCommand(client, "[AIDirector] decision: intent=%s delay=%.0f target=%s focus=%d primary=%s secondary=%s boss=%s",
		g_sIntent[g_Decision.intent], g_Decision.delay, g_sTarget[g_Decision.target], g_Decision.focusStrike,
		g_sClass[g_Decision.primary], g_sClass[g_Decision.secondary], g_sBoss[g_Decision.boss]);
	return Plugin_Handled;
}

// ====================================================================================================
// Helpers
// ====================================================================================================
bool IsSurvivor(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR;
}

bool IsAliveSurvivor(int client)
{
	return IsSurvivor(client) && IsPlayerAlive(client);
}

int GetZombieClass(int client)
{
	return GetEntProp(client, Prop_Send, "m_zombieClass");
}

bool IsControlClass(int zc)
{
	return zc == ZC_SMOKER || zc == ZC_HUNTER || zc == ZC_JOCKEY || zc == ZC_CHARGER;
}

bool IsControlOrSupportClass(int zc)
{
	return zc >= ZC_SMOKER && zc <= ZC_CHARGER;
}

int CountAliveSurvivors()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (IsAliveSurvivor(i))
			n++;
	return n;
}

// 不含 Tank 的活體特感數；counts 依兵種累計
int CountAliveSI(int counts[7] = {0, ...})
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
			continue;
		if (GetEntProp(i, Prop_Send, "m_isGhost"))
			continue;
		int zc = GetZombieClass(i);
		if (!IsControlOrSupportClass(zc))
			continue;
		counts[zc]++;
		n++;
	}
	return n;
}

// 波次超時清理：處決無法接觸生還者或卡在遠處的特感，但放過正在控場壓制的特感
void CleanStuckSI()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
			continue;
		if (GetEntProp(i, Prop_Send, "m_isGhost"))
			continue;

		int zc = GetZombieClass(i);
		if (!IsControlOrSupportClass(zc))
			continue;

		// 若特感正控制著生還者（舌抓、騎乘、突擊、壓制），不強行處決
		if (L4D2_GetSurvivorVictim(i) > 0)
			continue;

		PrintToServer("[AIDirector][DEBUG] Slaying stuck SI %s (client %d) on wave timeout", g_sClass[zc], i);
		ForcePlayerSuicide(i);
	}
}

int GetRandomAliveSurvivor()
{
	int list[MAXPLAYERS + 1], n = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (IsAliveSurvivor(i))
			list[n++] = i;
	return n ? list[GetRandomInt(0, n - 1)] : 0;
}

int GetNearestSurvivorExcept(int from, int except)
{
	float origin[3], pos[3];
	GetClientAbsOrigin(from, origin);

	int best = 0;
	float bestDist = -1.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == except || !IsAliveSurvivor(i) || L4D_IsPlayerIncapacitated(i))
			continue;
		GetClientAbsOrigin(i, pos);
		float d = GetVectorDistance(origin, pos, true);
		if (bestDist < 0.0 || d < bestDist)
		{
			bestDist = d;
			best = i;
		}
	}
	return best;
}

float fMin(float a, float b)
{
	return a < b ? a : b;
}
