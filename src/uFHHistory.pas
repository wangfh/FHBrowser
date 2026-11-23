{==============================================================================
  uFHHistory —— Chrome 风格"历史记录"窗口
  ----------------------------------------------------------------------------
  职责: 浏览历史记录列表（数据来自 uFHHistoryDB 的本地 SQLite）, 支持:
    - 顶部搜索框（按标题/URL 过滤, 输入即查）
    - 按日期分组（今天 / 昨天 / 具体日期）, 行内显示 favicon 占位、标题、URL、时间
    - 单击条目 = 在主窗口当前标签页打开（同 Chrome 历史页行为）, 并关闭本窗口
    - 右键菜单: 打开 / 在新标签页中打开 / 复制链接地址 / 从历史记录中删除
    - 右上角"清除浏览数据"（复用主窗体的清除对话框, 清完自动刷新）
  UI 参数按 Chrome 历史页取色/取值（#202124 标题、#5F6368 次要文字、
  #1A73E8 链接蓝、#F1F3F4 悬停底色）, 96 DPI 基准, 运行时按屏幕 DPI 换算。
  设计: 窗口为单例（ShowHistoryForm）, 数据在每次打开/搜索/删除/清除后重新查询。
==============================================================================}
unit uFHHistory;

interface

uses
  System.Classes, System.SysUtils, System.Types, System.UITypes, System.Math,
  System.DateUtils,
  Winapi.Windows, Winapi.Messages, Winapi.GDIPOBJ, Winapi.GDIPAPI,
  Vcl.Forms, Vcl.Controls, Vcl.Graphics, Vcl.StdCtrls, Vcl.ClipBrd,
  uFHHistoryDB, uFHChromeMenu, uFHChromeTabs, uFHBrowserControls, uLogger;

type
  TFHHistoryUrlEvent = procedure(Sender: TObject; const AUrl: string) of object;

  { 列表行的两种形态: hrGroup = 日期分组标题行, hrEntry = 历史条目行 }
  TFHHistoryRowKind = (hrGroup, hrEntry);

  { 绘制用行模型: BuildRows 把条目序列展开成交替的"分组标题 + 条目" }
  TFHHistoryRow = record
    Kind: TFHHistoryRowKind;
    GroupTitle: string;
    Entry: TFHHistoryEntry;
  end;

  { ---- 搜索框: 胶囊形浅灰底 + 放大镜 + 内嵌 EDIT + 右侧清除按钮 ---- }
  TFHHistorySearchBox = class(TCustomControl)
  private
    FEdit: TEdit;
    FBtnClear: TFHNavButton;
    FFocused: Boolean;
    FOnChange: TNotifyEvent;
    function Px(V: Integer): Integer;
    function BoxFill: TColor;
    procedure PinEditFont;
    procedure LayoutChildren;
    procedure EditEnter(Sender: TObject);
    procedure EditExit(Sender: TObject);
    procedure EditChange(Sender: TObject);
    procedure EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ClearClick(Sender: TObject);
    procedure DrawMagnifier;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure CreateWnd; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    function SearchText: string;
    procedure ClearText;
    procedure FocusSearch;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { ---- 历史列表: 自绘（日期分组 + 条目 + 悬停 + 滚动条） ---- }
  TFHHistoryList = class(TCustomControl)
  private
    FEntries: TFHHistoryEntries;
    FRows: TArray<TFHHistoryRow>;
    FTops: TArray<Integer>;
    FContentH: Integer;
    FOffset: Integer;
    FHotIndex: Integer;
    FPressRow: Integer;
    FSearching: Boolean;
    FScrollDragging: Boolean;
    FScrollHot: Boolean;
    FDeleteHot: Boolean;             // 鼠标悬停在行删除按钮上
    FMenuBtnHot: Boolean;            // 鼠标悬停在行"⋮"菜单按钮上
    FScrollDragY: Integer;
    FScrollDragOffset: Integer;
    FEntryRowH: Integer;              // 条目行高缓存（按实际字体行盒测量）
    FMenu: TFHMenu;
    FMenuEntry: TFHHistoryEntry;
    FOnOpen: TFHHistoryUrlEvent;
    FOnOpenNewTab: TFHHistoryUrlEvent;
    FOnDelete: TFHHistoryUrlEvent;
    function Px(V: Integer): Integer;
    function EntryRowHeight: Integer;
    function RowHeight(ARow: Integer): Integer;
    function MaxOffset: Integer;
    function IndexAtY(Y: Integer): Integer;
    function ThumbRect: TRect;
    function DeleteBtnRect(ARow: Integer): TRect;
    function MenuBtnRect(ARow: Integer): TRect;
    procedure BuildRows;
    procedure ScrollTo(AOffset: Integer);
    procedure ShowContextMenu(X, Y: Integer);
    procedure SetFontPx(ASize: Integer; AStyle: TFontStyles; AColor: TColor);
    procedure DrawGroup(ARow, ATop: Integer);
    procedure DrawEntry(ARow, ATop: Integer);
    procedure DrawFavicon(X, Y, ASize: Integer);
    procedure DrawTrashIcon(const R: TRect; AHot: Boolean);
    procedure DrawMenuDots(const R: TRect; AHot: Boolean);
    procedure DrawEmpty;
    procedure DrawScrollBar;
    procedure MenuOpen(Sender: TObject);
    procedure MenuOpenNewTab(Sender: TObject);
    procedure MenuCopy(Sender: TObject);
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
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { 装入查询结果并重建分组行; ASearching 决定空列表时显示"无搜索结果"文案 }
    procedure SetEntries(const AEntries: TFHHistoryEntries; ASearching: Boolean);
    property OnOpen: TFHHistoryUrlEvent read FOnOpen write FOnOpen;
    property OnOpenNewTab: TFHHistoryUrlEvent read FOnOpenNewTab write FOnOpenNewTab;
    property OnDelete: TFHHistoryUrlEvent read FOnDelete write FOnDelete;
  end;

  { ---- 历史记录窗口 ---- }
  TFHHistoryForm = class(TForm)
  private
    FTitle: TLabel;
    FClearRect: TRect;               // 标题栏"清除浏览数据"点击区（窗体自绘）
    FCloseHot: Boolean;              // 鼠标悬停在标题栏关闭按钮上
    FSearchBox: TFHHistorySearchBox;
    FList: TFHHistoryList;
    FOnOpen: TFHHistoryUrlEvent;
    FOnOpenNewTab: TFHHistoryUrlEvent;
    FOnClearData: TNotifyEvent;
    function Px(V: Integer): Integer;
    function CaptionH: Integer;
    function CloseBtnRect: TRect;
    procedure ApplyWindowMetrics;
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
    procedure WMNCCalcSize(var Message: TWMNCCalcSize);
      message WM_NCCALCSIZE;
    procedure WMNCActivate(var Message: TWMNCActivate);
      message WM_NCACTIVATE;
    procedure WMGetMinMaxInfo(var Message: TWMGetMinMaxInfo);
      message WM_GETMINMAXINFO;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    procedure BuildUi;
    procedure LayoutUi;
    procedure FormPaint(Sender: TObject);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure SearchChange(Sender: TObject);
    procedure ClearDataClick(Sender: TObject);
    procedure ListOpen(Sender: TObject; const AUrl: string);
    procedure ListOpenNewTab(Sender: TObject; const AUrl: string);
    procedure ListDelete(Sender: TObject; const AUrl: string);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure WndProc(var Message: TMessage); override;
    procedure Resize; override;
    procedure DoShow; override;
    procedure DoClose(var Action: TCloseAction); override;
    procedure WMDpiChanged(var Message: TMessage); message WM_DPICHANGED;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
    procedure SetCallbacks(AOnOpen, AOnOpenNewTab: TFHHistoryUrlEvent;
      AOnClearData: TNotifyEvent);
    procedure RefreshEntries;
  end;

{ 打开"历史记录"窗口（已开则刷新并前置）。
  AOnOpen        : 在当前标签页打开（单击条目 / 右键"在当前标签页中打开"）
  AOnOpenNewTab  : 在新标签页中打开（右键菜单）
  AOnClearData   : 右上角"清除浏览数据"（可传 nil 隐藏按钮） }
procedure ShowHistoryForm(AOnOpen, AOnOpenNewTab: TFHHistoryUrlEvent;
  AOnClearData: TNotifyEvent = nil);

implementation

var
  GForm: TFHHistoryForm = nil;
  GOnOpen: TFHHistoryUrlEvent = nil;
  GOnOpenNewTab: TFHHistoryUrlEvent = nil;
  GOnClearData: TNotifyEvent = nil;

const
  C_HIST_BG        = clWhite;
  C_HIST_TEXT      = TColor($242120);   // #202124
  C_HIST_TEXT2     = TColor($68635F);   // #5F6368
  C_HIST_BLUE      = TColor($E8731A);   // #1A73E8
  C_HIST_HOVER     = TColor($F4F3F1);   // #F1F3F4
  C_HIST_THUMB     = TColor($E0DCDA);   // #DADCE0
  C_HIST_THUMB_HOT = TColor($A6A09A);   // #9AA0A6
  C_HIST_BTNHOVER  = TColor($DCD7D4);   // #D4D7DC 行内按钮悬停底（与书签
                                          // 管理器同款; 与行底 #F1F3F4 差
                                          //  约 20 通道值才肉眼可辨）
  C_HIST_ROWBTN    = 28;                // 行内按钮尺寸(垃圾桶/⋮), 圆底直径
                                          // （20px 实测嫌小, Chrome 同款 28）

{ ---- GDI+ 辅助（与 uFHFindBar 同款取色/路径逻辑） --------------------------- }

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
  { 弧直径不得超过路径宽/高: 否则胶囊两端的上下半圆在切点错位,
    GDI+ 会自动补一段竖直直线 —— 聚焦描边时左右两边出现蓝色"竖线" }
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
  { 描边内缩后矩形变小, 半径必须跟着夹紧到半宽/半高 ——
    搜索框是"半径 = 高/2"的胶囊, 内缩 1px 后原半径就超了,
    两端半圆退化成竖直直线（用户看到的蓝色竖线） }
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

{ 抗锯齿圆/椭圆描边（GDI Ellipse 无 AA）; 返回 False = GDI+ 不可用, 已退回 GDI }
function DrawEllipseAA(ACanvas: TCanvas; const R: TRect; AColor: TColor;
  AW: Integer): Boolean;
var
  G: TGPGraphics;
  P: TGPPen;
begin
  Result := False;
  G := MakeGraphics(ACanvas);
  if G = nil then
  begin
    ACanvas.Brush.Style := bsClear;
    ACanvas.Pen.Style := psSolid;
    ACanvas.Pen.Color := AColor;
    ACanvas.Pen.Width := AW;
    ACanvas.Ellipse(R);
    Exit;
  end;
  try
    P := TGPPen.Create(ColorToARGB(AColor), AW);
    try
      G.DrawEllipse(P, R.Left + 0.5, R.Top + 0.5,
        R.Right - R.Left - 1, R.Bottom - R.Top - 1);
      Result := True;
    finally
      P.Free;
    end;
  finally
    G.Free;
  end;
end;

{ 抗锯齿实心圆（GDI+ 优先; GDI+ 不可用回退 GDI Ellipse, 锯齿可接受） }
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

{ 抗锯齿线段（圆帽, 斜线无阶梯锯齿）。AW 用 Single: 支持 1.5px 等
  浮点笔宽（高 DPI/高清观感），与 uFHChromeWidgets.DrawLineAA 签名一致 }
function DrawLineAA(ACanvas: TCanvas; X1, Y1, X2, Y2: Single;
  AColor: TColor; AW: Single): Boolean;
var
  G: TGPGraphics;
  P: TGPPen;
begin
  Result := False;
  G := MakeGraphics(ACanvas);
  if G = nil then
    Exit;
  try
    P := TGPPen.Create(ColorToARGB(AColor), AW);
    try
      P.SetStartCap(LineCapRound);
      P.SetEndCap(LineCapRound);
      G.DrawLine(P, X1, Y1, X2, Y2);
      Result := True;
    finally
      P.Free;
    end;
  finally
    G.Free;
  end;
end;

{ 日期分组标题文案: 今天 / 昨天 / 其余显示 "x年x月x日，星期x"。
  ADate = Trunc(VisitTime), 即当天 0 点的 TDateTime 天数 }
function GroupCaption(ADate: Int64): string;
const
  WeekNames: array[1 .. 7] of string =
    ('星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六');
var
  D: TDateTime;
begin
  if ADate = Trunc(Now) then
    Result := '今天'
  else if ADate = Trunc(Now) - 1 then
    Result := '昨天'
  else
  begin
    D := TDateTime(ADate);
    Result := Format('%d年%d月%d日，%s',
      [YearOf(D), MonthOf(D), DayOf(D), WeekNames[DayOfWeek(D)]]);
  end;
end;

{ ======================= TFHHistorySearchBox ============================== }

{ 构造: 内嵌无边框 TEdit + 右侧清除按钮（有文字才显示）, 默认 36 逻辑高 }
constructor TFHHistorySearchBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  Height := MulDiv(36, Screen.PixelsPerInch, 96);
  TabStop := False;
  Font.Name := 'Segoe UI';

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.ParentFont := False;
  FEdit.BorderStyle := bsNone;
  FEdit.AutoSize := False;
  FEdit.Color := C_HIST_HOVER;
  FEdit.Font.Name := 'Segoe UI';
  FEdit.Font.Color := C_HIST_TEXT;
  FEdit.TextHint := '搜索历史记录';
  FEdit.OnChange := EditChange;
  FEdit.OnEnter := EditEnter;
  FEdit.OnExit := EditExit;
  FEdit.OnKeyDown := EditKeyDown;

  FBtnClear := TFHNavButton.Create(Self);
  FBtnClear.Parent := Self;
  FBtnClear.ButtonType := nbtStop;
  FBtnClear.BackColor := C_HIST_HOVER;
  FBtnClear.Hint := '清除搜索';
  FBtnClear.ShowHint := True;
  FBtnClear.TabStop := False;
  FBtnClear.Visible := False;
  FBtnClear.OnClick := ClearClick;
end;

{ 96 DPI 基准逻辑像素 → 当前 DPI 实际像素 }
function TFHHistorySearchBox.Px(V: Integer): Integer;
var
  DPI: Integer;
begin
  DPI := 96;
  if HandleAllocated then
    DPI := GetDeviceCaps(Canvas.Handle, LOGPIXELSX);
  if DPI <= 0 then
    DPI := Screen.PixelsPerInch;
  Result := MulDiv(V, DPI, 96);
  if Result = 0 then
    Result := V;
end;

{ 胶囊底色: 聚焦白底, 常态浅灰 }
function TFHHistorySearchBox.BoxFill: TColor;
begin
  if FFocused then
    Result := clWhite
  else
    Result := C_HIST_HOVER;
end;

{ 按当前 DPI 钉死输入框字号（14px 逻辑值, 幂等） }
procedure TFHHistorySearchBox.PinEditFont;
var
  PPI: Integer;
begin
  if FEdit = nil then Exit;
  PPI := Px(96);
  FEdit.Font.PixelsPerInch := PPI;
  FEdit.Font.Height := -MulDiv(14, PPI, 96);
end;

{ 重排子控件: 输入框避让左侧放大镜区与右侧清除按钮 }
procedure TFHHistorySearchBox.LayoutChildren;
var
  BoxH, EditH, Btn: Integer;
begin
  if (FEdit = nil) or (Width <= 0) or (Height <= 0) then Exit;
  BoxH := Height;
  EditH := Px(24);
  Btn := Px(24);
  PinEditFont;
  FBtnClear.SetBounds(Width - Px(12) - Btn, (BoxH - Btn) div 2, Btn, Btn);
  FEdit.SetBounds(Px(46), (BoxH - EditH) div 2,
    Max(Px(40), Width - Px(46) - Px(44)), EditH);
end;

{ 输入框获得焦点: 记录态并重绘（胶囊转白底蓝边） }
procedure TFHHistorySearchBox.EditEnter(Sender: TObject);
begin
  FFocused := True;
  Invalidate;
end;

{ 输入框失去焦点: 记录态并重绘（胶囊回浅灰无边框） }
procedure TFHHistorySearchBox.EditExit(Sender: TObject);
begin
  FFocused := False;
  Invalidate;
end;

{ 输入变化: 按有无文字显隐清除按钮, 并触发宿主 OnChange（输入即查） }
procedure TFHHistorySearchBox.EditChange(Sender: TObject);
begin
  FBtnClear.Visible := FEdit.Text <> '';
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

{ 输入框按键: Esc 清空搜索词 }
procedure TFHHistorySearchBox.EditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    ClearText;
  end;
end;

{ 清除按钮: 清空搜索词并聚焦输入框 }
procedure TFHHistorySearchBox.ClearClick(Sender: TObject);
begin
  ClearText;
  if FEdit.CanFocus then
    FEdit.SetFocus;
end;

{ 清空搜索词（已空则仅重绘） }
procedure TFHHistorySearchBox.ClearText;
begin
  if FEdit.Text <> '' then
    FEdit.Text := ''
  else
    Invalidate;
end;

{ 当前搜索词 }
function TFHHistorySearchBox.SearchText: string;
begin
  Result := FEdit.Text;
end;

{ 聚焦输入框并全选（便于直接覆盖输入） }
procedure TFHHistorySearchBox.FocusSearch;
begin
  if FEdit.CanFocus then
    FEdit.SetFocus;
  FEdit.SelectAll;
end;

{ 画左侧放大镜图标（GDI+ 抗锯齿圆环 + 斜手柄） }
procedure TFHHistorySearchBox.DrawMagnifier;
var
  CX, CY, Rd, PW: Integer;
begin
  { 放大镜: 圆环 + 斜手柄都走 GDI+ 抗锯齿（GDI 的圆/斜线有阶梯锯齿） }
  CX := Px(22);
  CY := Height div 2 - Px(1);
  Rd := Px(7);
  PW := Max(1, Px(2));
  Canvas.Brush.Style := bsClear;
  DrawEllipseAA(Canvas, Rect(CX - Rd, CY - Rd, CX + Rd, CY + Rd),
    C_HIST_TEXT2, PW);
  if not DrawLineAA(Canvas, CX + Px(5), CY + Px(5), CX + Px(9), CY + Px(9),
    C_HIST_TEXT2, PW) then
  begin
    Canvas.Pen.Style := psSolid;
    Canvas.Pen.Color := C_HIST_TEXT2;
    Canvas.Pen.Width := PW;
    Canvas.MoveTo(CX + Px(5), CY + Px(5));
    Canvas.LineTo(CX + Px(9), CY + Px(9));
    Canvas.Pen.Style := psClear;
  end;
  Canvas.Brush.Style := bsSolid;
end;

{ 自绘胶囊: 聚焦白底蓝边 / 常态浅灰无边框, 内嵌控件底色同步 }
procedure TFHHistorySearchBox.Paint;
var
  R: TRect;
  Fill, Border: TColor;
  PenW: Integer;
begin
  Canvas.Lock;
  try
  try
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := C_HIST_BG;
    Canvas.Pen.Style := psClear;
    Canvas.FillRect(ClientRect);

    Fill := BoxFill;
    if FFocused then
    begin
      Border := C_HIST_BLUE;
      PenW := Max(1, Px(2));
    end
    else
    begin
      Border := Fill;
      PenW := 0;
    end;
    R := ClientRect;
    DrawRoundRect(Canvas, R, Height div 2, Fill, Border, PenW);

    FEdit.Color := Fill;
    FBtnClear.BackColor := Fill;

    DrawMagnifier;
  except
    on E: Exception do
      Logger.Error('历史搜索框绘制失败: %s - %s', [E.ClassName, E.Message]);
  end;
  finally
    Canvas.Unlock;
  end;
end;

{ 尺寸变化: 重排子控件并重绘 }
procedure TFHHistorySearchBox.Resize;
begin
  inherited;
  LayoutChildren;
  Invalidate;
end;

{ 句柄创建后: 重排子控件（DPI 此时才可查） }
procedure TFHHistorySearchBox.CreateWnd;
begin
  inherited CreateWnd;
  LayoutChildren;
end;

{ DPI 变化（跨屏）: 重排子控件并重绘 }
procedure TFHHistorySearchBox.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  LayoutChildren;
  Invalidate;
end;

{ 鼠标按下: 焦点交给输入框（点胶囊任意处可进入输入） }
procedure TFHHistorySearchBox.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FEdit.CanFocus then
    FEdit.SetFocus;
end;

{ ========================== TFHHistoryList ================================ }

{ 构造: 双缓冲自绘列表, 初始无悬停/按下行 }
constructor TFHHistoryList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := False;
  DoubleBuffered := True;
  Font.Name := 'Segoe UI';
  FHotIndex := -1;
  FPressRow := -1;
end;

{ 析构: 释放行内右键菜单实例 }
destructor TFHHistoryList.Destroy;
begin
  FreeAndNil(FMenu);
  inherited;
end;

{ 96 DPI 基准逻辑像素 → 当前 DPI 实际像素 }
function TFHHistoryList.Px(V: Integer): Integer;
var
  DPI: Integer;
begin
  DPI := 96;
  if HandleAllocated then
    DPI := GetDeviceCaps(Canvas.Handle, LOGPIXELSX);
  if DPI <= 0 then
    DPI := Screen.PixelsPerInch;
  Result := MulDiv(V, DPI, 96);
  if Result = 0 then
    Result := V;
end;

procedure TFHHistoryList.SetEntries(const AEntries: TFHHistoryEntries;
  ASearching: Boolean);
begin
  FEntries := AEntries;
  FSearching := ASearching;
  FEntryRowH := 0;          // 按当前 DPI/字体重新测量行高
  FOffset := 0;
  FHotIndex := -1;
  FDeleteHot := False;
  FMenuBtnHot := False;
  FPressRow := -1;
  BuildRows;
  Invalidate;
end;

{ 把条目序列展开成"分组标题 + 条目"交替行, 并累计各行顶边与内容总高 }
procedure TFHHistoryList.BuildRows;
var
  I, J, N: Integer;
  D: Int64;
begin
  SetLength(FRows, 0);
  SetLength(FTops, 0);
  SetLength(FRows, Length(FEntries) * 2 + 1);
  J := 0;
  for I := 0 to High(FEntries) do
  begin
    D := Trunc(FEntries[I].VisitTime);
    { 按日期分组: 数据已按 visit_time 倒序, 日期一变就插一个分组标题 }
    if (I = 0) or (Trunc(FEntries[I - 1].VisitTime) <> D) then
    begin
      FRows[J].Kind := hrGroup;
      FRows[J].GroupTitle := GroupCaption(D);
      FRows[J].Entry := Default(TFHHistoryEntry);
      Inc(J);
    end;
    FRows[J].Kind := hrEntry;
    FRows[J].Entry := FEntries[I];
    Inc(J);
  end;
  SetLength(FRows, J);
  SetLength(FTops, J);
  N := 0;
  for I := 0 to High(FRows) do
  begin
    FTops[I] := N;
    Inc(N, RowHeight(I));
  end;
  FContentH := N;
end;

{ 行高: 分组标题行 40px, 条目行按实测字体行盒（EntryRowHeight） }
function TFHHistoryList.RowHeight(ARow: Integer): Integer;
begin
  if (ARow >= 0) and (ARow < Length(FRows)) and (FRows[ARow].Kind = hrGroup) then
    Result := Px(40)
  else
    Result := EntryRowHeight;
end;

{ 条目行高 = 上留白 + 标题实际行盒 + 行间距 + URL 实际行盒 + 下留白。
  必须用 Canvas.TextHeight 实测行盒: 字体实际行高可能明显大于字号
  (含 internal leading / 中文字体回退), 用固定常量预留区会让上下两行
  文字在交界处相撞 —— 也就是用户看到的"两行之间没有行间距"。
  下留白比上留白大 3px: 字形顶部距行盒顶有 internal leading 的空隙,
  而底部 descent 被字母 g/y 等下伸部分用尽, 等值留白时下边视觉上
  会显得贴住 hover 底边（"网址被挡住"）, 加大下留白补回视觉对称。
  2026-11-18 加大留白(7/5/10→9/6/12): 宿主复现+像素测量证实静止态各分组
  行间距一致, "行距小"观感全部来自悬停 —— hover 灰底几乎满行(内缩 2px)
  把行间空隙从 24 压到 11 逻辑像素。加大行距并同步内缩 hover 底(→4px),
  悬停时行间空隙回到 18, 视觉不再"贴住/重叠" }
function TFHHistoryList.EntryRowHeight: Integer;
var
  TitleH, UrlH: Integer;
begin
  if FEntryRowH <= 0 then
  begin
    SetFontPx(13, [], C_HIST_TEXT);
    TitleH := Canvas.TextHeight('Ag');
    SetFontPx(12, [], C_HIST_TEXT2);
    UrlH := Canvas.TextHeight('Ag');
    FEntryRowH := Px(9) + TitleH + Px(6) + UrlH + Px(12);
  end;
  Result := FEntryRowH;
end;

{ DPI 变化: 清行高缓存并按新 DPI 重建行位置 }
procedure TFHHistoryList.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  { DPI 变化: 行高缓存/字体度量都要按新 DPI 重算, 行位置随之重建 }
  FEntryRowH := 0;
  if Length(FRows) > 0 then
    BuildRows;
  Invalidate;
end;

{ 最大滚动偏移 = 内容高 - 客户区高（下限 0） }
function TFHHistoryList.MaxOffset: Integer;
begin
  Result := Max(0, FContentH - ClientHeight);
end;

{ 滚动条滑块矩形（右缘 8px 宽, 高度按可视比例, 最小 40px） }
function TFHHistoryList.ThumbRect: TRect;
var
  TrackTop, TrackH, ThumbH, Top, W: Integer;
begin
  W := Px(8);
  TrackTop := Px(8);
  TrackH := Max(1, ClientHeight - Px(16));
  ThumbH := Max(Px(40), MulDiv(TrackH, ClientHeight, Max(1, FContentH)));
  if ThumbH > TrackH then
    ThumbH := TrackH;
  Top := TrackTop + MulDiv(TrackH - ThumbH, FOffset, Max(1, MaxOffset));
  Result := Rect(ClientWidth - W - Px(2), Top, ClientWidth - Px(2), Top + ThumbH);
end;

{ 客户区 y → 行索引（含滚动偏移换算）; 未命中返回 -1 }
function TFHHistoryList.IndexAtY(Y: Integer): Integer;
var
  I, T: Integer;
begin
  Result := -1;
  for I := 0 to High(FRows) do
  begin
    T := FTops[I] - FOffset;
    if (Y >= T) and (Y < T + RowHeight(I)) then
      Exit(I);
  end;
end;

{ 行删除按钮矩形: 悬停行最右侧, 20x20 逻辑像素, 垂直居中。
  位置与 DrawEntry 里时间的右移量（Px(12)+Btn+Px(12)）保持一致 }
function TFHHistoryList.DeleteBtnRect(ARow: Integer): TRect;
var
  Btn, X, Y: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if (ARow < 0) or (ARow >= Length(FRows)) then Exit;
  if FRows[ARow].Kind <> hrEntry then Exit;
  { C_HIST_ROWBTN=28 逻辑像素, 垂直居中于行; 排在"⋮"菜单按钮左侧 4px
    （右缘布局: 滚动条 8 + 留白 12 + ⋮ 28 + 缝 4 + 垃圾桶 28 = 80,
    与书签管理器同款） }
  Btn := Px(C_HIST_ROWBTN);
  X := ClientWidth - Px(8) - Px(12) - Btn - Px(4) - Btn;
  Y := FTops[ARow] - FOffset;
  Result := Rect(X, Y + (RowHeight(ARow) - Btn) div 2, X + Btn,
    Y + (RowHeight(ARow) + Btn) div 2);
end;

{ 行"⋮"菜单按钮矩形: 悬停行最右侧, 垂直居中（右缘布局见体内注释） }
function TFHHistoryList.MenuBtnRect(ARow: Integer): TRect;
var
  Btn, X, Y: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if (ARow < 0) or (ARow >= Length(FRows)) then Exit;
  if FRows[ARow].Kind <> hrEntry then Exit;
  { "⋮"菜单按钮: 行最右的 C_HIST_ROWBTN 按钮（原删除按钮位置） }
  Btn := Px(C_HIST_ROWBTN);
  X := ClientWidth - Px(8) - Px(12) - Btn;
  Y := FTops[ARow] - FOffset;
  Result := Rect(X, Y + (RowHeight(ARow) - Btn) div 2, X + Btn,
    Y + (RowHeight(ARow) + Btn) div 2);
end;

{ 滚动到指定偏移（夹取到 [0, MaxOffset], 值不变不重绘） }
procedure TFHHistoryList.ScrollTo(AOffset: Integer);
begin
  AOffset := EnsureRange(AOffset, 0, MaxOffset);
  if AOffset = FOffset then Exit;
  FOffset := AOffset;
  FHotIndex := -1;
  Invalidate;
end;

{ 按像素设画布字体（Segoe UI + 指定字号/样式/颜色） }
procedure TFHHistoryList.SetFontPx(ASize: Integer; AStyle: TFontStyles;
  AColor: TColor);
begin
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.PixelsPerInch := Px(96);
  Canvas.Font.Height := -Px(ASize);
  Canvas.Font.Style := AStyle;
  Canvas.Font.Color := AColor;
end;

{ 垃圾桶删除图标（悬停行右侧; Chrome/Material delete 形态）: 盖子横条 +
  提手 + 梯形桶体（两侧斜边 + 底边）。旧版"圆角矩形桶身 + 内部两条竖线"
  在 28px 按钮内细节过密（像笼子）, 已与下载窗口统一为 Material 简化形态。
  线条 GDI+ 抗锯齿; GDI+ 不可用回退 GDI 直线（Win7 兜底）。
  AHot=True（鼠标在按钮上）时用深色, 否则中灰色 }
procedure TFHHistoryList.DrawTrashIcon(const R: TRect; AHot: Boolean);
var
  Clr: TColor;
  PW: Single;
  CX, CY: Integer;

  { 统一线条绘制: GDI+ 抗锯齿优先, 失败回退 GDI 直线 }
  procedure Line(X1, Y1, X2, Y2: Integer);
  begin
    if not DrawLineAA(Canvas, X1, Y1, X2, Y2, Clr, PW) then
    begin
      Canvas.Pen.Style := psSolid;
      Canvas.Pen.Color := Clr;
      Canvas.Pen.Width := Max(1, Round(PW));
      Canvas.MoveTo(X1, Y1);
      Canvas.LineTo(X2, Y2);
    end;
  end;

begin
  if (R.Right - R.Left) <= 0 then Exit;
  if AHot then
    Clr := C_HIST_TEXT
  else
    Clr := C_HIST_TEXT2;
  { 1.5 逻辑像素: AA 下与 Chrome 图标观感一致（整数 1px 偏细） }
  PW := Max(1.0, 1.5 * Px(96) / 96);

  { 悬停按钮底: 圆形 #D4D7DC（与书签管理器同款, 比行 hover 底深一档） }
  if AHot then
    FillCircleAA(Canvas, R, C_HIST_BTNHOVER);

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

{ "⋮"菜单按钮: 竖排三点（悬停加深 + 圆形按钮底）。GDI+ 抗锯齿,
  GDI+ 不可用回退 GDI 实心小方块（1px 级小点, 锯齿不明显）。
  与书签管理器 TFHBookmarkList.DrawMenuDots 同款参数（点径 3、
  圆心距 5、总高 13, 与垃圾桶总视觉 14x18 平衡） }
procedure TFHHistoryList.DrawMenuDots(const R: TRect; AHot: Boolean);
var
  Clr: TColor;
  CX, Y0, D, I: Integer;
  G: TGPGraphics;
  B: TGPSolidBrush;
begin
  if AHot then
    Clr := C_HIST_TEXT
  else
    Clr := C_HIST_TEXT2;
  { 悬停按钮底: 圆形 #D4D7DC（与删除按钮同款） }
  if AHot then
    FillCircleAA(Canvas, R, C_HIST_BTNHOVER);
  CX := (R.Left + R.Right) div 2;
  D := Max(3, Px(3));
  { 三点分布: 直径 3px、圆心距 5px（逻辑）, 总高 13px,
    中点 = 按钮垂直中心 }
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

{ 画默认 favicon 占位: 浅灰圆角方块 + 地球线框（历史库不存 favicon） }
procedure TFHHistoryList.DrawFavicon(X, Y, ASize: Integer);
var
  Cy, CX, PW: Integer;
begin
  { 默认图标: 浅灰圆角方块 + 地球线框（历史库不存 favicon, 与 Chrome 的默认图标同义）;
    圆角/圆/经线均走 GDI+ 抗锯齿 }
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_HIST_HOVER;
  Canvas.Pen.Style := psClear;
  DrawRoundRect(Canvas, Rect(X, Y, X + ASize, Y + ASize), Px(4),
    C_HIST_HOVER, C_HIST_HOVER, 0);

  Canvas.Brush.Style := bsClear;
  PW := Max(1, Px(1));
  Cy := Y + ASize div 2;
  CX := X + ASize div 2;
  DrawEllipseAA(Canvas, Rect(X + Px(4), Y + Px(4),
    X + ASize - Px(4), Y + ASize - Px(4)), C_HIST_TEXT2, PW);
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := C_HIST_TEXT2;
  Canvas.Pen.Width := PW;
  Canvas.MoveTo(X + Px(4), Cy);
  Canvas.LineTo(X + ASize - Px(4), Cy);
  DrawEllipseAA(Canvas, Rect(CX - Px(2), Y + Px(4),
    CX + Px(2), Y + ASize - Px(4)), C_HIST_TEXT2, PW);
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Style := bsSolid;
end;

{ 画日期分组标题行（加粗灰字, 左对齐垂直居中） }
procedure TFHHistoryList.DrawGroup(ARow, ATop: Integer);
var
  R: TRect;
  S: string;
begin
  S := FRows[ARow].GroupTitle;
  SetFontPx(13, [fsBold], C_HIST_TEXT2);
  Canvas.Brush.Style := bsClear;
  R := Rect(Px(24), ATop, ClientWidth - Px(16), ATop + RowHeight(ARow));
  Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), R,
    DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_NOPREFIX);
  Canvas.Brush.Style := bsSolid;
end;

{ 画条目行: 悬停整行浅灰圆角底 + favicon + 标题/URL 两行
  + 右对齐时间 + 悬停行的删除/⋮按钮（布局细节见体内注释） }
procedure TFHHistoryList.DrawEntry(ARow, ATop: Integer);
var
  R, RowR, DelR: TRect;
  H, SBW, BtnW, TimeW, TextRight, TW: Integer;
  TitleH, UrlH, UrlTop: Integer;
  Title, Url, TimeStr: string;
begin
  H := RowHeight(ARow);
  SBW := Px(8);
  BtnW := Px(C_HIST_ROWBTN);

  { 悬停: 整行浅灰圆角底（Chrome 历史页的 hover 效果）。
    上下内缩 4px（原 2px）: 满行灰底会把行间空隙吃剩 11 逻辑像素,
    观感"行距小/像重叠"; 内缩 4px + 行距加大后悬停行间空隙回到 18 }
  if ARow = FHotIndex then
  begin
    RowR := Rect(Px(8), ATop + Px(4), ClientWidth - SBW - Px(8), ATop + H - Px(4));
    DrawRoundRect(Canvas, RowR, Px(8), C_HIST_HOVER, C_HIST_HOVER, 0);
  end;

  DrawFavicon(Px(24), ATop + (H - Px(20)) div 2, Px(20));

  { 右侧从左到右: 文字区 | 时间 | 垃圾桶 | ⋮（后两按钮仅悬停行显示） }
  TimeW := Px(52);
  TextRight := ClientWidth - SBW - Px(12) - BtnW - Px(4) - BtnW - Px(12) -
    TimeW - Px(8);
  if TextRight < Px(120) then
    TextRight := Px(120);

  Title := FRows[ARow].Entry.Title;
  if Title = '' then
    Title := FRows[ARow].Entry.Url;
  Url := FRows[ARow].Entry.Url;

  Canvas.Brush.Style := bsClear;

  SetFontPx(13, [], C_HIST_TEXT);
  { 用实测行盒定位 + DT_TOP: 矩形高度=行盒+1, 文字不会被"居中"挤出矩形;
    两行之间再留 Px(5) 行间距。此前用固定区高 + DT_VCENTER, 实际字体
    行盒更大时上下行文字在交界处相撞（看起来没有行间距） }
  TitleH := Canvas.TextHeight('Ag');
  R := Rect(Px(56), ATop + Px(9), TextRight, ATop + Px(9) + TitleH + 1);
  Winapi.Windows.DrawText(Canvas.Handle, PChar(Title), Length(Title), R,
    DT_SINGLELINE or DT_TOP or DT_LEFT or DT_END_ELLIPSIS or DT_NOPREFIX);

  SetFontPx(12, [], C_HIST_TEXT2);
  UrlH := Canvas.TextHeight('Ag');
  UrlTop := ATop + Px(9) + TitleH + Px(6);
  R := Rect(Px(56), UrlTop, TextRight, UrlTop + UrlH + 1);
  Winapi.Windows.DrawText(Canvas.Handle, PChar(Url), Length(Url), R,
    DT_SINGLELINE or DT_TOP or DT_LEFT or DT_END_ELLIPSIS or DT_NOPREFIX);

  { 时间: 右对齐（Chrome 历史页同位置）。这里用 TextOut 而不是 DrawText:
    DrawText 的 rect 在列表右侧曾出现整段不可见（截图核实无文字） }
  TimeStr := FormatDateTime('hh:nn', FRows[ARow].Entry.VisitTime);
  SetFontPx(12, [], C_HIST_TEXT2);
  TW := Canvas.TextWidth(TimeStr);

  Canvas.TextOut(ClientWidth - SBW - Px(12) - BtnW - Px(4) - BtnW -
    Px(12) - TW, ATop + Px(9), TimeStr);

  { 悬停行显示删除 + "⋮"菜单两按钮（鼠标移到按钮上: 圆形底 + 图标加深;
    与书签管理器同款形态） }
  if ARow = FHotIndex then
  begin
    DelR := DeleteBtnRect(ARow);
    DrawTrashIcon(DelR, FDeleteHot);
    DrawMenuDots(MenuBtnRect(ARow), FMenuBtnHot);
  end;

  Canvas.Brush.Style := bsSolid;
end;

{ 画空列表提示（搜索无结果 / 无历史记录, 居中灰字） }
procedure TFHHistoryList.DrawEmpty;
var
  R: TRect;
  S: string;
begin
  if FSearching then
    S := '未找到与您的搜索匹配的历史记录'
  else
    S := '没有历史记录';
  SetFontPx(14, [], C_HIST_TEXT2);
  Canvas.Brush.Style := bsClear;
  R := Rect(Px(24), 0, ClientWidth - Px(24), ClientHeight);
  Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), R,
    DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);
  Canvas.Brush.Style := bsSolid;
end;

{ 画滚动条滑块（悬停/拖拽加深, 圆角抗锯齿）; 不可滚动时不画 }
procedure TFHHistoryList.DrawScrollBar;
var
  R: TRect;
  Clr: TColor;
  Rd: Integer;
begin
  if MaxOffset <= 0 then Exit;
  if FScrollHot or FScrollDragging then
    Clr := C_HIST_THUMB_HOT
  else
    Clr := C_HIST_THUMB;
  R := ThumbRect;
  Rd := Min(Px(4), (R.Right - R.Left) div 2);
  { 滚动条圆角: GDI+ 抗锯齿 }
  DrawRoundRect(Canvas, R, Rd, Clr, Clr, 0);
end;

{ 全件自绘: 先做行高一致性自愈（无句柄期首测与绘制 DC 度量不一致的
  修复, 见体内注释）, 再逐行画分组/条目, 最后画滚动条 }
procedure TFHHistoryList.Paint;
var
  I, Y, H, T1, T2: Integer;
begin
  Canvas.Lock;
  try
  try
    { 行高自愈: ShowHistoryForm 在窗体 Show 前就 RefreshEntries 首测行高,
      此时控件无句柄, Canvas.TextHeight 走临时 DC, 字体度量与绘制 DC
      不一致 → 行高缓存偏小（首开行距挤、悬停行贴邻行, 删除触发刷新
      才恢复正常——2026-11-18 RTTI 诊断实锤 57 vs 59）。CreateWnd 的补救
      重测同样发生在首次绘制之前, 仍测到旧值。唯一度量与绘制同源的时机
      就是 Paint 本身: 每帧两次廉价 TextHeight 校验, 不一致即重建行位置,
      本帧按正确布局画 }
    if FEntryRowH > 0 then
    begin
      SetFontPx(13, [], C_HIST_TEXT);
      T1 := Canvas.TextHeight('Ag');
      SetFontPx(12, [], C_HIST_TEXT2);
      T2 := Canvas.TextHeight('Ag');
      if FEntryRowH <> Px(9) + T1 + Px(6) + T2 + Px(12) then
      begin
        FEntryRowH := 0;
        EntryRowHeight;
        if Length(FRows) > 0 then
          BuildRows;
        if FOffset > MaxOffset then
          FOffset := MaxOffset;
      end;
    end;

    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := C_HIST_BG;
    Canvas.Pen.Style := psClear;
    Canvas.FillRect(ClientRect);

    if Length(FRows) = 0 then
      DrawEmpty
    else
    begin
      for I := 0 to High(FRows) do
      begin
        Y := FTops[I] - FOffset;
        H := RowHeight(I);
        if Y + H <= 0 then Continue;
        if Y >= ClientHeight then Break;
        if FRows[I].Kind = hrGroup then
          DrawGroup(I, Y)
        else
          DrawEntry(I, Y);
      end;
    end;
    DrawScrollBar;
  except
    on E: Exception do
      Logger.Error('历史列表绘制失败: %s - %s', [E.ClassName, E.Message]);
  end;
  finally
    Canvas.Unlock;
  end;
end;

{ 尺寸变化: 夹紧滚动偏移并重绘 }
procedure TFHHistoryList.Resize;
begin
  inherited;
  ScrollTo(FOffset);
  Invalidate;
end;

{ 句柄创建后: 按窗口真实 DPI 重测行高并重建行位置（防副屏首开错位） }
procedure TFHHistoryList.CreateWnd;
begin
  inherited CreateWnd;
  { 句柄建立 → Px 从"主屏兜底"变为窗口所在监视器的真实 DPI。
    行高缓存若仍是兜底 DPI 下的旧值（窗口首次显示在非主屏 DPI 时即如此）,
    绘制按真实 DPI 布局而行高按旧 DPI, 网址行会向下溢出 hover 底边
    （"字体超出阴影"）。这里重测行高并重建行位置闭环 }
  FEntryRowH := 0;
  if Length(FRows) > 0 then
    BuildRows;
  Invalidate;
end;

{ 鼠标按下: 右键条目行 → 记悬停并弹右键菜单; 左键 → 滚动条拖拽/翻页
  或记录按下行 }
procedure TFHHistoryList.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  I: Integer;
  TR: TRect;
begin
  inherited;
  if Button = mbRight then
  begin
    I := IndexAtY(Y);
    if (I >= 0) and (FRows[I].Kind = hrEntry) then
    begin
      FHotIndex := I;
      Invalidate;
      ShowContextMenu(X, Y);
    end;
    Exit;
  end;
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

  FPressRow := IndexAtY(Y);
end;

{ 鼠标移动: 滚动条拖拽跟手; 更新悬停行与删除/⋮按钮悬停态 }
procedure TFHHistoryList.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  TrackH, ThumbH, Ratio: Integer;
  Hot, DelHot, MenuHot: Boolean;
  I: Integer;
begin
  inherited;
  if FScrollDragging and (MaxOffset > 0) then
  begin
    TrackH := Max(1, ClientHeight - Px(16));
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

  I := IndexAtY(Y);
  if I <> FHotIndex then
  begin
    FHotIndex := I;
    Invalidate;
  end;

  { 删除/"⋮"菜单按钮悬停态: 只在悬停行内命中按钮矩形才算 }
  DelHot := (I >= 0) and (I = FHotIndex) and
    PtInRect(DeleteBtnRect(I), Point(X, Y));
  MenuHot := (I >= 0) and (I = FHotIndex) and
    PtInRect(MenuBtnRect(I), Point(X, Y));
  if (DelHot <> FDeleteHot) or (MenuHot <> FMenuBtnHot) then
  begin
    FDeleteHot := DelHot;
    FMenuBtnHot := MenuHot;
    Invalidate;
  end;
end;

{ 鼠标松开: 结束滚动拖拽; 按下行内左键松开 → 命中删除按钮删该条 /
  命中 ⋮ 弹菜单 / 其余触发 OnOpen }
procedure TFHHistoryList.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  I: Integer;
  MR: TRect;
begin
  inherited;
  if Button <> mbLeft then Exit;
  if FScrollDragging then
  begin
    FScrollDragging := False;
    Invalidate;
    Exit;
  end;
  I := IndexAtY(Y);
  if (I >= 0) and (I = FPressRow) and (FRows[I].Kind = hrEntry) then
  begin
    FPressRow := -1;
    { 点在删除按钮上: 删除该条（复用右键菜单"从历史记录中删除"的 FOnDelete 通道）,
      不触发打开 }
    if PtInRect(DeleteBtnRect(I), Point(X, Y)) then
    begin
      FDeleteHot := False;
      if Assigned(FOnDelete) then
        FOnDelete(Self, FRows[I].Entry.Url);
    end
    else if PtInRect(MenuBtnRect(I), Point(X, Y)) then
    begin
      { "⋮"菜单按钮: 弹出与右键相同的菜单（锚在按钮正下方,
        与书签管理器同款） }
      MR := MenuBtnRect(I);
      ShowContextMenu(MR.Left, MR.Bottom);
    end
    else if Assigned(FOnOpen) then
      FOnOpen(Self, FRows[I].Entry.Url);
    Exit;
  end;
  FPressRow := -1;
end;

{ 滚轮: 上下滚动一屏的 1/3（120px 逻辑） }
function TFHHistoryList.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
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
procedure TFHHistoryList.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FHotIndex := -1;
  FDeleteHot := False;
  FMenuBtnHot := False;
  FScrollHot := False;
  Invalidate;
end;

{ 弹条目右键菜单: 打开/新标签页打开/复制链接/删除（重建 FMenu 实例） }
procedure TFHHistoryList.ShowContextMenu(X, Y: Integer);
var
  I: Integer;
  P: TPoint;
begin
  I := IndexAtY(Y);
  if (I < 0) or (FRows[I].Kind <> hrEntry) then Exit;
  FMenuEntry := FRows[I].Entry;

  FreeAndNil(FMenu);
  FMenu := TFHMenu.Create(Self);
  FMenu.ScaleFactor := Screen.PixelsPerInch / 96;
  FMenu.Add('在当前标签页中打开', MenuOpen, '', miOpen);
  FMenu.Add('在新标签页中打开', MenuOpenNewTab, '', miNewTab);
  FMenu.AddSeparator;
  FMenu.Add('复制链接地址', MenuCopy, '', miLink);
  FMenu.AddSeparator;
  FMenu.Add('从历史记录中删除', MenuDelete, '', miDelete);

  P := ClientToScreen(Point(X, Y));
  FMenu.Popup(P.X, P.Y);
end;

{ 菜单"在当前标签页中打开": 触发 OnOpen }
procedure TFHHistoryList.MenuOpen(Sender: TObject);
begin
  if Assigned(FOnOpen) then
    FOnOpen(Self, FMenuEntry.Url);
end;

{ 菜单"在新标签页中打开": 触发 OnOpenNewTab }
procedure TFHHistoryList.MenuOpenNewTab(Sender: TObject);
begin
  if Assigned(FOnOpenNewTab) then
    FOnOpenNewTab(Self, FMenuEntry.Url);
end;

{ 菜单"复制链接地址": 写剪贴板 }
procedure TFHHistoryList.MenuCopy(Sender: TObject);
begin
  if FMenuEntry.Url <> '' then
    Clipboard.AsText := FMenuEntry.Url;
end;

{ 菜单"从历史记录中删除": 触发 OnDelete }
procedure TFHHistoryList.MenuDelete(Sender: TObject);
begin
  if Assigned(FOnDelete) then
    FOnDelete(Self, FMenuEntry.Url);
end;

{ ========================== TFHHistoryForm ================================ }

{ 构造: 无边框 Chrome 弹窗（细节见体内注释）, 构建 UI 并按屏幕 DPI 兜底布局 }
constructor TFHHistoryForm.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  Caption := '历史记录';
  { bsSizeable 仅为保留 WS_THICKFRAME（边缘八向调整大小）; 系统标题栏在
    CreateParams 里去掉, 整窗客户区 + 顶部 44px 自绘标题栏（Chrome 弹窗式） }
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMinimize, biMaximize];
  Position := poMainFormCenter;
  Color := C_HIST_BG;
  Font.Name := 'Segoe UI';
  { 本窗体所有尺寸/字号已按 Px() 手动换算, 关掉 VCL 的自动缩放,
    否则 125%/150% 下会被再放大一次, 控件跑到窗口外（时间/按钮看不见） }
  Scaled := False;
  { 尺寸/约束/标题字号由 ApplyWindowMetrics 按窗口实际 DPI 计算
    （先用屏幕 DPI 兜底, DoShow 时再按所在监视器校正） }
  BuildUi;
  DoubleBuffered := True;
  OnPaint := FormPaint;
  OnMouseDown := FormMouseDown;
  OnMouseMove := FormMouseMove;
  ApplyWindowMetrics;
end;

{ 析构: 单例指针与全局回调清空（防悬垂） }
destructor TFHHistoryForm.Destroy;
begin
  if GForm = Self then
  begin
    GForm := nil;
    GOnOpen := nil;
    GOnOpenNewTab := nil;
    GOnClearData := nil;
  end;
  inherited;
end;

{ 无边框窗口: 去掉 WS_CAPTION（系统标题栏）, 保留 WS_THICKFRAME ——
  边缘仍由系统 hit-test 出八向调整大小, 客户区扩满整窗, 标题栏自绘。
  必须加 WS_POPUP 位: user32 对非 WS_POPUP 的顶层(overlapped)窗口,
  只要带 WS_THICKFRAME 就会在 CreateWindowEx 内部强制补回 WS_CAPTION
  （实测传入无 CAPTION 的样式, WM_NCCALCSIZE 时已含 CAPTION）——
  popup 类窗口不受该归一化; 任务栏按钮经 VCL 的 owner(MainForm)机制
  共享主窗按钮, 与改前行为一致 }
procedure TFHHistoryForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := (Params.Style or WS_POPUP) and (not WS_CAPTION)
    and (not WS_SYSMENU);
end;

{ 标题栏高度（自绘, 96 DPI 基准 44px） }
function TFHHistoryForm.CaptionH: Integer;
begin
  Result := Px(44);
end;

{ 标题栏右上角关闭按钮: 32x32, 距右 8px, 垂直居中于标题栏 }
function TFHHistoryForm.CloseBtnRect: TRect;
var
  Btn: Integer;
begin
  Btn := Px(32);
  Result := Rect(ClientWidth - Px(40), (CaptionH - Btn) div 2,
    ClientWidth - Px(40) + Btn, (CaptionH + Btn) div 2);

end;

{ 无客户区标题栏后的拖动/命中测试:
  - 边缘 resize（HTLEFT..HTBOTTOMRIGHT）优先, 直接采用系统结果;
  - 标题栏空白区 → HTCAPTION（可拖动, 系统处理移动/贴边）;
  - 标题栏上的按钮（关闭 / 清除浏览数据）留在 HTCLIENT, 走鼠标事件 }
procedure TFHHistoryForm.WMNCHitTest(var Message: TWMNCHitTest);
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
    if Assigned(FOnClearData) and PtInRect(FClearRect, P) then
      Exit;
    Message.Result := HTCAPTION;
  end;
end;

{ 让客户区覆盖整窗: 保留 WS_THICKFRAME 时系统默认把客户区从窗口顶边
  往下推一个 resize 边框带 —— 自绘标题栏与窗口物理顶边之间的"上边距"。
  wParam=TRUE 时不动 rgrc[0]（输入即整个窗口矩形）并返回 0, 客户区=整窗;
  边缘八向 resize 判定不受影响（thickframe 窗口与 NCCALCSIZE 结果解耦,
  上方 WMNCHitTest 已优先采用系统的边缘判定） }
procedure TFHHistoryForm.WMNCCalcSize(var Message: TWMNCCalcSize);
begin
  if Message.CalcValidRects then
    Message.Result := 0
  else
    inherited;
end;

{ 失活不重绘非客户区: 右键菜单等独立弹窗弹出的瞬间本窗口失活,
  DefWindowProc 对带 WS_THICKFRAME 的无边框窗口会在四周重绘一圈 inset
  的 inactive 边框 —— 与自绘 1px 边框线叠加后, 窗口与边框之间出现"缝隙"。
  lParam = -1 是官方的"不重绘"哨兵值, 仍走 inherited 保留 VCL 的
  激活/失活状态流转（CM_ACTIVATE/CM_DEACTIVATE） }
procedure TFHHistoryForm.WMNCActivate(var Message: TWMNCActivate);
begin
  Message.Unused := -1;
  inherited;
end;

{ 双击标题栏: 最大化/还原（HTCAPTION 双击发 WM_NCLBUTTONDBLCLK, 无系统
  标题栏时 DefWindowProc 不再代劳, 这里自己切） }
procedure TFHHistoryForm.WndProc(var Message: TMessage);
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

{ 去 WS_CAPTION 后 SW_MAXIMIZE 会盖住任务栏 —— 把最大化目标夹到所在
  监视器的工作区（PerMonitorV2 下各屏工作区不同, 用 Monitor 而非主屏） }
procedure TFHHistoryForm.WMGetMinMaxInfo(var Message: TWMGetMinMaxInfo);
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

{ 鼠标离开窗口: 清掉关闭按钮悬停态, 避免灰底残留 }
procedure TFHHistoryForm.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FCloseHot := False;
  Invalidate;
end;

{ 96 DPI 基准逻辑像素 → 窗口所在监视器实际像素（非主屏 DPI, 见体内注释） }
function TFHHistoryForm.Px(V: Integer): Integer;
var
  DPI: Integer;
  DC: HDC;
begin
  { 用窗口实际所在监视器的 DPI（PerMonitorV2 下各屏 DPI 可能不同）,
    而不是 Screen.PixelsPerInch（主屏 DPI）—— 窗口开在副屏时会整窗错位/偏大 }
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

{ 构建子控件: 标题标签 + 搜索框 + 历史列表, 并挂接事件 }
procedure TFHHistoryForm.BuildUi;
begin
  FTitle := TLabel.Create(Self);
  FTitle.Parent := Self;
  FTitle.ParentFont := False;
  FTitle.AutoSize := False;
  FTitle.Transparent := True;
  FTitle.Layout := tlCenter;          // 标题在自绘标题栏内垂直居中
  FTitle.Caption := '历史记录';
  FTitle.Font.Name := 'Segoe UI';
  FTitle.Font.PixelsPerInch := Px(96);
  FTitle.Font.Height := -Px(20);
  FTitle.Font.Style := [fsBold];
  FTitle.Font.Color := C_HIST_TEXT;

  { “清除浏览数据”不用 TLabel: 它在该窗口里实测完全不可见（自绘窗体上更可控） }
  FClearRect := Rect(0, 0, 0, 0);

  FSearchBox := TFHHistorySearchBox.Create(Self);
  FSearchBox.Parent := Self;
  FSearchBox.OnChange := SearchChange;

  FList := TFHHistoryList.Create(Self);
  FList.Parent := Self;
  FList.OnOpen := ListOpen;
  FList.OnOpenNewTab := ListOpenNewTab;
  FList.OnDelete := ListDelete;
end;

{ 标题栏自绘: 白底 + 底部 1px 分隔线 + 右上角关闭按钮(×, 悬停浅灰圆角底)
  + "清除浏览数据"蓝色文本。窗口无系统标题栏, 这一层就是 Chrome 弹窗的标题栏 }
procedure TFHHistoryForm.FormPaint(Sender: TObject);
var
  S: string;
  R: TRect;
  PW, CX, CY, D: Integer;
  Clr: TColor;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_HIST_BG;
  Canvas.Pen.Style := psClear;
  Canvas.FillRect(Rect(0, 0, ClientWidth, CaptionH()));

  { 四周 1px 边框线: 吞掉 WM_NCCALCSIZE 后客户区=整窗, 系统不再画任何
    非客户区边框, 白底窗口在浅色背景下无法区分边界 —— Chrome 弹窗
    同样自绘一圈浅灰细边（含顶部, 标题栏贴顶不等于无边框线） }
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := C_HIST_THUMB;
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

  { 关闭按钮: 悬停浅灰圆角底 + × 线条（走 GDI+ 抗锯齿） }
  R := CloseBtnRect();
  if FCloseHot then
    DrawRoundRect(Canvas, R, Px(8), C_HIST_HOVER, C_HIST_HOVER, 0);
  D := Px(10);
  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  if FCloseHot then
    Clr := C_HIST_TEXT
  else
    Clr := C_HIST_TEXT2;
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

  { "清除浏览数据"（可不给回调, 此时 LayoutUi 已把区域置空不显示） }
  if Assigned(FOnClearData) and (FClearRect.Right > FClearRect.Left) then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Name := 'Segoe UI';
    Canvas.Font.PixelsPerInch := Px(96);
    Canvas.Font.Height := -Px(13);
    Canvas.Font.Style := [];
    Canvas.Font.Color := C_HIST_BLUE;
    S := '清除浏览数据';
    Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), FClearRect,
      DT_SINGLELINE or DT_VCENTER or DT_RIGHT or DT_NOPREFIX);
    Canvas.Brush.Style := bsSolid;
  end;
end;

{ 鼠标按下: 命中标题栏关闭按钮则关窗; 命中"清除浏览数据"则触发回调 }
procedure TFHHistoryForm.FormMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  { 标题栏关闭按钮 }
  if PtInRect(CloseBtnRect, Point(X, Y)) then
  begin
    FCloseHot := False;
    Close;
    Exit;
  end;
  if Assigned(FOnClearData) and
     PtInRect(FClearRect, Point(X, Y)) then
    ClearDataClick(Self);
end;

{ 鼠标移动: 跟踪关闭按钮悬停态; "清除浏览数据"上手型光标 }
procedure TFHHistoryForm.FormMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  Hot: Boolean;
begin
  Hot := PtInRect(CloseBtnRect, Point(X, Y));
  if Hot <> FCloseHot then
  begin
    FCloseHot := Hot;
    Invalidate;
  end;
  if Assigned(FOnClearData) and PtInRect(FClearRect, Point(X, Y)) then
    Cursor := crHandPoint
  else
    Cursor := crDefault;
end;

{ 重排子控件: 标题/清除区在标题栏内, 搜索框与列表在内容区 }
procedure TFHHistoryForm.LayoutUi;
var
  Pad, SearchW, SearchTop: Integer;
begin
  if (FTitle = nil) or (FSearchBox = nil) or (FList = nil) then Exit;
  { 标题"历史记录"放自绘标题栏左侧垂直居中; 内容区从标题栏下开始 }
  Pad := Px(24);
  SearchTop := CaptionH + Px(16);

  FTitle.SetBounds(Px(16), 0,
    Max(Px(120), ClientWidth - Px(16) - Px(220)), CaptionH);

  { "清除浏览数据"在标题栏内、关闭按钮左侧（避开 32x32 关闭按钮） }
  FClearRect := Rect(ClientWidth - Px(40) - Px(12) - Px(110),
    (CaptionH - Px(20)) div 2,
    ClientWidth - Px(40) - Px(12), (CaptionH + Px(20)) div 2);
  Invalidate;

  SearchW := Min(Px(600), Max(Px(160), ClientWidth - 2 * Pad));
  FSearchBox.SetBounds(Pad, SearchTop, SearchW, Px(36));

  FList.SetBounds(Pad, SearchTop + Px(36) + Px(12),
    Max(Px(120), ClientWidth - 2 * Pad),
    Max(Px(80), ClientHeight - (SearchTop + Px(36) + Px(12)) - Pad));
end;

{ 窗口尺寸变化: 重排子控件 }
procedure TFHHistoryForm.Resize;
begin
  inherited;
  LayoutUi;
end;

{ 按窗口所在监视器的实际 DPI 重算窗口尺寸/最小尺寸/标题字号并重排。
  CreateNew（无句柄, Px 用屏幕 DPI 兜底）、DoShow、WM_DPICHANGED 时调用 }
procedure TFHHistoryForm.ApplyWindowMetrics;
begin
  { 无系统标题栏后客户区=整窗: 高度基准补回自绘标题栏（44px）,
    使内容区仍约为 900x640 }
  ClientWidth := Px(900);          // 96 DPI 逻辑尺寸
  ClientHeight := Px(640) + CaptionH;
  Constraints.MinWidth := Px(640);
  Constraints.MinHeight := Px(420) + CaptionH;

  if FTitle <> nil then
  begin
    FTitle.Font.Name := 'Segoe UI';
    FTitle.Font.PixelsPerInch := Px(96);
    FTitle.Font.Height := -Px(20);
    FTitle.Font.Style := [fsBold];
    FTitle.Font.Color := C_HIST_TEXT;
  end;

  LayoutUi;
end;

{ 跨到不同 DPI 的显示器: 按新 DPI 重算窗口尺寸与布局 }
procedure TFHHistoryForm.WMDpiChanged(var Message: TMessage);
begin
  { 窗口被拖到不同 DPI 的监视器 / 首次在副屏打开时触发。
    VCL 在 Scaled=False 时不会缩放子控件 —— 这里自己按新 DPI 重排 }
  inherited;
  ApplyWindowMetrics;
end;

{ 显示: 按窗口所在屏真实 DPI 校正布局, 焦点给列表（同 Chrome 历史页） }
procedure TFHHistoryForm.DoShow;
begin
  inherited;
  { 句柄已建立, 此时 Px 取的是窗口所在屏的真实 DPI, 再校正一次 }
  ApplyWindowMetrics;
  { 焦点给列表而不是搜索框, 与 Chrome 历史页一致（搜索框占位提示也能显示） }
  if FList.CanFocus then
    FList.SetFocus;
end;

{ 关闭: 释放窗口（单例指针在 Destroy 里清） }
procedure TFHHistoryForm.DoClose(var Action: TCloseAction);
begin
  inherited;
  Action := caFree;
end;

{ 挂接宿主回调: 打开/新标签打开/清除浏览数据 }
procedure TFHHistoryForm.SetCallbacks(AOnOpen, AOnOpenNewTab: TFHHistoryUrlEvent;
  AOnClearData: TNotifyEvent);
begin
  FOnOpen := AOnOpen;
  FOnOpenNewTab := AOnOpenNewTab;
  FOnClearData := AOnClearData;

  Invalidate;
end;

{ 按搜索框当前关键词重新查询历史库并刷新列表（打开窗口/搜索/删除/清除后调用） }
procedure TFHHistoryForm.RefreshEntries;
var
  Entries: TFHHistoryEntries;
  Kw: string;
begin
  if FList = nil then Exit;
  Kw := Trim(FSearchBox.SearchText);
  try
    Entries := HistoryDB.QueryHistory(Kw);
    FList.SetEntries(Entries, Kw <> '');
  except
    on E: Exception do
      Logger.Error('查询历史记录失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 搜索框文本变化: 按新关键词重新查询 }
procedure TFHHistoryForm.SearchChange(Sender: TObject);
begin
  RefreshEntries;
end;

{ "清除浏览数据"点击: 触发宿主回调（弹清除对话框）, 关闭后刷新列表 }
procedure TFHHistoryForm.ClearDataClick(Sender: TObject);
begin
  if Assigned(FOnClearData) then
  begin
    FOnClearData(Self);
    RefreshEntries;          // 清除对话框关闭后刷新（数据已被删）
  end;
end;

{ 列表单击条目: 在当前标签页打开并关闭本窗口
  （PostMessage 延迟关闭, 避免在 MouseUp 栈内释放自身） }
procedure TFHHistoryForm.ListOpen(Sender: TObject; const AUrl: string);
begin
  if Assigned(FOnOpen) then
    FOnOpen(Self, AUrl);
  { 单击 = 当前标签页打开（同 Chrome 历史页）, 窗口随之后关;
    用 PostMessage 延迟关闭, 避免在列表 MouseUp 栈内释放自身控件 }
  if HandleAllocated then
    PostMessage(Handle, WM_CLOSE, 0, 0);
end;

{ 列表"在新标签页中打开": 触发宿主回调（本窗口不关） }
procedure TFHHistoryForm.ListOpenNewTab(Sender: TObject; const AUrl: string);
begin
  if Assigned(FOnOpenNewTab) then
    FOnOpenNewTab(Self, AUrl);
end;

{ 列表删除条目: 从历史库删该 URL 并刷新列表 }
procedure TFHHistoryForm.ListDelete(Sender: TObject; const AUrl: string);
begin
  try
    HistoryDB.DeleteHistoryUrl(AUrl);
  except
    on E: Exception do
      Logger.Error('删除历史记录失败: %s - %s', [E.ClassName, E.Message]);
  end;
  RefreshEntries;
end;

{ ---- 单例入口 ------------------------------------------------------------ }

procedure ShowHistoryForm(AOnOpen, AOnOpenNewTab: TFHHistoryUrlEvent;
  AOnClearData: TNotifyEvent);
begin
  GOnOpen := AOnOpen;
  GOnOpenNewTab := AOnOpenNewTab;
  GOnClearData := AOnClearData;

  if (GForm = nil) or (csDestroying in GForm.ComponentState) then
  begin
    GForm := TFHHistoryForm.CreateNew(Application);
    GForm.SetCallbacks(GOnOpen, GOnOpenNewTab, GOnClearData);
    GForm.RefreshEntries;
    GForm.Show;
  end
  else
  begin
    GForm.SetCallbacks(GOnOpen, GOnOpenNewTab, GOnClearData);
    GForm.RefreshEntries;
    if not GForm.Visible then
      GForm.Show;
    GForm.BringToFront;
  end;
end;

initialization

finalization
  if GForm <> nil then
  begin
    GForm.Free;
    GForm := nil;
  end;
  GOnOpen := nil;
  GOnOpenNewTab := nil;
  GOnClearData := nil;

end.