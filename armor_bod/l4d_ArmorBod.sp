#pragma semicolon 1 

#include <sourcemod> 
#include <sdktools> 
#include <sdktools_functions>

#define PLUGIN_VERSION "1.2.0"

#define ZC_SMOKER		1
#define ZC_BOOMER		2
#define ZC_HUNTER		3
#define ZC_SPITTER		4
#define ZC_JOCKEY		5
#define ZC_CHARGER		6
#define ZC_WITCH		7
#define ZC_TANK			8

new Handle:infectProbability		= INVALID_HANDLE;
new Handle:iArmorLimit 		= INVALID_HANDLE;
new Handle:iArmorToHp 		= INVALID_HANDLE;
new Handle:iArmorHeadshotReward 		= INVALID_HANDLE;
new Handle:hHRDistance		= INVALID_HANDLE;
new Handle:hHRFirst		= INVALID_HANDLE;
new Handle:hHRSecond		= INVALID_HANDLE;
new Handle:hHRThird		= INVALID_HANDLE;
new Handle:hHRFourth		= INVALID_HANDLE;

public Plugin:myinfo =
{
    name = "[L4D2] Armor BOD",
    author = "hsuallan",
    description = "L4D2 Armor BOD",
    version = PLUGIN_VERSION,
    url = ""
}

new m_iArmor[MAXPLAYERS + 1];
new bool:bDistance;
new iFirst;
new iSecond;
new iThird;
new iFourth;

public OnPluginStart()
{
	CreateConVar("sm_l4d_armor_bod_version", PLUGIN_VERSION, "Plugin Version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);

	infectProbability = CreateConVar("l4d_armor_bod_prob", "25", "The probability of get armor from infected.", FCVAR_NOTIFY, true, 0.0, true, 100.0);
	iArmorLimit = CreateConVar("l4d_armor_bod_max", "100", "reward max armor value", FCVAR_NOTIFY);
	iArmorToHp = CreateConVar("l4d_armor_bod_armor_to_hp", "20", "How many armor get will change to hp", FCVAR_NOTIFY);
	iArmorHeadshotReward = CreateConVar("l4d_armor_bod_headshot_reward", "5", "How many bouns armor for headshot special", FCVAR_NOTIFY);
	hHRDistance = CreateConVar("l4d_armor_rewards_distance", "1", "Enable/Disable Distance Calculations", FCVAR_NOTIFY);
	hHRFirst = CreateConVar("l4d_armor_rewards_first", "1", "Rewarded Armor For Killing Boomers And Spitters", FCVAR_NOTIFY);
	hHRSecond = CreateConVar("l4d_armor_rewards_second", "3", "Rewarded Armor For Killing Smokers And Jockeys", FCVAR_NOTIFY);
	hHRThird = CreateConVar("l4d_armor_rewards_third", "5", "Rewarded Armor For Killing Hunters And Chargers", FCVAR_NOTIFY);
	hHRFourth = CreateConVar("l4d_armor_rewards_fourth", "20", "Rewarded Armor For Killing Tanks", FCVAR_NOTIFY);

	HookEvent("player_first_spawn", event_PlayerSpawn);
	HookEvent("player_spawn", event_PlayerSpawn);
	HookEvent("player_transitioned", event_SetStatus);
	HookEvent("survivor_rescued", event_Rescued);
	HookEvent("bot_player_replace", event_PlayerReplaced, EventHookMode_Post);
	HookEvent("player_bot_replace", event_BotReplaced, EventHookMode_Post);
	HookEvent("player_team", event_PlayerTeamSwitch);
	HookEvent("player_left_start_area", event_LeftStart);
	HookEvent("player_hurt", event_PlayerHurt);
	HookEvent("player_death", event_PlayerDeath);
	HookEvent("infected_death", event_InfectedDeath);
	bDistance = GetConVarBool(hHRDistance);
	iFirst = GetConVarInt(hHRFirst);
	iSecond = GetConVarInt(hHRSecond);
	iThird = GetConVarInt(hHRThird);
	iFourth = GetConVarInt(hHRFourth);
}

public event_PlayerSpawn(Handle:event, const String:name[], bool:Broadcast) 
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(client > 0 && GetClientTeam(client) == 2)
	{	
		SetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), m_iArmor[client], 4, true);
	}
}

public event_SetStatus(Handle:event, const String:name[], bool:dontBroadcast) 
{	
	new client = GetClientOfUserId(GetEventInt(event,"userid"));
	if(client > 0 && GetClientTeam(client) == 2)
	{
		SetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), m_iArmor[client], 4, true);
	}
}

public event_Rescued(Handle:event, const String:name[], bool:dontBroadcast) 
{	
	new client = GetClientOfUserId(GetEventInt(event,"victim"));
	if(client > 0 && GetClientTeam(client) == 2)
	{
		SetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), m_iArmor[client], 4, true);
	}
}

public event_PlayerReplaced(Handle:event, const String:name[], bool:dontBroadcast) 
{	
	new client = GetClientOfUserId(GetEventInt(event,"player"));
	if(client > 0 && GetClientTeam(client) == 2)
	{
		SetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), m_iArmor[client], 4, true);
	}
}

public event_BotReplaced(Handle:event, const String:name[], bool:dontBroadcast) 
{		
	new client = GetClientOfUserId(GetEventInt(event,"bot"));
	if(client > 0 && GetClientTeam(client) == 2)
	{
		SetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), m_iArmor[client], 4, true);
	}
}

public event_LeftStart(Handle:event, const String:name[], bool:dontBroadcast) 
{	
	new client = GetClientOfUserId(GetEventInt(event,"userid"));
	if(client > 0 && GetClientTeam(client) == 2)
	{
		SetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), m_iArmor[client], 4, true);
	}
}

public event_PlayerTeamSwitch(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(client > 0 && GetClientTeam(client) == 2)
	{
		SetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), m_iArmor[client], 4, true);
	}
}

public event_PlayerHurt(Handle:event, const String:name[], bool:Broadcast) 
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(GetClientTeam(client) == 2)
	{
		// m_iArmor[client] = GetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), 4);
		new iArmor = GetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), 4);
		PrintHintText(client, "Armor: %i/%i", iArmor, GetConVarInt(iArmorLimit));
	}
}

public Action:event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	new shooter = GetClientOfUserId(GetEventInt(event, "attacker"));
	new isHeadShot = GetEventBool(event, "headshot");
	if(shooter <= 0 || shooter > MaxClients || !IsClientInGame(shooter) || GetClientTeam(shooter) != 2 || !IsPlayerAlive(shooter) || IsPlayerIncapped(shooter))
	{
		return;
	}
	decl Float:cOrigin[3];
	GetEntPropVector(client, Prop_Send, "m_vecOrigin", cOrigin);
	decl Float:sOrigin[3];
	GetEntPropVector(shooter, Prop_Send, "m_vecOrigin", sOrigin);
	
	new dHealth;
	new Float:oDistance = GetVectorDistance(cOrigin, sOrigin);
	if(oDistance < 10000.0)
	{
		dHealth = RoundToZero(oDistance * 0.02);
	}
	else if(oDistance >= 10000.0)
	{
		dHealth = 200;
	}
	
	new addArmor = 0;
	new cClass = GetEntProp(client, Prop_Send, "m_zombieClass");
	if(isHeadShot)
	{
		addArmor = GetConVarInt(iArmorHeadshotReward);
	}
	if(cClass == ZC_BOOMER || cClass == ZC_SPITTER)
	{
		if(bDistance)
		{
			addArmor = iFirst + dHealth;
		}
		else
		{
			addArmor = iFirst;
		}
	}
	else if(cClass == ZC_SMOKER || cClass == ZC_JOCKEY)
	{
		if(bDistance)
		{
			addArmor = iSecond + dHealth;
		}
		else
		{
			addArmor = iSecond;
		}
	}
	else if(cClass == ZC_HUNTER || cClass == ZC_CHARGER)
	{
		if(bDistance)
		{
			addArmor = iThird + dHealth;
		}
		else
		{
			addArmor = iThird;
		}
	}
	else if(cClass == ZC_TANK)
	{
		addArmor = iFourth;
	}

	new iArmor = GetEntData(shooter, FindDataMapInfo(client, "m_ArmorValue"), 4);
	if(cClass == ZC_TANK)
	{
		for (new player = 1; player <= MaxClients; player++)
		{
			new pArmor = GetEntData(player, FindDataMapInfo(player, "m_ArmorValue"), 4);
			if(IsClientInGame(player) && GetClientTeam(player) == 2 && IsPlayerAlive(player) && !IsPlayerIncapped(player) && (pArmor + addArmor) < GetConVarInt(iArmorLimit))
			{
				SetEntData(player, FindDataMapInfo(player, "m_ArmorValue"), GetEntData(player, FindDataMapInfo(player, "m_ArmorValue"), 4) + addArmor, 4, true);
				PrintToChat(player, "\x05 %i Armor Restored", addArmor);
				PrintToChat(player, "\x05 You Have %i Armor", GetEntData(player, FindDataMapInfo(player, "m_ArmorValue"), 4));
			}
			else
			{
				SetEntData(player, FindDataMapInfo(player, "m_ArmorValue"), GetConVarInt(iArmorLimit), 4, true);
			}
		}
	}
	else if((iArmor + addArmor) < GetConVarInt(iArmorLimit))
	{
		SetEntData(shooter, FindDataMapInfo(client, "m_ArmorValue"), iArmor + addArmor, 4, true);
		PrintToChat(shooter, "\x05 %i Armor Restored", addArmor);
		PrintToChat(shooter, "\x05 You Have %i Armor", GetEntData(shooter, FindDataMapInfo(client, "m_ArmorValue"), 4));
	}
	else
	{
		SetEntData(shooter, FindDataMapInfo(client, "m_ArmorValue"), GetConVarInt(iArmorLimit), 4, true);
	}
}

public Action:event_InfectedDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "attacker"));
	new isHeadShot = GetEventBool(event, "headshot");
	new GetCashProbability = 0;
	new iArmor = GetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), 4);
	new armorChange = GetConVarInt(iArmorToHp);
	
	if(isHeadShot)
	{
		GetCashProbability = 0;
	} 
	else 
	{
		GetCashProbability = GetRandomInt(0, 100);
	}
	if(iArmor > armorChange)
	{
		new healthB = GetClientHealth(client);
		SetEntProp(client, Prop_Send, "m_iHealth", healthB + armorChange, 1);
		SetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), 0, 4, true);
		PrintToChat(client, "\x05 you use 20 armor change iHealth %i", armorChange);
	}
	if(GetCashProbability < GetConVarInt(infectProbability))
	{
		// new CashValue = GetRandomInt(1, 10);
		// iCash[client] += CashValue;
		if(iArmor < 100)
		{
			SetEntData(client, FindDataMapInfo(client, "m_ArmorValue"), iArmor + 1, 4, true);
			PrintHintText(client, "Armor: %i", iArmor + 1);
		}
		
		// PrintToChat(client, "\x05 you have %i Armor",  iArmor + 1);
	}
}


public IsPlayerIncapped(client)
{
	if(GetEntProp(client, Prop_Send, "m_isIncapacitated", 1))
	{
		return true;
	}
	else
	{
		return false;
	}
}