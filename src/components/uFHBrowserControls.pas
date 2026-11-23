unit uFHBrowserControls;

{==============================================================================
  FHBrowser 自绘控件 —— Chrome 风格地址栏/导航按钮/窗口控制按钮
  ----------------------------------------------------------------------------
  TFHNavButton:     扁平导航按钮（悬停圆形浅灰背景 + 自绘线条图标）
  TFHStarGlyph:     地址栏胶囊内星标（无句柄图形控件, 不遮挡胶囊描边）
  TFHAddressBar:    圆角地址栏（浅灰背景 + 聚焦蓝色边框 + 内嵌 TEdit 输入）
  TFHCaptionButton: 窗口控制按钮（最小化/最大化/关闭, 关闭悬停红底）
  约定（2026-10 修复）:
    - Paint 第一步必须按底色填满客户区: 子窗口区域父窗口不会帮擦, 悬停高亮
      结束后不重绘底色 → 灰色圆/方块永久残留（原实现的主要观感缺陷）
    - BackColor = clNone 时自动取父容器底色（挂 TFHChromeTabs 时取
      Theme.BarBackground）, 免去调用方手工配色
    - 所有几何量经 DPI 换算, 高 DPI 下图标/圆角/内缩同步放大
==============================================================================}

interface

uses
  System.Classes, System.SysUtils, System.UITypes, System.Math, System.TypInfo,
  System.Types,
  Winapi.Windows, Winapi.Messages,
  Winapi.GDIPOBJ, Winapi.GDIPAPI,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.StdCtrls;

type
  TFHNavButtonType = (nbtBack, nbtForward, nbtReload, nbtHome, nbtGo, nbtMenu,
    nbtStop, nbtChevronUp, nbtChevronDown, nbtMatchCase, nbtDownload,
    nbtDownloadDone, nbtStar, nbtStarred);
  TFHCaptionButtonType = (cbtMin, cbtMax, cbtClose);

  { ---- TFHNavButton: Chrome 风格扁平导航按钮 --------------------------- }
  TFHNavButton = class(TCustomControl)
  private
    FButtonType: TFHNavButtonType;
    FBackColor: TColor;
    FHovered: Boolean;
    FPressed: Boolean;
    FChecked: Boolean;
    procedure SetButtonType(Value: TFHNavButtonType);
    procedure SetBackColor(Value: TColor);
    procedure SetChecked(Value: Boolean);
    { DrawIconGDIPlus: GDI+ 抗锯齿画图标（首选）; DrawIconGDI: 降级到 GDI 折线
      画法。返回 True 表示已完成绘制 }

    function DrawIconGDIPlus(PenColor: TColor): Boolean;
    function DrawIconGDI(PenColor: TColor): Boolean;
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    function ResolvedBackColor: TColor;
    procedure SetEnabled(Value: Boolean); override;
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DrawIcon;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property ButtonType: TFHNavButtonType read FButtonType write SetButtonType default nbtBack;
    { BackColor: 控件底色; clNone（默认）= 自动取父容器底色 }
    property BackColor: TColor read FBackColor write SetBackColor default clNone;
    property Checked: Boolean read FChecked write SetChecked default False;
    property OnClick;
    property Enabled;
    property Hint;
    property ShowHint;
  end;

  { ---- TFHStarGlyph: 地址栏胶囊内星标（无句柄图形按钮） ----------------- }
  { 之前用 TFHNavButton（窗口化 TCustomControl）: 它 Paint 第一步铺不透明
    底色, 28x28 矩形恰好嵌进胶囊右半圆区（右缘仅距胶囊边 3px）, 把聚焦蓝
    描边的右弧段整段盖住 —— "书签按钮右边边框断开"的根因。
    TGraphicControl 绘制发生在父（地址栏）的 WM_PAINT 里且常态不铺底,
    胶囊描边完整透出; 悬停灰圆远小于右半圆且近似同心, 永不覆盖描边。
    鼠标/Click/hint 由 VCL 的父级消息转发照常工作。 }
  TFHStarGlyph = class(TGraphicControl)
  private
    FStarred: Boolean;
    FHovered: Boolean;
    FPressed: Boolean;
    procedure SetStarred(Value: Boolean);
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    { Starred: 空心灰星 / 实心蓝星 }
    property Starred: Boolean read FStarred write SetStarred default False;
    property OnClick;
    property Enabled;
    property Hint;
    property ShowHint;
  end;

  { ---- TFHAddressBar: Chrome 风格圆角地址栏 ---------------------------- }
  TFHAddressBar = class(TCustomControl)
  private
    FEdit: TEdit;
    FBtnStar: TFHStarGlyph;      // 胶囊内右端星标（无句柄, 不遮挡右半圆描边）
    FStarred: Boolean;
    FBackColor: TColor;
    FFocused: Boolean;
    FOnKeyPress: TKeyPressEvent;
    FOnChange: TNotifyEvent;
    FOnStarClick: TNotifyEvent;
    function GetText: string;
    procedure SetText(const Value: string);
    procedure SetBackColor(Value: TColor);
    procedure SetStarred(Value: Boolean);
    procedure StarBtnClick(Sender: TObject);
    procedure LayoutStarButton;
    procedure UpdateEditMargins;
    procedure UpdateEditBounds;
    { 把内嵌 EDIT 的字号钉死为设计值 12px@96（幂等）, 详见 UpdateEditBounds }
    procedure PinEditFont;
    { DrawPillGDIPlus: GDI+ 抗锯齿画胶囊（首选）; DrawPillGDI: 降级到 GDI 分笔
      拼画（两手半圆+两条直线）。两者返回 True 表示已完成绘制 }
    function DrawPillGDIPlus(R: TRect; BorderColor: TColor;
      PenW: Integer): Boolean;
    function DrawPillGDI(R: TRect; BorderColor: TColor; PenW: Integer): Boolean;
    procedure EditEnter(Sender: TObject);
    procedure EditExit(Sender: TObject);
    procedure EditKeyPress(Sender: TObject; var Key: Char);
    procedure EditChange(Sender: TObject);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure CreateWnd; override;
    procedure SetEnabled(Value: Boolean); override;
    { VCL 的 SetParent 自动缩放会把 EDIT 字号放大两次（见 PinEditFont 注释）,
      每次缩放级联过后都重新钉死, 任何 DPI 变化路径都不会再错 }
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure CMEnter(var Message: TCMEnter); message CM_ENTER;
    procedure CMExit(var Message: TCMExit); message CM_EXIT;
  public
    constructor Create(AOwner: TComponent); override;
    { SelectAll: 聚焦并全选（地址栏点击/快捷键常用） }
    procedure SelectAll;
    { 星标按钮的屏幕矩形（书签气泡的锚定区） }
    function StarScreenRect: TRect;
    property Edit: TEdit read FEdit;
  published
    property Text: string read GetText write SetText;
    { BackColor: 圆角外侧的四个角用什么色填（默认取父容器底色） }
    property BackColor: TColor read FBackColor write SetBackColor default clNone;
    property OnKeyPress: TKeyPressEvent read FOnKeyPress write FOnKeyPress;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    { Starred: 当前页是否已收藏 —— 星标在空心灰星/实心蓝星间切换 }
    property Starred: Boolean read FStarred write SetStarred default False;
    property OnStarClick: TNotifyEvent read FOnStarClick write FOnStarClick;
    property Enabled;
  end;

  { ---- TFHCaptionButton: Chrome 风格窗口控制按钮 ---------------------- }
  TFHCaptionButton = class(TCustomControl)
  private
    FButtonType: TFHCaptionButtonType;
    FBackColor: TColor;
    FHovered: Boolean;
    FPressed: Boolean;
    procedure SetButtonType(Value: TFHCaptionButtonType);
    procedure SetBackColor(Value: TColor);
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    function ResolvedBackColor: TColor;
    { 所在窗体当前是否为最大化状态（最大化按钮据此切换 最大化□ / 还原▣ 图标） }
    function ParentFormMaximized: Boolean;
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    { 窗口状态变化后调用: 让图标按新状态重画 }
    procedure UpdateGlyph;
  published
    property ButtonType: TFHCaptionButtonType read FButtonType write SetButtonType default cbtClose;
    { BackColor: clNone（默认）= 自动取父容器底色（标签条为 Theme.BarBackground） }
    property BackColor: TColor read FBackColor write SetBackColor default clNone;
    property OnClick;
    property Enabled;
  end;

implementation

uses
  uFHChromeTabs;

{ ---- DPI 与底色解析 ------------------------------------------------------ }

{ 96 DPI 基准逻辑像素 → 屏幕像素（构造期用, 屏幕 DPI 为基准） }
function ScaleDpi(Value: Integer): Integer;
begin
  // 构造期用: 以屏幕 DPI 为基准
  Result := MulDiv(Value, Screen.PixelsPerInch, 96);
  if Result = 0 then
    Result := Value;
end;

{ 96 DPI 基准逻辑像素 → 控件所在窗口实际像素（绘制期用, 跨屏可不同） }
function ScaleCanvas(ACanvas: TCanvas; Value: Integer): Integer;
var
  DPI: Integer;
begin
  // 绘制期用: 按控件所在窗口的实际 DPI（不同显示器可不同）
  DPI := 96;
  if (ACanvas <> nil) and (ACanvas.Handle <> 0) then
    DPI := GetDeviceCaps(ACanvas.Handle, LOGPIXELSX);
  if DPI <= 0 then
    DPI := 96;
  Result := MulDiv(Value, DPI, 96);
end;

{ ---- GDI+ 抗锯齿绘制辅助 ------------------------------------------------ }
{ GDI 的 Ellipse/Arc/MoveTo-LineTo 一律不做抗锯齿: 圆、弧、斜线必然出现阶梯状
  锯齿。这里统一走 GDI+（SmoothingModeAntiAlias）, 复用 uFHChromeTabs 的那份
  GDI+ 会话; 启动失败时各 Paint 自动退化到原来的 GDI 画法。 }

{ TColor($00BBGGRR) → GDI+ ARGB($AARRGGBB) }
function ColorToARGB(Color: TColor): ARGB;
var
  C: Cardinal;
begin
  C := ColorToRGB(Color);
  // GDI+ 颜色是 $AARRGGBB（TColor 为 $00BBGGRR）
  Result := ARGB($FF000000 or (GetRValue(C) shl 16) or
    (GetGValue(C) shl 8) or GetBValue(C));
end;

function CreateSmoothGraphics(ACanvas: TCanvas): TGPGraphics;
begin
  Result := nil;
  if (ACanvas = nil) or (ACanvas.Handle = 0) then
    Exit;
  if not EnsureGdiPlus then
    Exit;
  Result := TGPGraphics.Create(ACanvas.Handle);
  Result.SetSmoothingMode(SmoothingModeAntiAlias);
end;

{ 抗锯齿实心圆（按钮悬停圆底; GDI+ 不可用返回 False, 调用方回退 GDI Ellipse）。
  纯 GDI Ellipse 无抗锯齿 —— 用户在多显示器环境反馈圆底边缘有锯齿 }
function FillCircleAA(ACanvas: TCanvas; const R: TRect; AColor: TColor): Boolean;
var
  G: TGPGraphics;
  B: TGPSolidBrush;
begin
  Result := False;
  if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;
  G := CreateSmoothGraphics(ACanvas);
  if G = nil then Exit;
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
  Result := True;
end;

{ 解析控件底色: BackColor=clNone 时自动取父容器底色
  （标签条取主题条底色; 其余经 RTTI 读 published Color） }
function ResolveBackColor(AControl: TControl; ABackColor: TColor;
  AFallback: TColor): TColor;
var
  Prop: PPropInfo;
begin
  if ABackColor <> clNone then
    Exit(ABackColor);
  if AControl = nil then
    Exit(AFallback);
  // 挂在标签条上: 取主题条底色, 而不是 clBtnFace
  if AControl is TFHChromeTabs then
    Exit(TFHChromeTabs(AControl).Theme.BarBackground);
  // 父容器有 published Color（TPanel/TForm/TGroupBox 等）就取它;
  // TControl.Color 本体是 protected, 只能经 RTTI 读取
  Prop := GetPropInfo(AControl, 'Color');
  if (Prop <> nil) and (Prop^.PropType^.Kind = tkInteger) then
    Result := TColor(GetOrdProp(AControl, Prop))
  else
    Result := AFallback;
end;

{ ============================ TFHNavButton =============================== }

{ 构造: 默认 28x28 逻辑尺寸, 手型光标, 后退图标 }
constructor TFHNavButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  Width := ScaleDpi(28);
  Height := ScaleDpi(28);
  FButtonType := nbtBack;
  FBackColor := clNone;
  FHovered := False;
  FPressed := False;
  FChecked := False;
  Cursor := crHandPoint;
end;

{ 选中态 setter（区分大小写按钮等用）: 变化时重绘 }
procedure TFHNavButton.SetChecked(Value: Boolean);
begin
  if FChecked <> Value then
  begin
    FChecked := Value;
    Invalidate;
  end;
end;

{ 图标类型 setter: 变化时重绘 }
procedure TFHNavButton.SetButtonType(Value: TFHNavButtonType);
begin
  if FButtonType <> Value then
  begin
    FButtonType := Value;
    Invalidate;
  end;
end;

{ 底色 setter: 变化时重绘 }
procedure TFHNavButton.SetBackColor(Value: TColor);
begin
  if FBackColor <> Value then
  begin
    FBackColor := Value;
    Invalidate;
  end;
end;

{ 启用态 setter: 手动重绘（CMEnabledChanged 不会触发自绘控件刷新, 见体内注释） }
procedure TFHNavButton.SetEnabled(Value: Boolean);
begin
  inherited SetEnabled(Value);
  { 必须自己重画! TWinControl.CMEnabledChanged 只做 EnableWindow, 不会 Invalidate
    （TControl 那版才会）, 而本控件的外观完全靠 Paint 自绘 —— 所以"后退/前进
    按钮由灰变黑"在 Enabled 变化那一刻不会刷新, 要等鼠标划过触发重画才变。 }
  Invalidate;
end;

{ 实际生效底色（clNone → 父容器底色） }
function TFHNavButton.ResolvedBackColor: TColor;
begin
  Result := ResolveBackColor(Parent, FBackColor, clWhite);
end;

{ 鼠标进入: 记录悬停态并重绘 }
procedure TFHNavButton.CMMouseEnter(var Message: TMessage);
begin
  FHovered := True;
  Invalidate;
end;

{ 鼠标离开: 清悬停/按下态并重绘 }
procedure TFHNavButton.CMMouseLeave(var Message: TMessage);
begin
  FHovered := False;
  FPressed := False;
  Invalidate;
end;

{ 鼠标按下: 记录按下态并重绘 }
procedure TFHNavButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
end;

{ 鼠标松开: 清按下态并重绘（Click 由 VCL 基类在按下-松开序列里触发） }
procedure TFHNavButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FPressed := False;
    Invalidate;
  end;
end;

{ 自绘: 铺底色（防悬停圆底残留）→ 悬停/按下/选中态圆形背景 → 图标 }
procedure TFHNavButton.Paint;
var
  R: TRect;
  C: TColor;
begin
  R := ClientRect;
  // 第一步铺底色: 没有这一步, 悬停圆形背景在鼠标移开后会永久残留在窗口上
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := ResolvedBackColor;
  Canvas.Pen.Color := Canvas.Brush.Color;
  Canvas.FillRect(R);
  // 悬停/按下: Chrome 风格圆形浅灰背景
  if FPressed and FHovered then
    C := TColor($DADCE0)   // 按下: 稍深
  else if FHovered then
    C := TColor($E8EAED)   // 悬停: 浅灰
  else if FChecked then
    C := TColor($FDE3D3)   // 选中: 浅蓝 #D3E3FD
  else
    C := clNone;           // 常态: 与底色一致
  if C <> clNone then
  begin
    { 悬停/按下圆底: GDI+ 抗锯齿; 不可用回退 GDI }
    if not FillCircleAA(Canvas, R, C) then
    begin
      Canvas.Brush.Color := C;
      Canvas.Pen.Color := C;
      Canvas.Ellipse(R);
    end;
  end;
  DrawIcon;
end;

function TFHNavButton.DrawIconGDIPlus(PenColor: TColor): Boolean;
var
  G: TGPGraphics;
  P: TGPPen;
  B: TGPSolidBrush;
  Path: TGPGraphicsPath;
  Tri: array[0..2] of TGPPoint;
  Star: array[0..9] of TGPPoint;
  CX, CY, H, Rd, S, U, D, V, I, Gr, O, E, SX, R1, R2: Integer;
  A: Double;

  procedure Ln(X1, Y1, X2, Y2: Integer);
  begin
    G.DrawLine(P, X1, Y1, X2, Y2);
  end;

begin
  Result := False;
  G := CreateSmoothGraphics(Canvas);
  if G = nil then Exit;
  CX := Width div 2;
  CY := Height div 2;
  H := ScaleCanvas(Canvas, 6);      // 箭头半尺寸（16px 网格基准）
  Rd := ScaleCanvas(Canvas, 6);     // 刷新圆半径: 旧值 7 会让刷新明显比
                                    // 首页/箭头大一圈（实测包围盒 17x18 vs 15x15）
  S := Max(2, ScaleCanvas(Canvas, 2));
  U := ScaleCanvas(Canvas, 1);
  P := TGPPen.Create(ColorToARGB(PenColor), Single(S));
  try
    case FButtonType of
      nbtBack:
      begin
        // ← 横杆 + 箭头尖（Chrome 同款带杆箭头）
        Ln(CX - H, CY, CX + H, CY);
        Ln(CX - H + U, CY, CX, CY - H);
        Ln(CX - H + U, CY, CX, CY + H);
      end;
      nbtForward:
      begin
        // → 镜像
        Ln(CX - H, CY, CX + H, CY);
        Ln(CX + H - U, CY, CX, CY - H);
        Ln(CX + H - U, CY, CX, CY + H);
      end;
      nbtGo:
      begin
        { 转到 = 放大镜（搜索）: Chrome 地址栏里"回车即搜索/跳转"就是这个符号,
          与前进的 → 明确区分开。镜圈半径 4、中心上移 1（给右下手柄让位）,
          手柄从镜圈 45° 处外伸 }
        Gr := ScaleCanvas(Canvas, 4);            // 镜圈半径
        O  := ScaleCanvas(Canvas, 1);            // 镜圈中心相对按钮中心的偏移
        E  := ScaleCanvas(Canvas, 4);            // 手柄长度
        G.DrawEllipse(P, CX - O - Gr, CY - O - Gr, 2 * Gr, 2 * Gr);
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        Ln(CX - O + Round(Gr * 0.707), CY - O + Round(Gr * 0.707),
           CX - O + Round(Gr * 0.707) + E, CY - O + Round(Gr * 0.707) + E);
      end;
      nbtReload:
      begin
        { 刷新 = 300° 圆弧（右上留 60° 缺口）+ 顶端三角箭头。
          GDI+ 角度约定: 0°=右, 正角顺时针（y 向下）。
          起始 330°(≈右上缺口下沿) 顺时针扫 300° 到 270°(≡12 点),
          中间经过 0°/90°/180° 即 右→下→左, 方向与 GDI 折线版一致。 }
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        Path := TGPGraphicsPath.Create;
        try
          Path.AddArc(CX - Rd, CY - Rd, 2 * Rd, 2 * Rd, Single(330), Single(300));
          G.DrawPath(P, Path);
        finally
          Path.Free;
        end;
        // 三角箭头贴在弧头（12 点位置）, 指向顺时针切线方向 = 向右
        B := TGPSolidBrush.Create(ColorToARGB(PenColor));
        try
          Tri[0].X := CX + ScaleCanvas(Canvas, 5);
          Tri[0].Y := CY - Rd;
          Tri[1].X := CX - ScaleCanvas(Canvas, 1);
          Tri[1].Y := CY - Rd - ScaleCanvas(Canvas, 2);
          Tri[2].X := Tri[1].X;
          Tri[2].Y := CY - Rd + ScaleCanvas(Canvas, 2);
          G.FillPolygon(B, PGPPoint(@Tri[0]), 3);
        finally
          B.Free;
        end;
      end;
      nbtStop:
      begin
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        SX := ScaleCanvas(Canvas, 5);
        Ln(CX - SX, CY - SX, CX + SX, CY + SX);
        Ln(CX + SX, CY - SX, CX - SX, CY + SX);
      end;
      nbtChevronUp:
      begin
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        SX := ScaleCanvas(Canvas, 4);
        D  := ScaleCanvas(Canvas, 2);
        Ln(CX - SX, CY + D, CX, CY - D);
        Ln(CX, CY - D, CX + SX, CY + D);
      end;
      nbtChevronDown:
      begin
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        SX := ScaleCanvas(Canvas, 4);
        D  := ScaleCanvas(Canvas, 2);
        Ln(CX - SX, CY - D, CX, CY + D);
        Ln(CX, CY + D, CX + SX, CY - D);
      end;
      nbtHome:
      begin
        // 主页: 屋顶 + 墙体（Chrome 同款镂空房子）
        P.SetLineJoin(LineJoinRound);
        Ln(CX - H - U, CY, CX, CY - H - U);
        Ln(CX, CY - H - U, CX + H + U, CY);
        Ln(CX - ScaleCanvas(Canvas, 4), CY - U,
          CX - ScaleCanvas(Canvas, 4), CY + H);
        Ln(CX - ScaleCanvas(Canvas, 4), CY + H,
          CX + ScaleCanvas(Canvas, 4), CY + H);
        Ln(CX + ScaleCanvas(Canvas, 4), CY + H,
          CX + ScaleCanvas(Canvas, 4), CY - U);
      end;
      nbtMenu:
      begin
        // ⋮ 三点菜单（Chrome 右上角"自定义及控制"同款）
        D := Max(1, ScaleCanvas(Canvas, 1));   // 点半径
        V := ScaleCanvas(Canvas, 4);           // 点间距
        B := TGPSolidBrush.Create(ColorToARGB(PenColor));
        try
          for I := 0 to 2 do
            G.FillEllipse(B, CX - D, CY - V + I * V - D, 2 * D, 2 * D);
        finally
          B.Free;
        end;
      end;
      nbtDownload:
      begin
        { 下载中: 上半部下箭头 + 底部浅口 U 形托盘（Chrome 工具栏下载同款:
          箭头尖悬在托盘口上方、互不接触, 托盘侧壁仅 2px 浅碟。
          旧版竖杆直插托盘底 + 侧壁深 7px, 视觉是"竖线插桶"不像下载图标） }
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        Ln(CX, CY - ScaleCanvas(Canvas, 5), CX, CY - ScaleCanvas(Canvas, 1));
        Ln(CX - ScaleCanvas(Canvas, 3), CY - ScaleCanvas(Canvas, 4),
          CX, CY - ScaleCanvas(Canvas, 1));
        Ln(CX + ScaleCanvas(Canvas, 3), CY - ScaleCanvas(Canvas, 4),
          CX, CY - ScaleCanvas(Canvas, 1));
        P.SetLineJoin(LineJoinRound);
        Ln(CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 2),
          CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4));
        Ln(CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4),
          CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4));
        Ln(CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4),
          CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 2));
      end;
      nbtDownloadDone:
      begin
        { 下载完成: 底部浅口托盘 + 上方对勾（蓝色取色见 DrawIcon;
          勾与托盘口留 2px 间隙, 与下载中态的箭头/托盘关系一致） }
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
        Ln(CX - ScaleCanvas(Canvas, 3), CY - ScaleCanvas(Canvas, 2),
          CX - ScaleCanvas(Canvas, 1), CY);
        Ln(CX - ScaleCanvas(Canvas, 1), CY,
          CX + ScaleCanvas(Canvas, 3), CY - ScaleCanvas(Canvas, 4));
        P.SetLineJoin(LineJoinRound);
        Ln(CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 2),
          CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4));
        Ln(CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4),
          CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4));
        Ln(CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4),
          CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 2));
      end;
      nbtStar, nbtStarred:
      begin
        { 书签星形: 10 顶点五角星路径（外半径 7 / 内半径 3, 外顶点从正上方起）。
          空心星 = 描边, 实心星 = 填充 }
        R1 := ScaleCanvas(Canvas, 7);
        R2 := ScaleCanvas(Canvas, 3);
        for I := 0 to 9 do
        begin
          A := -Pi / 2 + I * Pi / 5;
          if (I and 1) = 0 then
            D := R1
          else
            D := R2;
          Star[I].X := CX + Round(D * Cos(A));
          Star[I].Y := CY + Round(D * Sin(A));
        end;
        Path := TGPGraphicsPath.Create;
        try
          Path.AddPolygon(PGPPoint(@Star[0]), 10);
          if FButtonType = nbtStarred then
          begin
            B := TGPSolidBrush.Create(ColorToARGB(PenColor));
            try
              G.FillPath(B, Path);
            finally
              B.Free;
            end;
          end
          else
          begin
            P.SetLineJoin(LineJoinRound);
            G.DrawPath(P, Path);
          end;
        finally
          Path.Free;
        end;
      end;
    end;
    Result := True;
  finally
    P.Free;
    G.Free;
  end;
end;

function TFHNavButton.DrawIconGDI(PenColor: TColor): Boolean;
var
  CX, CY, H, Rd, I, N, D, V, Gr, O, E, R1, R2: Integer;
  A, A0, A1: Double;
  Pts: array[0..24] of TPoint;
begin
  CX := Width div 2;
  CY := Height div 2;
  H := ScaleCanvas(Canvas, 6);    // 箭头半尺寸（16px 网格基准）
  Rd := ScaleCanvas(Canvas, 6);   // 刷新圆半径（与 GDI+ 分支保持一致）
  Canvas.Pen.Color := PenColor;
  Canvas.Pen.Width := Max(1, ScaleCanvas(Canvas, 2));
  Canvas.Pen.Style := psSolid;
  Canvas.Brush.Style := bsClear;

  case FButtonType of
    nbtBack:
    begin
      // ← 横杆 + 箭头尖（Chrome 同款带杆箭头）
      Canvas.MoveTo(CX - H, CY);
      Canvas.LineTo(CX + H, CY);
      Canvas.MoveTo(CX - H + ScaleCanvas(Canvas, 1), CY);
      Canvas.LineTo(CX, CY - H);
      Canvas.MoveTo(CX - H + ScaleCanvas(Canvas, 1), CY);
      Canvas.LineTo(CX, CY + H);
    end;
    nbtForward:
    begin
      // → 镜像
      Canvas.MoveTo(CX - H, CY);
      Canvas.LineTo(CX + H, CY);
      Canvas.MoveTo(CX + H - ScaleCanvas(Canvas, 1), CY);
      Canvas.LineTo(CX, CY - H);
      Canvas.MoveTo(CX + H - ScaleCanvas(Canvas, 1), CY);
      Canvas.LineTo(CX, CY + H);
    end;
    nbtGo:
    begin
      { 转到 = 放大镜（搜索）, 与 GDI+ 分支同参数: 镜圈半径 Gr、中心偏移 O、手柄长 E }
      Gr := ScaleCanvas(Canvas, 4);
      O  := ScaleCanvas(Canvas, 1);
      E  := ScaleCanvas(Canvas, 4);
      Canvas.Ellipse(CX - O - Gr, CY - O - Gr, CX - O + Gr, CY - O + Gr);
      Canvas.MoveTo(CX - O + Round(Gr * 0.707), CY - O + Round(Gr * 0.707));
      Canvas.LineTo(CX - O + Round(Gr * 0.707) + E,
                    CY - O + Round(Gr * 0.707) + E);
    end;
    nbtReload:
    begin
      { 刷新 = 300° 圆弧（右上留 60° 缺口）+ 顶端三角箭头。
        不用 Canvas.Arc: GDI 弧的起止点方向语义在 y 向下的设备坐标系里极易画反
        （缺口跑到别处、箭头贴错位置）。改为按角度自己算点走折线, 方向完全可控。
        角度约定: 0°=右, 90°=上; 顺时针方向 = 角度递减。
        弧尾 30°（约 1 点钟）顺时针绕 300° 到弧头 -270°(≡90°, 12 点钟)。 }
      N := 24;
      A0 := 30;      // 弧尾
      A1 := -270;    // 弧头
      for I := 0 to N do
      begin
        A := (A0 + (A1 - A0) * I / N) * Pi / 180;
        Pts[I] := Point(CX + Round(Rd * Cos(A)), CY - Round(Rd * Sin(A)));
      end;
      Canvas.Polyline(Pts);
      // 三角箭头贴在弧头（12 点位置）, 指向顺时针切线方向 = 向右
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := PenColor;
      Canvas.Pen.Color := PenColor;
      Canvas.Polygon([Point(CX + ScaleCanvas(Canvas, 5), CY - Rd),
        Point(CX - ScaleCanvas(Canvas, 1), CY - Rd - ScaleCanvas(Canvas, 2)),
        Point(CX - ScaleCanvas(Canvas, 1), CY - Rd + ScaleCanvas(Canvas, 2))]);
      Canvas.Brush.Style := bsClear;
    end;
    nbtStop:
    begin
      Canvas.MoveTo(CX - ScaleCanvas(Canvas, 5), CY - ScaleCanvas(Canvas, 5));
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 5));
      Canvas.MoveTo(CX + ScaleCanvas(Canvas, 5), CY - ScaleCanvas(Canvas, 5));
      Canvas.LineTo(CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 5));
    end;
    nbtChevronUp:
    begin
      Canvas.MoveTo(CX - ScaleCanvas(Canvas, 4), CY + ScaleCanvas(Canvas, 2));
      Canvas.LineTo(CX, CY - ScaleCanvas(Canvas, 2));
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 4), CY + ScaleCanvas(Canvas, 2));
    end;
    nbtChevronDown:
    begin
      Canvas.MoveTo(CX - ScaleCanvas(Canvas, 4), CY - ScaleCanvas(Canvas, 2));
      Canvas.LineTo(CX, CY + ScaleCanvas(Canvas, 2));
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 4), CY - ScaleCanvas(Canvas, 2));
    end;
    nbtMatchCase:
    begin
      Canvas.Font.Name := 'Segoe UI';
      Canvas.Font.Height := -ScaleCanvas(Canvas, 12);
      Canvas.Font.Style := [];
      Canvas.Font.Color := PenColor;
      Canvas.Brush.Style := bsClear;
      Canvas.TextOut(CX - Canvas.TextWidth('Aa') div 2,
        CY - Canvas.TextHeight('Aa') div 2, 'Aa');
    end;
    nbtHome:
    begin
      // 主页: 屋顶 + 墙体（Chrome 同款镂空房子）
      Canvas.MoveTo(CX - H - ScaleCanvas(Canvas, 1), CY);
      Canvas.LineTo(CX, CY - H - ScaleCanvas(Canvas, 1));
      Canvas.LineTo(CX + H + ScaleCanvas(Canvas, 1), CY);
      Canvas.MoveTo(CX - ScaleCanvas(Canvas, 4), CY - ScaleCanvas(Canvas, 1));
      Canvas.LineTo(CX - ScaleCanvas(Canvas, 4), CY + H);
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 4), CY + H);
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 4), CY - ScaleCanvas(Canvas, 1));
    end;
    nbtMenu:
    begin
      // ⋮ 三点菜单（与 GDI+ 分支同参数: 半径 D, 间距 V）
      D := Max(1, ScaleCanvas(Canvas, 1));
      V := ScaleCanvas(Canvas, 4);
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := PenColor;
      Canvas.Pen.Color := PenColor;
      for I := 0 to 2 do
        Canvas.Ellipse(CX - D, CY - V + I * V - D, CX + D, CY - V + I * V + D);
      Canvas.Brush.Style := bsClear;
    end;
    nbtDownload:
    begin
      { 下载中: 上半部下箭头 + 底部浅口托盘（与 GDI+ 分支同几何） }
      Canvas.MoveTo(CX, CY - ScaleCanvas(Canvas, 5));
      Canvas.LineTo(CX, CY - ScaleCanvas(Canvas, 1));
      Canvas.MoveTo(CX - ScaleCanvas(Canvas, 3), CY - ScaleCanvas(Canvas, 4));
      Canvas.LineTo(CX, CY - ScaleCanvas(Canvas, 1));
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 3), CY - ScaleCanvas(Canvas, 4));
      Canvas.MoveTo(CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 2));
      Canvas.LineTo(CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4));
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4));
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 2));
    end;
    nbtDownloadDone:
    begin
      { 下载完成: 浅口托盘 + 对勾（与 GDI+ 分支同几何） }
      Canvas.MoveTo(CX - ScaleCanvas(Canvas, 3), CY - ScaleCanvas(Canvas, 2));
      Canvas.LineTo(CX - ScaleCanvas(Canvas, 1), CY);
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 3), CY - ScaleCanvas(Canvas, 4));
      Canvas.MoveTo(CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 2));
      Canvas.LineTo(CX - ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4));
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 4));
      Canvas.LineTo(CX + ScaleCanvas(Canvas, 5), CY + ScaleCanvas(Canvas, 2));
    end;
    nbtStar, nbtStarred:
    begin
      { 五角星（与 GDI+ 分支同几何; GDI 无抗锯齿, 仅作回退） }
      R1 := ScaleCanvas(Canvas, 7);
      R2 := ScaleCanvas(Canvas, 3);
      for I := 0 to 9 do
      begin
        A := -Pi / 2 + I * Pi / 5;
        if (I and 1) = 0 then
          D := R1
        else
          D := R2;
        Pts[I] := Point(CX + Round(D * Cos(A)), CY + Round(D * Sin(A)));
      end;
      if FButtonType = nbtStarred then
        Canvas.Brush.Style := bsSolid
      else
        Canvas.Brush.Style := bsClear;
      Canvas.Brush.Color := PenColor;
      Canvas.Pen.Color := PenColor;
      Canvas.Pen.Width := Max(1, ScaleCanvas(Canvas, 1));
      Canvas.Polygon(Slice(Pts, 10));
      Canvas.Brush.Style := bsClear;
    end;
  end;
  Result := True;
end;

{ 画图标入口: 按状态定色（禁用灰/选中蓝/常态灰）,
  优先 GDI+ 抗锯齿, 不可用回退 GDI 折线 }
procedure TFHNavButton.DrawIcon;
var
  PenColor: TColor;
begin
  PenColor := TColor($68635F);    // #5F6368 Chrome 图标灰（TColor 是 $00BBGGRR）
  if not Enabled then
    PenColor := TColor($C6C1BD)  // #BDC1C6 Chrome 禁用态灰（原来写反了 R/B 通道）
  else if ((FButtonType = nbtMatchCase) and FChecked) or
          (FButtonType = nbtDownloadDone) or (FButtonType = nbtStarred) then
    PenColor := TColor($D0570B); // #0B57D0 选中/下载完成/已收藏态蓝
  // 优先 GDI+（抗锯齿: 圆弧/斜线不再有阶梯锯齿）; 不可用时退化到 GDI 折线画法
  if not DrawIconGDIPlus(PenColor) then
    DrawIconGDI(PenColor);
end;

{ ============================ TFHStarGlyph ================================ }

{ 构造: 默认 28x28 逻辑尺寸, 手型光标, 空心星 }
constructor TFHStarGlyph.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := ScaleDpi(28);
  Height := ScaleDpi(28);
  FStarred := False;
  FHovered := False;
  FPressed := False;
  Cursor := crHandPoint;
end;

{ 收藏态 setter: 空心灰星 ↔ 实心蓝星, 变化时重绘 }
procedure TFHStarGlyph.SetStarred(Value: Boolean);
begin
  if FStarred <> Value then
  begin
    FStarred := Value;
    Invalidate;
  end;
end;

{ 鼠标进入: 记录悬停态并重绘 }
procedure TFHStarGlyph.CMMouseEnter(var Message: TMessage);
begin
  FHovered := True;
  Invalidate;
end;

{ 鼠标离开: 清悬停/按下态并重绘 }
procedure TFHStarGlyph.CMMouseLeave(var Message: TMessage);
begin
  FHovered := False;
  FPressed := False;
  Invalidate;
end;

{ 鼠标按下: 记录按下态并重绘 }
procedure TFHStarGlyph.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
end;

{ 鼠标松开: 清按下态并重绘 }
procedure TFHStarGlyph.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FPressed := False;
    Invalidate;
  end;
end;

{ 自绘（透明底, 不遮挡胶囊描边, 见类声明注释）: 悬停/按下画同心浅灰圆
  + 五角星（空心描边/实心填充）; GDI+ 不可用回退 GDI }
procedure TFHStarGlyph.Paint;
var
  CX, CY, Rad, R1, R2, I, D: Integer;
  A: Double;
  PenColor, CircleColor: TColor;
  G: TGPGraphics;
  P: TGPPen;
  B: TGPSolidBrush;
  Path: TGPGraphicsPath;
  Star: array[0..9] of TGPPoint;
  Pts: array[0..9] of TPoint;
begin
  { 常态不铺任何底色（透明）: 父画的胶囊白底/描边完整透出 —— 这与窗口化
    TFHNavButton 铺不透明底的本质区别。悬停/按下才画同心浅灰圆: 它比胶囊
    右半圆小得多且近似同心, 永不触碰描边弧线。 }
  if FPressed and FHovered then
    CircleColor := TColor($DADCE0)   // 按下: 稍深
  else if FHovered then
    CircleColor := TColor($E8EAED)   // 悬停: 浅灰
  else
    CircleColor := clNone;           // 常态: 透明
  PenColor := TColor($68635F);       // #5F6368 空心星灰
  if not Enabled then
    PenColor := TColor($C6C1BD)      // #BDC1C6 禁用灰
  else if FStarred then
    PenColor := TColor($D0570B);     // #0B57D0 已收藏蓝
  CX := Width div 2;
  CY := Height div 2;
  Rad := ScaleCanvas(Canvas, 12);   // 悬停圆半径（28px 按钮内 24px 圆）

  G := CreateSmoothGraphics(Canvas);
  if G <> nil then
  begin
    try
      if CircleColor <> clNone then
      begin
        B := TGPSolidBrush.Create(ColorToARGB(CircleColor));
        try
          G.FillEllipse(B, CX - Rad, CY - Rad, 2 * Rad, 2 * Rad);
        finally
          B.Free;
        end;
      end;
      { 五角星: 10 顶点（外半径 7 / 内半径 3, 与 TFHNavButton 同几何）,
        空心 = 描边, 实心 = 填充 }
      R1 := ScaleCanvas(Canvas, 7);
      R2 := ScaleCanvas(Canvas, 3);
      for I := 0 to 9 do
      begin
        A := -Pi / 2 + I * Pi / 5;
        if (I and 1) = 0 then
          D := R1
        else
          D := R2;
        Star[I].X := CX + Round(D * Cos(A));
        Star[I].Y := CY + Round(D * Sin(A));
      end;
      Path := TGPGraphicsPath.Create;
      try
        Path.AddPolygon(PGPPoint(@Star[0]), 10);
        if FStarred then
        begin
          B := TGPSolidBrush.Create(ColorToARGB(PenColor));
          try
            G.FillPath(B, Path);
          finally
            B.Free;
          end;
        end
        else
        begin
          P := TGPPen.Create(ColorToARGB(PenColor), Single(Max(2, ScaleCanvas(Canvas, 2))));
          try
            P.SetLineJoin(LineJoinRound);
            G.DrawPath(P, Path);
          finally
            P.Free;
          end;
        end;
      finally
        Path.Free;
      end;
    finally
      G.Free;
    end;
  end
  else
  begin
    { GDI 回退（无抗锯齿, 仅保可用）: 同 TFHNavButton.DrawIconGDI 星形分支 }
    if CircleColor <> clNone then
    begin
      Canvas.Brush.Color := CircleColor;
      Canvas.Pen.Color := CircleColor;
      Canvas.Ellipse(CX - Rad, CY - Rad, CX + Rad, CY + Rad);
    end;
    R1 := ScaleCanvas(Canvas, 7);
    R2 := ScaleCanvas(Canvas, 3);
    for I := 0 to 9 do
    begin
      A := -Pi / 2 + I * Pi / 5;
      if (I and 1) = 0 then
        D := R1
      else
        D := R2;
      Pts[I] := Point(CX + Round(D * Cos(A)), CY + Round(D * Sin(A)));
    end;
    if FStarred then
      Canvas.Brush.Style := bsSolid
    else
      Canvas.Brush.Style := bsClear;
    Canvas.Brush.Color := PenColor;
    Canvas.Pen.Color := PenColor;
    Canvas.Pen.Width := Max(1, ScaleCanvas(Canvas, 1));
    Canvas.Polygon(Slice(Pts, 10));
    Canvas.Brush.Style := bsClear;
  end;
end;

{ ============================ TFHAddressBar =============================== }

{ 构造: 内嵌无边框 TEdit（文本输入）+ 胶囊右端星标（书签入口）,
  字号由 PinEditFont 钉死（细节见体内注释） }
constructor TFHAddressBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FBackColor := clNone;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  // 内嵌 TEdit 做实际文本输入
  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.BorderStyle := bsNone;
  FEdit.Color := clWhite;   // GM3: 地址栏两态都白底
  // 不能用 alClient: 输入框白色底铺满客户区会把外圈描边整圈盖掉（边框"看不见"的根因）
  FEdit.Align := alNone;
  // 不用 Margins: 压缩高度后 EDIT 装不下字体行高 → 文本垂直被裁成一半
  // （单行 EDIT 会自动垂直居中, 给足高度即可）; 左右留白用 EM_SETMARGIN
  FEdit.Font.Name := 'Segoe UI';
  { 9pt 仅为初始值: VCL 会在 SetParent 时把它按 DPI 放大（甚至两次）,
    真正的字号由 PinEditFont 按 Chrome 的 14px@1x 钉死 }
  FEdit.Font.Size := 9;
  FEdit.Font.Color := TColor($242120);
  FEdit.TextHint := '搜索或输入网址';
  FEdit.OnEnter := EditEnter;
  FEdit.OnExit := EditExit;
  FEdit.OnKeyPress := EditKeyPress;
  FEdit.OnChange := EditChange;
  { 星标按钮（胶囊内右端, 书签收藏入口, Chrome omnibox 同位）——无句柄
    图形控件: 窗口化按钮的不透明矩形底会盖掉胶囊右半圆的聚焦蓝描边 }
  FBtnStar := TFHStarGlyph.Create(Self);
  FBtnStar.Parent := Self;
  FBtnStar.Hint := '添加书签';
  FBtnStar.ShowHint := True;
  FBtnStar.OnClick := StarBtnClick;
  FStarred := False;
  FFocused := False;
end;

{ 收藏态 setter: 联动星标图标与悬停提示（添加书签/修改书签） }
procedure TFHAddressBar.SetStarred(Value: Boolean);
begin
  if FStarred <> Value then
  begin
    FStarred := Value;
    if FBtnStar <> nil then
    begin
      FBtnStar.Starred := Value;
      if Value then
        FBtnStar.Hint := '修改书签'
      else
        FBtnStar.Hint := '添加书签';
    end;
  end;
end;

{ 星标点击: 转发宿主挂的 OnStarClick }
procedure TFHAddressBar.StarBtnClick(Sender: TObject);
begin
  if Assigned(FOnStarClick) then
    FOnStarClick(Self);
end;

{ 星标按钮定位: 贴胶囊右端 3px, 垂直居中, 边长不超过控件高-4 }
procedure TFHAddressBar.LayoutStarButton;
var
  Btn, T: Integer;
begin
  if (FBtnStar = nil) or (Height <= 0) or (Width <= 0) then Exit;
  Btn := ScaleDpi(28);
  if Btn > Height - 4 then
    Btn := Height - 4;
  T := (Height - Btn) div 2;
  FBtnStar.SetBounds(Width - Btn - ScaleDpi(3), T, Btn, Btn);
end;

{ 底色 setter: 变化时重绘 }
procedure TFHAddressBar.SetBackColor(Value: TColor);
begin
  if FBackColor <> Value then
  begin
    FBackColor := Value;
    Invalidate;
  end;
end;

{ 启用态 setter: 联动内嵌 Edit（否则仍可输入）并重绘 }
procedure TFHAddressBar.SetEnabled(Value: Boolean);
begin
  inherited;
  // 原实现 Enabled 只是个摆设: 内嵌 TEdit 仍然可输入
  if FEdit <> nil then
    FEdit.Enabled := Value;
  Invalidate;
end;

procedure TFHAddressBar.SelectAll;
begin
  if FEdit <> nil then
  begin
    if FEdit.CanFocus then
      FEdit.SetFocus;
    FEdit.SelectAll;
  end;
end;

function TFHAddressBar.StarScreenRect: TRect;
var
  P1, P2: TPoint;
begin
  Result := Rect(0, 0, 0, 0);
  if (FBtnStar = nil) or not FBtnStar.Visible then Exit;
  P1 := FBtnStar.ClientToScreen(Point(0, 0));
  P2 := FBtnStar.ClientToScreen(Point(FBtnStar.Width, FBtnStar.Height));
  Result := Rect(P1.X, P1.Y, P2.X, P2.Y);
end;

{ 内嵌 Edit 获得焦点: 记录态并重绘（胶囊描边转蓝加粗） }
procedure TFHAddressBar.EditEnter(Sender: TObject);
begin
  FFocused := True;
  FEdit.Color := clWhite;   // 聚焦: 内嵌输入框也转白, 与圆角白底一致
  Invalidate;
end;

{ 内嵌 Edit 失去焦点: 记录态并重绘（描边回灰细线） }
procedure TFHAddressBar.EditExit(Sender: TObject);
begin
  FFocused := False;
  FEdit.Color := clWhite;   // GM3: 非聚焦也是白底（区别只在描边颜色）
  Invalidate;
end;

{ 内嵌 Edit 按键: 转发宿主挂的 OnKeyPress（回车导航在宿主处理） }
procedure TFHAddressBar.EditKeyPress(Sender: TObject; var Key: Char);
begin
  if Assigned(FOnKeyPress) then
    FOnKeyPress(Self, Key);
end;

{ 内嵌 Edit 文本变化: 转发宿主挂的 OnChange }
procedure TFHAddressBar.EditChange(Sender: TObject);
begin
  if Assigned(FOnChange) then
    FOnChange(Self);   // 原实现没有 OnChange, 宿主无法感知输入变化
end;

{ 控件本身获得键盘焦点: 记录态并重绘 }
procedure TFHAddressBar.CMEnter(var Message: TCMEnter);
begin
  FFocused := True;
  Invalidate;
end;

{ 控件本身失去键盘焦点: 记录态并重绘 }
procedure TFHAddressBar.CMExit(var Message: TCMExit);
begin
  FFocused := False;
  Invalidate;
end;

{ 文本 getter: 透传内嵌 Edit }
function TFHAddressBar.GetText: string;
begin
  Result := FEdit.Text;
end;

{ 文本 setter: 透传内嵌 Edit }
procedure TFHAddressBar.SetText(const Value: string);
begin
  FEdit.Text := Value;
end;

{ 尺寸变化: 重摆星标与输入框并重绘 }
procedure TFHAddressBar.Resize;
begin
  inherited;
  LayoutStarButton;
  UpdateEditBounds;
  Invalidate;
end;

{ 句柄创建后: 重摆星标与输入框, 并设文本内缩（EM_SETMARGIN 需句柄） }
procedure TFHAddressBar.CreateWnd;
begin
  inherited CreateWnd;
  LayoutStarButton;
  UpdateEditBounds;
  UpdateEditMargins;   // 句柄建立后才能发 EM_SETMARGIN
end;

procedure TFHAddressBar.PinEditFont;
const
  { Chrome 159 地址栏字号 = 14px@1x（触控模式 15）:
    location_bar_view.cc 用 typography_provider.GetFont(CONTEXT_OMNIBOX_PRIMARY,
    STYLE_PRIMARY); 该上下文在 chrome_typography.cc 的 ApplyCommonFontStyles 里
    被专门处理: 目标字号 14, 并受 GetAvailableTextHeight() 上限约束
    (= kLocationBarHeight 34 - 2*kLocationBarElementPadding 2 = 30, 装得下),
    字重保持默认 NORMAL —— 也就是说 Chrome 并**没有**加粗地址栏文字。

    VCL 的 SetParent 自动缩放还会把构造时设的字号放大两次:
    EDIT 自己 SetParent 一次（父未就绪时按 Screen DPI 缩放）+ 作为子控件
    随本控件被缩放再一次, 实测 9pt 会被放大到 lfHeight -27。
    所以这里以设备 DC 的真实 DPI 反算回设计像素值, 幂等, 随时调用都正确。 }
  C_FH_EditFontPx = 14;
var
  PPI: Integer;
  DC: HDC;
begin
  if FEdit = nil then Exit;
  PPI := 0;
  if FEdit.HandleAllocated then
  begin
    DC := GetDC(FEdit.Handle);
    PPI := GetDeviceCaps(DC, LOGPIXELSX);
    ReleaseDC(FEdit.Handle, DC);
  end;
  if PPI <= 0 then
    PPI := ScaleDpi(96);                     // 无句柄时按屏幕 DPI 兜底
  FEdit.Font.PixelsPerInch := PPI;
  FEdit.Font.Height := -MulDiv(C_FH_EditFontPx, PPI, 96);
end;

procedure TFHAddressBar.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  PinEditFont;                                   // 级联缩放后立即纠正字号
  LayoutStarButton;                              // 星标按新 DPI 重摆（覆盖 VCL 级联缩放值）
  UpdateEditBounds;                              // 几何同步重算
end;

{ 重排内嵌 Edit: 横向落在胶囊直段内（不盖半圆描边）,
  纵向按真实字体行盒双重居中（细节见体内注释） }
procedure TFHAddressBar.UpdateEditBounds;
var
  Cap, Inset, EH, EW, NewTop, LineH: Integer;
  TM: TTextMetric;
begin
  { 横向: 输入框必须整体落在胶囊的"直段"内（水平内缩 = 半圆帽深度 + 2）,
    否则它的白色背景会盖掉左右两个半圆的描边（四角断开的根因）。

    纵向: 用 EDIT 自己窗口 DC 上的真实字体度量算行盒, 让"控件整体 + 行盒"
    双重居中。此前文字偏下是两个错误叠加:
      1) 字号被双倍放大成 27px, 行盒(37) 比控件(29) 还高 → 单行 EDIT 放不下
         行盒, 退化为贴底放置, 文字自然沉底;
      2) 度量取自本控件 Canvas（字体尚未生效, 量到的是别的字体）, 数值虚高
         导致 Top 算错。
    字号钉死后行盒(25) < 控件高, 单行 EDIT 自会垂直居中。 }
  if (FEdit = nil) or (Width <= 0) or (Height <= 0) then Exit;

  Cap := Height div 2 + 2;                       // 半圆帽深度 ≈ 半高
  if Cap > (Width - 120) div 2 then              // 极窄时兜底, 保证输入框可用
    Cap := Max(6, (Width - 120) div 2);

  PinEditFont;                                   // 字号钉死为设计值（幂等）

  { 取行盒高度: 必须在本进程内用自己的 Canvas 量。
    （试过 SendMessage(WM_GETFONT) 后把 HFONT 选进 EDIT 的 DC 去量, 实测取不到
      值 —— 结果退化为兜底值, 行盒放不下又变贴底; 用本控件 Canvas 则与
      PinEditFont 后的字号一致, 150% 下 21px 字 → tmHeight=29） }
  LineH := 0;
  if HandleAllocated then
  begin
    Canvas.Font := FEdit.Font;
    Canvas.TextHeight('Wg');                     // 触发 Canvas 真正选中该字体
    FillChar(TM, SizeOf(TM), 0);
    if GetTextMetrics(Canvas.Handle, TM) then
      LineH := TM.tmHeight;
  end;
  if LineH < 1 then
    LineH := ScaleDpi(14);                       // 度量失败兜底（≈12px 字的行盒）

  EH := LineH + 2;                               // 行盒 + 余量, 放得下 EDIT 才会居中
  Inset := Max(3, ScaleDpi(3));
  if EH > Height - 2 * Inset then
    EH := Height - 2 * Inset;
  NewTop := (Height - EH) div 2;                 // 控件整体居中 → 行盒随之居中
  { 右侧让位星标按钮: EDIT 宽度从胶囊直段再缩进一个星标宽 + 4px,
    长文字不被星标覆盖 }
  EW := Width - 2 * Cap;
  if (FBtnStar <> nil) and (FBtnStar.Width > 0) then
    Dec(EW, FBtnStar.Width + ScaleDpi(4));
  FEdit.SetBounds(Cap, NewTop, EW, EH);
end;

{ 设内嵌 Edit 的文本左右内缩（EM_SETMARGIN, 不挤占高度） }
procedure TFHAddressBar.UpdateEditMargins;
var
  M: Integer;
begin
  // 文本左右内缩（EM_SETMARGIN, 不挤占 EDIT 高度）; 常量本地定义避免单元版本差异
  if (FEdit <> nil) and FEdit.HandleAllocated then
  begin
    M := ScaleDpi(4);    // 输入框左缘已在半圆帽之外, 文字只需少量内缩
    FEdit.Perform($00D3 {EM_SETMARGIN}, 1 or 2 {EC_LEFTMARGIN or EC_RIGHTMARGIN},
      MakeLParam(M, M));
  end;
end;

function TFHAddressBar.DrawPillGDIPlus(R: TRect; BorderColor: TColor;
  PenW: Integer): Boolean;
var
  G: TGPGraphics;
  P: TGPPen;
  B: TGPSolidBrush;
  Path: TGPGraphicsPath;
  Lf, Tp, Rt, Bt, Rad: Single;
begin
  Result := False;
  G := CreateSmoothGraphics(Canvas);
  if G = nil then Exit;
  { 坐标语义: TRect 的 Right/Bottom 是开区间（不含最后一列/行）, 而 GDI+ 的
    整数坐标落在像素中心 —— 宽度为 w 的笔触覆盖 [y + 0.5 - w/2, y + 0.5 + w/2]。
    两者混用就是"下边框比上边框细"的根因: 直接拿 R.Bottom(=Height) 当纵坐标画
    底线, 这条线整体落到最后一行之外而被裁掉（实测笔宽 1 时下边框墨量=0）。
    下面把四条边换算成"墨迹恰好占满第 0 行..第 Height-1 行"的坐标:
      顶/左:  PenW/2 - 0.5        底/右:  (Width|Height) - 0.5 - PenW/2
    奇数笔宽得整数（1px 清晰）, 偶数笔宽得 .5（由抗锯齿分摊, 仍是整像素）。 }
  Lf := R.Left + PenW / 2 - 0.5;
  Tp := R.Top + PenW / 2 - 0.5;
  Rt := R.Right - 0.5 - PenW / 2;
  Bt := R.Bottom - 0.5 - PenW / 2;
  Rad := (Bt - Tp) / 2;
  if Rad < 1 then
    Rad := 1;
  Path := TGPGraphicsPath.Create;
  try
    { 胶囊 = 顶直线 + 右半圆 + 底直线 + 左半圆。
      GDI+ 角度: 0°=右, 正角顺时针（y 向下）。四个连接点彼此重合且相切,
      闭合后是一条连续路径 —— 描边不会像分笔 GDI 那样错位, 且自带抗锯齿。 }
    Path.AddLine(Lf + Rad, Tp, Rt - Rad, Tp);
    Path.AddArc(Rt - 2 * Rad, Tp, 2 * Rad, Bt - Tp, Single(270), Single(180));
    Path.AddLine(Rt - Rad, Bt, Lf + Rad, Bt);
    Path.AddArc(Lf, Tp, 2 * Rad, Bt - Tp, Single(90), Single(180));
    Path.CloseFigure;
    B := TGPSolidBrush.Create(ColorToARGB(clWhite));
    P := TGPPen.Create(ColorToARGB(BorderColor), PenW);
    try
      G.FillPath(B, Path);
      G.DrawPath(P, Path);
    finally
      P.Free;
      B.Free;
    end;
    Result := True;
  finally
    Path.Free;
    G.Free;
  end;
end;

function TFHAddressBar.DrawPillGDI(R: TRect; BorderColor: TColor;
  PenW: Integer): Boolean;
var
  CapL, CapR: TRect;
  Rad: Integer;
begin
  // 描边整体收进客户区 PenW/2, 否则聚焦 2px 边框有一半被窗口裁掉
  InflateRect(R, -PenW div 2, -PenW div 2);
  Rad := Max(1, (R.Bottom - R.Top) div 2);
  CapL := Rect(R.Left, R.Top, R.Left + 2 * Rad, R.Bottom);
  CapR := Rect(R.Right - 2 * Rad, R.Top, R.Right, R.Bottom);
  // 先填充（笔色与填充色一致, 避免多描一圈）
  Canvas.Pen.Width := 1;
  Canvas.Pen.Color := clWhite;
  Canvas.Brush.Color := clWhite;
  Canvas.FillRect(Rect(R.Left + Rad, R.Top, R.Right - Rad, R.Bottom));
  Canvas.Ellipse(CapL);
  Canvas.Ellipse(CapR);
  // 再描边
  Canvas.Brush.Style := bsClear;
  Canvas.Pen.Color := BorderColor;
  Canvas.Pen.Width := PenW;
  Canvas.Ellipse(CapL);
  Canvas.Ellipse(CapR);
  Canvas.MoveTo(R.Left + Rad, R.Top);
  Canvas.LineTo(R.Right - Rad, R.Top);
  Canvas.MoveTo(R.Left + Rad, R.Bottom - 1);
  Canvas.LineTo(R.Right - Rad, R.Bottom - 1);
  Result := True;
end;

{ 自绘胶囊: 圆角外四角铺底色 → 白底胶囊描边
  （聚焦蓝粗线 / 常态灰细线）; GDI+ 不可用回退 GDI 分笔画法 }
procedure TFHAddressBar.Paint;
var
  R: TRect;
  BorderColor: TColor;
  PenW: Integer;
begin
  R := ClientRect;
  // 圆角外侧四角用底色填满（csOpaque 下不填就残留旧像素）
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := ResolveBackColor(Parent, FBackColor, clWhite);
  Canvas.Pen.Color := Canvas.Brush.Color;
  Canvas.FillRect(R);
  // Chrome GM3 取色（真机截图）: 两种状态都是白底胶囊;
  // 非聚焦 = 灰描边 #CACED4; 聚焦 = Google Blue #0B57D0 描边
  if FFocused then
  begin
    BorderColor := TColor($D0570B);   // #0B57D0
    PenW := Max(2, ScaleCanvas(Canvas, 2));
  end
  else
  begin
    BorderColor := TColor($D4CECA);   // #CACED4
    PenW := 1;
  end;
  // 优先 GDI+（抗锯齿, 半圆不再有锯齿）; 不可用时退化到 GDI 分笔画法
  if not DrawPillGDIPlus(R, BorderColor, PenW) then
    DrawPillGDI(R, BorderColor, PenW);
end;

{ ============================ TFHCaptionButton ============================ }

{ 构造: 默认 46x34 逻辑尺寸, 关闭按钮风格, 常规光标 }
constructor TFHCaptionButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  Width := ScaleDpi(46);
  Height := ScaleDpi(34);
  FButtonType := cbtClose;
  FBackColor := clNone;
  FHovered := False;
  FPressed := False;
  Cursor := crDefault;
end;

{ 按钮类型 setter（最小化/最大化/关闭）: 变化时重绘 }
procedure TFHCaptionButton.SetButtonType(Value: TFHCaptionButtonType);
begin
  if FButtonType <> Value then
  begin
    FButtonType := Value;
    Invalidate;
  end;
end;

{ 底色 setter: 变化时重绘 }
procedure TFHCaptionButton.SetBackColor(Value: TColor);
begin
  if FBackColor <> Value then
  begin
    FBackColor := Value;
    Invalidate;
  end;
end;

{ 实际生效底色（clNone → 父容器底色） }
function TFHCaptionButton.ResolvedBackColor: TColor;
begin
  Result := ResolveBackColor(Parent, FBackColor, clBtnFace);
end;

function TFHCaptionButton.ParentFormMaximized: Boolean;
var
  Form: TCustomForm;
begin
  { 图标必须跟着窗口真实状态走 —— 拖到屏幕边缘触发的最大化、双击标题栏还原、
    以及程序启动就是最大化等情况都能覆盖 }
  Form := GetParentForm(Self);
  Result := (Form <> nil) and (Form.WindowState = wsMaximized);
end;

procedure TFHCaptionButton.UpdateGlyph;
begin
  { 窗口状态变了: 最大化按钮的图标要在 □ / ▣ 之间切换 }
  Invalidate;
end;

{ 鼠标进入: 记录悬停态并重绘 }
procedure TFHCaptionButton.CMMouseEnter(var Message: TMessage);
begin
  FHovered := True;
  Invalidate;
end;

{ 鼠标离开: 清悬停/按下态并重绘 }
procedure TFHCaptionButton.CMMouseLeave(var Message: TMessage);
begin
  FHovered := False;
  FPressed := False;
  Invalidate;
end;

{ 鼠标按下: 记录按下态并重绘 }
procedure TFHCaptionButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
end;

{ 鼠标松开: 清按下态并重绘 }
procedure TFHCaptionButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FPressed := False;
    Invalidate;
  end;
end;

{ 自绘: 铺底色 → 悬停/按下整块底色（关闭 = 红底白图标, 其余淡钢蓝）
  → 图标（─ / □·▣ 随窗口状态 / ✕ GDI+ 抗锯齿） }
procedure TFHCaptionButton.Paint;
var
  R: TRect;
  BgColor, FgColor, EraseColor: TColor;
  CX, CY, K, D, M: Integer;
  MaxState: Boolean;
  G: TGPGraphics;
  GPen: TGPPen;
begin
  R := ClientRect;
  CX := Width div 2;
  CY := Height div 2;
  K := ScaleCanvas(Canvas, 5);   // 图标半尺寸（Chrome 的标题栏按钮符号约 11px）

  // 第一步铺底色（关键: 否则悬停灰/红底在鼠标移开后再也不会被擦掉）
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := ResolvedBackColor;
  Canvas.Pen.Color := Canvas.Brush.Color;
  Canvas.FillRect(R);

  // 最大化按钮按窗口状态切换图标: 普通=□ 最大化=▣（两个交叠方框）
  MaxState := (FButtonType = cbtMax) and ParentFormMaximized;

  // Chrome 风格: 常态贴合条底色; 悬停显色; 关闭 = 红底白图标（#E81123 / 按下 #C42B1C）
  if FPressed and FHovered then
  begin
    if FButtonType = cbtClose then BgColor := TColor($1C2BC4)   // #C42B1C
    else BgColor := TColor($CEB6A4);   // #A4B6CE 按下（比悬停深一档）
  end
  else if FHovered then
  begin
    if FButtonType = cbtClose then BgColor := TColor($2311E8)    // #E81123
    else BgColor := TColor($DEC4B0);   // #B0C4DE 最小化/最大化悬停淡钢蓝
  end
  else
    BgColor := clNone;

  if BgColor <> clNone then
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := BgColor;
    Canvas.Pen.Color := BgColor;
    Canvas.FillRect(R);
  end;

  // 图标颜色
  if FHovered and (FButtonType = cbtClose) then
    FgColor := clWhite
  else
    FgColor := TColor($5F6368);

  Canvas.Pen.Color := FgColor;
  Canvas.Pen.Width := Max(1, ScaleCanvas(Canvas, 1));
  Canvas.Pen.Style := psSolid;
  Canvas.Brush.Style := bsClear;

  case FButtonType of
    cbtMin:
    begin
      // 最小化: 水平线 ─
      Canvas.MoveTo(CX - K, CY);
      Canvas.LineTo(CX + K + 1, CY);
    end;
    cbtMax:
    begin
      if MaxState then
      begin
        { 还原 ▣: 两个交叠方框, 前面那个(右上)要用底色擦一遍再描边,
          才不会和后面那个(左下)糊成一坨 }
        D := Max(1, ScaleCanvas(Canvas, 2));            // 两框错位量
        M := (2 * K + 1) - D;                           // 单框边长
        EraseColor := ResolvedBackColor;
        if BgColor <> clNone then EraseColor := BgColor;

        // 后框(左下)
        Canvas.Rectangle(CX - K, CY + K + 1 - M, CX - K + M, CY + K + 1);
        // 前框(右上): 先填底色遮住重叠部分, 再描边
        Canvas.Brush.Style := bsSolid;
        Canvas.Brush.Color := EraseColor;
        Canvas.Rectangle(CX + K + 1 - M, CY - K, CX + K + 1, CY - K + M);
        Canvas.Brush.Style := bsClear;
        Canvas.Brush.Color := EraseColor;
        Canvas.Rectangle(CX + K + 1 - M, CY - K, CX + K + 1, CY - K + M);
      end
      else
        // 最大化: 方框 □
        Canvas.Rectangle(CX - K, CY - K, CX + K + 1, CY + K + 1);
    end;
    cbtClose:
    begin
      // 关闭: 叉 ✕; 45° 斜线纯 GDI 有阶梯锯齿 → GDI+ 抗锯齿（失败回退 GDI）
      G := CreateSmoothGraphics(Canvas);
      if G <> nil then
      try
        GPen := TGPPen.Create(ColorToARGB(FgColor),
          Max(1.0, ScaleCanvas(Canvas, 1)));
        try
          G.DrawLine(GPen, CX - K, CY - K, CX + K, CY + K);
          G.DrawLine(GPen, CX + K, CY - K, CX - K, CY + K);
        finally
          GPen.Free;
        end;
      finally
        G.Free;
      end
      else
      begin
        Canvas.MoveTo(CX - K, CY - K);
        Canvas.LineTo(CX + K, CY + K);
        Canvas.MoveTo(CX + K, CY - K);
        Canvas.LineTo(CX - K, CY + K);
      end;
    end;
  end;
end;

end.
