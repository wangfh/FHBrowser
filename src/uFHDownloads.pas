{==============================================================================
  单元: uFHDownloads
  职责: 浏览器下载功能的支撑层 —— 下载列表（CEF 事件写入, 界面轮询读取）、
        下载目录定位、文件去重命名, 以及一个"下载内容"窗口。
  设计: 下载项数据放在全局单例 Downloads 里, 与窗口解耦 —— 窗口关了下载
        继续进行, 重新打开窗口能看到全部记录。窗口用 300ms 轮询刷新,
        不做跨线程 UI 操作。
        下载项持有 ICefDownloadItemCallback, 窗口可据此取消正在进行的下载。
==============================================================================}
unit uFHDownloads;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, System.Math,
  System.Types,
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, Winapi.ShlObj,
  Winapi.ActiveX,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics, Vcl.Menus,
  uCEFInterfaces;

type
  TFHDownloadState = (dsInProgress, dsComplete, dsCanceled, dsInterrupted);

  TFHDownloadItem = class
  public
    Id: Cardinal;                  // CEF download id
    Url: string;
    Path: string;                  // 目标文件完整路径
    Name: string;                  // 显示名（文件名）
    Percent: Integer;              // 0..100, -1 = 总大小未知
    Received: Int64;
    Total: Int64;
    State: TFHDownloadState;
    StartTime: TDateTime;          // 开始时间（算速度/剩余时间用）
    Speed: Int64;                  // 字节/秒, 0 = 未知
    Eta: Int64;                    // 剩余秒, -1 = 未知
    EndTime: TDateTime;            // 完成/取消/中断时间（"x分钟前"用）
    Paused: Boolean;               // 暂停态（CEF 109 的 DownloadItem 无 IsPaused, 本地维护）
    Callback: ICefDownloadItemCallback;  // 取消/暂停/继续用; 下载结束后清空
  end;

  { 全局下载列表。CEF 事件回调在主线程（CEF4Delphi 非 MultiThreadedApp 模式,
    CEF UI 线程 = VCL 主线程）, 窗口轮询也在主线程 —— 无需加锁 }
  TFHDownloadList = class
  private
    FItems: TObjectList<TFHDownloadItem>;
    function GetItem(Index: Integer): TFHDownloadItem;
    function GetCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { 按 CEF download id 线性查找; 无则返回 nil }
    function ById(AId: Cardinal): TFHDownloadItem;
    { 新增下载项（下载开始时调）, 插到列表头 —— 最新的排最上 }
    procedure Add(AId: Cardinal; const AUrl, APath, AName: string);
    { 用 CEF 的最新状态刷新对应项。ACallback 用于取消（每次 Update 都传, CEF 保证有效）。
      返回 True 表示该项**刚刚**变成完成态 —— 调用方据此记一条完成日志 }
    function Update(const ADownloadItem: ICefDownloadItem;
      const ACallback: ICefDownloadItemCallback): Boolean;
    { 取消指定下载。找不到或已结束则静默忽略 }
    procedure Cancel(AId: Cardinal);
    { 暂停/继续指定下载（CEF 的 DownloadItemCallback.Pause/Resume） }
    procedure SetPaused(AId: Cardinal; APaused: Boolean);
    { 从列表移除指定项（仅允许移除非进行中的项） }
    procedure Remove(AId: Cardinal);
    { 清除所有非进行中的项（已完成/已取消/已中断） }
    procedure ClearFinished;
    { 重启恢复: 从 UserData\History.db 载入历史下载记录（uBrowserMain 启动时调）。
      写侧在下载事件回调（AddDownload/UpdateDownload）, 此前缺加载侧 →
      程序重启后下载记录消失 }
    procedure LoadFromDb;
    property Items[Index: Integer]: TFHDownloadItem read GetItem; default;
    property Count: Integer read GetCount;
  end;

function Downloads: TFHDownloadList;

{ 下载目录（设置里指定了自定义目录则用之, 否则系统"下载"文件夹） }
function DownloadsDir: string;

{ Downloads 目录下不重名的目标路径: 存在同名文件时追加 (1) (2) ... }
function UniqueDownloadPath(const AFileName: string): string;

{ 打开"下载内容"窗口（已开则前置）。
  ABringToFront = False 时仅确保窗口可见, 不抢焦点（用于下载进行中的非打扰提示） }
procedure ShowDownloadsForm(ABringToFront: Boolean = True);

{ "近期下载记录"气泡（工具栏下载按钮下方）:
  上半部分为进行中的下载（文件名 / 进度条 / 速度 / 暂停·继续 / 取消）,
  下半部分为最近完成的文件（文件名 / 大小 / 完成时长; 点击文件名或打开
  图标打开文件, 文件夹图标定位到所在目录）, 底部"完整的下载记录"打开
  ShowDownloadsForm。AAnchorScreen = 下载按钮的屏幕矩形;
  AToggle = True 时若气泡已显示则关闭（按钮点击的开关语义） }
procedure ShowDownloadsBubble(const AAnchorScreen: TRect;
  AToggle: Boolean = False);
procedure HideDownloadsBubble;
function IsDownloadsBubbleVisible: Boolean;

implementation

uses
  uLogger, uFHSettings, uFHChromeWidgets, uFHHistoryDB, uFHChromeMenu,
  uFHChromeTabs, Vcl.ClipBrd, Winapi.GDIPOBJ, Winapi.GDIPAPI;

var
  GList: TFHDownloadList = nil;
  GForm: TForm = nil;

{ 下载窗口/气泡共用的"打开文件 / 定位所在文件夹"（实现见本单元后半部） }
procedure OpenDownloadFile(const APath: string); forward;
procedure OpenContainingFolder(const APath: string); forward;

const
  FOLDERID_Downloads: TGUID = '{374DE290-123F-4565-9164-39C4925E467B}';
  { 弹窗边框线（Chrome 灰 #DADCE0, 与历史记录窗口一致） }
  FH_DL_EDGE = TColor($E0DCDA);
  { 下载窗口 6 列表格: 各列左缘（96 DPI 逻辑 px, 列表客户区坐标）。
    顺序: 复选框+文件名 | 大小 | 格式 | 下载时间 | 文件位置 | 操作。
    文件位置列弹性到操作区, 操作列固定右缘。行首 16..42 预留给复选框 }
  C_DL_X_NAME   = 46;
  C_DL_X_SIZE   = 280;
  C_DL_X_FORMAT = 395;
  C_DL_X_TIME   = 458;
  C_DL_X_LOC    = 596;
  C_DL_BTNHOVER = TColor($DCD7D4);  // #D4D7DC 图标圆钮悬停底（与书签/历史同款）
  C_DL_SELBG    = TColor($FEE8F0);  // #E8F0FE 选中行浅蓝底（Chrome 同款）

{ 全局下载列表单例: 首次访问时创建 }
function Downloads: TFHDownloadList;
begin
  if GList = nil then
    GList := TFHDownloadList.Create;
  Result := GList;
end;

{ 下载目录: 设置里指定了自定义目录则用之, 否则系统"下载"文件夹
  （SHGetKnownFolderPath, 失败退回 %USERPROFILE%\Downloads —— 兜底在
  uFHSettings.EffectiveDownloadDir 里实现） }
function DownloadsDir: string;
begin
  Result := Settings.EffectiveDownloadDir;
end;

function UniqueDownloadPath(const AFileName: string): string;
var
  Dir, Base, Ext, Candidate: string;
  I: Integer;
begin
  Dir := DownloadsDir;
  Base := ChangeFileExt(AFileName, '');
  Ext := ExtractFileExt(AFileName);
  Candidate := Dir + AFileName;
  I := 1;
  while FileExists(Candidate) do
  begin
    Candidate := Format('%s%s (%d)%s', [Dir, Base, I, Ext]);
    Inc(I);
  end;
  Result := Candidate;
end;

{ ---- TFHDownloadList ------------------------------------------------------ }

{ 构造: 建拥有式下载项列表 }
constructor TFHDownloadList.Create;
begin
  inherited Create;
  FItems := TObjectList<TFHDownloadItem>.Create(True);
end;

{ 析构: 释放列表（连同全部下载项） }
destructor TFHDownloadList.Destroy;
begin
  FItems.Free;
  inherited;
end;

{ 索引器实现 }
function TFHDownloadList.GetItem(Index: Integer): TFHDownloadItem;
begin
  Result := FItems[Index];
end;

{ 条目数实现 }
function TFHDownloadList.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TFHDownloadList.ById(AId: Cardinal): TFHDownloadItem;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FItems.Count - 1 do
    if FItems[I].Id = AId then
      Exit(FItems[I]);
end;

procedure TFHDownloadList.Add(AId: Cardinal; const AUrl, APath, AName: string);
var
  Item: TFHDownloadItem;
begin
  Item := TFHDownloadItem.Create;
  Item.Id := AId;
  Item.Url := AUrl;
  Item.Path := APath;
  Item.Name := AName;
  Item.Percent := 0;
  Item.State := dsInProgress;
  Item.StartTime := Now;
  Item.Speed := 0;
  Item.Eta := -1;
  Item.EndTime := 0;
  Item.Paused := False;
  FItems.Insert(0, Item);            // 最新的排最上（Chrome 下载列表同序）
end;

{ 重启恢复: 库按 start_time 倒序返回; 反向遍历（旧→新）逐条插头 →
  列表头 = 最新, 与运行期 Add 的"最新的排最上"同序。
  恢复项无 CEF 回话（Callback=nil, 不能取消/续传）, state=0 的进行中
  残留标记为已中断（CEF 会话已断, Chrome 同款语义） }
procedure TFHDownloadList.LoadFromDb;
var
  Rows: TFHDownloadDbRows;
  I: Integer;
  Item: TFHDownloadItem;
begin
  try
    Rows := HistoryDB.QueryDownloads;
  except
    on E: Exception do
    begin
      Logger.Error('加载下载记录失败: %s - %s', [E.ClassName, E.Message]);
      Exit;
    end;
  end;
  for I := High(Rows) downto 0 do
  begin
    Item := TFHDownloadItem.Create;
    Item.Id := Rows[I].Id;
    Item.Url := Rows[I].Url;
    Item.Path := Rows[I].Path;
    Item.Name := Rows[I].Name;
    Item.StartTime := Rows[I].StartTime;
    Item.EndTime := Rows[I].EndTime;
    Item.Received := Rows[I].Received;
    Item.Total := Rows[I].Total;
    if Rows[I].Total > 0 then
      Item.Percent := Min(100, Rows[I].Received * 100 div Rows[I].Total)
    else
      Item.Percent := -1;
    case Rows[I].State of
      1: Item.State := dsComplete;
      2: Item.State := dsCanceled;
      3: Item.State := dsInterrupted;
    else
      Item.State := dsInterrupted;
    end;
    Item.Speed := 0;
    Item.Eta := -1;
    Item.Paused := False;
    FItems.Insert(0, Item);
  end;
end;

function TFHDownloadList.Update(const ADownloadItem: ICefDownloadItem;
  const ACallback: ICefDownloadItemCallback): Boolean;
var
  Item: TFHDownloadItem;
  WasComplete: Boolean;
  Dt: Double;
  NewReceived: Int64;
begin
  Result := False;
  if ADownloadItem = nil then Exit;
  Item := ById(ADownloadItem.Id);
  if Item = nil then Exit;
  WasComplete := Item.State = dsComplete;

  NewReceived := ADownloadItem.ReceivedBytes;
  { 速度/ETA: 用"自开始以来"的平均速率, 比瞬时速率稳, 不抖动;
    暂停时不显示速度/剩余时间 }
  Dt := (Now - Item.StartTime) * SecsPerDay;
  if Item.Paused then
  begin
    Item.Speed := 0;
    Item.Eta := -1;
  end
  else if Dt > 0.5 then
  begin
    Item.Speed := Round(NewReceived / Dt);
    if (Item.Speed > 0) and (ADownloadItem.TotalBytes > 0) then
      Item.Eta := (ADownloadItem.TotalBytes - NewReceived) div Item.Speed
    else
      Item.Eta := -1;
  end;

  Item.Received := NewReceived;
  Item.Total := ADownloadItem.TotalBytes;
  Item.Percent := ADownloadItem.PercentComplete;
  Item.Callback := ACallback;       // 留着给"取消/暂停/继续"用; CEF 在下载结束后释放

  if ADownloadItem.IsComplete then
  begin
    Item.State := dsComplete;
    Item.Percent := 100;
    Item.Speed := 0;
    Item.Eta := 0;
    Item.EndTime := Now;
    Item.Paused := False;
    Item.Callback := nil;           // 已完成, 不再需要
  end
  else if ADownloadItem.IsCanceled then
  begin
    Item.State := dsCanceled;
    Item.Speed := 0;
    Item.Eta := -1;
    Item.EndTime := Now;
    Item.Paused := False;
    Item.Callback := nil;
  end
  else if ADownloadItem.IsInProgress then
    Item.State := dsInProgress
  else
  begin
    Item.State := dsInterrupted;
    Item.Speed := 0;
    Item.Eta := -1;
    Item.EndTime := Now;
    Item.Paused := False;
    Item.Callback := nil;
  end;
  Result := (Item.State = dsComplete) and not WasComplete;
end;

procedure TFHDownloadList.SetPaused(AId: Cardinal; APaused: Boolean);
var
  Item: TFHDownloadItem;
begin
  Item := ById(AId);
  if (Item = nil) or (Item.State <> dsInProgress) or (Item.Callback = nil) then
    Exit;
  try
    if APaused then
      Item.Callback.Pause
    else
      Item.Callback.Resume;
    Item.Paused := APaused;
    if APaused then
    begin
      Item.Speed := 0;
      Item.Eta := -1;
    end;
  except
    on E: Exception do
      Logger.Error('暂停/继续下载失败 (id=%d): %s - %s',
        [AId, E.ClassName, E.Message]);
  end;
end;

procedure TFHDownloadList.Cancel(AId: Cardinal);
var
  Item: TFHDownloadItem;
begin
  Item := ById(AId);
  if (Item <> nil) and (Item.State = dsInProgress) and (Item.Callback <> nil) then
  try
    Item.Callback.Cancel;
    Item.State := dsCanceled;
    Item.Callback := nil;
  except
    on E: Exception do
      Logger.Error('取消下载失败 (id=%d): %s - %s', [AId, E.ClassName, E.Message]);
  end;
end;

procedure TFHDownloadList.Remove(AId: Cardinal);
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if FItems[I].Id = AId then
    begin
      if FItems[I].State = dsInProgress then Exit;   // 进行中的不允许直接移除
      FItems.Delete(I);
      Exit;
    end;
end;

procedure TFHDownloadList.ClearFinished;
var
  I: Integer;
begin
  for I := FItems.Count - 1 downto 0 do
    if FItems[I].State <> dsInProgress then
      FItems.Delete(I);
end;

{ ---- 显示辅助 ------------------------------------------------------------- }

{ 字节数人性化显示: GB/MB/KB/B 自适应档位 }
function FormatBytes(N: Int64): string;
const
  KB: Int64 = 1024;
  MB: Int64 = 1024 * 1024;
  GB: Int64 = 1024 * 1024 * 1024;
begin
  if N >= GB then
    Result := Format('%.2f GB', [N / GB])
  else if N >= MB then
    Result := Format('%.1f MB', [N / MB])
  else if N >= KB then
    Result := Format('%.0f KB', [N / KB])
  else
    Result := Format('%d B', [N]);
end;

{ 剩余时间人性化显示（x秒 / x分x秒 / x时x分）; 负数(未知)返回空串 }
function FormatEta(S: Int64): string;
begin
  if S < 0 then
    Result := ''
  else if S < 60 then
    Result := Format('%d秒', [S])
  else if S < 3600 then
    Result := Format('%d分%d秒', [S div 60, S mod 60])
  else
    Result := Format('%d时%d分', [S div 3600, (S mod 3600) div 60]);
end;

{ 完成时间的人性化显示: 刚刚 / x 分钟前 / x 小时前 / x 天前 }
function FormatRelativeTime(ATime: TDateTime): string;
var
  Secs: Int64;
begin
  if ATime <= 0 then
    Exit('');
  Secs := Round((Now - ATime) * SecsPerDay);
  if Secs < 0 then
    Secs := 0;
  if Secs < 60 then
    Result := '刚刚'
  else if Secs < 3600 then
    Result := Format('%d 分钟前', [Secs div 60])
  else if Secs < 86400 then
    Result := Format('%d 小时前', [Secs div 3600])
  else
    Result := Format('%d 天前', [Secs div 86400]);
end;

{ 下载项在列表中的一行文本: 已完成/已取消/已中断给状态; 进行中带
  百分比 + 已下载/总大小 + 速度 + 剩余时间 }
function ItemText(Item: TFHDownloadItem): string;
begin
  case Item.State of
    dsComplete:    Result := Format('%s  —  已完成 (%s)', [Item.Name, FormatBytes(Item.Total)]);
    dsCanceled:    Result := Format('%s  —  已取消', [Item.Name]);
    dsInterrupted: Result := Format('%s  —  已中断', [Item.Name]);
  else
    if Item.Percent >= 0 then
      Result := Format('%s  —  %d%% (%s / %s)', [Item.Name, Item.Percent,
        FormatBytes(Item.Received), FormatBytes(Item.Total)])
    else
      Result := Format('%s  —  已下载 %s', [Item.Name, FormatBytes(Item.Received)]);
    if Item.Speed > 0 then
    begin
      Result := Result + Format('  %s/s', [FormatBytes(Item.Speed)]);
      if Item.Eta > 0 then
        Result := Result + Format('  剩余 %s', [FormatEta(Item.Eta)]);
    end;
  end;
end;

{ ---- 下载窗口 ------------------------------------------------------------- }

type
  { 行内操作: 打开文件按钮 / 删除按钮（仅删记录） / "⋮"菜单按钮（弹出
    打开文件位置·删除记录·删除记录和文件·复制下载链接 列表） }
  TFHDlAction = (dlaNone, dlaOpen, dlaDelete, dlaMenu);

  { 下载记录列表: 6 列表格自绘 —— 复选框+文件名 / 大小 / 格式 / 下载时间 /
    文件位置 / 操作（打开文件 + 删除 + "⋮"菜单）。支持多选:
    表头全选框 + 选中态表头出现"删除记录 / 删除记录和文件"批量按钮 }
  TFHDownloadsList = class(TCustomControl)
  private
    FRows: TArray<TFHDownloadItem>;
    FTops: TArray<Integer>;
    FContentH: Integer;
    FOffset: Integer;
    FHotRow: Integer;
    FHotAct: TFHDlAction;
    FScrollHot: Boolean;
    FScrollDragging: Boolean;
    FScrollDragY: Integer;
    FScrollDragOffset: Integer;
    FMenu: TFHMenu;                  // 行内"⋮"菜单（Owner=Self）
    FMenuId: Cardinal;               // 弹菜单时的下载项快照（防刷新后行号错位）
    FMenuPath: string;
    FMenuUrl: string;
    FSelected: TList<Cardinal>;      // 选中的下载项 Id 集合（按 Id 防 RefreshData 错位）
    FChkHotRow: Integer;             // 悬停中的行复选框（-1 = 无）
    FHeadChkHot: Boolean;            // 表头全选框悬停
    FHeadBtnHot: Integer;            // 选择态表头按钮悬停: 0=无 1=删记录 2=删记录和文件
    function Px(V: Integer): Integer;
    function RowHeight: Integer;
    function HeaderHeight: Integer;
    function MaxOffset: Integer;
    function ThumbRect: TRect;
    function IndexAtY(Y: Integer): Integer;
    function ColX(ACol: Integer): Integer;
    function ActionRect(ARow: Integer; AAct: TFHDlAction): TRect;
    function ActionAtPos(ARow, X, Y: Integer): TFHDlAction;
    function CheckBoxRect(ARow: Integer): TRect;
    function HeaderChkRect: TRect;
    function HeaderBtnRect(AIndex: Integer): TRect;
    function IsSelected(ARow: Integer): Boolean;
    function SelectedCount: Integer;
    procedure ScrollTo(AOffset: Integer);
    procedure SetFontPx(ASize: Integer; ABold: Boolean; AColor: TColor);
    procedure FillAA(const R: TRect; ARadius: Single; AColor: TColor);
    procedure DrawTextRect(const S: string; const R: TRect; AFlags: Cardinal);
    procedure DoAction(ARow: Integer; AAct: TFHDlAction);
    procedure DoDelete(AId: Cardinal; const APath: string;
      ADeleteFile: Boolean);
    procedure DeleteById(AId: Cardinal; const APath: string;
      ADeleteFile: Boolean);
    procedure DeleteSelected(ADeleteFile: Boolean);
    procedure ToggleSelect(ARow: Integer);
    procedure ToggleSelectAll;
    procedure DrawActionButton(const R: TRect; const ACaption: string;
      AHot, AEnabled, ADanger: Boolean);
    procedure DrawMenuDots(const R: TRect; AHot: Boolean);
    procedure DrawTrashIcon(const R: TRect; AHot: Boolean);
    procedure DrawCheckBox(const R: TRect; AState: Integer; AHot: Boolean);
    procedure DrawHeader;
    procedure DrawRow(AIndex, ATop: Integer);
    procedure DrawEmpty;
    procedure DrawScrollBar;
    procedure ShowRowMenu(ARow: Integer; X, Y: Integer);
    procedure MenuFolder(Sender: TObject);
    procedure MenuDelRec(Sender: TObject);
    procedure MenuDelFile(Sender: TObject);
    procedure MenuCopyLink(Sender: TObject);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { 从全局 Downloads 重建行并刷新 }
    procedure RefreshData;
  end;

  TFHDownloadsForm = class(TForm)
  private
    FScale: Single;
    FTitle: TLabel;
    FList: TFHDownloadsList;
    FBtnOpenDir: TLabel;
    FBtnClear: TLabel;
    FTimer: TTimer;
    FLastSig: string;
    FCloseHot: Boolean;              // 鼠标悬停在标题栏关闭按钮上
    function Px(V: Integer): Integer;
    function CaptionH: Integer;
    function CloseBtnRect: TRect;
    procedure BuildUi;
    procedure LayoutUi;
    procedure RefreshTick(Sender: TObject);
    procedure OpenDirClick(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure FormPaint(Sender: TObject);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
    procedure WMNCCalcSize(var Message: TWMNCCalcSize); message WM_NCCALCSIZE;
    procedure WMNCActivate(var Message: TWMNCActivate); message WM_NCACTIVATE;
    procedure WMGetMinMaxInfo(var Message: TWMGetMinMaxInfo);
      message WM_GETMINMAXINFO;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure WndProc(var Message: TMessage); override;
    procedure Resize; override;
    procedure DoShow; override;
    procedure DoClose(var Action: TCloseAction); override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
  end;

{ ---- 下载记录列表: 自绘 ---------------------------------------------------- }

{ GDI+ 画布（抗锯齿; GDI+ 不可用返回 nil） }
function MakeGraphics(ACanvas: TCanvas): TGPGraphics;
begin
  Result := nil;
  if (ACanvas = nil) or (ACanvas.Handle = 0) or not EnsureGdiPlus then Exit;
  Result := TGPGraphics.Create(ACanvas.Handle);
  Result.SetSmoothingMode(SmoothingModeAntiAlias);
end;

{ 抗锯齿实心圆（GDI+ 优先; 不可用回退 GDI Ellipse） }
procedure FillCircleAA(ACanvas: TCanvas; const R: TRect; AColor: TColor);
var
  G: TGPGraphics;
  B: TGPSolidBrush;
begin
  G := MakeGraphics(ACanvas);
  if G = nil then
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := AColor;
    ACanvas.Ellipse(R);
    ACanvas.Brush.Style := bsClear;
    Exit;
  end;
  try
    B := TGPSolidBrush.Create(ColorToARGB(AColor));
    try
      G.FillEllipse(B, R.Left + 0.5, R.Top + 0.5,
        R.Right - R.Left - 1, R.Bottom - R.Top - 1);
    finally
      B.Free;
    end;
  finally
    G.Free;
  end;
end;

{ 构造: 双缓冲自绘列表, 建选中 Id 集合 }
constructor TFHDownloadsList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  Font.Name := 'Segoe UI';
  FHotRow := -1;
  FHotAct := dlaNone;
  FChkHotRow := -1;
  FMenuId := 0;
  FSelected := TList<Cardinal>.Create;
end;

{ 析构: 释放选中 Id 集合 }
destructor TFHDownloadsList.Destroy;
begin
  FSelected.Free;
  inherited;
end;

{ 96 DPI 基准逻辑像素 → 窗口实际像素（无句柄期按屏幕 DPI 兜底） }
function TFHDownloadsList.Px(V: Integer): Integer;
var
  DPI: Integer;
  DC: HDC;
begin
  DPI := 0;
  if HandleAllocated then
  begin
    DC := GetDC(Handle);
    DPI := GetDeviceCaps(DC, LOGPIXELSX);
    ReleaseDC(Handle, DC);
  end;
  if DPI <= 0 then
    DPI := Screen.PixelsPerInch;
  if DPI <= 0 then
    DPI := 96;
  Result := MulDiv(V, DPI, 96);
  if (V > 0) and (Result = 0) then
    Result := 1;
end;

{ 行高（固定 40 逻辑像素） }
function TFHDownloadsList.RowHeight: Integer;
begin
  Result := Px(40);
end;

{ 固定表头高度（列标题行, 不随内容滚动） }
function TFHDownloadsList.HeaderHeight: Integer;
begin
  Result := Px(36);
end;

{ 最大滚动偏移 = 内容高 + 表头 - 客户区高（下限 0） }
function TFHDownloadsList.MaxOffset: Integer;
begin
  Result := Max(0, FContentH + HeaderHeight - ClientHeight);
end;

{ 滚动条滑块矩形（表头下方轨道, 高度按可视比例, 最小 40px） }
function TFHDownloadsList.ThumbRect: TRect;
var
  TrackTop, TrackH, ThumbH, Top, W: Integer;
begin
  W := Px(8);
  TrackTop := HeaderHeight + Px(8);
  TrackH := Max(1, ClientHeight - HeaderHeight - Px(16));
  ThumbH := Max(Px(40), MulDiv(TrackH, ClientHeight - HeaderHeight, Max(1, FContentH)));
  if ThumbH > TrackH then
    ThumbH := TrackH;
  Top := TrackTop + MulDiv(TrackH - ThumbH, FOffset, Max(1, MaxOffset));
  Result := Rect(ClientWidth - W - Px(2), Top, ClientWidth - Px(2), Top + ThumbH);
end;

{ 客户区 y → 行索引（含表头与滚动偏移换算）; 未命中返回 -1 }
function TFHDownloadsList.IndexAtY(Y: Integer): Integer;
var
  I, T: Integer;
begin
  Result := -1;
  for I := 0 to High(FTops) do
  begin
    T := FTops[I] - FOffset + HeaderHeight;
    if (Y >= T) and (Y < T + RowHeight) then
      Exit(I);
  end;
end;

{ 6 列左缘 X（客户区坐标）。0=文件名 1=大小 2=格式 3=下载时间 4=文件位置 5=操作 }
function TFHDownloadsList.ColX(ACol: Integer): Integer;
begin
  case ACol of
    1: Result := Px(C_DL_X_SIZE);
    2: Result := Px(C_DL_X_FORMAT);
    3: Result := Px(C_DL_X_TIME);
    4: Result := Px(C_DL_X_LOC);
    5: Result := ActionRect(0, dlaOpen).Left - Px(16);
  else
    Result := Px(C_DL_X_NAME);
  end;
end;

{ 操作列三按钮位置（右对齐列表右缘）: "打开文件"文本按钮(76x24) +
  垃圾桶圆钮(28x28) + "⋮"圆钮(28x28), 图标钮间距 6 }
function TFHDownloadsList.ActionRect(ARow: Integer; AAct: TFHDlAction): TRect;
var
  Top, H, RightEdge: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if (ARow < 0) or (ARow > High(FTops)) then Exit;
  Top := FTops[ARow] - FOffset + HeaderHeight;
  RightEdge := ClientWidth - Px(16);
  case AAct of
    dlaMenu:
      Result := Rect(RightEdge - Px(28), Top + (RowHeight - Px(28)) div 2,
        RightEdge, Top + (RowHeight + Px(28)) div 2);
    dlaDelete:
      Result := Rect(RightEdge - Px(62), Top + (RowHeight - Px(28)) div 2,
        RightEdge - Px(34), Top + (RowHeight + Px(28)) div 2);
    dlaOpen:
      begin
        H := Px(24);
        Result := Rect(RightEdge - Px(144), Top + (RowHeight - H) div 2,
          RightEdge - Px(68), Top + (RowHeight + H) div 2);
      end;
  end;
end;

{ 坐标 → 行内操作（打开文件/删除/⋮菜单）; 不在任何按钮上返回 dlaNone }
function TFHDownloadsList.ActionAtPos(ARow, X, Y: Integer): TFHDlAction;
var
  P: TPoint;
begin
  Result := dlaNone;
  if ARow < 0 then Exit;
  P := Point(X, Y);
  if PtInRect(ActionRect(ARow, dlaOpen), P) then Exit(dlaOpen);
  if PtInRect(ActionRect(ARow, dlaDelete), P) then Exit(dlaDelete);
  if PtInRect(ActionRect(ARow, dlaMenu), P) then Exit(dlaMenu);
end;

{ 行首复选框（18x18, X=Px(20), 垂直居中） }
function TFHDownloadsList.CheckBoxRect(ARow: Integer): TRect;
var
  Top: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if (ARow < 0) or (ARow > High(FTops)) then Exit;
  Top := FTops[ARow] - FOffset + HeaderHeight;
  Result := Rect(Px(20), Top + (RowHeight - Px(18)) div 2,
    Px(38), Top + (RowHeight + Px(18)) div 2);
end;

{ 表头全选框（与行复选框同 X, 垂直居中于表头） }
function TFHDownloadsList.HeaderChkRect: TRect;
begin
  Result := Rect(Px(20), (HeaderHeight - Px(18)) div 2,
    Px(38), (HeaderHeight + Px(18)) div 2);
end;

{ 选择态表头右侧两个批量按钮: 0=删除记录(76) 1=删除记录和文件(104), 间距 8 }
function TFHDownloadsList.HeaderBtnRect(AIndex: Integer): TRect;
var
  RightEdge, H: Integer;
begin
  H := Px(24);
  RightEdge := ClientWidth - Px(16);
  if AIndex = 0 then
    Result := Rect(RightEdge - Px(188), (HeaderHeight - H) div 2,
      RightEdge - Px(112), (HeaderHeight + H) div 2)
  else
    Result := Rect(RightEdge - Px(104), (HeaderHeight - H) div 2,
      RightEdge, (HeaderHeight + H) div 2);
end;

{ 指定行是否在选中集合（按下载 Id 判, 免疫刷新错位） }
function TFHDownloadsList.IsSelected(ARow: Integer): Boolean;
begin
  Result := (ARow >= 0) and (ARow <= High(FRows)) and (FRows[ARow] <> nil)
    and (FSelected.IndexOf(FRows[ARow].Id) >= 0);
end;

{ 选中项数 }
function TFHDownloadsList.SelectedCount: Integer;
begin
  Result := FSelected.Count;
end;

{ 滚动到指定偏移（夹取, 值不变不重绘; 滚动后清行悬停态） }
procedure TFHDownloadsList.ScrollTo(AOffset: Integer);
begin
  AOffset := EnsureRange(AOffset, 0, MaxOffset);
  if AOffset = FOffset then Exit;
  FOffset := AOffset;
  FHotRow := -1;
  FHotAct := dlaNone;
  Invalidate;
end;

procedure TFHDownloadsList.RefreshData;
var
  I, N: Integer;
begin
  SetLength(FRows, Downloads.Count);
  SetLength(FTops, Downloads.Count);
  N := 0;
  for I := 0 to Downloads.Count - 1 do
  begin
    FRows[I] := Downloads[I];
    FTops[I] := N;
    Inc(N, RowHeight);
  end;
  FContentH := N;
  { 清理失效选中: 选中项可能被外部（下载气泡/菜单）删除 }
  for I := FSelected.Count - 1 downto 0 do
    if Downloads.ById(FSelected[I]) = nil then
      FSelected.Delete(I);
  FOffset := EnsureRange(FOffset, 0, MaxOffset);
  Invalidate;
end;

{ 按像素设画布字体（Segoe UI + 字号/加粗/颜色） }
procedure TFHDownloadsList.SetFontPx(ASize: Integer; ABold: Boolean;
  AColor: TColor);
begin
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.PixelsPerInch := Px(96);
  Canvas.Font.Height := -Px(ASize);
  if ABold then
    Canvas.Font.Style := [fsBold]
  else
    Canvas.Font.Style := [];
  Canvas.Font.Color := AColor;
end;

{ 抗锯齿圆角矩形填充（GDI+ 优先, 回退 GDI FillRect） }
procedure TFHDownloadsList.FillAA(const R: TRect; ARadius: Single;
  AColor: TColor);
begin
  if not FillRoundRectAA(Canvas, R.Left, R.Top, R.Right, R.Bottom, ARadius,
    AColor, clNone, 0) then
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := AColor;
    Canvas.FillRect(R);
  end;
end;

{ 透明背景画文本（空串跳过） }
procedure TFHDownloadsList.DrawTextRect(const S: string; const R: TRect;
  AFlags: Cardinal);
var
  TR: TRect;
begin
  if S = '' then Exit;
  TR := R;
  Canvas.Brush.Style := bsClear;
  Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), TR, AFlags);
  Canvas.Brush.Style := bsSolid;
end;

{ 画文字操作按钮: 蓝/红前景 + 悬停浅底圆角 + 禁用灰
  （"打开文件"/批量删除按钮共用） }
procedure TFHDownloadsList.DrawActionButton(const R: TRect;
  const ACaption: string; AHot, AEnabled, ADanger: Boolean);
var
  Fg, Bg: TColor;
begin
  if R.Right <= R.Left then Exit;
  if ADanger then
    Fg := TColor($2530D9)          // #D93025 Google 红
  else
    Fg := FH_FOCUS;
  if not AEnabled then
    Fg := FH_TEXT_DIS;
  if AHot and AEnabled then
  begin
    if ADanger then
      Bg := TColor($E6E8FC)        // #FCE8E6 浅红悬停底
    else
      Bg := FH_HOVER_BG;
    FillAA(R, Px(4), Bg);
  end;
  SetFontPx(12, False, Fg);
  DrawTextRect(ACaption, R,
    DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
end;

{ 画行内"⋮"菜单按钮: 悬停圆底 + 竖排三点（GDI+ 抗锯齿, 回退 GDI） }
procedure TFHDownloadsList.DrawMenuDots(const R: TRect; AHot: Boolean);
var
  Clr: TColor;
  CX, Y0, D, I: Integer;
  G: TGPGraphics;
  B: TGPSolidBrush;
begin
  if R.Right <= R.Left then Exit;
  if AHot then
    Clr := FH_TEXT
  else
    Clr := FH_TEXT2;
  if AHot then
    FillCircleAA(Canvas, R, C_DL_BTNHOVER);
  CX := (R.Left + R.Right) div 2;
  D := Max(3, Px(3));
  Y0 := (R.Top + R.Bottom) div 2;
  G := MakeGraphics(Canvas);
  if G = nil then
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := Clr;
    for I := -1 to 1 do
      Canvas.FillRect(Rect(CX - D div 2, Y0 + I * Px(5) - D div 2,
        CX - D div 2 + D, Y0 + I * Px(5) - D div 2 + D));
    Canvas.Brush.Style := bsClear;
    Exit;
  end;
  try
    B := TGPSolidBrush.Create(ColorToARGB(Clr));
    try
      for I := -1 to 1 do
        G.FillEllipse(B, CX - D div 2 - 0.5, Y0 + I * Px(5) - D div 2 - 0.5,
          D, D);
    finally
      B.Free;
    end;
  finally
    G.Free;
  end;
end;

{ 垃圾桶删除图标（Chrome/Material delete 形态）: 盖子横条 + 提手 +
  梯形桶体（两侧斜边 + 底边）。旧版"圆角矩形桶身 + 内部两条竖线"在
  28px 按钮内细节过密, 观感像笼子（用户反馈奇怪）, 已按 Material 图标
  简化; 线条 GDI+ 抗锯齿, GDI+ 不可用回退 GDI（Win7 兜底） }
procedure TFHDownloadsList.DrawTrashIcon(const R: TRect; AHot: Boolean);
var
  Clr: TColor;
  PW: Single;
  CX, CY: Integer;

  { 统一线条绘制: GDI+ 抗锯齿圆头优先, 失败回退 GDI 直线 }
  procedure Line(X1, Y1, X2, Y2: Integer);
  var
    G: TGPGraphics;
    P: TGPPen;
  begin
    G := MakeGraphics(Canvas);
    if G = nil then
    begin
      Canvas.Pen.Style := psSolid;
      Canvas.Pen.Color := Clr;
      Canvas.Pen.Width := Max(1, Round(PW));
      Canvas.MoveTo(X1, Y1);
      Canvas.LineTo(X2, Y2);
      Exit;
    end;
    try
      P := TGPPen.Create(ColorToARGB(Clr), PW);
      try
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        G.DrawLine(P, X1, Y1, X2, Y2);
      finally
        P.Free;
      end;
    finally
      G.Free;
    end;
  end;

begin
  if (R.Right - R.Left) <= 0 then Exit;
  if AHot then
    Clr := FH_TEXT
  else
    Clr := FH_TEXT2;
  { 1.5 逻辑像素: AA 下与 Chrome 图标观感一致（整数 1px 偏细） }
  PW := Max(1.0, 1.5 * Px(96) / 96);
  if AHot then
    FillCircleAA(Canvas, R, C_DL_BTNHOVER);

  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  Canvas.Brush.Style := bsClear;

  { 提手: 盖上方居中的短横线 }
  Line(CX - Px(2), CY - Px(8), CX + Px(2), CY - Px(8));
  { 盖子: 总宽 12 }
  Line(CX - Px(6), CY - Px(5), CX + Px(6), CY - Px(5));
  { 桶体: 两侧斜边 + 底边（上宽 10 / 下宽 8 的开口梯形, Material 同款） }
  Line(CX - Px(5), CY - Px(3), CX - Px(4), CY + Px(7));
  Line(CX + Px(5), CY - Px(3), CX + Px(4), CY + Px(7));
  Line(CX - Px(4), CY + Px(7), CX + Px(4), CY + Px(7));

  Canvas.Brush.Style := bsSolid;
end;

{ 复选框: 18x18 圆角方形。AState: 0=未选 1=选中 2=部分（表头三态横线）。
  选中 = 蓝底白勾, 未选 = 灰边空心, 悬停加深 }
procedure TFHDownloadsList.DrawCheckBox(const R: TRect; AState: Integer;
  AHot: Boolean);
var
  Border, FillClr: TColor;
  CX, CY, PW: Integer;

  procedure Line(X1, Y1, X2, Y2: Integer; AColor: TColor; AWidth: Integer);
  var
    G: TGPGraphics;
    P: TGPPen;
  begin
    G := MakeGraphics(Canvas);
    if G = nil then
    begin
      Canvas.Pen.Style := psSolid;
      Canvas.Pen.Color := AColor;
      Canvas.Pen.Width := AWidth;
      Canvas.MoveTo(X1, Y1);
      Canvas.LineTo(X2, Y2);
      Exit;
    end;
    try
      P := TGPPen.Create(ColorToARGB(AColor), AWidth);
      try
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        G.DrawLine(P, X1, Y1, X2, Y2);
      finally
        P.Free;
      end;
    finally
      G.Free;
    end;
  end;

  { 圆角矩形描边: GDI+ 路径抗锯齿, GDI+ 不可用回退 GDI RoundRect（Win7 兜底） }
  procedure StrokeRoundRect(const RR: TRect; AColor: TColor; AWidth: Integer);
  var
    G: TGPGraphics;
    Path: TGPGraphicsPath;
    Pen: TGPPen;
    L, T, Rt, Bt, D: Single;
  begin
    G := MakeGraphics(Canvas);
    if G = nil then
    begin
      Canvas.Brush.Style := bsClear;
      Canvas.Pen.Color := AColor;
      Canvas.Pen.Width := AWidth;
      Canvas.RoundRect(RR.Left, RR.Top, RR.Right, RR.Bottom, Px(4), Px(4));
      Canvas.Brush.Style := bsSolid;
      Exit;
    end;
    try
      L := RR.Left + 0.5;
      T := RR.Top + 0.5;
      Rt := RR.Right - 0.5;
      Bt := RR.Bottom - 0.5;
      D := Px(4) * 2;
      if D > Rt - L then
        D := Rt - L;
      if D > Bt - T then
        D := Bt - T;
      if D < 1 then
        D := 1;
      Path := TGPGraphicsPath.Create;
      try
        Path.AddArc(L, T, D, D, 180, 90);
        Path.AddArc(Rt - D, T, D, D, 270, 90);
        Path.AddArc(Rt - D, Bt - D, D, D, 0, 90);
        Path.AddArc(L, Bt - D, D, D, 90, 90);
        Path.CloseFigure;
        Pen := TGPPen.Create(ColorToARGB(AColor), AWidth);
        try
          G.DrawPath(Pen, Path);
        finally
          Pen.Free;
        end;
      finally
        Path.Free;
      end;
    finally
      G.Free;
    end;
  end;

begin
  if (R.Right - R.Left) <= 0 then Exit;
  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  if AState > 0 then
  begin
    FillClr := FH_FOCUS;

    FillAA(R, Px(4), FillClr);
    PW := Max(2, Px(2));
    if AState = 1 then
    begin
      { 白勾: 左短边 + 右长边 }
      Line(CX - Px(4), CY, CX - Px(1), CY + Px(3), clWhite, PW);
      Line(CX - Px(1), CY + Px(3), CX + Px(4), CY - Px(3), clWhite, PW);
    end
    else
      { 部分选中: 白色横线 }
      Line(CX - Px(4), CY, CX + Px(4), CY, clWhite, PW);
  end
  else
  begin
    if AHot then
      Border := FH_TEXT
    else
      Border := FH_TEXT2;
    StrokeRoundRect(Rect(R.Left, R.Top, R.Right - 1, R.Bottom - 1),
      Border, Max(1, Px(1)));
  end;
end;

{ 固定表头: 列标题行 + 底部分隔线（不随内容滚动）。
  无选中: 列标题 + 全选框; 有选中: 切换为"已选 N 项" + 批量删除两按钮 }
procedure TFHDownloadsList.DrawHeader;
const
  Titles: array [0..5] of string = ('文件名', '大小', '格式', '下载时间',
    '文件位置', '操作');
var
  I, N, W: Integer;
  R: TRect;
begin
  W := ClientWidth;
  if W <= 0 then Exit;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.FillRect(Rect(0, 0, W, HeaderHeight));

  { 全选框: 全选=勾, 部分=横线, 无=空 }
  N := SelectedCount;
  if (N > 0) and (N >= Length(FRows)) then
    DrawCheckBox(HeaderChkRect, 1, FHeadChkHot)
  else if N > 0 then
    DrawCheckBox(HeaderChkRect, 2, FHeadChkHot)
  else
    DrawCheckBox(HeaderChkRect, 0, FHeadChkHot);

  if N > 0 then
  begin
    { 选择模式: 左侧"已选 N 项", 右侧批量按钮 }
    SetFontPx(12, True, FH_TEXT);
    R := Rect(Px(46), 0, Px(240), HeaderHeight);
    DrawTextRect(Format('已选 %d 项', [N]), R,
      DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_NOPREFIX);
    DrawActionButton(HeaderBtnRect(0), '删除记录',
      FHeadBtnHot = 1, True, False);
    DrawActionButton(HeaderBtnRect(1), '删除记录和文件',
      FHeadBtnHot = 2, True, True);
  end
  else
  begin
    SetFontPx(12, True, FH_TEXT2);
    for I := 0 to 5 do
    begin
      R := Rect(ColX(I), 0, ColX(I + 1) - Px(12), HeaderHeight);
      if I = 5 then
        R.Right := W;
      if I >= 1 then
        OffsetRect(R, -Px(4), 0);
      DrawTextRect(Titles[I], R,
        DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_END_ELLIPSIS or DT_NOPREFIX);
    end;
  end;
  Canvas.Pen.Color := FH_DL_EDGE;
  Canvas.Pen.Width := 1;
  Canvas.MoveTo(0, HeaderHeight - 1);
  Canvas.LineTo(W, HeaderHeight - 1);
  Canvas.Brush.Style := bsSolid;
end;

{ 画一行: 选中/悬停行底 + 复选框 + 六列内容
  （文件名/大小/格式/时间/位置/操作, 细节见体内注释） }
procedure TFHDownloadsList.DrawRow(AIndex, ATop: Integer);
var
  Item: TFHDownloadItem;
  R, RowR: TRect;
  H: Integer;
  SizeStr, Ext, Loc: string;
  OpenOk: Boolean;
const
  CellFlags = DT_SINGLELINE or DT_VCENTER or DT_LEFT or
    DT_END_ELLIPSIS or DT_NOPREFIX;
begin
  Item := FRows[AIndex];
  if Item = nil then Exit;
  H := RowHeight;

  { 行底: 选中优先浅蓝, 未选中悬停浅灰 }
  if IsSelected(AIndex) then
  begin
    RowR := Rect(Px(8), ATop + Px(2), ClientWidth - Px(8), ATop + H - Px(2));
    FillAA(RowR, Px(8), C_DL_SELBG);
  end
  else if AIndex = FHotRow then
  begin
    RowR := Rect(Px(8), ATop + Px(2), ClientWidth - Px(8), ATop + H - Px(2));
    FillAA(RowR, Px(8), FH_HOVER_GRAY);
  end;

  { 行首复选框（悬停行才加深边框） }
  if IsSelected(AIndex) then
    DrawCheckBox(CheckBoxRect(AIndex), 1, AIndex = FChkHotRow)
  else
    DrawCheckBox(CheckBoxRect(AIndex), 0, AIndex = FChkHotRow);

  { 大小列（下载中带进度/状态前缀, 其余为纯大小或状态） }
  case Item.State of
    dsInProgress:
      if Item.Paused then
        SizeStr := '已暂停 · ' + FormatBytes(Item.Received)
      else if Item.Percent >= 0 then
        SizeStr := Format('%d%% · %s / %s', [Item.Percent,
          FormatBytes(Item.Received), FormatBytes(Item.Total)])
      else
        SizeStr := '下载中 · ' + FormatBytes(Item.Received);
    dsComplete:
      SizeStr := FormatBytes(Item.Total);
    dsCanceled:
      SizeStr := '已取消 · ' + FormatBytes(Item.Received);
  else
    SizeStr := '已中断 · ' + FormatBytes(Item.Received);
  end;

  { 格式列: 扩展名大写 }
  Ext := UpperCase(Copy(ExtractFileExt(Item.Name), 2, MaxInt));
  if Ext = '' then
    Ext := '—';

  { 文件位置列: 所在目录 }
  Loc := ExtractFileDir(Item.Path);
  if Loc = '' then
    Loc := '—';

  { 文件名列（主色, 字号稍大）; 已完成但文件已不存在 → 删除线 + 灰字 }
  SetFontPx(13, False, FH_TEXT);
  if (Item.State = dsComplete) and not FileExists(Item.Path) then
  begin
    Canvas.Font.Color := FH_TEXT2;
    Canvas.Font.Style := [fsStrikeOut];
  end;
  R := Rect(ColX(0), ATop, ColX(1) - Px(12), ATop + H);
  DrawTextRect(Item.Name, R, CellFlags);

  { 大小 / 格式 / 下载时间 / 文件位置列 }
  SetFontPx(12, False, FH_TEXT2);
  R := Rect(ColX(1), ATop, ColX(2) - Px(12), ATop + H);
  DrawTextRect(SizeStr, R, CellFlags);
  R := Rect(ColX(2), ATop, ColX(3) - Px(12), ATop + H);
  DrawTextRect(Ext, R, CellFlags);
  R := Rect(ColX(3), ATop, ColX(4) - Px(12), ATop + H);
  DrawTextRect(FormatDateTime('yyyy-mm-dd hh:nn', Item.StartTime), R, CellFlags);
  R := Rect(ColX(4), ATop, ColX(5) - Px(12), ATop + H);
  DrawTextRect(Loc, R, CellFlags);

  { 操作列: 打开文件按钮 + 删除按钮 + "⋮"菜单按钮 }
  OpenOk := (Item.State = dsComplete) and FileExists(Item.Path);
  DrawActionButton(ActionRect(AIndex, dlaOpen), '打开文件',
    (AIndex = FHotRow) and (FHotAct = dlaOpen), OpenOk, False);
  DrawTrashIcon(ActionRect(AIndex, dlaDelete),
    (AIndex = FHotRow) and (FHotAct = dlaDelete));
  DrawMenuDots(ActionRect(AIndex, dlaMenu),
    (AIndex = FHotRow) and (FHotAct = dlaMenu));
end;

{ 画空列表提示（"暂无下载记录", 居中灰字） }
procedure TFHDownloadsList.DrawEmpty;
var
  R: TRect;
begin
  SetFontPx(13, False, FH_TEXT2);
  R := Rect(Px(24), HeaderHeight, ClientWidth - Px(24), ClientHeight);
  DrawTextRect('暂无下载记录', R,
    DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);
end;

{ 画滚动条滑块（悬停/拖拽加深, 圆角）; 不可滚动时不画 }
procedure TFHDownloadsList.DrawScrollBar;
var
  R: TRect;
  Clr: TColor;
begin
  if MaxOffset <= 0 then Exit;
  if FScrollHot or FScrollDragging then
    Clr := TColor($A6A09A)         // #9AA0A6
  else
    Clr := TColor($E0DCDA);        // #DADCE0
  R := ThumbRect;
  FillAA(R, Min(Px(4), (R.Right - R.Left) div 2), Clr);
end;

{ 全件自绘: 铺底 → 表头 → 空提示/逐行 → 滚动条 }
procedure TFHDownloadsList.Paint;
var
  I, Y: Integer;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Color := FH_BG;
  Canvas.FillRect(ClientRect);

  DrawHeader;

  if Length(FRows) = 0 then
    DrawEmpty
  else
    for I := 0 to High(FRows) do
    begin
      Y := FTops[I] - FOffset + HeaderHeight;
      if Y + RowHeight <= HeaderHeight then Continue;
      if Y >= ClientHeight then Break;
      DrawRow(I, Y);
    end;

  DrawScrollBar;
end;

{ 尺寸变化: 夹紧滚动偏移并重绘 }
procedure TFHDownloadsList.Resize;
begin
  inherited;
  ScrollTo(FOffset);
  Invalidate;
end;

{ 执行行内操作: 打开文件 / 删除记录 / 弹 ⋮菜单（快照 Id/Path/Url, 见体内注释） }
procedure TFHDownloadsList.DoAction(ARow: Integer; AAct: TFHDlAction);
var
  Item: TFHDownloadItem;
begin
  if (ARow < 0) or (ARow > High(FRows)) then Exit;
  Item := FRows[ARow];
  if Item = nil then Exit;

  case AAct of
    dlaOpen:
      begin
        if (Item.State = dsComplete) and FileExists(Item.Path) then
          ShellExecute(0, 'open', PChar(Item.Path), nil, nil, SW_SHOWNORMAL);
      end;
    dlaDelete:
      DeleteById(Item.Id, Item.Path, False);
    dlaMenu:
      begin
        { 快照 Id/Path/Url: 菜单是模态 Popup, 期间 300ms 轮询可能
          RefreshData 重建 FRows（行号失效）, 菜单项按快照操作 }
        FMenuId := Item.Id;
        FMenuPath := Item.Path;
        FMenuUrl := Item.Url;
        ShowRowMenu(ARow, ActionRect(ARow, dlaMenu).Left,
          ActionRect(ARow, dlaMenu).Bottom);
      end;
  end;
end;

{ 删除核心（不刷新）: 取消进行中 + 移列表 + 可选删文件 + 删库 }
procedure TFHDownloadsList.DoDelete(AId: Cardinal; const APath: string;
  ADeleteFile: Boolean);
begin
  if Downloads.ById(AId) = nil then Exit;
  if Downloads.ById(AId).State = dsInProgress then
    Downloads.Cancel(AId);
  Downloads.Remove(AId);

  if ADeleteFile and (APath <> '') and FileExists(APath) then
  try
    { 显式限定: Winapi.Windows 也有 DeleteFile(PWideChar), 会盖掉 SysUtils 版 }
    System.SysUtils.DeleteFile(APath);
  except
    on E: Exception do
      Logger.Error('删除下载文件失败: %s - %s', [APath, E.ClassName, E.Message]);
  end;

  try
    HistoryDB.DeleteDownload(AId);
  except
    on E: Exception do
      Logger.Error('删除下载记录失败 (id=%d): %s - %s',
        [AId, E.ClassName, E.Message]);
  end;
end;

{ 删除下载记录（及可选文件）。菜单项与行内删除按钮共用 }
procedure TFHDownloadsList.DeleteById(AId: Cardinal; const APath: string;
  ADeleteFile: Boolean);
begin
  if Downloads.ById(AId) = nil then Exit;
  DoDelete(AId, APath, ADeleteFile);
  RefreshData;
end;

{ 批量删除选中项 }
procedure TFHDownloadsList.DeleteSelected(ADeleteFile: Boolean);
var
  I: Integer;
  Item: TFHDownloadItem;
begin
  if FSelected.Count = 0 then Exit;
  for I := FSelected.Count - 1 downto 0 do
  begin
    Item := Downloads.ById(FSelected[I]);
    if Item <> nil then
      DoDelete(Item.Id, Item.Path, ADeleteFile);
  end;
  FSelected.Clear;
  RefreshData;
end;

{ 切换指定行的选中态（按 Id 加入/移出集合） }
procedure TFHDownloadsList.ToggleSelect(ARow: Integer);
var
  Idx: Integer;
begin
  if (ARow < 0) or (ARow > High(FRows)) or (FRows[ARow] = nil) then Exit;
  Idx := FSelected.IndexOf(FRows[ARow].Id);
  if Idx >= 0 then
    FSelected.Delete(Idx)
  else
    FSelected.Add(FRows[ARow].Id);
  Invalidate;
end;

{ 全选/全不选切换（表头全选框） }
procedure TFHDownloadsList.ToggleSelectAll;
var
  I: Integer;
begin
  if (Length(FRows) > 0) and (FSelected.Count >= Length(FRows)) then
    FSelected.Clear
  else
  begin
    FSelected.Clear;
    for I := 0 to High(FRows) do
      if FRows[I] <> nil then
        FSelected.Add(FRows[I].Id);
  end;
  Invalidate;
end;

{ 行内"⋮"菜单: 打开文件位置 / 删除记录 / 删除记录和文件 / 复制下载链接。
  锚在按钮正下方（与书签管理器/历史窗口同款形态） }
procedure TFHDownloadsList.ShowRowMenu(ARow, X, Y: Integer);
var
  P: TPoint;
begin
  FreeAndNil(FMenu);
  FMenu := TFHMenu.Create(Self);
  FMenu.ScaleFactor := Screen.PixelsPerInch / 96;
  FMenu.Add('打开文件位置', MenuFolder, '', miFolder);
  FMenu.AddSeparator;
  FMenu.Add('删除记录', MenuDelRec, '', miDelete);
  FMenu.Add('删除记录和文件', MenuDelFile, '', miDeleteData);
  FMenu.AddSeparator;
  FMenu.Add('复制下载链接', MenuCopyLink, '', miLink);
  P := ClientToScreen(Point(X, Y));
  FMenu.Popup(P.X, P.Y);
end;

{ 菜单"打开文件位置": 定位到所在文件夹 }
procedure TFHDownloadsList.MenuFolder(Sender: TObject);
begin
  if FMenuPath <> '' then
    OpenContainingFolder(FMenuPath);
end;

{ 菜单"删除记录": 按快照 Id 删记录（不删文件） }
procedure TFHDownloadsList.MenuDelRec(Sender: TObject);
begin
  DeleteById(FMenuId, FMenuPath, False);
end;

{ 菜单"删除记录和文件": 按快照 Id 删记录并删文件 }
procedure TFHDownloadsList.MenuDelFile(Sender: TObject);
begin
  DeleteById(FMenuId, FMenuPath, True);
end;

{ 菜单"复制下载链接": 按快照 Url 写剪贴板 }
procedure TFHDownloadsList.MenuCopyLink(Sender: TObject);
begin
  if FMenuUrl <> '' then
    Clipboard.AsText := FMenuUrl;
end;

{ 鼠标按下: 左键 → 滚动条拖拽/翻页 }
procedure TFHDownloadsList.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  TR: TRect;
begin
  inherited;
  if Button <> mbLeft then Exit;
  if (MaxOffset > 0) and (X >= ClientWidth - Px(10)) then
  begin
    TR := ThumbRect;
    if PtInRect(TR, Point(X, Y)) then
    begin
      FScrollDragging := True;
      FScrollDragY := Y;
      FScrollDragOffset := FOffset;
    end
    else if Y < TR.Top then
      ScrollTo(FOffset - ClientHeight)
    else
      ScrollTo(FOffset + ClientHeight);
    Exit;
  end;
end;

{ 鼠标移动: 滚动条拖拽跟手; 表头/行/复选框/操作按钮悬停态跟踪 }
procedure TFHDownloadsList.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  TrackH, ThumbH, Ratio: Integer;
  Hot, ChkHot: Boolean;
  Row, HeadBtn: Integer;
  Act: TFHDlAction;
  P: TPoint;
begin
  inherited;
  if FScrollDragging and (MaxOffset > 0) then
  begin
    TrackH := Max(1, ClientHeight - HeaderHeight - Px(16));
    ThumbH := ThumbRect.Bottom - ThumbRect.Top;
    Ratio := Max(1, TrackH - ThumbH);
    ScrollTo(FScrollDragOffset + Round((Y - FScrollDragY) *
      (MaxOffset / Ratio)));
  end;

  Hot := (MaxOffset > 0) and (X >= ClientWidth - Px(10));
  if Hot <> FScrollHot then
  begin
    FScrollHot := Hot;
    Invalidate;
  end;

  P := Point(X, Y);

  { 表头区域: 全选框/批量按钮悬停（选中态才有批量按钮） }
  if Y < HeaderHeight then
  begin
    ChkHot := PtInRect(HeaderChkRect, P);
    HeadBtn := 0;
    if (SelectedCount > 0) then
    begin
      if PtInRect(HeaderBtnRect(0), P) then
        HeadBtn := 1
      else if PtInRect(HeaderBtnRect(1), P) then
        HeadBtn := 2;
    end;
    if ChkHot or (HeadBtn <> 0) then
      Cursor := crHandPoint
    else
      Cursor := crDefault;
    if (ChkHot <> FHeadChkHot) or (HeadBtn <> FHeadBtnHot) or
      (FHotRow <> -1) or (FHotAct <> dlaNone) or (FChkHotRow <> -1) then
    begin
      FHeadChkHot := ChkHot;
      FHeadBtnHot := HeadBtn;
      FHotRow := -1;
      FHotAct := dlaNone;
      FChkHotRow := -1;
      Invalidate;
    end;
    Exit;
  end;

  Row := IndexAtY(Y);
  if FScrollHot then
    Act := dlaNone
  else
    Act := ActionAtPos(Row, X, Y);
  ChkHot := (Row >= 0) and PtInRect(CheckBoxRect(Row), P);

  if (Row <> FHotRow) or (Act <> FHotAct) or (ChkHot <> (FChkHotRow = Row)) or
    ((not ChkHot) and (FChkHotRow <> -1)) then
  begin
    FHotRow := Row;
    FHotAct := Act;
    if ChkHot then
      FChkHotRow := Row
    else
      FChkHotRow := -1;
    if (Act = dlaNone) and (not ChkHot) then
      Cursor := crDefault
    else
      Cursor := crHandPoint;
    FHeadChkHot := False;
    FHeadBtnHot := 0;
    Invalidate;
  end;
end;

{ 鼠标松开: 结束滚动拖拽; 表头全选/批量删除、行复选框、行内操作分发 }
procedure TFHDownloadsList.MouseUp(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Row: Integer;
  Act: TFHDlAction;
  P: TPoint;
begin
  inherited;
  if Button <> mbLeft then Exit;
  if FScrollDragging then
  begin
    FScrollDragging := False;
    Invalidate;
    Exit;
  end;
  P := Point(X, Y);

  { 表头: 全选框切换 / 批量删除按钮 }
  if Y < HeaderHeight then
  begin
    if PtInRect(HeaderChkRect, P) then
      ToggleSelectAll
    else if SelectedCount > 0 then
    begin
      if PtInRect(HeaderBtnRect(0), P) then
        DeleteSelected(False)
      else if PtInRect(HeaderBtnRect(1), P) then
        DeleteSelected(True);
    end;
    Exit;
  end;

  { 行首复选框: 切换选中 }
  Row := IndexAtY(Y);
  if (Row >= 0) and PtInRect(CheckBoxRect(Row), P) then
  begin
    ToggleSelect(Row);
    Exit;
  end;

  Act := ActionAtPos(Row, X, Y);
  if Act <> dlaNone then
    DoAction(Row, Act);
end;

{ 滚轮: 上下滚动 120 逻辑像素 }
function TFHDownloadsList.DoMouseWheel(Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if MaxOffset > 0 then
  begin
    if WheelDelta > 0 then
      ScrollTo(FOffset - Px(120))
    else
      ScrollTo(FOffset + Px(120));
    Result := True;
  end
  else
    Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
end;

{ 鼠标离开: 清全部悬停态并重绘 }
procedure TFHDownloadsList.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FHotRow := -1;
  FHotAct := dlaNone;
  FChkHotRow := -1;
  FHeadChkHot := False;
  FHeadBtnHot := 0;
  FScrollHot := False;
  Invalidate;
end;

{ ---- 下载记录窗口 ----------------------------------------------------------- }

{ 构造: 无边框 Chrome 弹窗四件套, 按屏幕 DPI 定尺寸, 构建 UI 并启动 300ms 轮询 }
constructor TFHDownloadsForm.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  { 手动按 DPI 换算（Px）, 关掉 VCL 自动缩放避免双重放大 }
  Scaled := False;
  if Screen <> nil then
    FScale := Screen.PixelsPerInch / 96
  else
    FScale := 1;
  Caption := '下载内容';
  { 无边框 Chrome 弹窗（参考历史记录窗口的四件套: WS_POPUP + 吞 NCCALCSIZE
    + 自绘 1px 边框线 + NCACTIVATE 哨兵, 详见 docs\01_UI开发规范.md 6~9 条）;
    bsSizeable 仅为保留 WS_THICKFRAME（边缘八向调整大小） }
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu];
  Position := poScreenCenter;
  Color := FH_BG;
  Font.Name := 'Segoe UI';
  { 无系统标题栏后客户区=整窗: 高度基准补回自绘标题栏（44px）;
    宽度按 6 列表格内容放宽 }
  ClientWidth := Px(880);
  ClientHeight := Px(560) + CaptionH;
  Constraints.MinWidth := Px(760);
  Constraints.MinHeight := Px(400) + CaptionH;
  DoubleBuffered := True;
  OnPaint := FormPaint;
  OnMouseDown := FormMouseDown;
  OnMouseMove := FormMouseMove;
  BuildUi;
  LayoutUi;
  FList.RefreshData;
  FTimer.Enabled := True;
end;

{ 析构: 真正释放时才清全局指针（caFree 异步释放, 见体内注释） }
destructor TFHDownloadsForm.Destroy;
begin
  { 真正释放时才清全局指针 —— DoClose 里 caFree 是异步释放, 若在那置 nil,
    释放前的空窗期再调 ShowDownloadsForm 会 CreateNew 出第二个窗体 }
  if GForm = Self then
    GForm := nil;
  inherited;
end;

{ 96 DPI 基准逻辑像素 → 窗口实际像素（无句柄期按屏幕 DPI 兜底） }
function TFHDownloadsForm.Px(V: Integer): Integer;
var
  DPI: Integer;
  DC: HDC;
begin
  DPI := 0;
  if HandleAllocated then
  begin
    DC := GetDC(Handle);
    DPI := GetDeviceCaps(DC, LOGPIXELSX);
    ReleaseDC(Handle, DC);
  end;
  if DPI <= 0 then
    DPI := Screen.PixelsPerInch;
  if DPI <= 0 then
    DPI := 96;
  Result := MulDiv(V, DPI, 96);
  if (V > 0) and (Result = 0) then
    Result := 1;
end;

{ 构建子控件: 标题 + 下载列表 + 底部两个链接按钮 + 300ms 轮询定时器 }
procedure TFHDownloadsForm.BuildUi;
begin
  FTitle := TLabel.Create(Self);
  FTitle.Parent := Self;
  FTitle.Transparent := True;
  FTitle.AutoSize := False;
  FTitle.Layout := tlCenter;
  FTitle.Caption := '下载内容';
  FTitle.Font.Name := 'Segoe UI';
  FTitle.Font.PixelsPerInch := Px(96);
  FTitle.Font.Height := -Px(22);
  FTitle.Font.Style := [fsBold];
  FTitle.Font.Color := FH_TEXT;

  FList := TFHDownloadsList.Create(Self);
  FList.Parent := Self;

  FBtnOpenDir := TLabel.Create(Self);
  FBtnOpenDir.Parent := Self;
  FBtnOpenDir.Transparent := True;
  FBtnOpenDir.AutoSize := False;
  FBtnOpenDir.Layout := tlCenter;
  FBtnOpenDir.Caption := '打开下载文件夹';
  FBtnOpenDir.Cursor := crHandPoint;
  FBtnOpenDir.Font.Name := 'Segoe UI';
  FBtnOpenDir.Font.PixelsPerInch := Px(96);
  FBtnOpenDir.Font.Height := -Px(13);
  FBtnOpenDir.Font.Color := FH_FOCUS;
  FBtnOpenDir.OnClick := OpenDirClick;

  FBtnClear := TLabel.Create(Self);
  FBtnClear.Parent := Self;
  FBtnClear.Transparent := True;
  FBtnClear.AutoSize := False;
  FBtnClear.Layout := tlCenter;
  FBtnClear.Caption := '清空已结束';
  FBtnClear.Cursor := crHandPoint;
  FBtnClear.Font.Name := 'Segoe UI';
  FBtnClear.Font.PixelsPerInch := Px(96);
  FBtnClear.Font.Height := -Px(13);
  FBtnClear.Font.Color := FH_FOCUS;
  FBtnClear.OnClick := ClearClick;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 300;
  FTimer.OnTimer := RefreshTick;
end;

{ 重排子控件: 标题在标题栏内, 列表占内容区, 底部按钮行贴底 }
procedure TFHDownloadsForm.LayoutUi;
var
  Pad, ListTop, BarH: Integer;
begin
  if (FTitle = nil) or (FList = nil) then Exit;
  Pad := Px(24);
  BarH := Px(32);
  { 标题在自绘标题栏内左侧垂直居中; 列表区从标题栏下开始 }
  FTitle.SetBounds(Px(16), 0,
    Max(Px(120), ClientWidth - Px(16) - Px(48)), CaptionH());

  ListTop := CaptionH() + Px(16);
  FList.SetBounds(Pad, ListTop, Max(Px(120), ClientWidth - 2 * Pad),
    Max(Px(80), ClientHeight - ListTop - BarH - Pad));

  FBtnOpenDir.SetBounds(Pad, ClientHeight - BarH - Px(10), Px(150), Px(24));
  if FBtnClear <> nil then
    FBtnClear.SetBounds(ClientWidth - Pad - Px(110),
      ClientHeight - BarH - Px(10), Px(110), Px(24));
end;

{ ---- 无边框四件套（参考历史记录窗口, docs\01_UI开发规范.md 第 6~9 条） ---- }

{ 无边框: 去 WS_CAPTION/WS_SYSMENU 保留 WS_THICKFRAME; 必须 or WS_POPUP ——
  user32 对带 WS_THICKFRAME 的非 popup 顶层窗口会在 CreateWindowEx 内部
  强制补回 WS_CAPTION（规范第 7 条） }
procedure TFHDownloadsForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := (Params.Style or WS_POPUP) and (not WS_CAPTION)
    and (not WS_SYSMENU);
end;

{ 标题栏高度（自绘, 96 DPI 基准 44px） }
function TFHDownloadsForm.CaptionH: Integer;
begin
  Result := Px(44);
end;

{ 标题栏右上角关闭按钮: 32x32, 距右 8px, 垂直居中于标题栏 }
function TFHDownloadsForm.CloseBtnRect: TRect;
var
  Btn: Integer;
begin
  Btn := Px(32);
  Result := Rect(ClientWidth - Px(40), (CaptionH() - Btn) div 2,
    ClientWidth - Px(40) + Btn, (CaptionH() + Btn) div 2);
end;

{ 边缘 resize 优先采用系统结果; 标题栏空白区 → HTCAPTION（拖动）;
  关闭按钮留 HTCLIENT 走鼠标事件 }
procedure TFHDownloadsForm.WMNCHitTest(var Message: TWMNCHitTest);
var
  P: TPoint;
begin
  inherited;
  if (Message.Result >= HTLEFT) and (Message.Result <= HTBOTTOMRIGHT) then
    Exit;
  if Message.Result <> HTCLIENT then
    Exit;
  P := ScreenToClient(Point(Message.XPos, Message.YPos));
  if (P.Y >= 0) and (P.Y < CaptionH()) then
  begin
    if PtInRect(CloseBtnRect(), P) then
      Exit;
    Message.Result := HTCAPTION;
  end;
end;

{ 吞掉顶部 resize 边框带: 客户区=整窗, 标题栏贴物理顶边（规范第 8 条） }
procedure TFHDownloadsForm.WMNCCalcSize(var Message: TWMNCCalcSize);
begin
  if Message.CalcValidRects then
    Message.Result := 0
  else
    inherited;
end;

{ 失活不重绘 NC（规范第 9 条: 否则弹菜单/对话框时窗口边缘出现缝隙） }
procedure TFHDownloadsForm.WMNCActivate(var Message: TWMNCActivate);
begin
  Message.Unused := -1;
  inherited;
end;

{ 无 WS_CAPTION 后 SW_MAXIMIZE 会盖住任务栏 —— 夹到所在监视器工作区 }
procedure TFHDownloadsForm.WMGetMinMaxInfo(var Message: TWMGetMinMaxInfo);
var
  WA: TRect;
begin
  inherited;
  if Monitor <> nil then
    WA := Monitor.WorkareaRect
  else
    WA := Rect(Screen.WorkAreaLeft, Screen.WorkAreaTop,
      Screen.WorkAreaLeft + Screen.WorkAreaWidth,
      Screen.WorkAreaTop + Screen.WorkAreaHeight);
  Message.MinMaxInfo^.ptMaxPosition.X := WA.Left;
  Message.MinMaxInfo^.ptMaxPosition.Y := WA.Top;
  Message.MinMaxInfo^.ptMaxSize.X := WA.Right - WA.Left;
  Message.MinMaxInfo^.ptMaxSize.Y := WA.Bottom - WA.Top;
end;

{ 双击标题栏: 最大化/还原（无系统标题栏时 DefWindowProc 不再代劳） }
procedure TFHDownloadsForm.WndProc(var Message: TMessage);
begin
  if (Message.Msg = WM_NCLBUTTONDBLCLK) and (Message.WParam = HTCAPTION) then
  begin
    if WindowState = wsMaximized then
      Perform(WM_SYSCOMMAND, SC_RESTORE, 0)
    else
      Perform(WM_SYSCOMMAND, SC_MAXIMIZE, 0);
    Exit;
  end;
  inherited WndProc(Message);
end;

{ 鼠标离开: 清关闭按钮悬停态并重绘 }
procedure TFHDownloadsForm.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FCloseHot := False;
  Invalidate;
end;

{ 标题栏自绘: 白底 + 四周 1px 边框线 + 底部分隔线 + 右上角关闭按钮 × }
procedure TFHDownloadsForm.FormPaint(Sender: TObject);
var
  R: TRect;
  PW, CX, CY, D: Integer;
  Clr: TColor;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Style := psClear;
  Canvas.FillRect(Rect(0, 0, ClientWidth, CaptionH()));

  { 四周 1px 边框线（吞 NCCALCSIZE 后系统不再画任何非客户区边框） }
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := FH_DL_EDGE;
  Canvas.Pen.Width := 1;
  Canvas.MoveTo(0, 0);
  Canvas.LineTo(ClientWidth - 1, 0);
  Canvas.LineTo(ClientWidth - 1, ClientHeight - 1);
  Canvas.LineTo(0, ClientHeight - 1);
  Canvas.LineTo(0, 0);

  { 标题栏底部分隔线 }
  Canvas.MoveTo(0, CaptionH() - 1);
  Canvas.LineTo(ClientWidth, CaptionH() - 1);
  Canvas.Pen.Style := psClear;

  { 关闭按钮: 悬停浅灰圆角底 + ×（GDI+ 抗锯齿, 失败回退 GDI） }
  R := CloseBtnRect();
  if FCloseHot then
    FillRoundRectAA(Canvas, R.Left, R.Top, R.Right, R.Bottom, Px(8),
      FH_HOVER_GRAY, FH_HOVER_GRAY, 0);
  D := Px(10);
  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  if FCloseHot then
    Clr := FH_TEXT
  else
    Clr := FH_TEXT2;
  PW := Max(1, Px(1));
  if not DrawLineAA(Canvas, CX - D div 2, CY - D div 2, CX + D div 2,
    CY + D div 2, Clr, PW) then
  begin
    Canvas.Pen.Style := psSolid;
    Canvas.Pen.Color := Clr;
    Canvas.Pen.Width := PW;
    Canvas.MoveTo(CX - D div 2, CY - D div 2);
    Canvas.LineTo(CX + D div 2, CY + D div 2);
    Canvas.MoveTo(CX + D div 2, CY - D div 2);
    Canvas.LineTo(CX - D div 2, CY + D div 2);
    Canvas.Pen.Style := psClear;
  end;
  if not DrawLineAA(Canvas, CX + D div 2, CY - D div 2, CX - D div 2,
    CY + D div 2, Clr, PW) then
  begin
    Canvas.Pen.Style := psSolid;
    Canvas.Pen.Color := Clr;
    Canvas.Pen.Width := PW;
    Canvas.MoveTo(CX + D div 2, CY - D div 2);
    Canvas.LineTo(CX - D div 2, CY + D div 2);
    Canvas.Pen.Style := psClear;
  end;
end;

{ 鼠标按下: 命中标题栏关闭按钮则关窗 }
procedure TFHDownloadsForm.FormMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  if PtInRect(CloseBtnRect(), Point(X, Y)) then
  begin
    FCloseHot := False;
    Close;
    Exit;
  end;
end;

{ 鼠标移动: 跟踪关闭按钮悬停态, 变化时重绘 }
procedure TFHDownloadsForm.FormMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  Hot: Boolean;
begin
  Hot := PtInRect(CloseBtnRect(), Point(X, Y));
  if Hot <> FCloseHot then
  begin
    FCloseHot := Hot;
    Invalidate;
  end;
end;

{ 窗口尺寸变化: 重排子控件 }
procedure TFHDownloadsForm.Resize;
begin
  inherited;
  LayoutUi;
end;

{ 显示: 重排并把窗口居中到主窗口所在显示器的工作区 }
procedure TFHDownloadsForm.DoShow;
var
  Mon: TMonitor;
  R: TRect;
begin
  inherited;
  LayoutUi;
  { 窗口居中（放在主窗口所在显示器的正中） }
  if (Application.MainForm <> nil) and Application.MainForm.HandleAllocated then
    Mon := Application.MainForm.Monitor
  else
    Mon := Screen.PrimaryMonitor;
  if Mon <> nil then
  begin
    R := Mon.WorkareaRect;
    Left := R.Left + (R.Right - R.Left - Width) div 2;
    Top := R.Top + (R.Bottom - R.Top - Height) div 2;
  end;
end;

{ 关闭: 释放窗口（下载记录留在全局单例; 全局指针在 Destroy 里清） }
procedure TFHDownloadsForm.DoClose(var Action: TCloseAction);
begin
  inherited;
  Action := caFree;                  // 窗口关闭即释放; 下载记录留在全局单例里
  { GForm 的清空在 Destroy 里做, 见 Destroy 注释 }
end;

{ 300ms 轮询: 按内容签名判断有无变化, 变了才刷新列表
  （避免每轮重排打断滚轮/悬停） }
procedure TFHDownloadsForm.RefreshTick(Sender: TObject);
var
  I: Integer;
  Sig: string;
begin
  { 内容签名没变就不重建 —— 避免每 300ms 重排打断滚轮/悬停 }
  Sig := '';
  for I := 0 to Downloads.Count - 1 do
    Sig := Sig + Format('%d:%d:%d:%d:%d;', [Downloads[I].Id,
      Ord(Downloads[I].State), Downloads[I].Percent, Downloads[I].Speed,
      Ord(Downloads[I].Paused)]);
  if Sig = FLastSig then Exit;
  FLastSig := Sig;
  FList.RefreshData;
end;

{ "打开下载文件夹"链接: 打开下载根目录 }
procedure TFHDownloadsForm.OpenDirClick(Sender: TObject);
begin
  ShellExecute(0, 'open', PChar(DownloadsDir), nil, nil, SW_SHOWNORMAL);
end;

{ "清空已结束"链接: 清内存列表与库中已结束的记录并刷新 }
procedure TFHDownloadsForm.ClearClick(Sender: TObject);
begin
  Downloads.ClearFinished;
  try
    HistoryDB.ClearDownloads(0);
  except
    on E: Exception do
      Logger.Error('清空下载记录失败: %s - %s', [E.ClassName, E.Message]);
  end;
  FLastSig := '';
  FList.RefreshData;
end;

procedure ShowDownloadsForm(ABringToFront: Boolean);
begin
  if (GForm = nil) or (csDestroying in GForm.ComponentState) or (not GForm.HandleAllocated) then
  begin
    GForm := TFHDownloadsForm.CreateNew(Application);
    GForm.Show;
  end
  else
  begin
    if not GForm.Visible then
      GForm.Show;
    if ABringToFront then
      GForm.BringToFront;
  end;
end;

{ ---- "近期下载记录"气泡 ---------------------------------------------------- }

type
  TFHBubbleHit = (bhNone, bhPause, bhCancel, bhName, bhFolder, bhDelete,
    bhMenu, bhFull, bhClose);
  TFHBubbleRowKind = (brkActive, brkDone, brkEmpty);

  TFHBubbleRow = record
    Kind: TFHBubbleRowKind;
    Item: TFHDownloadItem;
    RowRect: TRect;                   // 整行
    BtnARect: TRect;                  // 进行中: 暂停/继续;  已完成: 文件夹
    BtnBRect: TRect;                  // 进行中: 取消;      已完成: 删除
    BtnCRect: TRect;                  // 已完成: 菜单
    NameRect: TRect;                  // 已完成: 文件名点击区（打开文件）
  end;

  TFHDownloadsBubble = class(TForm)
  private
    FTimer: TTimer;
    FRows: TArray<TFHBubbleRow>;
    FContentEnd: Integer;             // 内容区底部 y（底栏分隔线）
    FHotRow: Integer;
    FHotHit: TFHBubbleHit;
    FCloseRect: TRect;
    FFullRect: TRect;
    FLastSig: string;
    FMenu: TFHMenu;                   // 行内"⋮"菜单（模态 Popup）
    FMenuId: Cardinal;                // 快照 Id/Path/Url: Popup 期间 300ms 轮询
    FMenuPath: string;                //   可能 Rebuild 重建 FRows, 菜单按快照操作
    FMenuUrl: string;
    function Px(V: Integer): Integer;
    procedure BuildRows;
    function ContentHeight: Integer;
    procedure Rebuild;
    function HitTest(X, Y: Integer; out ARow: Integer): TFHBubbleHit;
    procedure RefreshTick(Sender: TObject);
    procedure FormPaint(Sender: TObject);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure FormDeactivate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    { 鼠标移出气泡客户区: 清悬停态（否则 FHotHit 残留 bhFull/bhClose,
      "完整的下载记录"高亮不消失 —— 移出气泡后不再有 MouseMove 可重算） }
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    procedure FillAA(const R: TRect; ARadius: Single; AColor: TColor);
    procedure DrawTextPx(const S: string; ARect: TRect; APx: Integer;
      ABold: Boolean; AColor: TColor; AFlags: Cardinal;
      AStrikeOut: Boolean = False);
    procedure DrawCloseGlyph(const R: TRect; AColor: TColor);
    procedure DrawFolderGlyph(const R: TRect; AColor: TColor);
    procedure DrawTrashGlyph(const R: TRect; AColor: TColor);
    procedure DrawMenuGlyph(const R: TRect; AColor: TColor);
    { 删除下载记录（及可选文件）, 与窗口 DoDelete 同款。
      行内删除按钮与菜单项共用; 传 Id/Path 快照, 不持对象引用 }
    procedure DeleteItem(AId: Cardinal; const APath: string;
      ADeleteFile: Boolean);
    { 行内"⋮"菜单: 打开文件位置 / 删除记录 / 删除记录和文件 / 复制下载链接
      （与下载记录窗口行内菜单同款） }
    procedure ShowRowMenu(ARow: Integer);
    procedure MenuFolder(Sender: TObject);
    procedure MenuDelRec(Sender: TObject);
    procedure MenuDelFile(Sender: TObject);
    procedure MenuCopyLink(Sender: TObject);
    procedure DrawRow(ARowIndex: Integer);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure DoShow; override;
    procedure DoClose(var Action: TCloseAction); override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
  end;

var
  GBubble: TFHDownloadsBubble = nil;

const
  C_BBL_W        = 360;   // 气泡宽度（96 DPI）
  C_BBL_TITLE_H  = 44;    // 标题栏
  C_BBL_ACTIVE_H = 62;    // 进行中行高
  C_BBL_DONE_H   = 54;    // 已完成行高（2026-11-18 46→54: 文件名垂直居中于
                          // 整行时 14px 行盒实际落 Top+13..33, 与第二行
                          // Top+26 互相侵占, 两行文字间隙只剩几像素;
                          // 改顶部对齐流式布局并拉开两行间距 6px）
  C_BBL_EMPTY_H  = 56;    // 空态行高
  C_BBL_FOOT_H   = 44;    // 底部按钮行
  C_BBL_MAXDONE  = 5;     // 已完成为最多显示条数（更多窗口里看）

{ 用系统默认方式打开下载的文件（文件不存在则忽略） }
procedure OpenDownloadFile(const APath: string);
begin
  if (APath <> '') and FileExists(APath) then
    ShellExecute(0, 'open', PChar(APath), nil, nil, SW_SHOWNORMAL);
end;

{ 打开文件所在目录并选中文件（explorer /select）; 文件不在了开下载根目录 }
procedure OpenContainingFolder(const APath: string);
var
  Cmd: string;
begin
  { explorer /select 打开所在目录并选中文件; 文件不在了就打开下载根目录 }
  if (APath <> '') and FileExists(APath) then
    Cmd := Format('/select,"%s"', [APath])
  else
    Cmd := '"' + DownloadsDir + '"';
  ShellExecute(0, 'open', 'explorer.exe', PChar(Cmd), nil, SW_SHOWNORMAL);
end;

{ 构造: 无边框工具窗气泡, 建行并启动 300ms 轮询 }
constructor TFHDownloadsBubble.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  Scaled := False;
  BorderStyle := bsNone;
  Color := FH_BG;
  Font.Name := 'Segoe UI';
  KeyPreview := True;
  DoubleBuffered := True;
  Width := Px(C_BBL_W);
  ClientHeight := Px(120);
  OnPaint := FormPaint;
  OnMouseMove := FormMouseMove;
  OnMouseDown := FormMouseDown;
  OnDeactivate := FormDeactivate;
  OnKeyDown := FormKeyDown;
  FHotRow := -1;
  FHotHit := bhNone;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 300;
  FTimer.OnTimer := RefreshTick;
  FTimer.Enabled := True;
  BuildRows;
  ClientHeight := ContentHeight;
end;

{ 析构: 全局气泡指针自清（防悬垂） }
destructor TFHDownloadsBubble.Destroy;
begin
  if GBubble = Self then
    GBubble := nil;
  inherited;
end;

{ 工具窗样式（不占任务栏/Alt-Tab）+ 系统投影 }
procedure TFHDownloadsBubble.CreateParams(var Params: TCreateParams);
begin
  inherited;
  { 工具窗（不占任务栏/Alt-Tab）+ 系统投影 }
  Params.ExStyle := Params.ExStyle or WS_EX_TOOLWINDOW;
  Params.WindowClass.Style := Params.WindowClass.Style or CS_DROPSHADOW;
end;

{ 显示: 激活窗体（失焦关闭依赖激活） }
procedure TFHDownloadsBubble.DoShow;
begin
  inherited;
  SetFocus;   // 激活才能靠"失去焦点即关闭"工作, 并接收 Esc
end;

{ 关闭: 释放窗口（全局指针在 Destroy 里清） }
procedure TFHDownloadsBubble.DoClose(var Action: TCloseAction);
begin
  inherited;
  Action := caFree;
end;

{ 96 DPI 基准逻辑像素 → 窗口实际像素（无句柄期按屏幕 DPI 兜底） }
function TFHDownloadsBubble.Px(V: Integer): Integer;
var
  DPI: Integer;
  DC: HDC;
begin
  DPI := 0;
  if HandleAllocated then
  begin
    DC := GetDC(Handle);
    DPI := GetDeviceCaps(DC, LOGPIXELSX);
    ReleaseDC(Handle, DC);
  end;
  if DPI <= 0 then
    DPI := Screen.PixelsPerInch;
  if DPI <= 0 then
    DPI := 96;
  Result := MulDiv(V, DPI, 96);
  if (V > 0) and (Result = 0) then
    Result := 1;
end;

{ 重建行模型: 进行中全部 + 最近完成最多 5 条（空态占位行）,
  并累计各行矩形与按钮命中区（细节见体内注释） }
procedure TFHDownloadsBubble.BuildRows;
var
  I, DoneN, Y, RowH: Integer;
  Row: TFHBubbleRow;
  InDone: Boolean;
begin
  SetLength(FRows, 0);
  DoneN := 0;
  { 进行中的下载全部显示（最新的在前, 与全局列表同序） }
  for I := 0 to Downloads.Count - 1 do
  begin
    if Downloads[I].State <> dsInProgress then Continue;
    Row := Default(TFHBubbleRow);
    Row.Kind := brkActive;
    Row.Item := Downloads[I];
    FRows := FRows + [Row];
  end;
  { 最近完成的文件（最多 C_BBL_MAXDONE 条） }
  for I := 0 to Downloads.Count - 1 do
  begin
    if (Downloads[I].State <> dsComplete) or (DoneN >= C_BBL_MAXDONE) then
      Continue;
    Row := Default(TFHBubbleRow);
    Row.Kind := brkDone;
    Row.Item := Downloads[I];
    FRows := FRows + [Row];
    Inc(DoneN);
  end;
  if Length(FRows) = 0 then
  begin
    Row := Default(TFHBubbleRow);
    Row.Kind := brkEmpty;
    FRows := FRows + [Row];
  end;

  { 行矩形与子命中区 }
  Y := Px(C_BBL_TITLE_H);
  InDone := False;
  for I := 0 to High(FRows) do
  begin
    if (FRows[I].Kind = brkDone) and not InDone then
    begin
      InDone := True;
      if I > 0 then
        Inc(Y, 1);                      // 进行中/已完成之间的分隔线
    end;
    case FRows[I].Kind of
      brkActive: RowH := Px(C_BBL_ACTIVE_H);
      brkDone:   RowH := Px(C_BBL_DONE_H);
    else
      RowH := Px(C_BBL_EMPTY_H);
    end;
    FRows[I].RowRect := Rect(0, Y, Width, Y + RowH);

    if FRows[I].Kind = brkActive then
    begin
      FRows[I].BtnBRect := Rect(Width - Px(12) - Px(24), Y + Px(6),
        Width - Px(12), Y + Px(6) + Px(24));
      FRows[I].BtnARect := Rect(FRows[I].BtnBRect.Left - Px(8) - Px(52),
        Y + Px(6), FRows[I].BtnBRect.Left - Px(8), Y + Px(6) + Px(24));
    end
    else if FRows[I].Kind = brkDone then
    begin
      { 已完成行三按钮（右→左）: 菜单 / 删除 / 文件夹, 间隔 6px }
      FRows[I].BtnCRect := Rect(Width - Px(12) - Px(24), Y + Px(15),
        Width - Px(12), Y + Px(15) + Px(24));
      FRows[I].BtnBRect := Rect(FRows[I].BtnCRect.Left - Px(6) - Px(24),
        Y + Px(15), FRows[I].BtnCRect.Left - Px(6), Y + Px(15) + Px(24));
      FRows[I].BtnARect := Rect(FRows[I].BtnBRect.Left - Px(6) - Px(24),
        Y + Px(15), FRows[I].BtnBRect.Left - Px(6), Y + Px(15) + Px(24));
      { 文件名区域: 顶部对齐流式（Top+6..Top+28）, 命中与绘制同区 }
      FRows[I].NameRect := Rect(Px(16), Y + Px(6), FRows[I].BtnARect.Left - Px(8),
        Y + Px(28));
    end;
    Inc(Y, RowH);
  end;
  FContentEnd := Y;

  FCloseRect := Rect(Width - Px(12) - Px(24), (Px(C_BBL_TITLE_H) - Px(24)) div 2,
    Width - Px(12), (Px(C_BBL_TITLE_H) - Px(24)) div 2 + Px(24));
  FFullRect := Rect(0, FContentEnd + 1, Width, FContentEnd + 1 + Px(C_BBL_FOOT_H));
end;

{ 气泡总高 = 内容底 + 分隔线 + 底栏 + 下边框 }
function TFHDownloadsBubble.ContentHeight: Integer;
begin
  Result := FContentEnd + 1 + Px(C_BBL_FOOT_H) + 1;   // 分隔线 + 底栏 + 下边框
end;

{ 重建行并按内容高调整窗口, 重绘 }
procedure TFHDownloadsBubble.Rebuild;
begin
  BuildRows;
  ClientHeight := ContentHeight;
  Invalidate;
end;

{ 300ms 轮询: 焦点丢失兜底关闭 + 内容签名变化才重建
  （避免每轮重排打断悬停/点击） }
procedure TFHDownloadsBubble.RefreshTick(Sender: TObject);
var
  I: Integer;
  Sig: string;
begin
  { 兜底: 菜单弹出期间失焦被 FormDeactivate 保护; 若菜单关闭后焦点
    没回气泡（用户点了外部窗口）, 气泡会残留 —— 轮询发现即关闭 }
  if Visible and not Focused and not ((FMenu <> nil) and
    FMenu.PopupVisible) then
  begin
    HideDownloadsBubble;
    Exit;
  end;

  { 内容签名没变就不重建 —— 避免每 300ms 重排打断悬停/点击 }
  Sig := '';
  for I := 0 to Downloads.Count - 1 do
    Sig := Sig + Format('%d:%d:%d:%d:%d;', [Downloads[I].Id,
      Ord(Downloads[I].State), Downloads[I].Percent, Downloads[I].Speed,
      Ord(Downloads[I].Paused)]);
  if Sig = FLastSig then Exit;
  FLastSig := Sig;
  Rebuild;
end;

{ 完整命中测试: 关闭/底栏/行内按钮/文件名 → 命中类型与行索引 }
function TFHDownloadsBubble.HitTest(X, Y: Integer;
  out ARow: Integer): TFHBubbleHit;
var
  I: Integer;
  Row: TFHBubbleRow;
  P: TPoint;
begin
  ARow := -1;
  Result := bhNone;
  P := Point(X, Y);
  if PtInRect(FCloseRect, P) then
    Exit(bhClose);
  if PtInRect(FFullRect, P) then
    Exit(bhFull);
  for I := 0 to High(FRows) do
  begin
    Row := FRows[I];
    if not PtInRect(Row.RowRect, P) then Continue;
    ARow := I;
    if Row.Kind = brkActive then
    begin
      if PtInRect(Row.BtnARect, P) then Exit(bhPause);
      if PtInRect(Row.BtnBRect, P) then Exit(bhCancel);
    end
    else if Row.Kind = brkDone then
    begin
      if PtInRect(Row.BtnARect, P) then Exit(bhFolder);
      if PtInRect(Row.BtnBRect, P) then Exit(bhDelete);
      if PtInRect(Row.BtnCRect, P) then Exit(bhMenu);
      if PtInRect(Row.NameRect, P) then Exit(bhName);
    end;
    Exit;
  end;
end;

{ 鼠标移动: 跟踪悬停命中区, 变化时切光标并重绘 }
procedure TFHDownloadsBubble.FormMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  H: TFHBubbleHit;
  R: Integer;
begin
  H := HitTest(X, Y, R);
  if (H <> FHotHit) or (R <> FHotRow) then
  begin
    FHotHit := H;
    FHotRow := R;
    if H = bhNone then
      Cursor := crDefault
    else
      Cursor := crHandPoint;
    Invalidate;
  end;
end;

{ 鼠标移出气泡客户区（从底栏/按钮直接划出窗口边界时不再有 MouseMove）
  → 清悬停态并重绘, 高亮不残留 }
procedure TFHDownloadsBubble.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  if (FHotHit <> bhNone) or (FHotRow >= 0) then
  begin
    FHotHit := bhNone;
    FHotRow := -1;
    Cursor := crDefault;
    Invalidate;
  end;
end;

{ 鼠标按下: 按命中区分发 —— 关闭/完整记录/暂停继续/取消/打开文件/
  定位文件夹/删记录/弹菜单 }
procedure TFHDownloadsBubble.FormMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  H: TFHBubbleHit;
  R: Integer;
  Item: TFHDownloadItem;
begin
  if Button <> mbLeft then Exit;
  H := HitTest(X, Y, R);
  case H of
    bhClose:
      HideDownloadsBubble;
    bhFull:
      begin
        HideDownloadsBubble;
        ShowDownloadsForm(True);
      end;
    bhPause:
      begin
        if R >= 0 then
        begin
          Item := FRows[R].Item;
          if Item <> nil then
          begin
            Downloads.SetPaused(Item.Id, not Item.Paused);
            FLastSig := '';
            Rebuild;
          end;
        end;
      end;
    bhCancel:
      begin
        if R >= 0 then
        begin
          Item := FRows[R].Item;
          if Item <> nil then
          begin
            Downloads.Cancel(Item.Id);
            FLastSig := '';
            Rebuild;
          end;
        end;
      end;
    bhName:
      if (R >= 0) and (FRows[R].Item <> nil) then
        OpenDownloadFile(FRows[R].Item.Path);
    bhFolder:
      if (R >= 0) and (FRows[R].Item <> nil) then
        OpenContainingFolder(FRows[R].Item.Path);
    bhDelete:
      if (R >= 0) and (FRows[R].Item <> nil) then
      begin
        DeleteItem(FRows[R].Item.Id, FRows[R].Item.Path, False);
        FLastSig := '';
        Rebuild;
      end;
    bhMenu:
      ShowRowMenu(R);
  end;
end;

{ 删除下载记录（及可选文件）, 与窗口 DoDelete 同款: 取消进行中 + 移列表 +
  可选删文件 + 删库。传 Id/Path 快照, 不持对象引用 }
procedure TFHDownloadsBubble.DeleteItem(AId: Cardinal; const APath: string;
  ADeleteFile: Boolean);
var
  Item: TFHDownloadItem;
begin
  Item := Downloads.ById(AId);
  if Item = nil then Exit;
  if Item.State = dsInProgress then
    Downloads.Cancel(AId);
  Downloads.Remove(AId);

  if ADeleteFile and (APath <> '') and FileExists(APath) then
  try
    { 显式限定: Winapi.Windows 也有 DeleteFile(PWideChar), 会盖掉 SysUtils 版 }
    System.SysUtils.DeleteFile(APath);
  except
    on E: Exception do
      Logger.Error('删除下载文件失败: %s - %s', [APath, E.ClassName, E.Message]);
  end;

  try
    HistoryDB.DeleteDownload(AId);
  except
    on E: Exception do
      Logger.Error('删除下载记录失败 (id=%d): %s - %s',
        [AId, E.ClassName, E.Message]);
  end;
end;

{ 行内"⋮"菜单: 打开文件位置 / 删除记录 / 删除记录和文件 / 复制下载链接。
  锚在按钮正下方（与下载记录窗口/书签/历史同款形态）。
  TFHMenu.Popup 是非阻塞的（创建菜单窗口后立即返回）, FMenu 须保留到
  下次弹出或气泡销毁 —— Popup 后立即释放会把刚创建的菜单窗口一并销毁,
  菜单弹不出来。菜单显示期间 300ms 轮询可能 Rebuild 重建 FRows
  （行号失效）, 菜单项按 Id/Path/Url 快照操作 }
procedure TFHDownloadsBubble.ShowRowMenu(ARow: Integer);
var
  Item: TFHDownloadItem;
  P: TPoint;
begin
  if (ARow < 0) or (ARow > High(FRows)) then Exit;
  Item := FRows[ARow].Item;
  if Item = nil then Exit;

  FMenuId := Item.Id;
  FMenuPath := Item.Path;
  FMenuUrl := Item.Url;

  FreeAndNil(FMenu);          { 已显示则先关再开（切换目标行） }
  FMenu := TFHMenu.Create(Self);
  FMenu.ScaleFactor := Screen.PixelsPerInch / 96;
  { 菜单从按钮正下方弹出, 允许超出气泡下边框（宿主反查会把气泡自身
    当宿主, 默认夹紧会把菜单翻到按钮上方） }
  FMenu.ConfineToHost := False;
  FMenu.Add('打开文件位置', MenuFolder, '', miFolder);
  FMenu.AddSeparator;
  FMenu.Add('删除记录', MenuDelRec, '', miDelete);
  FMenu.Add('删除记录和文件', MenuDelFile, '', miDeleteData);
  FMenu.AddSeparator;
  FMenu.Add('复制下载链接', MenuCopyLink, '', miLink);
  P := ClientToScreen(Point(FRows[ARow].BtnCRect.Left,
    FRows[ARow].BtnCRect.Bottom));
  FMenu.Popup(P.X, P.Y);
end;

{ 菜单"打开文件位置": 按快照路径定位 }
procedure TFHDownloadsBubble.MenuFolder(Sender: TObject);
begin
  if FMenuPath <> '' then
    OpenContainingFolder(FMenuPath);
end;

{ 菜单"删除记录": 按快照 Id 删记录（不删文件）并重建 }
procedure TFHDownloadsBubble.MenuDelRec(Sender: TObject);
begin
  DeleteItem(FMenuId, FMenuPath, False);
  FLastSig := '';
  Rebuild;
end;

{ 菜单"删除记录和文件": 按快照 Id 删记录并删文件, 重建 }
procedure TFHDownloadsBubble.MenuDelFile(Sender: TObject);
begin
  DeleteItem(FMenuId, FMenuPath, True);
  FLastSig := '';
  Rebuild;
end;

{ 菜单"复制下载链接": 按快照 Url 写剪贴板 }
procedure TFHDownloadsBubble.MenuCopyLink(Sender: TObject);
begin
  if FMenuUrl <> '' then
    Clipboard.AsText := FMenuUrl;
end;

{ 失焦即关闭（菜单显示中除外, 见体内注释） }
procedure TFHDownloadsBubble.FormDeactivate(Sender: TObject);
begin
  { 菜单显示中不关（Popup 抢焦点触发失焦, 菜单关闭后焦点回气泡）;
    菜单关闭后 FMenu 对象仍在, 须用 PopupVisible 判断, 否则"失焦即关"失效 }
  if (FMenu <> nil) and FMenu.PopupVisible then Exit;
  { 点击气泡外部（窗口失焦）即关闭, 与 Chrome 下载气泡一致 }
  HideDownloadsBubble;
end;

{ 键盘: Esc 关闭气泡 }
procedure TFHDownloadsBubble.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    HideDownloadsBubble;
  end;
end;

{ 抗锯齿圆角矩形填充（GDI+ 优先, 回退 GDI FillRect） }
procedure TFHDownloadsBubble.FillAA(const R: TRect; ARadius: Single;
  AColor: TColor);
begin
  if not FillRoundRectAA(Canvas, R.Left, R.Top, R.Right, R.Bottom, ARadius,
    AColor, clNone, 0) then
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := AColor;
    Canvas.FillRect(R);
  end;
end;

{ 按像素画文本（透明背景, 可选删除线 —— 文件已删除的记录用） }
procedure TFHDownloadsBubble.DrawTextPx(const S: string; ARect: TRect;
  APx: Integer; ABold: Boolean; AColor: TColor; AFlags: Cardinal;
  AStrikeOut: Boolean);
var
  R: TRect;
begin
  if S = '' then Exit;
  SetCanvasFontPx(Canvas, APx, ABold, AColor);
  if AStrikeOut then
    Canvas.Font.Style := Canvas.Font.Style + [fsStrikeOut];
  R := ARect;
  Canvas.Brush.Style := bsClear;
  Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), R, AFlags);
  Canvas.Brush.Style := bsSolid;
end;

{ 画关闭 × 符号（取消按钮/标题栏关闭共用） }
procedure TFHDownloadsBubble.DrawCloseGlyph(const R: TRect; AColor: TColor);
var
  S, CX, CY: Integer;
begin
  Canvas.Brush.Style := bsClear;
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := AColor;
  Canvas.Pen.Width := Max(1, Px(1));
  S := Min(R.Right - R.Left, R.Bottom - R.Top) div 4;
  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  Canvas.MoveTo(CX - S, CY - S);
  Canvas.LineTo(CX + S, CY + S);
  Canvas.MoveTo(CX + S, CY - S);
  Canvas.LineTo(CX - S, CY + S);
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Style := bsSolid;
end;

{ 画文件夹图标（左上小标签 + 主体） }
procedure TFHDownloadsBubble.DrawFolderGlyph(const R: TRect; AColor: TColor);
var
  L, T, W, H: Integer;
begin
  Canvas.Brush.Style := bsClear;
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := AColor;
  Canvas.Pen.Width := Max(1, Px(1));
  L := R.Left + Px(4);
  T := R.Top + Px(5);
  W := (R.Right - R.Left) - Px(8);
  H := (R.Bottom - R.Top) - Px(9);
  { 文件夹: 左上小标签 + 主体 }
  Canvas.MoveTo(L, T + Px(3));
  Canvas.LineTo(L + Px(4), T + Px(3));
  Canvas.LineTo(L + Px(6), T + Px(5));
  Canvas.LineTo(L + W, T + Px(5));
  Canvas.LineTo(L + W, T + H);
  Canvas.LineTo(L, T + H);
  Canvas.LineTo(L, T + Px(3));
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Style := bsSolid;
end;

{ 垃圾桶删除图标（与下载记录窗口 DrawTrashIcon 同款: Material delete 形态,
  GDI+ 抗锯齿圆头线条, GDI+ 不可用回退 GDI —— Win7 兜底） }
procedure TFHDownloadsBubble.DrawTrashGlyph(const R: TRect; AColor: TColor);
var
  PW: Single;
  CX, CY: Integer;

  { 统一线条绘制: GDI+ 抗锯齿圆头优先, 失败回退 GDI 直线 }
  procedure Line(X1, Y1, X2, Y2: Integer);
  var
    G: TGPGraphics;
    P: TGPPen;
  begin
    G := MakeGraphics(Canvas);
    if G = nil then
    begin
      Canvas.Pen.Style := psSolid;
      Canvas.Pen.Color := AColor;
      Canvas.Pen.Width := Max(1, Round(PW));
      Canvas.MoveTo(X1, Y1);
      Canvas.LineTo(X2, Y2);
      Exit;
    end;
    try
      P := TGPPen.Create(ColorToARGB(AColor), PW);
      try
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        G.DrawLine(P, X1, Y1, X2, Y2);
      finally
        P.Free;
      end;
    finally
      G.Free;
    end;
  end;

begin
  if (R.Right - R.Left) <= 0 then Exit;
  { 1.5 逻辑像素: AA 下与 Chrome 图标观感一致（整数 1px 偏细） }
  PW := Max(1.0, 1.5 * Px(96) / 96);
  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  Canvas.Brush.Style := bsClear;

  { 提手: 盖上方居中的短横线 }
  Line(CX - Px(2), CY - Px(8), CX + Px(2), CY - Px(8));
  { 盖子: 总宽 12 }
  Line(CX - Px(6), CY - Px(5), CX + Px(6), CY - Px(5));
  { 桶体: 两侧斜边 + 底边（上宽 10 / 下宽 8 的开口梯形, Material 同款） }
  Line(CX - Px(5), CY - Px(3), CX - Px(4), CY + Px(7));
  Line(CX + Px(5), CY - Px(3), CX + Px(4), CY + Px(7));
  Line(CX - Px(4), CY + Px(7), CX + Px(4), CY + Px(7));

  Canvas.Brush.Style := bsSolid;
end;

{ "⋮"菜单图标（三点, GDI+ 抗锯齿, GDI 回退; 与窗口 DrawMenuDots 同款） }
procedure TFHDownloadsBubble.DrawMenuGlyph(const R: TRect; AColor: TColor);
var
  CX, Y0, D, I: Integer;
  G: TGPGraphics;
  B: TGPSolidBrush;
begin
  if R.Right <= R.Left then Exit;
  CX := (R.Left + R.Right) div 2;
  D := Max(3, Px(3));
  Y0 := (R.Top + R.Bottom) div 2;
  G := MakeGraphics(Canvas);
  if G = nil then
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := AColor;
    for I := -1 to 1 do
      Canvas.FillRect(Rect(CX - D div 2, Y0 + I * Px(5) - D div 2,
        CX - D div 2 + D, Y0 + I * Px(5) - D div 2 + D));
    Canvas.Brush.Style := bsClear;
    Exit;
  end;
  try
    B := TGPSolidBrush.Create(ColorToARGB(AColor));
    try
      for I := -1 to 1 do
        G.FillEllipse(B, CX - D div 2 - 0.5, Y0 + I * Px(5) - D div 2 - 0.5,
          D, D);
    finally
      B.Free;
    end;
  finally
    G.Free;
  end;
end;

{ 画一行: 空态提示 / 进行中（文件名+进度条+状态+暂停取消）/
  已完成（文件名+大小时长+文件夹/删除/菜单按钮, 细节见体内注释） }
procedure TFHDownloadsBubble.DrawRow(ARowIndex: Integer);
var
  Row: TFHBubbleRow;
  Item: TFHDownloadItem;
  TR: TRect;
  Status: string;
  TrackW, FillW: Integer;
  Gone: Boolean;
begin
  Row := FRows[ARowIndex];
  if Row.Kind = brkEmpty then
  begin
    DrawTextPx('暂无下载记录', Row.RowRect, 12, False, FH_TEXT2,
      DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
    Exit;
  end;

  Item := Row.Item;

  if Row.Kind = brkActive then
  begin
    { 文件名 }
    DrawTextPx(Item.Name,
      Rect(Row.RowRect.Left + Px(16), Row.RowRect.Top + Px(6),
        Row.BtnARect.Left - Px(8), Row.RowRect.Top + Px(28)),
      14, False, FH_TEXT,
      DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX);

    { 进度条: 浅灰轨道 + 蓝色进度 }
    TR := Rect(Row.RowRect.Left + Px(16), Row.RowRect.Top + Px(32),
      Row.RowRect.Right - Px(16), Row.RowRect.Top + Px(35));
    FillAA(TR, 2, FH_TRACK_OFF);
    if Item.Percent > 0 then
    begin
      TrackW := TR.Right - TR.Left;
      FillW := Max(3, TrackW * Min(100, Item.Percent) div 100);
      FillAA(Rect(TR.Left, TR.Top, TR.Left + FillW, TR.Bottom), 2, FH_FOCUS);
    end;

    { 状态: 进度 · 速度 · 剩余; 暂停时改文案 }
    if Item.Paused then
      Status := Format('已暂停 · %s / %s', [FormatBytes(Item.Received),
        FormatBytes(Item.Total)])
    else
    begin
      if Item.Percent >= 0 then
        Status := Format('%d%%', [Item.Percent])
      else
        Status := '已下载 ' + FormatBytes(Item.Received);
      if Item.Speed > 0 then
        Status := Status + Format(' · %s/s', [FormatBytes(Item.Speed)]);
      if Item.Eta > 0 then
        Status := Status + Format(' · 剩余 %s', [FormatEta(Item.Eta)]);
    end;
    DrawTextPx(Status,
      Rect(Row.RowRect.Left + Px(16), Row.RowRect.Top + Px(38),
        Row.BtnARect.Left - Px(8), Row.RowRect.Bottom),
      12, False, FH_TEXT2,
      DT_LEFT or DT_TOP or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX);

    { 暂停/继续 文字按钮 }
    if (FHotRow = ARowIndex) and (FHotHit = bhPause) then
      FillAA(Row.BtnARect, Px(4), FH_HOVER_BG);
    if Item.Paused then
      DrawTextPx('继续', Row.BtnARect, 12, False, FH_FOCUS,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX)
    else
      DrawTextPx('暂停', Row.BtnARect, 12, False, FH_FOCUS,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);

    { 取消 × }
    if (FHotRow = ARowIndex) and (FHotHit = bhCancel) then
      FillAA(Row.BtnBRect, Px(4), FH_HOVER_BG);
    DrawCloseGlyph(Row.BtnBRect, FH_TEXT2);
  end
  else
  begin
    { 已完成: 文件名（顶部对齐, 悬停变蓝, 点击打开文件）;
      文件已不存在 → 删除线 + 灰字（与下载记录窗口同款） }
    Gone := not FileExists(Item.Path);
    if (FHotRow = ARowIndex) and (FHotHit = bhName) then
      DrawTextPx(Item.Name, Row.NameRect, 14, False, FH_FOCUS,
        DT_LEFT or DT_TOP or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX,
        Gone)
    else if Gone then
      DrawTextPx(Item.Name, Row.NameRect, 14, False, FH_TEXT2,
        DT_LEFT or DT_TOP or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX,
        True)
    else
      DrawTextPx(Item.Name, Row.NameRect, 14, False, FH_TEXT,
        DT_LEFT or DT_TOP or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX);

    { 大小 · 完成时长（第二行: 与文件名行盒拉开 6px 间距） }
    DrawTextPx(Format('%s · %s', [FormatBytes(Item.Total),
      FormatRelativeTime(Item.EndTime)]),
      Rect(Row.RowRect.Left + Px(16), Row.RowRect.Top + Px(31),
        Row.BtnARect.Left - Px(8), Row.RowRect.Bottom),
      12, False, FH_TEXT2,
      DT_LEFT or DT_TOP or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX);

    { 文件夹按钮（悬停圆形底, 与窗口图标按钮同款） }
    if (FHotRow = ARowIndex) and (FHotHit = bhFolder) then
    begin
      FillCircleAA(Canvas, Row.BtnARect, C_DL_BTNHOVER);
      DrawFolderGlyph(Row.BtnARect, FH_TEXT);
    end
    else
      DrawFolderGlyph(Row.BtnARect, FH_TEXT2);

    { 删除按钮（仅删记录, 不删文件） }
    if (FHotRow = ARowIndex) and (FHotHit = bhDelete) then
    begin
      FillCircleAA(Canvas, Row.BtnBRect, C_DL_BTNHOVER);
      DrawTrashGlyph(Row.BtnBRect, FH_TEXT);
    end
    else
      DrawTrashGlyph(Row.BtnBRect, FH_TEXT2);

    { 菜单按钮（⋮, 弹行内菜单） }
    if (FHotRow = ARowIndex) and (FHotHit = bhMenu) then
    begin
      FillCircleAA(Canvas, Row.BtnCRect, C_DL_BTNHOVER);
      DrawMenuGlyph(Row.BtnCRect, FH_TEXT);
    end
    else
      DrawMenuGlyph(Row.BtnCRect, FH_TEXT2);
  end;
end;

{ 全窗自绘: 边框线（线宽随 DPI, 见体内注释）+ 标题 + 关闭 × +
  各行 + 分隔线 + "完整的下载记录"底栏 }
procedure TFHDownloadsBubble.FormPaint(Sender: TObject);
var
  I: Integer;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Color := FH_BG;
  Canvas.FillRect(ClientRect);

  { 1px 边框（无边框窗体, 直角即可 — GDI+ 圆角需要窗口 region, 收益不大）。
    2026-11-18 两轮修正: (a) FH_DIVIDER(#E8EAED) 在白底不可见 → 换
    FH_DL_EDGE(#DADCE0), 与历史/书签/设置窗口同款; (b) Pen.Width=1 是
    1 物理像素 —— 150% DPI 屏上是一条极细淡线, 换色后用户仍实测"看不见"
    → 线宽随 DPI 换算 Max(1,Px(1))（144 DPI = 2 物理像素 ≈ 1 逻辑像素）,
    并改逐边 LineTo（宽笔画 Rectangle 时外半像素会被客户区裁掉）。
    LineTo 终点开区间: 上/左线落在 0 行/列, 下/右线落在 Height-1/Width-1 }
  Canvas.Brush.Style := bsClear;
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := FH_DL_EDGE;
  Canvas.Pen.Width := Max(1, Px(1));
  Canvas.MoveTo(0, 0);
  Canvas.LineTo(Width - 1, 0);
  Canvas.LineTo(Width - 1, Height - 1);
  Canvas.LineTo(0, Height - 1);
  Canvas.LineTo(0, 0);
  Canvas.Pen.Width := 1;
  Canvas.Brush.Style := bsSolid;

  { 标题 }
  DrawTextPx('近期下载记录',
    Rect(Px(16), 0, Width - Px(48), Px(C_BBL_TITLE_H)),
    14, True, FH_TEXT,
    DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);

  { 关闭 × }
  if FHotHit = bhClose then
    FillAA(FCloseRect, Px(4), FH_HOVER_GRAY);
  DrawCloseGlyph(FCloseRect, FH_TEXT2);

  { 各行 }
  for I := 0 to High(FRows) do
    DrawRow(I);

  { 内容与底栏之间的分隔线 }
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_DIVIDER;
  Canvas.FillRect(Rect(0, FContentEnd, Width + 1, FContentEnd + 1));

  { 底栏: 完整的下载记录 }
  if FHotHit = bhFull then
    FillAA(Rect(0, FContentEnd + 1, Width, Height - 1), 0, FH_HOVER_GRAY);
  DrawTextPx('完整的下载记录',
    Rect(0, FContentEnd + 1, Width, Height - 1),
    14, False, FH_FOCUS,
    DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
end;

{ ---- 气泡入口 --------------------------------------------------------------- }

{ 下载气泡当前是否显示中（含释放中判定） }
function IsDownloadsBubbleVisible: Boolean;
begin
  Result := (GBubble <> nil) and GBubble.Visible and
    not (csDestroying in GBubble.ComponentState);
end;

{ 关闭下载气泡（不可见则忽略） }
procedure HideDownloadsBubble;
begin
  if IsDownloadsBubbleVisible then
    GBubble.Close;
end;

procedure ShowDownloadsBubble(const AAnchorScreen: TRect; AToggle: Boolean);
var
  B: TFHDownloadsBubble;
  Mon: TMonitor;
  Work: TRect;
  L, T, Gap: Integer;
begin
  if AToggle and IsDownloadsBubbleVisible then
  begin
    HideDownloadsBubble;
    Exit;
  end;

  if not IsDownloadsBubbleVisible then
  begin
    B := TFHDownloadsBubble.CreateNew(Application);
    GBubble := B;
  end
  else
  begin
    B := GBubble;
    B.Rebuild;
  end;

  { 定位: 水平右对齐按钮、垂直贴按钮下方; 下方放不下翻到上方 }
  Mon := Screen.MonitorFromRect(AAnchorScreen, mdNearest);
  if Mon = nil then
    Mon := Screen.PrimaryMonitor;
  Work := Mon.WorkareaRect;
  Gap := MulDiv(2, Screen.PixelsPerInch, 96);
  L := AAnchorScreen.Right - B.Width;
  if L < Work.Left then
    L := Work.Left;
  if L + B.Width > Work.Right then
    L := Work.Right - B.Width;
  T := AAnchorScreen.Bottom + Gap;
  if T + B.Height > Work.Bottom then
  begin
    T := AAnchorScreen.Top - B.Height - Gap;
    if T < Work.Top then
      T := Work.Top;
  end;
  B.Left := L;
  B.Top := T;

  if not B.Visible then
    B.Show;
  B.SetFocus;
end;

initialization
finalization
  FreeAndNil(GList);
end.
