{==============================================================================
  uFHBookmarks —— 书签功能支撑层 + 三个界面件
  ----------------------------------------------------------------------------
  职责:
    1. TFHBookmarkBar    书签栏控件（工具栏下方一条, 主窗体嵌入）
    2. TFHBookmarkBubble 星标气泡（添加/修改/删除书签, 地址栏星标与
                         书签栏/管理器"编辑"共用）
    3. TFHBookmarksForm  书签管理器窗口（搜索/列表/行内删除/右键菜单）
  数据: 全部经 uFHHistoryDB 存 UserData\History.db 的 fh_bookmarks 表。
  通知: 增删改统一走 NotifyBookmarksChanged —— 刷新已注册的书签栏与
        管理器窗口, 并回调主窗体注册的变更处理器（刷地址栏星标态）。
  UI 规范: docs\01_UI开发规范.md 全九条（无边框四件套/DPI/GDI+ 抗锯齿/
    行盒实测排版）。占位图标 = 圆底 #E8EAED + 标题首字符（不下载真 favicon）。
=============================================================================}
unit uFHBookmarks;

interface

uses
  System.Classes, System.SysUtils, System.Types, System.UITypes, System.Math,
  Winapi.Windows, Winapi.Messages, Winapi.GDIPOBJ, Winapi.GDIPAPI,
  Vcl.Forms, Vcl.Controls, Vcl.Graphics, Vcl.StdCtrls, Vcl.ClipBrd,
  uFHHistoryDB, uFHChromeMenu, uFHChromeTabs, uLogger;

type
  TFHBookmarkUrlEvent = procedure(Sender: TObject; const AUrl: string) of object;

  { ---- 书签栏: 工具栏下方一条, 自绘 -------------------------------------- }
  TFHBookmarkBar = class(TCustomControl)
  private
    FEntries: TFHBookmarkEntries;
    FTops: TArray<Integer>;       // 每项左边界
    FWidths: TArray<Integer>;     // 每项宽度
    FOverflowFrom: Integer;       // 第一个溢出项索引（-1 = 无溢出）
    FHot: Integer;                // 悬停项索引（-1 = 无; Count = 溢出按钮）
    FItemH: Integer;              // 条目高度缓存（-1 = 待重测）
    FMenu: TFHMenu;               // 条目右键菜单（固定项, 目标存 FMenuEntry）
    FOverflowMenu: TFHMenu;       // 溢出菜单（每次弹出重建）
    FMenuEntry: TFHBookmarkEntry; // 右键菜单当前目标
    FOnOpen: TFHBookmarkUrlEvent;
    FOnOpenNewTab: TFHBookmarkUrlEvent;
    function Px(V: Integer): Integer;
    procedure ApplyFont;
    procedure MeasureLayout;
    function ItemRect(I: Integer): TRect;
    function OverflowRect: TRect;
    function IndexAt(X, Y: Integer): Integer;
    function IndexOfEntry(const AUrl: string): Integer;
    function ClientToScreenRect(const R: TRect): TRect;
    procedure DrawChevronGlyph(ACanvas: TCanvas; const R: TRect);
    procedure ShowContextMenu(I: Integer);
    procedure ShowOverflowMenu;
    procedure MenuOpen(Sender: TObject);
    procedure MenuOpenNewTab(Sender: TObject);
    procedure MenuEdit(Sender: TObject);
    procedure MenuDelete(Sender: TObject);
    procedure MenuOverflowOpen(Sender: TObject);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure CreateWnd; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { 重新查库并重摆（数据变更通知调用; 数据量小每次全量重查） }
    procedure Reload;
    property OnOpen: TFHBookmarkUrlEvent read FOnOpen write FOnOpen;
    property OnOpenNewTab: TFHBookmarkUrlEvent read FOnOpenNewTab
      write FOnOpenNewTab;
  end;

  { ---- 星标气泡: 添加/修改/删除书签 -------------------------------------- }
  TFHBookmarkBubble = class(TForm)
  private
    FIsNew: Boolean;              // True = 添加（无删除按钮）; False = 修改
    FOrigUrl: string;             // 原 URL（修改模式按它定位）
    FNameEdit: TEdit;
    FUrlEdit: TEdit;
    FDoneRect: TRect;             // "完成"胶囊按钮
    FDeleteRect: TRect;           // "删除"文字按钮（仅修改模式显示）
    FDoneHot: Boolean;
    FDeleteHot: Boolean;
    function Px(V: Integer): Integer;
    procedure PinFont(AEdit: TEdit; AFontPx: Integer);
    procedure BuildUi;
    procedure LayoutUi;
    procedure FormPaint(Sender: TObject);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure FormDeactivate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure DoneClick;
    procedure DeleteClick;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure DoShow; override;
    procedure DoClose(var Action: TCloseAction); override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
    { 弹出气泡。AAnchorScreen = 锚定矩形（星标/书签条目的屏幕矩形）,
      气泡出现在其正下方（放不下改上方）, 左对齐并按工作区夹紧。
      AUrl/ATitle = 目标书签地址与标题（未收藏 = 添加模式） }
    procedure ShowEdit(const AAnchorScreen: TRect; const AUrl, ATitle: string);
  end;

  { ---- 书签管理器列表: 自绘（两行文字/悬停/删除/滚动条） ------------------ }
  TFHBookmarkList = class(TCustomControl)
  private
    FEntries: TFHBookmarkEntries;
    FKeyword: string;
    FTops: TArray<Integer>;       // 每行顶边
    FRowH: Integer;               // 行高缓存（行盒实测, -1 = 待重测）
    FContentH: Integer;
    FOffset: Integer;             // 滚动偏移
    FHot: Integer;                // 悬停行（-1 = 无）
    FDeleteHot: Boolean;          // 悬停在行删除按钮上
    FMenuBtnHot: Boolean;         // 悬停在行"⋮"菜单按钮上
    FScrollDragging: Boolean;
    FScrollDragY: Integer;
    FScrollDragOffset: Integer;
    FMenu: TFHMenu;               // 右键菜单（固定项, 目标存 FMenuEntry）
    FMenuEntry: TFHBookmarkEntry;
    FOnOpen: TFHBookmarkUrlEvent;
    FOnOpenNewTab: TFHBookmarkUrlEvent;
    function Px(V: Integer): Integer;
    procedure ApplyFont;
    procedure BuildTops;
    function RowHeight: Integer;
    function MaxOffset: Integer;
    function IndexAtY(Y: Integer): Integer;
    function IndexOfEntry(const AUrl: string): Integer;
    function ThumbRect: TRect;
    function DeleteBtnRect(ARow: Integer): TRect;
    function MenuBtnRect(ARow: Integer): TRect;
    procedure ScrollTo(AOffset: Integer);
    { 悬停行删除按钮: 历史记录同款垃圾桶图标（AHot = 鼠标在按钮上, 图标加深） }
    procedure DrawTrashIcon(const R: TRect; AHot: Boolean);
    { 悬停行"⋮"菜单按钮: 竖三点图标（AHot = 鼠标在按钮上, 点色加深） }
    procedure DrawMenuDots(const R: TRect; AHot: Boolean);
    procedure DrawScrollBar;
    procedure ShowContextMenu(X, Y: Integer);
    procedure MenuOpen(Sender: TObject);
    procedure MenuOpenNewTab(Sender: TObject);
    procedure MenuCopy(Sender: TObject);
    procedure MenuEdit(Sender: TObject);
    procedure MenuDelete(Sender: TObject);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure CreateWnd; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { 装入查询结果; AKeyword 决定空列表时显示"无搜索结果"还是空态文案 }
    procedure SetEntries(const AEntries: TFHBookmarkEntries;
      const AKeyword: string);
    property OnOpen: TFHBookmarkUrlEvent read FOnOpen write FOnOpen;
    property OnOpenNewTab: TFHBookmarkUrlEvent read FOnOpenNewTab
      write FOnOpenNewTab;
  end;

  { ---- 书签管理器窗口（无边框四件套） ------------------------------------ }
  TFHBookmarksForm = class(TForm)
  private
    FTitle: TLabel;
    FSearchEdit: TEdit;           // 搜索框内嵌 EDIT（外圈胶囊自绘）
    FList: TFHBookmarkList;
    FCloseHot: Boolean;
    FSearchFocused: Boolean;      // 搜索框焦点态（聚焦蓝描边）
    FOnOpen: TFHBookmarkUrlEvent;
    FOnOpenNewTab: TFHBookmarkUrlEvent;
    function Px(V: Integer): Integer;
    function CaptionH: Integer;
    function CloseBtnRect: TRect;
    function SearchRect: TRect;
    procedure BuildUi;
    procedure LayoutUi;
    procedure FormPaint(Sender: TObject);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure SearchEnter(Sender: TObject);
    procedure SearchExit(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure ListOpen(Sender: TObject; const AUrl: string);
    procedure ListOpenNewTab(Sender: TObject; const AUrl: string);
    procedure DrawCloseGlyph(ACanvas: TCanvas; const R: TRect; AColor: TColor);
    procedure WMNCCalcSize(var Message: TWMNCCalcSize);
      message WM_NCCALCSIZE;
    procedure WMNCActivate(var Message: TWMNCActivate);
      message WM_NCACTIVATE;
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure Resize; override;
    procedure DoShow; override;
    procedure DoClose(var Action: TCloseAction); override;
    procedure WMDpiChanged(var Message: TMessage); message WM_DPICHANGED;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
    procedure SetCallbacks(AOnOpen, AOnOpenNewTab: TFHBookmarkUrlEvent);
    procedure RefreshEntries;
  end;

{ 打开"书签管理器"窗口（已开则刷新并前置）。
  AOnOpen       : 在当前标签页打开（单击条目）
  AOnOpenNewTab : 在新标签页中打开（右键菜单） }
procedure ShowBookmarksManager(AOnOpen, AOnOpenNewTab: TFHBookmarkUrlEvent);

{ 以星标/书签条目为锚点弹"添加/修改书签"气泡（已显示则先关再开, 切换目标） }
procedure ShowBookmarkBubble(const AAnchorScreen: TRect;
  const AUrl, ATitle: string);
procedure HideBookmarkBubble;
function IsBookmarkBubbleVisible: Boolean;

{ 书签栏实例注册（主窗体创建书签栏后调; 数据变更时自动 Reload） }
procedure RegisterBookmarkBar(ABar: TFHBookmarkBar);

{ 主窗体注册书签变更处理器（任意入口增删改后回调, 用于刷新地址栏星标态） }
procedure RegisterBookmarksChanged(AChanged: TNotifyEvent);

{ 数据变更统一通知: 刷新书签栏/管理器 + 回调主窗体注册的处理器 }
procedure NotifyBookmarksChanged;

implementation

var
  GBubble: TFHBookmarkBubble = nil;
  GManager: TFHBookmarksForm = nil;
  GBookmarkBar: TFHBookmarkBar = nil;
  GOnBookmarksChanged: TNotifyEvent = nil;

const
  { Chrome 取色（TColor 为 $00BBGGRR） }
  C_BM_BG       = clWhite;
  C_BM_TEXT     = TColor($242120);   // #202124 标题
  C_BM_TEXT2    = TColor($68635F);   // #5F6368 次要文字
  C_BM_BLUE     = TColor($D0570B);   // #0B57D0 蓝按钮
  C_BM_RED      = TColor($2530D9);   // #D93025 删除红
  C_BM_HOVER    = TColor($F4F3F1);   // #F1F3F4 悬停底
  C_BM_EDGE     = TColor($E0DCDA);   // #DADCE0 边框线/分隔线
  C_BM_THUMB    = TColor($E0DCDA);   // 滚动条 thumb
  C_BM_ICONBG   = TColor($E8EAED);   // 占位图标圆底
  C_BM_BTNHOVER = TColor($DCD7D4);   // #D4D7DC 行内按钮悬停底
                                        // （#E8EAED 与行底 #F1F3F4 仅差 3~5 通道,
                                        //  实测肉眼不可辨, 加深一档）

  { 书签栏（96 DPI 基准） }
  C_BAR_H       = 34;      // Chrome BOOKMARK_BAR_HEIGHT
  C_BAR_ITEM_H  = 28;      // 条目高
  C_BAR_ICON    = 16;      // 占位图标直径
  C_BAR_PADX    = 4;       // 首项左留白 / 末项右留白
  C_BAR_TXTPAD  = 8;       // 条目内文字左右留白
  C_BAR_ICONGAP = 6;       // 图标与文字间距
  C_BAR_MAXTXT  = 180;     // 条目文字最大宽（超出省略号）
  C_BAR_RADIUS  = 4;       // 悬停底圆角

  { 气泡（96 DPI 基准） }
  C_BBL_W       = 360;
  C_BBL_CAPT_H  = 44;
  C_BBL_LABEL_H = 16;
  C_BBL_EDIT_H  = 36;
  C_BBL_GAP     = 16;
  C_BBL_BTN_H   = 36;
  C_BBL_DONE_W  = 84;
  C_BBL_DEL_W   = 64;

  { 管理器窗口（96 DPI 基准） }
  C_MGR_W       = 640;
  C_MGR_H       = 560;
  C_MGR_CAPT_H  = 44;
  C_MGR_SEARCH_H = 36;
  C_MGR_ROWBTN  = 28;    // 列表行内按钮尺寸(垃圾桶/⋮), 圆形 hover 底直径
                          // （20px 实测嫌小, Chrome 图标按钮圆底约 28px）

{ ---- GDI+ 辅助（与 uFHHistory 同款取色/路径逻辑） ------------------------- }

{ TColor($00BBGGRR) → GDI+ ARGB($AARRGGBB) }
function ColorToARGB(Color: TColor): ARGB;
var
  C: Cardinal;
begin
  C := ColorToRGB(Color);
  Result := ARGB($FF000000 or (GetRValue(C) shl 16) or
    (GetGValue(C) shl 8) or GetBValue(C));
end;

{ 由 VCL Canvas 创建抗锯齿 GDI+ Graphics; 不可用返回 nil（调用方回退 GDI） }
function MakeGraphics(ACanvas: TCanvas): TGPGraphics;
begin
  Result := nil;
  if (ACanvas = nil) or (ACanvas.Handle = 0) or not EnsureGdiPlus then Exit;
  Result := TGPGraphics.Create(ACanvas.Handle);
  Result.SetSmoothingMode(SmoothingModeAntiAlias);
end;

{ 构造圆角矩形 GDI+ 路径（弧直径夹紧到宽/高, 防胶囊切点错位补竖线） }
function RoundRectPath(const R: TRect; ARadius: Single): TGPGraphicsPath;
var
  L, T, Rt, Bt, D: Single;
begin
  L := R.Left + 0.5;
  T := R.Top + 0.5;
  Rt := R.Right - 0.5;
  Bt := R.Bottom - 0.5;
  D := ARadius * 2;
  { 弧直径不得超过路径宽/高（规范第 4 条: 半径夹紧, 否则胶囊错位补竖线） }
  if D > Rt - L then
    D := Rt - L;
  if D > Bt - T then
    D := Bt - T;
  if D < 1 then
    D := 1;
  Result := TGPGraphicsPath.Create;
  Result.AddArc(L, T, D, D, 180, 90);
  Result.AddArc(Rt - D, T, D, D, 270, 90);
  Result.AddArc(Rt - D, Bt - D, D, D, 0, 90);
  Result.AddArc(L, Bt - D, D, D, 90, 90);
  Result.CloseFigure;
end;

{ 抗锯齿画圆角矩形（填充 + 可选描边, 半径随描边内缩夹紧）; GDI+ 回退 GDI }
procedure DrawRoundRect(ACanvas: TCanvas; const R: TRect; ARadius: Integer;
  AFill, ABorder: TColor; ABorderW: Integer);
var
  G: TGPGraphics;
  Path: TGPGraphicsPath;
  Brush: TGPSolidBrush;
  Pen: TGPPen;
  RR: TRect;
begin
  RR := R;
  if ABorderW > 0 then
    InflateRect(RR, -(ABorderW div 2), -(ABorderW div 2));
  { 描边内缩后半径夹紧到半宽/半高（规范第 4 条） }
  if ARadius * 2 > RR.Right - RR.Left then
    ARadius := (RR.Right - RR.Left) div 2;
  if ARadius * 2 > RR.Bottom - RR.Top then
    ARadius := (RR.Bottom - RR.Top) div 2;
  if ARadius < 1 then
    ARadius := 1;
  G := MakeGraphics(ACanvas);
  if G = nil then
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := AFill;
    ACanvas.Pen.Color := ABorder;
    ACanvas.Pen.Width := ABorderW;
    ACanvas.RoundRect(RR.Left, RR.Top, RR.Right, RR.Bottom,
      ARadius * 2, ARadius * 2);
    Exit;
  end;
  Path := RoundRectPath(RR, ARadius);
  try
    Brush := TGPSolidBrush.Create(ColorToARGB(AFill));
    try
      G.FillPath(Brush, Path);
    finally
      Brush.Free;
    end;
    if ABorderW > 0 then
    begin
      Pen := TGPPen.Create(ColorToARGB(ABorder), ABorderW);
      try
        G.DrawPath(Pen, Path);
      finally
        Pen.Free;
      end;
    end;
  finally
    Path.Free;
    G.Free;
  end;
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

{ Win32 DrawText 封装: const 矩形转 var + 透明文字背景
  （不设 TRANSPARENT 时每行文字带白底, 悬停灰底上露白块） }
procedure DrawTextD(ACanvas: TCanvas; const S: string; const R: TRect;
  AFlags: Cardinal);
var
  RR: TRect;
begin
  { Win32 DrawText 的第四参是 var TRect, 不能直接传 const → 复制到局部 }
  RR := R;
  { 透明文字背景: DC 的 bkMode/bkColor 残留自先前的 FillRect(bsSolid 白),
    不设 TRANSPARENT 时每行文字会用白底填充（悬停灰底上露出白块） }
  SetBkMode(ACanvas.Handle, TRANSPARENT);
  DrawText(ACanvas.Handle, PChar(S), -1, RR, AFlags or DT_NOPREFIX);
end;

{ 占位图标: 圆底 + 标题首字符（不下载真 favicon） }
procedure DrawFaviconPlaceholder(ACanvas: TCanvas; const R: TRect;
  const ATitle: string);
var
  Ch: string;
  SaveColor: TColor;
  SaveHeight: Integer;
begin
  if ATitle <> '' then
    Ch := Copy(ATitle, 1, 1)
  else
    Ch := '?';
  FillCircleAA(ACanvas, R, C_BM_ICONBG);
  SaveColor := ACanvas.Font.Color;
  SaveHeight := ACanvas.Font.Height;
  ACanvas.Font.Color := C_BM_TEXT2;
  ACanvas.Font.Height := MulDiv(SaveHeight, 8, 12);   // 图标字号 ≈ 2/3
  DrawTextD(ACanvas, Ch, R, DT_CENTER or DT_VCENTER or DT_SINGLELINE);
  ACanvas.Font.Color := SaveColor;
  ACanvas.Font.Height := SaveHeight;
end;

{ ============================ TFHBookmarkBar =============================== }

{ 构造: 默认条高按屏幕 DPI 换算, 建条目右键菜单（打开/新标签/编辑/删除） }
constructor TFHBookmarkBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  if Screen <> nil then
    Height := MulDiv(C_BAR_H, Screen.PixelsPerInch, 96)
  else
    Height := C_BAR_H;
  FHot := -1;
  FOverflowFrom := -1;
  FItemH := -1;
  Color := clWhite;
  { 条目右键菜单（固定项, 目标条目存 FMenuEntry） }
  FMenu := TFHMenu.Create(Self);
  FMenu.Add('打开', MenuOpen, '', miOpen);
  FMenu.Add('在新标签页中打开', MenuOpenNewTab, '', miNewTab);
  FMenu.AddSeparator;
  FMenu.Add('编辑', MenuEdit, '', miEdit);
  FMenu.Add('删除', MenuDelete, '', miDelete);
end;

{ 析构: 全局书签栏指针自清（防悬垂） }
destructor TFHBookmarkBar.Destroy;
begin
  if GBookmarkBar = Self then
    GBookmarkBar := nil;
  inherited;
end;

{ 96 DPI 基准逻辑像素 → 窗口实际像素（无句柄期按屏幕 DPI 兜底） }
function TFHBookmarkBar.Px(V: Integer): Integer;
var
  DPI, DC: Integer;
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

{ 按当前 DPI 设画布字体（12px Segoe UI） }
procedure TFHBookmarkBar.ApplyFont;
begin
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.Height := -Px(12);
  Canvas.Font.Style := [];
  Canvas.Font.Color := C_BM_TEXT;
end;

procedure TFHBookmarkBar.Reload;
begin
  FEntries := HistoryDB.QueryBookmarks('');
  FHot := -1;
  MeasureLayout;
  Invalidate;
end;

{ 测量条目布局: 逐项量文字宽累计左边界, 放不下的项折叠进溢出菜单 }
procedure TFHBookmarkBar.MeasureLayout;
var
  I, X, W, IconW, TxtW, OverW: Integer;
begin
  ApplyFont;
  if FItemH < 0 then
    FItemH := Px(C_BAR_ITEM_H);
  IconW := Px(C_BAR_ICON);
  OverW := Px(C_BAR_ITEM_H);      // 溢出按钮宽（方形）
  SetLength(FTops, Length(FEntries));
  SetLength(FWidths, Length(FEntries));
  X := Px(C_BAR_PADX);
  FOverflowFrom := -1;
  for I := 0 to High(FEntries) do
  begin
    TxtW := Canvas.TextWidth(FEntries[I].Title);
    if TxtW > Px(C_BAR_MAXTXT) then
      TxtW := Px(C_BAR_MAXTXT);
    W := Px(C_BAR_TXTPAD) + IconW + Px(C_BAR_ICONGAP) + TxtW +
      Px(C_BAR_TXTPAD);
    { 放不下（给溢出按钮留位） → 从这里开始折叠 }
    if X + W > Width - Px(C_BAR_PADX) - OverW then
    begin
      FOverflowFrom := I;
      Break;
    end;
    FTops[I] := X;
    FWidths[I] := W;
    Inc(X, W);
  end;
end;

{ 第 I 个条目的矩形（垂直居中于栏高） }
function TFHBookmarkBar.ItemRect(I: Integer): TRect;
begin
  Result := Rect(FTops[I], (Height - FItemH) div 2,
    FTops[I] + FWidths[I], (Height - FItemH) div 2 + FItemH);
end;

{ 溢出按钮 » 的矩形（右端方形） }
function TFHBookmarkBar.OverflowRect: TRect;
begin
  Result := Rect(Width - Px(C_BAR_PADX) - Px(C_BAR_ITEM_H),
    (Height - FItemH) div 2, Width - Px(C_BAR_PADX),
    (Height - FItemH) div 2 + FItemH);
end;

{ 坐标 → 条目索引（折叠项不命中）; 命中溢出按钮返回 Count }
function TFHBookmarkBar.IndexAt(X, Y: Integer): Integer;
var
  I: Integer;
  R: TRect;
begin
  Result := -1;
  if (Y < 0) or (Y > Height) then Exit;
  for I := 0 to High(FEntries) do
  begin
    if (FOverflowFrom >= 0) and (I >= FOverflowFrom) then
      Break;
    R := ItemRect(I);
    if (X >= R.Left) and (X < R.Right) then
      Exit(I);
  end;
  if FOverflowFrom >= 0 then
  begin
    R := OverflowRect;
    if (X >= R.Left) and (X < R.Right) then
      Exit(Length(FEntries));   // 溢出按钮
  end;
end;

{ 按 URL 反查条目索引; 未找到返回 -1 }
function TFHBookmarkBar.IndexOfEntry(const AUrl: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FEntries) do
    if SameText(FEntries[I].Url, AUrl) then
      Exit(I);
end;

{ 客户区矩形 → 屏幕坐标矩形 }
function TFHBookmarkBar.ClientToScreenRect(const R: TRect): TRect;
var
  P1, P2: TPoint;
begin
  P1 := ClientToScreen(Point(R.Left, R.Top));
  P2 := ClientToScreen(Point(R.Right, R.Bottom));
  Result := Rect(P1.X, P1.Y, P2.X, P2.Y);
end;

{ 自绘: 逐条目画悬停底 + 占位图标 + 标题, 折叠时画溢出按钮 » }
procedure TFHBookmarkBar.Paint;
var
  I, IconW, LineH, TxtY: Integer;
  R, IconR: TRect;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_BM_BG;
  Canvas.Pen.Color := C_BM_BG;
  Canvas.FillRect(ClientRect);
  if Length(FEntries) = 0 then
    Exit;
  ApplyFont;
  IconW := Px(C_BAR_ICON);
  LineH := Canvas.TextHeight('Wg');
  for I := 0 to High(FEntries) do
  begin
    if (FOverflowFrom >= 0) and (I >= FOverflowFrom) then
      Break;
    R := ItemRect(I);
    if I = FHot then
      DrawRoundRect(Canvas, R, Px(C_BAR_RADIUS), C_BM_HOVER, clNone, 0);
    IconR := Rect(R.Left + Px(C_BAR_TXTPAD),
      R.Top + (FItemH - IconW) div 2,
      R.Left + Px(C_BAR_TXTPAD) + IconW,
      R.Top + (FItemH - IconW) div 2 + IconW);
    DrawFaviconPlaceholder(Canvas, IconR, FEntries[I].Title);
    { 标题: 单行, 按实测行盒垂直居中, DT_END_ELLIPSIS 截断 }
    TxtY := R.Top + (FItemH - LineH) div 2;
    DrawTextD(Canvas, FEntries[I].Title,
      Rect(IconR.Right + Px(C_BAR_ICONGAP), TxtY,
        R.Right - Px(C_BAR_TXTPAD), TxtY + LineH + 2),
      DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
  end;
  { 溢出按钮 »（双 chevron） }
  if FOverflowFrom >= 0 then
  begin
    R := OverflowRect;
    if FHot = Length(FEntries) then
      DrawRoundRect(Canvas, R, Px(C_BAR_RADIUS), C_BM_HOVER, clNone, 0);
    DrawChevronGlyph(Canvas, R);
  end;
end;

{ 画溢出按钮的双 chevron（GDI+ 抗锯齿, 回退 GDI 折线） }
procedure TFHBookmarkBar.DrawChevronGlyph(ACanvas: TCanvas; const R: TRect);
var
  G: TGPGraphics;
  P: TGPPen;
  CX, CY, S, D, I: Integer;
begin
  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  S := Px(4);
  D := Px(2);
  G := MakeGraphics(ACanvas);
  if G = nil then
  begin
    ACanvas.Pen.Color := C_BM_TEXT2;
    ACanvas.Pen.Width := Max(1, Px(1));
    for I := 0 to 1 do
    begin
      ACanvas.MoveTo(CX - S + I * (S - D), CY - D);
      ACanvas.LineTo(CX + I * (S - D), CY);
      ACanvas.LineTo(CX - S + I * (S - D), CY + D);
    end;
    Exit;
  end;
  try
    P := TGPPen.Create(ColorToARGB(C_BM_TEXT2), Max(1, Px(1)));
    try
      P.SetStartCap(LineCapRound);
      P.SetEndCap(LineCapRound);
      for I := 0 to 1 do
      begin
        G.DrawLine(P, CX - S + I * (S - D), CY - D, CX + I * (S - D), CY);
        G.DrawLine(P, CX + I * (S - D), CY, CX - S + I * (S - D), CY + D);
      end;
    finally
      P.Free;
    end;
  finally
    G.Free;
  end;
end;

{ 尺寸变化: 重新测量布局（可容纳条目数变化） }
procedure TFHBookmarkBar.Resize;
begin
  inherited;
  MeasureLayout;
end;

{ 句柄创建后: 按真实 DPI 重测条目高度并重摆 }
procedure TFHBookmarkBar.CreateWnd;
begin
  inherited CreateWnd;
  { 无句柄期按主屏 DPI 兜底测量的缓存重测（规范第 5 条） }
  FItemH := -1;
  MeasureLayout;
  Invalidate;
end;

{ DPI 变化（跨屏）: 清高度缓存并重测布局 }
procedure TFHBookmarkBar.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  FItemH := -1;
  MeasureLayout;
end;

{ 鼠标移动: 跟踪悬停条目, 变化时重绘 }
procedure TFHBookmarkBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited;
  I := IndexAt(X, Y);
  if I <> FHot then
  begin
    FHot := I;
    Invalidate;
  end;
end;

{ 鼠标按下: 左键/Ctrl+左键 = 当前/新标签打开, 中键 = 新标签打开,
  右键 = 条目菜单, 溢出按钮左键 = 溢出菜单 }
procedure TFHBookmarkBar.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  I: Integer;
  E: TFHBookmarkEntry;
begin
  inherited;
  I := IndexAt(X, Y);
  if I < 0 then Exit;
  if I = Length(FEntries) then
  begin
    if Button = mbLeft then
      ShowOverflowMenu;
    Exit;
  end;
  E := FEntries[I];
  case Button of
    mbLeft:
      if ssCtrl in Shift then
      begin
        if Assigned(FOnOpenNewTab) then
          FOnOpenNewTab(Self, E.Url);
      end
      else if Assigned(FOnOpen) then
        FOnOpen(Self, E.Url);
    mbMiddle:
      if Assigned(FOnOpenNewTab) then
        FOnOpenNewTab(Self, E.Url);
    mbRight:
      ShowContextMenu(I);
  end;
end;

{ 鼠标离开: 清悬停态并重绘 }
procedure TFHBookmarkBar.CMMouseLeave(var Message: TMessage);
begin
  FHot := -1;
  Invalidate;
end;

{ 弹条目右键菜单（锚在条目正下方, 目标存 FMenuEntry） }
procedure TFHBookmarkBar.ShowContextMenu(I: Integer);
var
  P: TPoint;
  R: TRect;
begin
  if (I < 0) or (I > High(FEntries)) then Exit;
  FMenuEntry := FEntries[I];
  R := ItemRect(I);
  P := ClientToScreen(Point(R.Left, R.Bottom));
  FMenu.Popup(P.X, P.Y);
end;

{ 弹溢出菜单: 收纳放不下的条目（每次重建, 条目索引存 Tag） }
procedure TFHBookmarkBar.ShowOverflowMenu;
var
  I: Integer;
  P: TPoint;
  R: TRect;
begin
  if FOverflowFrom < 0 then Exit;
  { 菜单条目随书签集合变化 → 每次重建（TFHMenu 无 Clear; 旧菜单窗口
    此前早已关闭, 无重入风险） }
  FreeAndNil(FOverflowMenu);
  FOverflowMenu := TFHMenu.Create(Self);
  for I := FOverflowFrom to High(FEntries) do
    FOverflowMenu.Add(FEntries[I].Title, MenuOverflowOpen, '', miPage).Tag := I;
  R := OverflowRect;
  P := ClientToScreen(Point(R.Left, R.Bottom));
  FOverflowMenu.Popup(P.X, P.Y);
end;

{ 菜单"打开": 触发 OnOpen }
procedure TFHBookmarkBar.MenuOpen(Sender: TObject);
begin
  if Assigned(FOnOpen) then
    FOnOpen(Self, FMenuEntry.Url);
end;

{ 菜单"在新标签页中打开": 触发 OnOpenNewTab }
procedure TFHBookmarkBar.MenuOpenNewTab(Sender: TObject);
begin
  if Assigned(FOnOpenNewTab) then
    FOnOpenNewTab(Self, FMenuEntry.Url);
end;

{ 菜单"编辑": 以该条目为锚点弹书签编辑气泡 }
procedure TFHBookmarkBar.MenuEdit(Sender: TObject);
var
  I: Integer;
  R: TRect;
begin
  I := IndexOfEntry(FMenuEntry.Url);
  if I < 0 then Exit;
  R := ClientToScreenRect(ItemRect(I));
  ShowBookmarkBubble(R, FMenuEntry.Url, FMenuEntry.Title);
end;

{ 菜单"删除": 删库并广播书签变更 }
procedure TFHBookmarkBar.MenuDelete(Sender: TObject);
begin
  HistoryDB.DeleteBookmarkUrl(FMenuEntry.Url);
  NotifyBookmarksChanged;
end;

{ 溢出菜单条目点击: 按 Tag 取索引, 触发 OnOpen }
procedure TFHBookmarkBar.MenuOverflowOpen(Sender: TObject);
var
  I: Integer;
begin
  if Sender is TFHMenuItem then
  begin
    I := TFHMenuItem(Sender).Tag;
    if (I >= 0) and (I <= High(FEntries)) and Assigned(FOnOpen) then
      FOnOpen(Self, FEntries[I].Url);
  end;
end;

{ ============================ TFHBookmarkBubble ============================ }

{ 构造: 无边框工具窗气泡（系统投影）, 建名称/网址两个输入框并布局 }
constructor TFHBookmarkBubble.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  Scaled := False;
  BorderStyle := bsNone;
  Color := C_BM_BG;
  Font.Name := 'Segoe UI';
  KeyPreview := True;
  DoubleBuffered := True;
  Width := Px(C_BBL_W);
  ClientHeight := Px(C_BBL_CAPT_H + C_BBL_LABEL_H + 8 + C_BBL_EDIT_H +
    C_BBL_GAP + C_BBL_LABEL_H + 8 + C_BBL_EDIT_H + C_BBL_GAP + C_BBL_BTN_H +
    C_BBL_GAP);
  OnPaint := FormPaint;
  OnMouseMove := FormMouseMove;
  OnMouseDown := FormMouseDown;
  OnDeactivate := FormDeactivate;
  OnKeyDown := FormKeyDown;
  FIsNew := True;
  FDoneHot := False;
  FDeleteHot := False;
  BuildUi;
  LayoutUi;
end;

{ 析构: 全局气泡指针自清（防悬垂） }
destructor TFHBookmarkBubble.Destroy;
begin
  if GBubble = Self then
    GBubble := nil;
  inherited;
end;

{ 工具窗样式（不占任务栏/Alt-Tab）+ 系统投影（与下载气泡同款） }
procedure TFHBookmarkBubble.CreateParams(var Params: TCreateParams);
begin
  inherited;
  { 工具窗（不占任务栏/Alt-Tab）+ 系统投影（与下载气泡同款） }
  Params.ExStyle := Params.ExStyle or WS_EX_TOOLWINDOW;
  Params.WindowClass.Style := Params.WindowClass.Style or CS_DROPSHADOW;
end;

{ 96 DPI 基准逻辑像素 → 窗口实际像素（无句柄期按屏幕 DPI 兜底） }
function TFHBookmarkBubble.Px(V: Integer): Integer;
var
  DPI, DC: Integer;
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

{ 把内嵌 EDIT 的字号钉死为设计像素值（VCL SetParent 双重缩放坑,
  见 TFHAddressBar.PinEditFont 同款注释） }
procedure TFHBookmarkBubble.PinFont(AEdit: TEdit; AFontPx: Integer);
var
  PPI, DC: Integer;
begin
  if AEdit = nil then Exit;
  PPI := 0;
  if AEdit.HandleAllocated then
  begin
    DC := GetDC(AEdit.Handle);
    PPI := GetDeviceCaps(DC, LOGPIXELSX);
    ReleaseDC(AEdit.Handle, DC);
  end;
  if PPI <= 0 then
    PPI := Screen.PixelsPerInch;
  if PPI <= 0 then
    PPI := 96;
  AEdit.Font.PixelsPerInch := PPI;
  AEdit.Font.Height := -MulDiv(AFontPx, PPI, 96);
end;

{ 建名称/网址两个内嵌无边框 TEdit }
procedure TFHBookmarkBubble.BuildUi;
begin
  FNameEdit := TEdit.Create(Self);
  FNameEdit.Parent := Self;
  FNameEdit.BorderStyle := bsNone;
  FNameEdit.Color := clWhite;
  FNameEdit.Font.Name := 'Segoe UI';
  FNameEdit.Font.Color := C_BM_TEXT;
  FNameEdit.TextHint := '名称';
  FNameEdit.OnKeyDown := EditKeyDown;

  FUrlEdit := TEdit.Create(Self);
  FUrlEdit.Parent := Self;
  FUrlEdit.BorderStyle := bsNone;
  FUrlEdit.Color := clWhite;
  FUrlEdit.Font.Name := 'Segoe UI';
  FUrlEdit.Font.Color := C_BM_TEXT2;
  FUrlEdit.TextHint := '网址';
  FUrlEdit.OnKeyDown := EditKeyDown;
end;

{ 重排子控件: 两个输入框 + 右下角 [删除] [完成] 按钮矩形 }
procedure TFHBookmarkBubble.LayoutUi;
var
  Pad, Y, EditW: Integer;
begin
  Pad := Px(C_BBL_GAP);
  EditW := ClientWidth - 2 * Pad;
  Y := Px(C_BBL_CAPT_H) + Px(C_BBL_LABEL_H) + Px(8);
  FNameEdit.SetBounds(Pad + Px(8), Y + Px(8), EditW - Px(16),
    Px(C_BBL_EDIT_H) - Px(16));
  Inc(Y, Px(C_BBL_EDIT_H) + Px(C_BBL_GAP));
  Inc(Y, Px(C_BBL_LABEL_H) + Px(8));
  FUrlEdit.SetBounds(Pad + Px(8), Y + Px(8), EditW - Px(16),
    Px(C_BBL_EDIT_H) - Px(16));
  { 按钮行: 右下角 [删除] [完成] }
  FDoneRect := Rect(ClientWidth - Pad - Px(C_BBL_DONE_W),
    ClientHeight - Px(C_BBL_GAP) - Px(C_BBL_BTN_H),
    ClientWidth - Pad, ClientHeight - Px(C_BBL_GAP));
  FDeleteRect := Rect(FDoneRect.Left - Px(12) - Px(C_BBL_DEL_W),
    FDoneRect.Top, FDoneRect.Left - Px(12), FDoneRect.Bottom);
end;

{ 全窗自绘: 边框线 + 标题（添加/修改书签）+ 名称/网址表单外框
  + 完成蓝胶囊 + 删除红字按钮（悬停下划线） }
procedure TFHBookmarkBubble.FormPaint(Sender: TObject);
var
  R: TRect;
begin
  R := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_BM_BG;
  Canvas.FillRect(R);
  { 1px 边框线（Chrome 灰 #DADCE0） }
  Canvas.Pen.Color := C_BM_EDGE;
  Canvas.Pen.Width := 1;
  Canvas.Brush.Style := bsClear;
  Canvas.MoveTo(R.Left, R.Top);
  Canvas.LineTo(R.Right - 1, R.Top);
  Canvas.LineTo(R.Right - 1, R.Bottom - 1);
  Canvas.LineTo(R.Left, R.Bottom - 1);
  Canvas.LineTo(R.Left, R.Top);

  { 标题 }
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.Height := -Px(16);
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := C_BM_TEXT;
  if FIsNew then
    DrawTextD(Canvas, '添加书签',
      Rect(Px(C_BBL_GAP), 0, ClientWidth - Px(48), Px(C_BBL_CAPT_H)),
      DT_LEFT or DT_VCENTER or DT_SINGLELINE)
  else
    DrawTextD(Canvas, '修改书签',
      Rect(Px(C_BBL_GAP), 0, ClientWidth - Px(48), Px(C_BBL_CAPT_H)),
      DT_LEFT or DT_VCENTER or DT_SINGLELINE);
  Canvas.Font.Style := [];

  { 表单: 标签 + 输入框外框（两个同构块） }
  Canvas.Font.Height := -Px(12);
  Canvas.Font.Color := C_BM_TEXT2;
  R := Rect(Px(C_BBL_GAP), Px(C_BBL_CAPT_H),
    ClientWidth - Px(C_BBL_GAP), Px(C_BBL_CAPT_H + C_BBL_LABEL_H));
  DrawTextD(Canvas, '名称', R, DT_LEFT or DT_VCENTER or DT_SINGLELINE);
  R := Rect(Px(C_BBL_GAP), R.Bottom + Px(8),
    ClientWidth - Px(C_BBL_GAP), R.Bottom + Px(8) + Px(C_BBL_EDIT_H));
  DrawRoundRect(Canvas, R, Px(4), clWhite, C_BM_EDGE, 1);
  R := Rect(Px(C_BBL_GAP), R.Bottom + Px(C_BBL_GAP),
    ClientWidth - Px(C_BBL_GAP), R.Bottom + Px(C_BBL_GAP) +
    Px(C_BBL_LABEL_H));
  DrawTextD(Canvas, '网址', R, DT_LEFT or DT_VCENTER or DT_SINGLELINE);
  R := Rect(Px(C_BBL_GAP), R.Bottom + Px(8),
    ClientWidth - Px(C_BBL_GAP), R.Bottom + Px(8) + Px(C_BBL_EDIT_H));
  DrawRoundRect(Canvas, R, Px(4), clWhite, C_BM_EDGE, 1);

  { 完成按钮（蓝胶囊白字） }
  DrawRoundRect(Canvas, FDoneRect, FDoneRect.Height div 2, C_BM_BLUE,
    clNone, 0);
  Canvas.Font.Height := -Px(14);
  Canvas.Font.Color := clWhite;
  DrawTextD(Canvas, '完成', FDoneRect,
    DT_CENTER or DT_VCENTER or DT_SINGLELINE);
  { 删除按钮（红文字按钮, 仅修改模式） }
  if not FIsNew then
  begin
    Canvas.Font.Color := C_BM_RED;
    if FDeleteHot then
      Canvas.Font.Style := [fsUnderline];
    DrawTextD(Canvas, '删除', FDeleteRect,
      DT_CENTER or DT_VCENTER or DT_SINGLELINE);
    Canvas.Font.Style := [];
  end;
end;

{ 鼠标移动: 跟踪完成/删除按钮悬停态, 变化时重绘 }
procedure TFHBookmarkBubble.FormMouseMove(Sender: TObject;
  Shift: TShiftState; X, Y: Integer);
var
  NewDone, NewDelete: Boolean;
begin
  NewDone := PtInRect(FDoneRect, Point(X, Y));
  NewDelete := (not FIsNew) and PtInRect(FDeleteRect, Point(X, Y));
  if (NewDone <> FDoneHot) or (NewDelete <> FDeleteHot) then
  begin
    FDoneHot := NewDone;
    FDeleteHot := NewDelete;
    Invalidate;
  end;
end;

{ 鼠标按下: 命中完成/删除按钮则执行对应动作 }
procedure TFHBookmarkBubble.FormMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  if PtInRect(FDoneRect, Point(X, Y)) then
    DoneClick
  else if (not FIsNew) and PtInRect(FDeleteRect, Point(X, Y)) then
    DeleteClick;
end;

{ 失焦即关闭（未提交的改动丢弃, 与 Chrome 气泡一致） }
procedure TFHBookmarkBubble.FormDeactivate(Sender: TObject);
begin
  Close;   { 失焦即关闭（未提交的改动丢弃, 与 Chrome 气泡一致） }
end;

{ 窗体级按键: Esc 关闭气泡 }
procedure TFHBookmarkBubble.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    Close;
  end;
end;

{ 输入框按键: 回车 = 保存, Esc = 关闭 }
procedure TFHBookmarkBubble.EditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    Key := 0;
    DoneClick;
  end
  else if Key = VK_ESCAPE then
  begin
    Key := 0;
    Close;
  end;
end;

{ 显示: 激活窗体（失焦关闭依赖激活）并聚焦名称输入框 }
procedure TFHBookmarkBubble.DoShow;
begin
  inherited;
  SetFocus;         { 激活才能靠"失焦关闭"工作, 并接收 Esc/Enter }
  if FNameEdit <> nil then
    FNameEdit.SetFocus;
end;

{ 关闭: 释放窗口（全局指针在 Destroy 里清） }
procedure TFHBookmarkBubble.DoClose(var Action: TCloseAction);
begin
  inherited;
  Action := caFree;
end;

procedure TFHBookmarkBubble.ShowEdit(const AAnchorScreen: TRect;
  const AUrl, ATitle: string);
var
  WA: TRect;
  X, Y: Integer;
begin
  FIsNew := not HistoryDB.BookmarkExists(AUrl);
  FOrigUrl := AUrl;
  FNameEdit.Text := ATitle;
  FUrlEdit.Text := AUrl;
  PinFont(FNameEdit, 14);
  PinFont(FUrlEdit, 14);
  LayoutUi;
  { 位置: 锚定矩形正下方, 左对齐, 按屏幕工作区夹紧; 下方放不下改上方 }
  WA := Screen.WorkAreaRect;
  X := AAnchorScreen.Left;
  if X + Width > WA.Right then
    X := WA.Right - Width;
  if X < WA.Left then
    X := WA.Left;
  Y := AAnchorScreen.Bottom + Px(4);
  if Y + Height > WA.Bottom then
    Y := AAnchorScreen.Top - Height - Px(4);
  if Y < WA.Top then
    Y := WA.Top;
  SetBounds(X, Y, Width, Height);
  Show;
  BringToFront;
end;

{ "完成": 新增（AddBookmark）或修改（UpdateBookmark 按原 URL 定位）,
  成功后广播书签变更并关闭 }
procedure TFHBookmarkBubble.DoneClick;
var
  Url, Name: string;
begin
  Url := Trim(FUrlEdit.Text);
  Name := Trim(FNameEdit.Text);
  if Url = '' then
    Url := FOrigUrl;
  if Name = '' then
    Name := Url;
  try
    if FIsNew then
      HistoryDB.AddBookmark(Url, Name)
    else
      HistoryDB.UpdateBookmark(FOrigUrl, Url, Name);
  except
    on E: Exception do
      Logger.Error('保存书签失败: %s - %s', [E.ClassName, E.Message]);
  end;
  NotifyBookmarksChanged;
  Close;
end;

{ "删除": 删书签（仅修改模式）, 广播变更并关闭 }
procedure TFHBookmarkBubble.DeleteClick;
begin
  try
    HistoryDB.DeleteBookmarkUrl(FOrigUrl);
  except
    on E: Exception do
      Logger.Error('删除书签失败: %s - %s', [E.ClassName, E.Message]);
  end;
  NotifyBookmarksChanged;
  Close;
end;

{ ============================ TFHBookmarkList ============================== }

{ 构造: 建行右键菜单（打开/新标签/复制/编辑/删除） }
constructor TFHBookmarkList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FHot := -1;
  FDeleteHot := False;
  FRowH := -1;
  FOffset := 0;
  Color := clWhite;
  FMenu := TFHMenu.Create(Self);
  FMenu.Add('在当前标签页中打开', MenuOpen, '', miOpen);
  FMenu.Add('在新标签页中打开', MenuOpenNewTab, '', miNewTab);
  FMenu.AddSeparator;
  FMenu.Add('复制网址', MenuCopy, '', miLink);
  FMenu.Add('编辑', MenuEdit, '', miEdit);
  FMenu.Add('删除', MenuDelete, '', miDelete);
end;

{ 析构: 菜单随 Owner 释放, 无额外清理 }
destructor TFHBookmarkList.Destroy;
begin
  inherited;
end;

{ 96 DPI 基准逻辑像素 → 窗口实际像素（无句柄期按屏幕 DPI 兜底） }
function TFHBookmarkList.Px(V: Integer): Integer;
var
  DPI, DC: Integer;
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

{ 设画布基础字体（Segoe UI, 字号由调用方按像素指定） }
procedure TFHBookmarkList.ApplyFont;
begin
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.Style := [];
end;

{ 行高 = 上留白 + 标题行盒 + 行间距 + 次行行盒 + 下留白（规范第 4 条:
  按实测行盒, 不用固定像素区高 + DT_VCENTER） }
function TFHBookmarkList.RowHeight: Integer;
begin
  if FRowH < 0 then
  begin
    ApplyFont;
    Canvas.Font.Height := -Px(14);
    FRowH := Px(10) + Canvas.TextHeight('Wg');
    Canvas.Font.Height := -Px(12);
    Inc(FRowH, Px(4) + Canvas.TextHeight('Wg'));
    Inc(FRowH, Px(10));
  end;
  Result := FRowH;
end;

{ 累计各行顶边与内容总高, 并夹紧滚动偏移 }
procedure TFHBookmarkList.BuildTops;
var
  I: Integer;
begin
  SetLength(FTops, Length(FEntries));
  FContentH := 0;
  for I := 0 to High(FEntries) do
  begin
    FTops[I] := FContentH;
    Inc(FContentH, RowHeight);
  end;
  if FOffset > MaxOffset then
    FOffset := MaxOffset;
end;

{ 最大滚动偏移 = 内容高 - 客户区高（下限 0） }
function TFHBookmarkList.MaxOffset: Integer;
begin
  Result := Max(0, FContentH - ClientHeight);
end;

procedure TFHBookmarkList.SetEntries(const AEntries: TFHBookmarkEntries;
  const AKeyword: string);
begin
  FEntries := AEntries;
  FKeyword := AKeyword;
  FHot := -1;
  FDeleteHot := False;
  FMenuBtnHot := False;
  FOffset := 0;
  BuildTops;
  Invalidate;
end;

{ 客户区 y → 行索引（含滚动偏移换算）; 未命中返回 -1 }
function TFHBookmarkList.IndexAtY(Y: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FEntries) do
    if (Y + FOffset >= FTops[I]) and (Y + FOffset < FTops[I] + RowHeight) then
      Exit(I);
end;

{ 按 URL 反查行索引; 未找到返回 -1 }
function TFHBookmarkList.IndexOfEntry(const AUrl: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FEntries) do
    if SameText(FEntries[I].Url, AUrl) then
      Exit(I);
end;

{ 滚动条滑块矩形（右缘 6px 宽, 高度按可视比例, 最小 30px） }
function TFHBookmarkList.ThumbRect: TRect;
var
  TH, TY: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if (MaxOffset <= 0) or (ClientHeight <= 0) then Exit;
  TH := Max(Px(30), MulDiv(ClientHeight, ClientHeight, FContentH));
  TY := MulDiv(ClientHeight - TH, FOffset, MaxOffset);
  Result := Rect(ClientWidth - Px(8), TY, ClientWidth - Px(2), TY + TH);
end;

{ 行删除按钮矩形: 悬停行右侧, 垂直居中, 排在 ⋮ 按钮左侧（布局见体内注释） }
function TFHBookmarkList.DeleteBtnRect(ARow: Integer): TRect;
var
  Btn, X, Y: Integer;
begin
  { C_MGR_ROWBTN=28 逻辑像素, 垂直居中于行; 排在"⋮"菜单按钮左侧 4px
    （右缘布局: 滚动条 8 + 留白 12 + ⋮ 28 + 缝 4 + 垃圾桶 28 = 80,
    与 Paint 里文字区右移量 Px(92) 保持不冲突） }
  Btn := Px(C_MGR_ROWBTN);
  X := ClientWidth - Px(8) - Px(12) - Btn - Px(4) - Btn;
  Y := FTops[ARow] - FOffset;
  Result := Rect(X, Y + (RowHeight - Btn) div 2, X + Btn,
    Y + (RowHeight + Btn) div 2);
end;

{ 行"⋮"菜单按钮矩形: 行最右, 垂直居中 }
function TFHBookmarkList.MenuBtnRect(ARow: Integer): TRect;
var
  Btn, X, Y: Integer;
begin
  { "⋮"菜单按钮: 行最右的 C_MGR_ROWBTN 按钮（原删除按钮位置） }
  Btn := Px(C_MGR_ROWBTN);
  X := ClientWidth - Px(8) - Px(12) - Btn;
  Y := FTops[ARow] - FOffset;
  Result := Rect(X, Y + (RowHeight - Btn) div 2, X + Btn,
    Y + (RowHeight + Btn) div 2);
end;

{ 滚动到指定偏移（夹取到 [0, MaxOffset], 值不变不重绘） }
procedure TFHBookmarkList.ScrollTo(AOffset: Integer);
begin
  AOffset := Max(0, Min(MaxOffset, AOffset));
  if AOffset <> FOffset then
  begin
    FOffset := AOffset;
    Invalidate;
  end;
end;

{ 全件自绘: 行高一致性自愈（同历史列表）→ 空态文案/逐行悬停底+图标
  +标题/网址两行+删除/⋮按钮 → 滚动条 }
procedure TFHBookmarkList.Paint;
var
  I, IconW, LineH, T1, T2: Integer;
  RowR, IconR: TRect;
begin
  { 行高自愈（与历史列表同款）: 无句柄期首测的行高与绘制 DC 度量不一致
    时在此重测重建, 避免首开行距挤 }
  if FRowH > 0 then
  begin
    ApplyFont;
    Canvas.Font.Height := -Px(14);
    T1 := Canvas.TextHeight('Wg');
    Canvas.Font.Height := -Px(12);
    T2 := Canvas.TextHeight('Wg');
    if FRowH <> Px(10) + T1 + Px(4) + T2 + Px(10) then
    begin
      FRowH := -1;
      RowHeight;
      BuildTops;
      if FOffset > MaxOffset then
        FOffset := MaxOffset;
    end;
  end;

  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_BM_BG;
  Canvas.Pen.Color := C_BM_BG;
  Canvas.FillRect(ClientRect);
  if Length(FEntries) = 0 then
  begin
    ApplyFont;
    Canvas.Font.Height := -Px(14);
    Canvas.Font.Color := C_BM_TEXT2;
    if FKeyword <> '' then
      DrawTextD(Canvas, '无搜索结果', ClientRect,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE)
    else
      DrawTextD(Canvas, '书签栏为空', ClientRect,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE);
    Exit;
  end;
  IconW := Px(C_BAR_ICON);
  for I := 0 to High(FEntries) do
  begin
    if (FTops[I] - FOffset + RowHeight <= 0) or
       (FTops[I] - FOffset >= ClientHeight) then
      Continue;
    RowR := Rect(Px(16), FTops[I] - FOffset, ClientWidth - Px(16),
      FTops[I] - FOffset + RowHeight);
    { 悬停: 整行浅灰圆角底（历史记录同款 hover: 上下内缩 2px, 圆角 8,
      填充+描边同色消除圆角白缝; 左缘 Px(8) 比内容左缘更外扩） }
    if I = FHot then
      DrawRoundRect(Canvas, Rect(Px(8), RowR.Top + Px(2), RowR.Right,
        RowR.Bottom - Px(2)), Px(8), C_BM_HOVER, C_BM_HOVER, 0);
    IconR := Rect(RowR.Left + Px(8), RowR.Top + Px(10),
      RowR.Left + Px(8) + IconW, RowR.Top + Px(10) + IconW);
    DrawFaviconPlaceholder(Canvas, IconR, FEntries[I].Title);
    { 标题行（顶部对齐实测行盒） }
    ApplyFont;
    Canvas.Font.Height := -Px(14);
    Canvas.Font.Color := C_BM_TEXT;
    LineH := Canvas.TextHeight('Wg');
    DrawTextD(Canvas, FEntries[I].Title,
      Rect(IconR.Right + Px(12), RowR.Top + Px(10),
        RowR.Right - Px(92), RowR.Top + Px(10) + LineH),
      DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    { 网址行（底部对齐, 距下留白 10px） }
    Canvas.Font.Height := -Px(12);
    Canvas.Font.Color := C_BM_TEXT2;
    LineH := Canvas.TextHeight('Wg');
    DrawTextD(Canvas, FEntries[I].Url,
      Rect(IconR.Right + Px(12), RowR.Bottom - Px(10) - LineH,
        RowR.Right - Px(92), RowR.Bottom - Px(10)),
      DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
    { 悬停行显示删除 + "⋮"菜单两按钮（鼠标移到按钮上图标加深） }
    if I = FHot then
    begin
      DrawTrashIcon(DeleteBtnRect(I), FDeleteHot);
      DrawMenuDots(MenuBtnRect(I), FMenuBtnHot);
    end;
  end;
  DrawScrollBar;
end;

{ 垃圾桶删除图标（Chrome/Material delete 形态, 与历史/下载窗口统一）:
  盖子横条 + 提手 + 梯形桶体（两侧斜边 + 底边）。旧版"圆角矩形桶身 +
  内部两条竖线"在 28px 按钮内细节过密（像笼子）, 已简化。
  线条 GDI+ 抗锯齿; GDI+ 不可用回退 GDI 直线（Win7 兜底）。
  AHot=True（鼠标在按钮上）用深色, 否则中灰色 }
procedure TFHBookmarkList.DrawTrashIcon(const R: TRect; AHot: Boolean);
var
  Clr: TColor;
  PW: Single;
  CX, CY: Integer;

  { 统一线条绘制: GDI+ 抗锯齿优先, 失败回退 GDI 直线 }
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
    Clr := C_BM_TEXT
  else
    Clr := C_BM_TEXT2;
  { 1.5 逻辑像素: AA 下与 Chrome 图标观感一致（整数 1px 偏细） }
  PW := Max(1.0, 1.5 * Px(96) / 96);

  { 悬停按钮底: 圆形 #D4D7DC（比行 hover 底深一档, 视觉可辨） }
  if AHot then
    FillCircleAA(Canvas, R, C_BM_BTNHOVER);

  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  Canvas.Brush.Style := bsClear;

  { 提手: 盖上方居中的短横线 }
  Line(CX - Px(2), CY - Px(8), CX + Px(2), CY - Px(8));
  { 盖子: 总宽 12 }
  Line(CX - Px(6), CY - Px(5), CX + Px(6), CY - Px(5));
  { 桶体: 两侧斜边 + 底边（上宽 10 / 下宽 8 的开口梯形） }
  Line(CX - Px(5), CY - Px(3), CX - Px(4), CY + Px(7));
  Line(CX + Px(5), CY - Px(3), CX + Px(4), CY + Px(7));
  Line(CX - Px(4), CY + Px(7), CX + Px(4), CY + Px(7));

  Canvas.Brush.Style := bsSolid;
end;

{ "⋮"菜单按钮: 竖排三点（悬停加深）。GDI+ 抗锯齿, GDI+ 不可用回退 GDI
  实心小方块（1px 级小点, 锯齿不明显） }
procedure TFHBookmarkList.DrawMenuDots(const R: TRect; AHot: Boolean);
var
  Clr: TColor;
  CX, Y0, D, I: Integer;
  G: TGPGraphics;
  B: TGPSolidBrush;
begin
  if AHot then
    Clr := C_BM_TEXT
  else
    Clr := C_BM_TEXT2;
  { 悬停按钮底: 圆形 #D4D7DC（与删除按钮同款） }
  if AHot then
    FillCircleAA(Canvas, R, C_BM_BTNHOVER);
  CX := (R.Left + R.Right) div 2;
  D := Max(3, Px(3));
  { 三点分布: 直径 3px、圆心距 5px（逻辑）, 总高 13px, 中点 = 按钮垂直
    中心; 与垃圾桶总视觉 14x18 平衡（此前 D=2 总高 10, 显得比垃圾桶小） }
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

{ 画滚动条滑块（上下圆角 + 直身）; 不可滚动时不画 }
procedure TFHBookmarkList.DrawScrollBar;
var
  R: TRect;
begin
  if MaxOffset <= 0 then Exit;
  R := ThumbRect;
  FillCircleAA(Canvas, Rect(R.Left, R.Top, R.Right, R.Top + 2), C_BM_THUMB);
  FillCircleAA(Canvas, Rect(R.Left, R.Bottom - 2, R.Right, R.Bottom),
    C_BM_THUMB);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_BM_THUMB;
  Canvas.FillRect(Rect(R.Left, R.Top + 2, R.Right, R.Bottom - 2));
  Canvas.Brush.Style := bsClear;
end;

{ 尺寸变化: 夹紧滚动偏移 }
procedure TFHBookmarkList.Resize;
begin
  inherited;
  if FOffset > MaxOffset then
    FOffset := MaxOffset;
end;

{ 句柄创建后: 按真实 DPI 重测行高并重建行位置 }
procedure TFHBookmarkList.CreateWnd;
begin
  inherited CreateWnd;
  FRowH := -1;   { 无句柄期兜底 DPI 的行高缓存失效重测（规范第 5 条） }
  BuildTops;
  Invalidate;
end;

{ DPI 变化（跨屏）: 清行高缓存并重建行位置 }
procedure TFHBookmarkList.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  FRowH := -1;
  BuildTops;
end;

{ 鼠标按下: 右键行 → 弹菜单; 左键 → 滚动条拖拽 / ⋮ 弹菜单 / 删除按钮删条 /
  其余触发 OnOpen }
procedure TFHBookmarkList.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  I: Integer;
  E: TFHBookmarkEntry;
  P: TPoint;
begin
  inherited;
  SetFocus;
  if Button = mbRight then
  begin
    if IndexAtY(Y) >= 0 then
      ShowContextMenu(X, Y);
    Exit;
  end;
  if Button <> mbLeft then Exit;
  { 滚动条拖拽 }
  if (MaxOffset > 0) and PtInRect(ThumbRect, Point(X, Y)) then
  begin
    FScrollDragging := True;
    FScrollDragY := Y;
    FScrollDragOffset := FOffset;
    Exit;
  end;
  I := IndexAtY(Y);
  if I < 0 then Exit;
  E := FEntries[I];
  { "⋮"菜单按钮: 弹出与右键相同的菜单（锚在按钮下方） }
  if (I = FHot) and FMenuBtnHot then
  begin
    FMenuEntry := E;
    P := ClientToScreen(Point(MenuBtnRect(I).Left,
      MenuBtnRect(I).Bottom));
    FMenu.Popup(P.X, P.Y);
    Exit;
  end;
  if (I = FHot) and FDeleteHot then
  begin
    HistoryDB.DeleteBookmarkUrl(E.Url);
    NotifyBookmarksChanged;   { 内部会刷新管理器窗口列表 }
    Exit;
  end;
  if Assigned(FOnOpen) then
    FOnOpen(Self, E.Url);
end;

{ 鼠标移动: 滚动条拖拽跟手; 更新悬停行与删除/⋮按钮悬停态 }
procedure TFHBookmarkList.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  NewDeleteHot: Boolean;
begin
  inherited;
  if FScrollDragging then
  begin
    if FContentH > ClientHeight then
      ScrollTo(FScrollDragOffset + MulDiv(Y - FScrollDragY,
        FContentH - ClientHeight, ClientHeight));
    Exit;
  end;
  I := IndexAtY(Y);
  NewDeleteHot := (I >= 0) and PtInRect(DeleteBtnRect(I), Point(X, Y));
  if (I <> FHot) or (NewDeleteHot <> FDeleteHot) or
     (FMenuBtnHot <> ((I >= 0) and PtInRect(MenuBtnRect(I), Point(X, Y)))) then
  begin
    FHot := I;
    FDeleteHot := NewDeleteHot;
    FMenuBtnHot := (I >= 0) and PtInRect(MenuBtnRect(I), Point(X, Y));
    Invalidate;
  end;
end;

{ 鼠标松开: 结束滚动条拖拽 }
procedure TFHBookmarkList.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  FScrollDragging := False;
end;

{ 鼠标离开: 清全部悬停/拖拽态并重绘 }
procedure TFHBookmarkList.CMMouseLeave(var Message: TMessage);
begin
  FHot := -1;
  FDeleteHot := False;
  FMenuBtnHot := False;
  FScrollDragging := False;
  Invalidate;
end;

{ 滚轮: 按滚轮增量滚动 }
function TFHBookmarkList.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  ScrollTo(FOffset - WheelDelta);
  Result := True;
end;

{ 弹行右键菜单（目标存 FMenuEntry） }
procedure TFHBookmarkList.ShowContextMenu(X, Y: Integer);
var
  I: Integer;
  P: TPoint;
begin
  I := IndexAtY(Y);
  if (I < 0) or (I > High(FEntries)) then Exit;
  FMenuEntry := FEntries[I];
  P := ClientToScreen(Point(X, Y));
  FMenu.Popup(P.X, P.Y);
end;

{ 菜单"在当前标签页中打开": 触发 OnOpen }
procedure TFHBookmarkList.MenuOpen(Sender: TObject);
begin
  if Assigned(FOnOpen) then
    FOnOpen(Self, FMenuEntry.Url);
end;

{ 菜单"在新标签页中打开": 触发 OnOpenNewTab }
procedure TFHBookmarkList.MenuOpenNewTab(Sender: TObject);
begin
  if Assigned(FOnOpenNewTab) then
    FOnOpenNewTab(Self, FMenuEntry.Url);
end;

{ 菜单"复制网址": 写剪贴板 }
procedure TFHBookmarkList.MenuCopy(Sender: TObject);
begin
  try
    Clipboard.AsText := FMenuEntry.Url;
  except
    on E: Exception do
      Logger.Error('复制网址失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 菜单"编辑": 以该行屏幕矩形为锚点弹书签编辑气泡 }
procedure TFHBookmarkList.MenuEdit(Sender: TObject);
var
  I: Integer;
  R: TRect;
  P: TPoint;
begin
  I := IndexOfEntry(FMenuEntry.Url);
  if I < 0 then Exit;
  { 锚点 = 该行在屏幕上的矩形（气泡弹在行下方） }
  P := ClientToScreen(Point(Px(16), FTops[I] - FOffset));
  R := Rect(P.X, P.Y, P.X + Px(60), P.Y + RowHeight);
  ShowBookmarkBubble(R, FMenuEntry.Url, FMenuEntry.Title);
end;

{ 菜单"删除": 删库并广播书签变更 }
procedure TFHBookmarkList.MenuDelete(Sender: TObject);
begin
  HistoryDB.DeleteBookmarkUrl(FMenuEntry.Url);
  NotifyBookmarksChanged;
end;

{ ============================ TFHBookmarksForm ============================= }

{ 构造: 无边框 Chrome 弹窗四件套, 按屏幕 DPI 定尺寸/最小约束, 构建 UI }
constructor TFHBookmarksForm.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  Scaled := False;    { 手动按 DPI 换算（Px）, 关掉 VCL 自动缩放避免双重放大 }
  Caption := '书签管理器';
  { 无边框 Chrome 弹窗四件套（docs\01_UI开发规范.md 6~9 条）;
    bsSizeable 仅为保留 WS_THICKFRAME（边缘八向 resize） }
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu];
  Position := poMainFormCenter;
  Color := C_BM_BG;
  Font.Name := 'Segoe UI';
  { 无系统标题栏后客户区=整窗: 高度基准补回自绘标题栏（44px） }
  ClientWidth := Px(C_MGR_W);
  ClientHeight := Px(C_MGR_H) + Px(C_MGR_CAPT_H);
  Constraints.MinWidth := Px(520);
  Constraints.MinHeight := Px(360) + Px(C_MGR_CAPT_H);
  DoubleBuffered := True;
  OnPaint := FormPaint;
  OnMouseDown := FormMouseDown;
  OnMouseMove := FormMouseMove;
  FCloseHot := False;
  BuildUi;
  LayoutUi;
end;

{ 析构: 全局管理器指针自清（防悬垂） }
destructor TFHBookmarksForm.Destroy;
begin
  if GManager = Self then
    GManager := nil;
  inherited;
end;

{ 无边框: 去 WS_CAPTION/WS_SYSMENU 保留 WS_THICKFRAME, 必须 or WS_POPUP
  （防 user32 强制补回 WS_CAPTION, 规范第 7 条） }
procedure TFHBookmarksForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  { WS_POPUP 位必须有: user32 对带 WS_THICKFRAME 的非 popup 顶层窗口会在
    CreateWindowEx 内部强制补回 WS_CAPTION（规范第 7 条） }
  Params.Style := (Params.Style or WS_POPUP) and (not WS_CAPTION)
    and (not WS_SYSMENU);
end;

{ 96 DPI 基准逻辑像素 → 窗口实际像素（无句柄期按屏幕 DPI 兜底） }
function TFHBookmarksForm.Px(V: Integer): Integer;
var
  DPI, DC: Integer;
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

{ 自绘标题栏高度（96 DPI 基准 44px） }
function TFHBookmarksForm.CaptionH: Integer;
begin
  Result := Px(C_MGR_CAPT_H);
end;

{ 标题栏右上角关闭按钮矩形: 32x32, 距右 8px, 垂直居中于标题栏 }
function TFHBookmarksForm.CloseBtnRect: TRect;
var
  Btn: Integer;
begin
  Btn := Px(32);
  Result := Rect(ClientWidth - Px(40), (CaptionH - Btn) div 2,
    ClientWidth - Px(40) + Btn, (CaptionH + Btn) div 2);
end;

{ 搜索框胶囊矩形（标题栏下方, 左右各留 16px） }
function TFHBookmarksForm.SearchRect: TRect;
begin
  Result := Rect(Px(16), CaptionH + Px(12),
    ClientWidth - Px(16), CaptionH + Px(12) + Px(C_MGR_SEARCH_H));
end;

{ 构建子控件: 标题标签 + 搜索输入框 + 书签列表, 并挂接事件 }
procedure TFHBookmarksForm.BuildUi;
begin
  FTitle := TLabel.Create(Self);
  FTitle.Parent := Self;
  FTitle.Transparent := True;
  FTitle.AutoSize := False;
  FTitle.Layout := tlCenter;
  FTitle.Caption := '书签管理器';
  FTitle.Font.Name := 'Segoe UI';
  FTitle.Font.PixelsPerInch := 96;
  FTitle.Font.Height := -Px(18);
  FTitle.Font.Style := [fsBold];
  FTitle.Font.Color := C_BM_TEXT;

  FSearchEdit := TEdit.Create(Self);
  FSearchEdit.Parent := Self;
  FSearchEdit.BorderStyle := bsNone;
  FSearchEdit.Color := clWhite;
  FSearchEdit.Font.Name := 'Segoe UI';
  FSearchEdit.Font.Color := C_BM_TEXT;
  FSearchEdit.TextHint := '搜索书签';
  FSearchEdit.OnChange := SearchChange;
  FSearchEdit.OnEnter := SearchEnter;
  FSearchEdit.OnExit := SearchExit;

  FList := TFHBookmarkList.Create(Self);
  FList.Parent := Self;
  FList.OnOpen := ListOpen;
  FList.OnOpenNewTab := ListOpenNewTab;
end;

{ 重排子控件: 标题在标题栏内, 搜索框与列表在内容区 }
procedure TFHBookmarksForm.LayoutUi;
var
  SR: TRect;
begin
  if (FTitle = nil) or (FList = nil) then Exit;
  FTitle.SetBounds(Px(16), 0, Max(Px(120), ClientWidth - Px(16) - Px(48)),
    CaptionH);
  SR := SearchRect;
  if FSearchEdit <> nil then
    FSearchEdit.SetBounds(SR.Left + Px(10), SR.Top + Px(8),
      SR.Width - Px(20), SR.Height - Px(16));
  FList.SetBounds(Px(16), SR.Bottom + Px(12),
    Max(Px(120), ClientWidth - Px(32)),
    Max(Px(80), ClientHeight - SR.Bottom - Px(12) - Px(16)));
end;

{ 全窗自绘: 1px 边框线 + 关闭按钮 ✕（悬停灰底）+ 搜索框胶囊描边
  （聚焦蓝粗线 / 失焦灰细线） }
procedure TFHBookmarksForm.FormPaint(Sender: TObject);
var
  R, SR: TRect;
begin
  R := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_BM_BG;
  Canvas.Pen.Color := C_BM_BG;
  Canvas.FillRect(R);
  { 四周 1px 边框线（吞 NCCALCSIZE 后系统不画, 规范第 8 条） }
  Canvas.Pen.Color := C_BM_EDGE;
  Canvas.Pen.Width := 1;
  Canvas.Brush.Style := bsClear;
  Canvas.MoveTo(R.Left, R.Top);
  Canvas.LineTo(R.Right - 1, R.Top);
  Canvas.LineTo(R.Right - 1, R.Bottom - 1);
  Canvas.LineTo(R.Left, R.Bottom - 1);
  Canvas.LineTo(R.Left, R.Top);
  { 关闭按钮 ✕（悬停灰底） }
  R := CloseBtnRect;
  if FCloseHot then
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := C_BM_HOVER;
    Canvas.Pen.Color := C_BM_HOVER;
    Canvas.FillRect(R);
    Canvas.Brush.Style := bsClear;
  end;
  DrawCloseGlyph(Canvas, R, C_BM_TEXT2);
  { 搜索框胶囊（内嵌 EDIT 的外框）: 聚焦 = 蓝描边 #0B57D0（地址栏/历史
    搜索框同款, 笔宽 2px）; 失焦 = 灰描边 1px }
  SR := SearchRect;
  if FSearchFocused then
    DrawRoundRect(Canvas, SR, SR.Height div 2, clWhite, C_BM_BLUE,
      Max(2, Px(2)))
  else
    DrawRoundRect(Canvas, SR, SR.Height div 2, clWhite, C_BM_EDGE, 1);
end;

{ 画关闭按钮 ✕（GDI+ 抗锯齿, 回退 GDI 直线） }
procedure TFHBookmarksForm.DrawCloseGlyph(ACanvas: TCanvas; const R: TRect;
  AColor: TColor);
var
  G: TGPGraphics;
  P: TGPPen;
  CX, CY, K: Integer;
begin
  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  K := Px(5);
  G := MakeGraphics(ACanvas);
  if G = nil then
  begin
    ACanvas.Pen.Color := AColor;
    ACanvas.Pen.Width := Max(1, Px(1));
    ACanvas.MoveTo(CX - K, CY - K);
    ACanvas.LineTo(CX + K, CY + K);
    ACanvas.MoveTo(CX + K, CY - K);
    ACanvas.LineTo(CX - K, CY + K);
    Exit;
  end;
  try
    P := TGPPen.Create(ColorToARGB(AColor), Max(1, Px(1)));
    try
      P.SetStartCap(LineCapRound);
      P.SetEndCap(LineCapRound);
      G.DrawLine(P, CX - K, CY - K, CX + K, CY + K);
      G.DrawLine(P, CX + K, CY - K, CX - K, CY + K);
    finally
      P.Free;
    end;
  finally
    G.Free;
  end;
end;

{ 鼠标按下: 命中标题栏关闭按钮则关窗 }
procedure TFHBookmarksForm.FormMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (Button = mbLeft) and PtInRect(CloseBtnRect, Point(X, Y)) then
    Close;
end;

{ 鼠标移动: 跟踪关闭按钮悬停态, 变化时重绘 }
procedure TFHBookmarksForm.FormMouseMove(Sender: TObject;
  Shift: TShiftState; X, Y: Integer);
var
  NewHot: Boolean;
begin
  NewHot := PtInRect(CloseBtnRect, Point(X, Y));
  if NewHot <> FCloseHot then
  begin
    FCloseHot := NewHot;
    Invalidate;
  end;
end;

{ 鼠标离开: 清关闭按钮悬停态并重绘 }
procedure TFHBookmarksForm.CMMouseLeave(var Message: TMessage);
begin
  FCloseHot := False;
  Invalidate;
end;

{ 搜索框获得焦点: 记录态并重绘（胶囊描边转蓝加粗） }
procedure TFHBookmarksForm.SearchEnter(Sender: TObject);
begin
  FSearchFocused := True;
  Invalidate;
end;

{ 搜索框失去焦点: 记录态并重绘（描边回灰细线） }
procedure TFHBookmarksForm.SearchExit(Sender: TObject);
begin
  FSearchFocused := False;
  Invalidate;
end;

{ 搜索文本变化: 按新关键词重新查询 }
procedure TFHBookmarksForm.SearchChange(Sender: TObject);
begin
  RefreshEntries;
end;

{ 列表单击条目: 在当前标签页打开并关闭本窗口（同历史窗口行为） }
procedure TFHBookmarksForm.ListOpen(Sender: TObject; const AUrl: string);
begin
  { 单击 = 当前标签打开并关闭本窗口（同历史窗口行为） }
  if Assigned(FOnOpen) then
    FOnOpen(Self, AUrl);
  Close;
end;

{ 列表"在新标签页中打开": 触发宿主回调（本窗口不关） }
procedure TFHBookmarksForm.ListOpenNewTab(Sender: TObject; const AUrl: string);
begin
  if Assigned(FOnOpenNewTab) then
    FOnOpenNewTab(Self, AUrl);
end;

{ 按搜索框当前关键词重新查库并刷新列表 }
procedure TFHBookmarksForm.RefreshEntries;
begin
  if (FList <> nil) and (FSearchEdit <> nil) then
    FList.SetEntries(HistoryDB.QueryBookmarks(
      Trim(FSearchEdit.Text)), Trim(FSearchEdit.Text));
end;

{ 挂接宿主回调: 打开/新标签打开 }
procedure TFHBookmarksForm.SetCallbacks(AOnOpen,
  AOnOpenNewTab: TFHBookmarkUrlEvent);
begin
  FOnOpen := AOnOpen;
  FOnOpenNewTab := AOnOpenNewTab;
end;

{ 窗口尺寸变化: 重排子控件 }
procedure TFHBookmarksForm.Resize;
begin
  inherited;
  LayoutUi;
end;

{ 显示: 重新查询刷新列表 }
procedure TFHBookmarksForm.DoShow;
begin
  inherited;
  RefreshEntries;
end;

{ 关闭: 释放窗口（全局指针在 Destroy 里清） }
procedure TFHBookmarksForm.DoClose(var Action: TCloseAction);
begin
  inherited;
  Action := caFree;
end;

{ 跨到不同 DPI 的显示器: 重排子控件并刷新列表 }
procedure TFHBookmarksForm.WMDpiChanged(var Message: TMessage);
begin
  inherited;
  LayoutUi;
  if FList <> nil then
    FList.Invalidate;
end;

{ ---- 无边框四件套的另外两件（吞 NCCALCSIZE + NCACTIVATE 哨兵） ------------ }

procedure TFHBookmarksForm.WMNCCalcSize(var Message: TWMNCCalcSize);
begin
  { 吞掉顶部缩进: 客户区覆盖整窗, 自绘标题栏贴物理顶边（规范第 8 条） }
  if Message.CalcValidRects then
    Message.Result := 0
  else
    inherited;
end;

procedure TFHBookmarksForm.WMNCActivate(var Message: TWMNCActivate);
begin
  { lParam=-1 哨兵: 阻止失活时系统在四周重绘 inset 边框（规范第 9 条,
    否则右键菜单弹出的瞬间窗口与边框间出现缝隙） }
  Message.Unused := -1;
  inherited;
end;

procedure TFHBookmarksForm.WMNCHitTest(var Message: TWMNCHitTest);
var
  P: TPoint;
begin
  inherited;
  if (Message.Result >= HTLEFT) and (Message.Result <= HTBOTTOMRIGHT) then
    Exit;
  if Message.Result <> HTCLIENT then
    Exit;
  P := ScreenToClient(Point(Message.XPos, Message.YPos));
  if (P.Y >= 0) and (P.Y < CaptionH) then
  begin
    if PtInRect(CloseBtnRect, P) then
      Exit;                      { 关闭按钮走鼠标事件 }
    Message.Result := HTCAPTION; { 标题栏空白区可拖动 }
  end;
end;

{ ---- 对外接口 ------------------------------------------------------------ }

procedure ShowBookmarksManager(AOnOpen, AOnOpenNewTab: TFHBookmarkUrlEvent);
begin
  if GManager = nil then
    GManager := TFHBookmarksForm.CreateNew(nil);
  GManager.SetCallbacks(AOnOpen, AOnOpenNewTab);
  if not GManager.Visible then
    GManager.Show
  else
  begin
    GManager.RefreshEntries;
    GManager.BringToFront;
  end;
end;

procedure ShowBookmarkBubble(const AAnchorScreen: TRect;
  const AUrl, ATitle: string);
begin
  HideBookmarkBubble;   { 已显示则先关再开（切换目标） }
  GBubble := TFHBookmarkBubble.CreateNew(nil);
  GBubble.ShowEdit(AAnchorScreen, AUrl, ATitle);
end;

{ 主动关闭气泡（摘掉失焦关闭路径, 再 Close） }
procedure HideBookmarkBubble;
begin
  if GBubble <> nil then
  begin
    GBubble.OnDeactivate := nil;   { 主动关闭不触发失焦路径 }
    GBubble.Close;
  end;
end;

{ 书签气泡当前是否显示中 }
function IsBookmarkBubbleVisible: Boolean;
begin
  Result := (GBubble <> nil) and GBubble.Visible;
end;

procedure RegisterBookmarkBar(ABar: TFHBookmarkBar);
begin
  GBookmarkBar := ABar;
  if ABar <> nil then
    ABar.Reload;
end;

procedure RegisterBookmarksChanged(AChanged: TNotifyEvent);
begin
  GOnBookmarksChanged := AChanged;
end;

procedure NotifyBookmarksChanged;
begin
  if GBookmarkBar <> nil then
    GBookmarkBar.Reload;
  if GManager <> nil then
    GManager.RefreshEntries;
  if Assigned(GOnBookmarksChanged) then
    GOnBookmarksChanged(nil);
end;

end.