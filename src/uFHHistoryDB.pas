{==============================================================================
  uFHHistoryDB —— 浏览历史 + 下载记录持久化（本地 SQLite）
  ----------------------------------------------------------------------------
  职责: 在 exe 目录下 UserData\History.db 里持久化浏览历史和下载记录，
        供"删除浏览数据"按时间范围清理，并为历史记录窗口提供查询/单条删除。
  设计:
    - 用 Delphi 自带 FireDAC + sqlite3.dll（部署在 exe 目录）
    - 全局单例 HistoryDB，主线程访问（CEF 回调在主线程），无需加锁
    - TDateTime 经 FireDAC DateTimeFormat=DateTime 存为 REAL（TDateTime 双精度
      天数）, 与列声明 visit_time REAL / start_time REAL 一致,
      WHERE visit_time >= :since 与 ORDER BY 直接按数值比较
    - 浏览历史: 同 URL 用 UPSERT 累加 visit_count（同 Chrome 行为）
    - 下载记录: 以 CEF download id 为主键，INSERT OR REPLACE
    - 清理时保留进行中的下载（state=0）
  表结构:
    fh_history(id, url UNIQUE, title, visit_time, visit_count)
    fh_downloads(id PK, url, path, name, start_time, end_time, received, total, state)
      state: 0=进行中 1=完成 2=取消 3=中断
==============================================================================}
unit uFHHistoryDB;

interface

uses
  System.Classes, System.SysUtils, System.DateUtils,
  FireDAC.Stan.Intf, FireDAC.Stan.Def, FireDAC.Stan.Pool, FireDAC.Stan.Async,
  FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Comp.Client;

type
  { 一条浏览历史（fh_history 的一行） }
  TFHHistoryEntry = record
    Id: Int64;
    Url: string;
    Title: string;
    VisitTime: TDateTime;
    VisitCount: Integer;
  end;
  TFHHistoryEntries = TArray<TFHHistoryEntry>;

  { 一条书签（fh_bookmarks 的一行） }
  TFHBookmarkEntry = record
    Id: Int64;
    Url: string;
    Title: string;
    CreatedAt: TDateTime;
  end;
  TFHBookmarkEntries = TArray<TFHBookmarkEntry>;

  { 一条下载记录（fh_downloads 的一行）。独立于 uFHDownloads 的
    TFHDownloadItem（含 CEF 回话回调, 不可持久化）, 只承载数据库字段 }
  TFHDownloadDbRow = record
    Id: Cardinal;
    Url: string;
    Path: string;
    Name: string;
    StartTime: TDateTime;
    EndTime: TDateTime;
    Received: Int64;
    Total: Int64;
    State: Integer;          // 0=进行中 1=完成 2=取消 3=中断（写侧映射见 uBrowserMain）
  end;
  TFHDownloadDbRows = TArray<TFHDownloadDbRow>;

  TFHHistoryDB = class
  private
    FConn: TFDConnection;
    FDBPath: string;
    procedure OpenConnection;
    procedure CreateTables;
  public
    constructor Create;
    destructor Destroy; override;

    { 浏览历史: 记录一次访问（同 URL 累加 visit_count） }
    procedure AddHistory(const AUrl, ATitle: string);
    { 查询浏览历史。AKeyword 为空 = 全部; 否则按 URL/标题做不区分大小写的子串匹配。
      结果按最近访问时间倒序, 最多 AMaxCount 条 }
    function QueryHistory(const AKeyword: string;
      AMaxCount: Integer = 5000): TFHHistoryEntries;
    { 删除某条 URL 的历史（同 URL 在库里只有一行, Chrome 的"从历史记录中移除"同义） }
    procedure DeleteHistoryUrl(const AUrl: string);
    { 清除浏览历史。ASince=0 清全部；否则清 visit_time >= ASince 的 }
    procedure ClearHistory(ASince: TDateTime);

    { 下载记录: 新增一条（下载开始时调） }
    procedure AddDownload(AId: Cardinal; const AUrl, APath, AName: string);
    { 下载记录: 更新进度/状态（下载更新时调） }
    procedure UpdateDownload(AId: Cardinal; AReceived, ATotal: Int64;
      AState: Integer; AEndTime: TDateTime);
    { 清除下载记录。ASince=0 清全部；否则清 start_time >= ASince 的。
      始终保留进行中的（state=0） }
    procedure ClearDownloads(ASince: TDateTime);
    { 删除单条下载记录（下载窗口的"删除记录"/"删除记录和文件"） }
    procedure DeleteDownload(AId: Cardinal);
    { 查询下载记录（启动恢复用）。按开始时间倒序, 最多 AMaxCount 条。
      此前只有写侧（Add/UpdateDownload）没有加载侧 → 程序重启后下载记录消失 }
    function QueryDownloads(AMaxCount: Integer = 500): TFHDownloadDbRows;

    { 书签: 判断 URL 是否已收藏（地址栏星标的实心/空心态） }
    function BookmarkExists(const AUrl: string): Boolean;
    { 书签: 新增一条收藏（Ctrl+D / 星标点击）。URL 已存在时静默忽略（幂等） }
    procedure AddBookmark(const AUrl, ATitle: string);
    { 书签: 修改书签的标题与 URL（星标气泡的"编辑"）。按旧 URL 定位 }
    procedure UpdateBookmark(const AOldUrl, ANewUrl, ATitle: string);
    { 查询书签。AKeyword 为空 = 全部; 否则按 URL/标题做不区分大小写的子串匹配。
      结果按创建时间倒序, 最多 AMaxCount 条 }
    function QueryBookmarks(const AKeyword: string;
      AMaxCount: Integer = 5000): TFHBookmarkEntries;
    { 删除某条 URL 的书签（星标再次点击 = 取消收藏） }
    procedure DeleteBookmarkUrl(const AUrl: string);

    property DBPath: string read FDBPath;
  end;

{ 全局单例。首次调用时创建并打开数据库（自动建表） }
function HistoryDB: TFHHistoryDB;

implementation

uses
  Data.DB,
  FireDAC.DApt,   { TFDQuery 的 dataset factory（FireDAC.Comp.Client 只声明类型） }
  FireDAC.Comp.UI,{ TFDQuery.Open 需要 GUIxWaitCursor factory, 否则抛 factory missing }
  FireDAC.VCLUI.Wait,{ 真正注册 IFDGUIxWaitCursor 的 VCL 实现（initialization 里） }
  uLogger;

type
  { TFDGUIxWaitCursor 在 Loaded（DFM 流式加载结束）里注册 factory; 动态 Create
    不会触发 Loaded, 用子类把它暴露出来手动调一次 }
  TFHFDGUIxWaitCursor = class(TFDGUIxWaitCursor)
  public
    procedure RegisterFactory;
  end;

procedure TFHFDGUIxWaitCursor.RegisterFactory;
begin
  Loaded;
end;

var
  GHistoryDB: TFHHistoryDB = nil;
  GWaitCursor: TFHFDGUIxWaitCursor = nil;

function HistoryDB: TFHHistoryDB;
begin
  if GHistoryDB = nil then
    GHistoryDB := TFHHistoryDB.Create;
  Result := GHistoryDB;
end;

{ ---- TFHHistoryDB ---- }

{ 构造: 补注册 FireDAC GUI 等待光标 factory, 打开 UserData\History.db 并自动建表 }
constructor TFHHistoryDB.Create;
begin
  { TFDQuery.Open 走 GUI 环境时会找 IFDGUIxWaitCursor factory,
    没有实例就抛 "Object factory ... missing" —— 在这里补上（仅首次创建） }
  if GWaitCursor = nil then
  begin
    GWaitCursor := TFHFDGUIxWaitCursor.Create(nil);
    GWaitCursor.RegisterFactory;
  end;

  FDBPath := ExtractFilePath(ParamStr(0)) + 'UserData\History.db';
  ForceDirectories(ExtractFileDir(FDBPath));
  FConn := TFDConnection.Create(nil);
  OpenConnection;
  CreateTables;
end;

{ 析构: 释放数据库连接 }
destructor TFHHistoryDB.Destroy;
begin
  FConn.Free;
  inherited;
end;

{ 打开 SQLite 连接: 日期时间按 REAL 存储（DateTimeFormat=DateTime）,
  单进程访问用 Normal 锁定/同步避免 WAL 副文件 }
procedure TFHHistoryDB.OpenConnection;
begin
  FConn.DriverName := 'SQLite';
  FConn.Params.Values['Database'] := FDBPath;
  { 日期时间存 REAL（Delphi TDateTime 双精度）。FireDAC SQLite 默认 dtfString
    会把时间写成 ISO 文本, 而列声明是 REAL —— 读取时驱动按列类型把 '2026-...'
    转成数值 2026, 时间全错。显式指定 DateTime 让存储与列类型一致 }
  FConn.Params.Values['DateTimeFormat'] := 'DateTime';
  { SQLite 默认 WAL，单进程访问用 Normal 即可，避免 -wal/-shm 副文件 }
  FConn.Params.Values['LockingMode'] := 'Normal';
  FConn.Params.Values['Synchronous'] := 'Normal';
  FConn.Connected := True;
end;

{ 建表（已存在则跳过）: 浏览历史 fh_history / 下载记录 fh_downloads / 书签 fh_bookmarks }
procedure TFHHistoryDB.CreateTables;
begin
  FConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS fh_history (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  url TEXT NOT NULL UNIQUE,' +
    '  title TEXT,' +
    '  visit_time REAL,' +
    '  visit_count INTEGER DEFAULT 1' +
    ')');
  FConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS fh_downloads (' +
    '  id INTEGER PRIMARY KEY,' +
    '  url TEXT,' +
    '  path TEXT,' +
    '  name TEXT,' +
    '  start_time REAL,' +
    '  end_time REAL,' +
    '  received INTEGER,' +
    '  total INTEGER,' +
    '  state INTEGER DEFAULT 0' +
    ')');
  FConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS fh_bookmarks (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  url TEXT NOT NULL UNIQUE,' +
    '  title TEXT,' +
    '  created_at REAL' +
    ')');
end;

{ ---- 浏览历史 ---- }

procedure TFHHistoryDB.AddHistory(const AUrl, ATitle: string);
begin
  if AUrl = '' then Exit;
  { 跳过 about: / chrome: / data: 等内部页面 }
  if (Pos('about:', AUrl) = 1) or (Pos('chrome:', AUrl) = 1) or
     (Pos('data:', AUrl) = 1) or (Pos('javascript:', AUrl) = 1) then Exit;

  try
    { 同 URL 累加 visit_count: 先查再 INSERT/UPDATE。
      不用 UPSERT(ON CONFLICT DO UPDATE) —— 它要 SQLite 3.24+, 而随程序部署的
      sqlite3.dll 版本较旧, 会在 "ON" 处报语法错误导致历史记录全部静默丢失 }
    if FConn.ExecSQLScalar('SELECT count(*) FROM fh_history WHERE url = :u',
      [AUrl]) > 0 then
      FConn.ExecSQL(
        'UPDATE fh_history SET title = :t, visit_time = :vt, ' +
        'visit_count = visit_count + 1 WHERE url = :u',
        [ATitle, Now, AUrl])
    else
      FConn.ExecSQL(
        'INSERT INTO fh_history(url, title, visit_time, visit_count) ' +
        'VALUES(:u, :t, :vt, 1)',
        [AUrl, ATitle, Now]);
  except
    on E: Exception do
      { 历史记录失败不应影响浏览, 但必须留痕（否则"历史为空"无从排查） }
      Logger.Error('记录浏览历史失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

function TFHHistoryDB.QueryHistory(const AKeyword: string;
  AMaxCount: Integer): TFHHistoryEntries;
var
  Q: TFDQuery;
  F: TField;
  Kw: string;
  N: Integer;
begin
  SetLength(Result, 0);
  if AMaxCount <= 0 then
    AMaxCount := 5000;
  Q := TFDQuery.Create(nil);
  try
    try
    Q.Connection := FConn;
    Kw := Trim(AKeyword);
    { 用 instr(lower(...)) 做子串匹配: 不需要转义 LIKE 的 % / _,
      且同一条 SQL 里能直接匹配 URL 与标题（title 可能为 NULL, 用 ifnull 兜住） }
    if Kw = '' then
      Q.SQL.Text :=
        'SELECT id, url, title, visit_time, visit_count FROM fh_history ' +
        'ORDER BY visit_time DESC LIMIT ' + IntToStr(AMaxCount)
    else
    begin
      Q.SQL.Text :=
        'SELECT id, url, title, visit_time, visit_count FROM fh_history ' +
        'WHERE instr(lower(url || '' '' || ifnull(title, '''')), lower(:kw)) > 0 ' +
        'ORDER BY visit_time DESC LIMIT ' + IntToStr(AMaxCount);
      Q.ParamByName('kw').AsString := Kw;
    end;
    Q.Open;
    N := 0;
    while not Q.Eof do
    begin
      SetLength(Result, N + 1);
      Result[N].Id := Q.FieldByName('id').AsLargeInt;
      Result[N].Url := Q.FieldByName('url').AsString;
      Result[N].Title := Q.FieldByName('title').AsString;
      { visit_time 按列声明存 REAL, 正常映射为 ftFloat 直接取 AsFloat;
        字符串分支兜底旧库（早期版本曾把时间写成 ISO 文本）, 手工解析,
        避免隐式转换抛异常导致整个查询返回空 }
      F := Q.FieldByName('visit_time');
      if F.IsNull then
        Result[N].VisitTime := 0
      else if F.DataType = ftFloat then
        Result[N].VisitTime := F.AsFloat
      else
        Result[N].VisitTime := StrToDateTimeDef(F.AsString, 0);
      Result[N].VisitCount := Q.FieldByName('visit_count').AsInteger;
      Inc(N);
      Q.Next;
    end;
    except
      on E: Exception do
      begin
        Logger.Error('查询浏览历史失败: %s - %s', [E.ClassName, E.Message]);
        SetLength(Result, 0);    // 历史查询失败不应打断 UI, 返回空列表
      end;
    end;
  finally
    Q.Free;
  end;
end;

procedure TFHHistoryDB.DeleteHistoryUrl(const AUrl: string);
begin
  if AUrl = '' then Exit;
  try
    FConn.ExecSQL('DELETE FROM fh_history WHERE url = :u', [AUrl]);
  except
    on E: Exception do ;
  end;
end;

procedure TFHHistoryDB.ClearHistory(ASince: TDateTime);
begin
  try
    if ASince = 0 then
      FConn.ExecSQL('DELETE FROM fh_history')
    else
      FConn.ExecSQL('DELETE FROM fh_history WHERE visit_time >= :s', [ASince]);
  except
    on E: Exception do ;
  end;
end;

{ ---- 下载记录 ---- }

procedure TFHHistoryDB.AddDownload(AId: Cardinal; const AUrl, APath, AName: string);
begin
  try
    FConn.ExecSQL(
      'INSERT OR REPLACE INTO fh_downloads(id, url, path, name, start_time, end_time, received, total, state) ' +
      'VALUES(:id, :u, :p, :n, :st, 0, 0, 0, 0)',
      [Integer(AId), AUrl, APath, AName, Now]);
  except
    on E: Exception do ;
  end;
end;

procedure TFHHistoryDB.UpdateDownload(AId: Cardinal; AReceived, ATotal: Int64;
  AState: Integer; AEndTime: TDateTime);
begin
  try
    FConn.ExecSQL(
      'UPDATE fh_downloads SET received = :r, total = :t, state = :s, end_time = :et ' +
      'WHERE id = :id',
      [AReceived, ATotal, AState, AEndTime, Integer(AId)]);
  except
    on E: Exception do ;
  end;
end;

procedure TFHHistoryDB.ClearDownloads(ASince: TDateTime);
begin
  try
    { 始终保留进行中的（state=0） }
    if ASince = 0 then
      FConn.ExecSQL('DELETE FROM fh_downloads WHERE state <> 0')
    else
      FConn.ExecSQL('DELETE FROM fh_downloads WHERE state <> 0 AND start_time >= :s',
        [ASince]);
  except
    on E: Exception do ;
  end;
end;

procedure TFHHistoryDB.DeleteDownload(AId: Cardinal);
begin
  try
    FConn.ExecSQL('DELETE FROM fh_downloads WHERE id = :id',
      [Integer(AId)]);
  except
    on E: Exception do ;
  end;
end;

function TFHHistoryDB.QueryDownloads(AMaxCount: Integer): TFHDownloadDbRows;
var
  Q: TFDQuery;
  N: Integer;
  F: TField;
begin
  SetLength(Result, 0);
  if AMaxCount <= 0 then
    AMaxCount := 500;
  Q := TFDQuery.Create(nil);
  try
    try
      Q.Connection := FConn;
      Q.SQL.Text :=
        'SELECT id, url, path, name, start_time, end_time, received, total, state ' +
        'FROM fh_downloads ORDER BY start_time DESC LIMIT ' + IntToStr(AMaxCount);
      Q.Open;
      N := 0;
      while not Q.Eof do
      begin
        SetLength(Result, N + 1);
        Result[N].Id := Cardinal(Q.FieldByName('id').AsLargeInt);
        Result[N].Url := Q.FieldByName('url').AsString;
        Result[N].Path := Q.FieldByName('path').AsString;
        Result[N].Name := Q.FieldByName('name').AsString;
        { 时间列与 QueryHistory 同款三段式兜底（REAL 正常, 文本兜旧库, NULL 归零） }
        F := Q.FieldByName('start_time');
        if F.IsNull then
          Result[N].StartTime := 0
        else if F.DataType = ftFloat then
          Result[N].StartTime := F.AsFloat
        else
          Result[N].StartTime := StrToDateTimeDef(F.AsString, 0);
        F := Q.FieldByName('end_time');
        if F.IsNull then
          Result[N].EndTime := 0
        else if F.DataType = ftFloat then
          Result[N].EndTime := F.AsFloat
        else
          Result[N].EndTime := StrToDateTimeDef(F.AsString, 0);
        Result[N].Received := Q.FieldByName('received').AsLargeInt;
        Result[N].Total := Q.FieldByName('total').AsLargeInt;
        Result[N].State := Q.FieldByName('state').AsInteger;
        Inc(N);
        Q.Next;
      end;
    except
      on E: Exception do
      begin
        Logger.Error('查询下载记录失败: %s - %s', [E.ClassName, E.Message]);
        SetLength(Result, 0);    // 查询失败不应打断启动, 返回空列表
      end;
    end;
  finally
    Q.Free;
  end;
end;

{ ---- 书签 ---- }

function TFHHistoryDB.BookmarkExists(const AUrl: string): Boolean;
begin
  Result := False;
  if AUrl = '' then Exit;
  try
    Result := FConn.ExecSQLScalar(
      'SELECT count(*) FROM fh_bookmarks WHERE url = :u', [AUrl]) > 0;
  except
    on E: Exception do
      Logger.Error('查询书签失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

procedure TFHHistoryDB.AddBookmark(const AUrl, ATitle: string);
begin
  if AUrl = '' then Exit;
  if BookmarkExists(AUrl) then Exit;   // 幂等: 已收藏不再插（不更新标题）
  try
    FConn.ExecSQL(
      'INSERT INTO fh_bookmarks(url, title, created_at) VALUES(:u, :t, :ca)',
      [AUrl, ATitle, Now]);
  except
    on E: Exception do
      Logger.Error('添加书签失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

procedure TFHHistoryDB.UpdateBookmark(const AOldUrl, ANewUrl, ATitle: string);
begin
  if AOldUrl = '' then Exit;
  try
    FConn.ExecSQL(
      'UPDATE fh_bookmarks SET url = :nu, title = :t WHERE url = :ou',
      [ANewUrl, ATitle, AOldUrl]);
  except
    on E: Exception do
      Logger.Error('修改书签失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

function TFHHistoryDB.QueryBookmarks(const AKeyword: string;
  AMaxCount: Integer): TFHBookmarkEntries;
var
  Q: TFDQuery;
  F: TField;
  Kw: string;
  N: Integer;
begin
  SetLength(Result, 0);
  if AMaxCount <= 0 then
    AMaxCount := 5000;
  Q := TFDQuery.Create(nil);
  try
    try
    Q.Connection := FConn;
    Kw := Trim(AKeyword);
    { 与 QueryHistory 同套子串匹配（title 可能为 NULL, ifnull 兜住） }
    if Kw = '' then
      Q.SQL.Text :=
        'SELECT id, url, title, created_at FROM fh_bookmarks ' +
        'ORDER BY created_at DESC LIMIT ' + IntToStr(AMaxCount)
    else
    begin
      Q.SQL.Text :=
        'SELECT id, url, title, created_at FROM fh_bookmarks ' +
        'WHERE instr(lower(url || '' '' || ifnull(title, '''')), lower(:kw)) > 0 ' +
        'ORDER BY created_at DESC LIMIT ' + IntToStr(AMaxCount);
      Q.ParamByName('kw').AsString := Kw;
    end;
    Q.Open;
    N := 0;
    while not Q.Eof do
    begin
      SetLength(Result, N + 1);
      Result[N].Id := Q.FieldByName('id').AsLargeInt;
      Result[N].Url := Q.FieldByName('url').AsString;
      Result[N].Title := Q.FieldByName('title').AsString;
      F := Q.FieldByName('created_at');
      if F.IsNull then
        Result[N].CreatedAt := 0
      else if F.DataType = ftFloat then
        Result[N].CreatedAt := F.AsFloat
      else
        Result[N].CreatedAt := StrToDateTimeDef(F.AsString, 0);
      Inc(N);
      Q.Next;
    end;
    except
      on E: Exception do
      begin
        Logger.Error('查询书签列表失败: %s - %s', [E.ClassName, E.Message]);
        SetLength(Result, 0);
      end;
    end;
  finally
    Q.Free;
  end;
end;

procedure TFHHistoryDB.DeleteBookmarkUrl(const AUrl: string);
begin
  if AUrl = '' then Exit;
  try
    FConn.ExecSQL('DELETE FROM fh_bookmarks WHERE url = :u', [AUrl]);
  except
    on E: Exception do ;
  end;
end;

initialization

finalization
  GHistoryDB.Free;
  GHistoryDB := nil;
  GWaitCursor.Free;
  GWaitCursor := nil;

end.