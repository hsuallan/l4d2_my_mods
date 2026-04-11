#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0"

// --- Sound Files ---
char   g_sSoundActivate[] = "level/bell_impact.wav";
char   g_sSoundBreak[]    = "physics/glass/glass_impact_bullet4.wav";

// --- ConVars ---
Handle g_cvMaxShieldHP    = null;
Handle g_cvDuration       = null;
Handle g_cvCooldown       = null;
Handle g_cvDecayRate      = null;
Handle g_cvLifesteal      = null;

// --- Player Variables ---
int    g_iShieldHP[MAXPLAYERS + 1];
bool   g_bHasShield[MAXPLAYERS + 1];
float  g_fCooldownTime[MAXPLAYERS + 1];
float  g_fShieldEndTime[MAXPLAYERS + 1];
float  g_fLastMsgTime[MAXPLAYERS + 1];
int    g_iLastButtons[MAXPLAYERS + 1];
Handle g_hShieldTimer[MAXPLAYERS + 1];
bool   g_bDisableBoD[MAXPLAYERS + 1];

// --- Forward Declarations / Commands ---
public Action Cmd_StopBoD(int client, int args)
{
    if (client == 0) return Plugin_Handled;

    if (g_bDisableBoD[client])
    {
        PrintToChat(client, "\x04[BoD]\x01 BoD is already disabled.");
        return Plugin_Handled;
    }

    g_bDisableBoD[client] = true;
    BreakShield(client, false);
    PrintToChat(client, "\x04[BoD]\x01 \x02 BoD disabled.\x01 Type \x03/bod_start\x01 to re-enable.");
    return Plugin_Handled;
}

public Action Cmd_StartBoD(int client, int args)
{
    if (client == 0) return Plugin_Handled;

    if (!g_bDisableBoD[client])
    {
        PrintToChat(client, "\x04[BoD]\x01 BoD is already enabled.");
        return Plugin_Handled;
    }

    g_bDisableBoD[client] = false;
    PrintToChat(client, "\x04[BoD]\x01 \x05 BoD re-enabled.\x01 Press \x03Reload (R)\x01 to activate.");
    return Plugin_Handled;
}

public Plugin myinfo =
{
    name        = "L4D2 Breath of Divinity (Dawn Shield)",
    author      = "hsuallan & AI Assistant",
    description = "Activates Dawn Shield using the Reload key",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    // Create ConVars
    g_cvMaxShieldHP = CreateConVar("l4d2_bod_max_hp", "100", "Maximum HP of the Dawn Shield");
    g_cvDuration    = CreateConVar("l4d2_bod_duration", "60.0", "Duration of the shield in seconds");
    g_cvCooldown    = CreateConVar("l4d2_bod_cooldown", "60.0", "Cooldown in seconds after usage");
    g_cvDecayRate   = CreateConVar("l4d2_bod_decay_rate", "2", "HP lost per second (Decay)");
    g_cvLifesteal   = CreateConVar("l4d2_bod_lifesteal", "5", "Shield HP regenerated per hit on enemy");

    AutoExecConfig(true, "l4d2_bod");

    RegConsoleCmd("sm_bod_stop", Cmd_StopBoD, "Disable BoD for yourself");
    RegConsoleCmd("sm_bod_start", Cmd_StartBoD, "Enable BoD for yourself");

    // Hooks
    HookEvent("player_spawn", Event_PlayerSpawn);

    // Late load support
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
}

public void OnMapStart()
{
    PrecacheSound(g_sSoundActivate, true);
    PrecacheSound(g_sSoundBreak, true);
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    ResetShield(client);
    g_iLastButtons[client] = 0;
    g_bDisableBoD[client]  = false;

    CreateTimer(10.0, Timer_WelcomeMsg, client);
}

public Action Timer_WelcomeMsg(Handle timer, int client)
{
    if (IsClientInGame(client))
    {
        PrintToChat(client, "\x04[BoD]\x01 This server has \x05 Dawn Shield \x01 enabled. Press \x03Reload (R)\x01 to activate.");
        PrintToChat(client, "\x04[BoD]\x01 To disable, type \x03 /bod_stop \x01. To re-enable, type \x03/bod_start\x01.");
    }
    return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
    ResetShield(client);
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0) ResetShield(client);
    return Plugin_Continue;
}

// --- Activation Logic via Reload Key ---
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    // Check if client is valid, alive, on Survivor team (2), and hasn't disabled BoD
    if (!IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != 2 || g_bDisableBoD[client])
    {
        g_iLastButtons[client] = buttons;
        return Plugin_Continue;
    }

    // Check for RELOAD button press (Debounced)
    bool isPressing  = !!(buttons & IN_RELOAD);
    bool wasPressing = !!(g_iLastButtons[client] & IN_RELOAD);

    if (isPressing && !wasPressing)
    {
        AttemptActivateShield(client);
    }

    g_iLastButtons[client] = buttons;
    return Plugin_Continue;
}

void AttemptActivateShield(int client)
{
    // If shield is already active, do nothing (allow normal reload)
    if (g_bHasShield[client])
    {
        return;
    }

    float currentTime = GetGameTime();
    float remaining   = g_fCooldownTime[client] - currentTime;

    // Check Cooldown
    if (remaining > 0.0)
    {
        bool shouldPrint = false;

        if (remaining <= 10.0)
        {
            shouldPrint = true;
        }
        else
        {
            if (currentTime - g_fLastMsgTime[client] >= 5.0)
            {
                shouldPrint            = true;
                g_fLastMsgTime[client] = currentTime;
            }
        }

        if (shouldPrint)
        {
            PrintToChat(client, "\x04[BoD]\x01 Skill is on cooldown. Wait \x03%.1f\x01 seconds.", remaining);
        }

        return;
    }

    // Activate
    ActivateShield(client);
}

void ActivateShield(int client)
{
    g_bHasShield[client]     = true;
    g_iShieldHP[client]      = GetConVarInt(g_cvMaxShieldHP);
    g_fShieldEndTime[client] = GetGameTime() + GetConVarFloat(g_cvDuration);
    g_fCooldownTime[client]  = GetGameTime() + GetConVarFloat(g_cvCooldown);

    // Visual/Audio Effects
    PerformScreenFade(client, 100, 0, 200, 50, 1000);
    EmitSoundToClient(client, g_sSoundActivate);
    PrintToChat(client, "\x04[BoD]\x01 \x05 Dawn Shield Activated!");

    if (g_hShieldTimer[client] != null)
    {
        KillTimer(g_hShieldTimer[client]);
        g_hShieldTimer[client] = null;
    }
    g_hShieldTimer[client] = CreateTimer(1.0, Timer_ShieldLoop, client, TIMER_REPEAT);
}

public Action Timer_ShieldLoop(Handle timer, int client)
{
    if (!IsClientInGame(client) || !IsPlayerAlive(client) || !g_bHasShield[client])
    {
        g_hShieldTimer[client] = null;
        return Plugin_Stop;
    }

    float currentTime = GetGameTime();

    // Check Duration
    if (currentTime >= g_fShieldEndTime[client])
    {
        BreakShield(client, false);
        return Plugin_Stop;
    }

    // Decay
    int decay = GetConVarInt(g_cvDecayRate);
    g_iShieldHP[client] -= decay;

    if (g_iShieldHP[client] <= 0)
    {
        BreakShield(client, true);
        return Plugin_Stop;
    }

    // --- UPDATED HUD DISPLAY ---
    float timeLeft = g_fShieldEndTime[client] - currentTime;
    PrintHintText(client, "Dawn Shield: %d / %d - %.0f sec", g_iShieldHP[client], GetConVarInt(g_cvMaxShieldHP), timeLeft);

    return Plugin_Continue;
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    // 1. DEFENSE
    if (victim > 0 && victim <= MaxClients && g_bHasShield[victim])
    {
        int damageInt = RoundToCeil(damage);
        if (g_iShieldHP[victim] > 0)
        {
            g_iShieldHP[victim] -= damageInt;

            // Defense feedback (kept simple, or add time if you want)
            PrintHintText(victim, "Shield Absorbed! HP: %d", g_iShieldHP[victim]);

            if (g_iShieldHP[victim] <= 0) BreakShield(victim, true);
            return Plugin_Handled;
        }
    }

    // 2. OFFENSE (Lifesteal)
    if (attacker > 0 && attacker <= MaxClients && g_bHasShield[attacker] && victim != attacker)
    {
        bool isValidTarget = false;
        if (victim > 0 && victim <= MaxClients)
        {
            if (IsClientInGame(victim) && GetClientTeam(victim) == 3) isValidTarget = true;
        }
        else if (victim > MaxClients)
        {
            char classname[64];
            GetEntityClassname(victim, classname, sizeof(classname));
            if (StrEqual(classname, "infected") || StrEqual(classname, "witch")) isValidTarget = true;
        }

        if (isValidTarget)
        {
            int maxHP     = GetConVarInt(g_cvMaxShieldHP);
            int lifesteal = GetConVarInt(g_cvLifesteal);

            if (g_iShieldHP[attacker] < maxHP)
            {
                g_iShieldHP[attacker] += lifesteal;
                if (g_iShieldHP[attacker] > maxHP) g_iShieldHP[attacker] = maxHP;

                // --- UPDATED HUD DISPLAY (LIFESTEAL) ---
                float timeLeft = g_fShieldEndTime[attacker] - GetGameTime();
                PrintHintText(attacker, "Dawn Shield: %d / %d (+%d) - %.0f sec", g_iShieldHP[attacker], maxHP, lifesteal, timeLeft);
            }
        }
    }
    return Plugin_Continue;
}

void BreakShield(int client, bool brokenByDamage)
{
    g_bHasShield[client] = false;
    g_iShieldHP[client]  = 0;

    if (g_hShieldTimer[client] != null)
    {
        KillTimer(g_hShieldTimer[client]);
        g_hShieldTimer[client] = null;
    }

    if (IsClientInGame(client))
    {
        PerformScreenFade(client, 0, 0, 0, 0, 0);
        if (brokenByDamage)
        {
            PrintToChat(client, "\x04[BoD]\x01 \x02Shield Broken!");
            EmitSoundToClient(client, g_sSoundBreak);
        }
        else
        {
            PrintToChat(client, "\x04[BoD]\x01 Shield expired.");
        }
    }
}

void ResetShield(int client)
{
    g_bHasShield[client]     = false;
    g_iShieldHP[client]      = 0;
    g_fCooldownTime[client]  = 0.0;
    g_fShieldEndTime[client] = 0.0;
    g_fLastMsgTime[client]   = 0.0;
    g_iLastButtons[client]   = 0;

    if (g_hShieldTimer[client] != null)
    {
        KillTimer(g_hShieldTimer[client]);
        g_hShieldTimer[client] = null;
    }
}

void PerformScreenFade(int client, int r, int g, int b, int a, int duration)
{
    Handle msg = StartMessageOne("Fade", client);
    if (msg != INVALID_HANDLE)
    {
        BfWriteShort(msg, duration);
        BfWriteShort(msg, 0);
        BfWriteShort(msg, 0x0002);
        BfWriteByte(msg, r);
        BfWriteByte(msg, g);
        BfWriteByte(msg, b);
        BfWriteByte(msg, a);
        EndMessage();
    }
}
