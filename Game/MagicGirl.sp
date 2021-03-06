/******************************************************************/
/*                                                                */
/*                      MagicGirl.NET Core                        */
/*                                                                */
/*                                                                */
/*  File:          MagicGirl.sp                                   */
/*  Description:   Interconnector of Game and Forum.              */
/*                                                                */
/*                                                                */
/*  Copyright (C) 2018  MagicGirl.NET Dev Team                    */
/*  2018/01/04 11:16:39                                           */
/*                                                                */
/*  This code is licensed under the Apache License.               */
/*                                                                */
/******************************************************************/


#pragma semicolon 1
#pragma newdecls required

#include <MagicGirl.NET>

// game rules.
#include <sdktools_gamerules>

#define PI_NAME THIS_PRETAG ... " - Core"
#define PI_DESC "provides an API of MagicGirl.NET"

public Plugin myinfo = 
{
    name        = PI_NAME,
    author      = PI_AUTH,
    description = PI_DESC,
    version     = PI_VERS,
    url         = PI_URLS
};

int g_iServerId = -1;
int g_iServerPort = 27015;
int g_iServerModId = -1;

bool g_bConnected = false;

char g_szServerIp[24]  = "127.0.0.1";
char g_szRconPswd[24]  = "fuckMyLife";
char g_szHostName[128] = "MagicGirl.NET - Server";

ArrayList     g_aQueriesQueue = null;
Database      g_hMySQL        = null;
Handle        g_hOnAvailable  = null;
EngineVersion g_Engine        = Engine_Unknown;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    // connections
    CreateNative("MG_MySQL_IsConnected", Native_IsConnected);
    CreateNative("MG_MySQL_GetDatabase", Native_GetDatabase);

    // quick handle
    CreateNative("MG_MySQL_EscapeString", Native_EscapeString);
    CreateNative("MG_MySQL_SaveDatabase", Native_SaveDatabase);
    CreateNative("MG_MySQL_ExecDatabase", Native_ExecDatabase);

    // core
    CreateNative("MG_Core_GetServerId",    Native_GetServerId);
    CreateNative("MG_Core_GetServerModId", Native_GetServerModId);

    // logs
    CreateNative("MG_Core_LogError",   Native_LogError);
    CreateNative("MG_Core_LogMessage", Native_LogMessage);

    // lib
    RegPluginLibrary("MagicGirl");

    /* Init plugin */
    SetConVarInt(FindConVar("sv_hibernate_when_empty"), 0);
    g_Engine = GetEngineVersion();
    int ip = GetConVarInt(FindConVar("hostip"));
    FormatEx(g_szServerIp, 24, "%d.%d.%d.%d", ((ip & 0xFF000000) >> 24) & 0xFF, ((ip & 0x00FF0000) >> 16) & 0xFF, ((ip & 0x0000FF00) >>  8) & 0xFF, ((ip & 0x000000FF) >>  0) & 0xFF);
    g_iServerPort = GetConVarInt(FindConVar("hostport"));

    return APLRes_Success;
}

public int Native_IsConnected(Handle plugin, int numParams)
{
    return g_bConnected;
}

public int Native_GetDatabase(Handle plugin, int numParams)
{
    return view_as<int>(g_hMySQL);
}

public int Native_EscapeString(Handle plugin, int numParams)
{
    // database is unavailable
    if(!g_bConnected || g_hMySQL == null)
        return false;

    // dynamic length
    int inLen = 0;
    GetNativeStringLength(1, inLen);
    char[] input = new char[inLen+1];
    if(GetNativeString(1, input, inLen+1) != SP_ERROR_NONE)
        return false;

    int maxLen = strlen(input)*2+1;
    char[] output = new char[maxLen];
    if(!g_hMySQL.Escape(input, output, maxLen))
        return false;

    return (SetNativeString(2, output, GetNativeCell(3), true) == SP_ERROR_NONE);
}

public int Native_SaveDatabase(Handle plugin, int numParams)
{
    // dynamic length
    int inLen = 0;
    GetNativeStringLength(1, inLen);
    char[] input = new char[++inLen];
    if(GetNativeString(1, input, inLen) != SP_ERROR_NONE)
        return;

    // database is unavailable
    if(!g_bConnected || g_hMySQL == null)
    {
        g_aQueriesQueue.PushString(input);
        return;
    }

    DataPack data = new DataPack();
    data.WriteCell(inLen);
    data.WriteString(input);

    g_hMySQL.Query(NativeSave_Callback, input, data, DBPrio_High);
}

public int Native_ExecDatabase(Handle plugin, int numParams)
{
    // database is unavailable
    if(!g_bConnected || g_hMySQL == null)
        return view_as<int>(INVALID_HANDLE);

    // dynamic length
    int inLen = 0;
    GetNativeStringLength(1, inLen);
    char[] input = new char[++inLen];
    if(GetNativeString(1, input, inLen) != SP_ERROR_NONE)
        return view_as<int>(INVALID_HANDLE);

    return view_as<int>(SQL_Query(g_hMySQL, input));
}

public int Native_GetServerId(Handle plugin, int numParams)
{
    return g_iServerId;
}

public int Native_GetServerModId(Handle plugin, int numParams)
{
    return g_iServerModId;
}

public int Native_LogError(Handle plugin, int numParams)
{
    char module[32], func[64], format[256];
    GetNativeString(1, module,  32);
    GetNativeString(2, func,    64);
    GetNativeString(3, format, 256);

    char error[2048];
    FormatNativeString(0, 0, 4, 2048, _, error, format);

    char path[128];
    BuildPath(Path_SM, path, 128, "logs/MagicGirl.Net/%s_err.log", module);

    LogToFileEx(path, "[%s] -> %s", func, error);
}

public int Native_LogMessage(Handle plugin, int numParams)
{
    char module[32], func[64], format[256];
    GetNativeString(1, module,  32);
    GetNativeString(2, func,    64);
    GetNativeString(3, format, 256);

    char message[2048];
    FormatNativeString(0, 0, 4, 2048, _, message, format);

    char path[128];
    BuildPath(Path_SM, path, 128, "logs/MagicGirl.Net/%s_msg.log", module);
    
    LogToFileEx(path, "[%s] -> %s", func, message);
}

public void OnPluginStart()
{
    // queries queue
    g_aQueriesQueue = new ArrayList(ByteCountToCells(2048));

    // forwards
    g_hOnAvailable = CreateGlobalForward("MG_Core_OnAvailable",  ET_Ignore, Param_Cell, Param_Cell);

    // connections
    ConnectToDatabase(0);

    // log dir
    CheckLogsDirectory();
}

void CheckLogsDirectory()
{
    char path[128];
    BuildPath(Path_SM, path, 128, "logs/MagicGirl.Net");
    if(!DirExists(path))
        CreateDirectory(path, 755);
}

void ConnectToDatabase(int retry)
{
    // connected?
    if(g_bConnected)
        return;

    // not null
    if(g_hMySQL != null)
    {
        g_bConnected = true;
        return;
    }

    Database.Connect(OnConnected, "default", retry);
}

public void OnConnected(Database db, const char[] error, int retry)
{
    if(db == null)
    {
        MG_Core_LogError("MySQL", "OnConnected", "Connect failed -> %s", error);
        if(++retry <= 10)
            CreateTimer(5.0, Timer_Reconnect, retry);
        else
            SetFailState("connect to database failed! -> %s", error);
        return;
    }

    g_hMySQL = db;
    g_hMySQL.SetCharset("utf8");
    g_bConnected = true;

    // server message
    PrintToServer("Database Connected!");

    // parse data
    char m_szQuery[2048];
    FormatEx(m_szQuery, 2048, "SELECT * FROM `dxg_servers` WHERE `ip`='%s' AND `port`='%d';", g_szServerIp, g_iServerPort);
    db.Query(ServerDataCallback, m_szQuery, _, DBPrio_High);
    
    // process queue
    while(g_aQueriesQueue.Length)
    {
        g_aQueriesQueue.GetString(0, m_szQuery, 2048);
        g_aQueriesQueue.Erase(0);
        
        DataPack data = new DataPack();
        data.WriteCell(strlen(m_szQuery)+1);
        data.WriteString(m_szQuery);

        db.Query(NativeSave_Callback, m_szQuery, data, DBPrio_High);
    }
}

public Action Timer_Reconnect(Handle timer, int retry)
{
    ConnectToDatabase(retry);
    return Plugin_Stop;
}

public void ServerDataCallback(Database db, DBResultSet results, const char[] error, any unuse)
{
    if(results == null || error[0])
    {
        MG_Core_LogError("MySQL", "ServerDataCallback", "Query Server Info: %s", error);
        RetrieveInfoFromKV();
    }
    else
    {
        if(!results.FetchRow())
        {
            MG_Core_LogError("MySQL", "ServerDataCallback", "Not Found this server in database");
            SetFailState("Not Found this server in database");
            return;
        }

        g_iServerId = results.FetchInt(0);
        g_iServerModId = results.FetchInt(1);
        results.FetchString(2, g_szHostName, 128);

        SaveInfoToKV();
    }

    // apply configs
    OnMapStart();

    // we used random rcon password.
    GenerateRandomString(g_szRconPswd, 24);

    // sync to database
    char m_szQuery[128];
    FormatEx(m_szQuery, 128, "UPDATE `dxg_servers` SET `rcon`='%s' WHERE `sid`='%d';", g_szRconPswd, g_iServerId);
    db.Query(UpdatePasswordCallback, m_szQuery, _, DBPrio_High);
}

public void UpdatePasswordCallback(Database db, DBResultSet results, const char[] error, any unuse)
{
    if(results == null || error[0])
        MG_Core_LogError("MySQL", "UpdatePasswordCallback", "Update RCon password: %s", error);
    
    // server loaded
    Call_StartForward(g_hOnAvailable);
    Call_PushCell(g_iServerId);
    Call_PushCell(g_iServerModId);
    Call_Finish();
}

public void NativeSave_Callback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    if(results == null || error[0] || results.AffectedRows == 0)
    {
        pack.Reset();
        int strLen = pack.ReadCell();
        char[] str = new char[strLen];
        pack.ReadString(str, strLen);
        MG_Core_LogError("MySQL", "NativeSave_Callback", "SQL Error: %s\nQuery: %s", (results == null || error[0]) ? error : "No affected row", str);
    }

    delete pack;
}

void RetrieveInfoFromKV()
{
    char path[128];
    BuildPath(Path_SM, path, 128, "configs/MagicGirl.core");
    
    if(!FileExists(path))
        SetFailState("Connect to database error and kv NOT FOUND");
    
    KeyValues kv = new KeyValues("MagicGirl.Net");
    
    if(!kv.ImportFromFile(path))
        SetFailState("Connect to database error and kv load failed!");
    
    g_iServerId = kv.GetNum("serverid", -1);
    g_iServerModId = kv.GetNum("modid", -1);
    kv.GetString("hostname", g_szHostName, 128, "MagicGirl.NET - Server");
    delete kv;

    if(g_iServerId == -1)
        SetFailState("Why your server id still is -1");
}

void SaveInfoToKV()
{
    KeyValues kv = new KeyValues("MagicGirl.Net");
    
    kv.SetNum("serverid", g_iServerId);
    kv.SetNum("modid", g_iServerModId);
    kv.SetString("hostname", g_szHostName);
    kv.Rewind();

    char path[128];
    BuildPath(Path_SM, path, 128, "configs/MagicGirl.core");
    kv.ExportToFile(path);

    delete kv;
}

void GenerateRandomString(char[] buffer, int maxLen)
{
    // terminator
    maxLen--;

    char random[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01234556789";
    int randlen = strlen(random) - 1;

    int n = 0;
    int c = 0;

    while(n < maxLen)
    {
        if(random[0] == '\0')
        {
            c = GetRandomInt(33, 126);
            buffer[n] = c;
        }
        else
        {
            c = GetRandomInt(0, randlen);
            buffer[n] = random[c];
        }

        n++;
    }

    buffer[maxLen] = '\0';
}

public void OnMapStart()
{
    if(g_Engine == Engine_CSGO)
    {
        // fix host name in gotv
        ConVar host_name_store = FindConVar("host_name_store");
        if(host_name_store != null)
            host_name_store.SetString("1", false, false);
        
        // fake offical server
        GameRules_SetProp("m_bIsValveDS", 1, 0, 0, true);
    }

    FindConVar("hostname").SetString(g_szHostName, false, false);
}