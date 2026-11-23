{==============================================================================
  单元: uFHChromeWidgets
  职责: Chrome 风格自绘控件 + GDI+ 抗锯齿绘制辅助（对话框公用）。
        由 uFHSettingsDlg 抽出, 供 设置 / 清除浏览数据 等对话框共用,
        避免每个对话框各写一套绘制代码导致观感与锯齿修复不统一。

  控件:
    TFHToggleSwitch  开关（胶囊轨道 + 白色圆钮）
    TFHRadioDot      单选（圆点 + 文字, 整行可点）
    TFHCheckBox      复选（18px 方形勾选框 + 文字, 整行可点）
    TFHFlatEdit      圆角输入框（内嵌无边框 TEdit）
    TFHSegmented      分段选择（替代下拉框, 选中段蓝底白字）
    TFHFlatButton    圆角按钮（主按钮蓝底胶囊 / 文字按钮）

  绘制约定（与 uFHBrowserControls 同源）:
    - 圆角/圆形一律走 GDI+ SmoothingModeAntiAlias（GDI RoundRect 有阶梯锯齿）,
      GDI+ 不可用时各 Paint 退回 GDI 画法
    - 坐标按 Canvas 设备 DC 的真实 DPI 换算; 宿主窗口应设 Scaled := False,
      由调用方按屏幕 DPI 手动排布, 避免 VCL 自动缩放双重放大
==============================================================================}
unit uFHChromeWidgets;

interface

uses
  System.Classes, System.SysUtils, System.Math, System.Types,
  Winapi.Windows, Winapi.Messages,
  Winapi.GDIPOBJ, Winapi.GDIPAPI,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.StdCtrls;

const
  { ---- Chrome 取色（TColor = $00BBGGRR） ---- }
  FH_BG        = clWhite;
  FH_TEXT      = TColor($242120);   // #202124
  FH_TEXT2     = TColor($68635F);   // #5F6368
  FH_TEXT_DIS  = TColor($A6A09A);   // #9AA0A6
  FH_DIVIDER   = TColor($EDEAE8);   // #E8EAED
  FH_BORDER    = TColor($D4CECA);   // #CACED4
  FH_BORDER_DIS = TColor($EDEAE8);  // #E8EAED
  FH_FOCUS     = TColor($D0570B);   // #0B57D0 Google Blue
  FH_FOCUS_DARK = TColor($A04208);  // #0842A0
  FH_HOVER_BG  = TColor($FEF0E8);   // #E8F0FE
  FH_TRACK_OFF = TColor($E0DCDA);   // #DADCE0
  FH_THUMB_EDGE = TColor($C5C7C4);  // #C4C7C5
  FH_RADIO_EDGE = TColor($68635F);  // #5F6368
  FH_BTN_DIS   = TColor($EDEAE8);   // #E8EAED 禁用主按钮底
  FH_HOVER_GRAY = TColor($F4F3F1);  // #F1F3F4 分段/行悬停浅灰

{ ---- GDI+ 绘制辅助（导出给需要自绘的宿主使用） ---- }
function ColorToARGB(Color: TColor): ARGB;
  { 按 Canvas 设备 DC 的真实 DPI 换算像素 }
  function CtlScalePx(ACanvas: TCanvas; P: Integer): Integer;
  { 按像素钉字号（避免 VCL 按磅值放大两次） }
  procedure SetCanvasFontPx(ACanvas: TCanvas; APx: Integer; ABold: Boolean;
    AColor: TColor);
  { 抗锯齿圆角矩形（可填充/描边）; False = GDI+ 不可用, 调用方退回 GDI }
  function FillRoundRectAA(ACanvas: TCanvas; Lf, Tp, Rt, Bt, Rad: Single;
    FillColor, BorderColor: TColor; BorderW: Single): Boolean;
  { 抗锯齿椭圆 }
  function FillEllipseAA(ACanvas: TCanvas; X, Y, W, H: Single;
    FillColor, BorderColor: TColor; BorderW: Single): Boolean;
  { 抗锯齿线段（圆帽） }
  function DrawLineAA(ACanvas: TCanvas; X1, Y1, X2, Y2: Single;
    AColor: TColor; AWidth: Single; ARoundCap: Boolean = True): Boolean;

type
  { ---- TFHToggleSwitch ---- }
  TFHToggleSwitch = class(TCustomControl)
  private
    FChecked: Boolean;
    FHovered: Boolean;
    FPressed: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(Value: Boolean);
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Checked: Boolean read FChecked write SetChecked default False;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { ---- TFHRadioDot ---- }
  TFHRadioDot = class(TCustomControl)
  private
    FChecked: Boolean;
    FText: string;
    FHovered: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(Value: Boolean);
    procedure SetText(const Value: string);
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Checked: Boolean read FChecked write SetChecked default False;
    property Text: string read FText write SetText;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { ---- TFHCheckBox: 方形勾选框（Chrome 复选框） ---- }
  TFHCheckBox = class(TCustomControl)
  private
    FChecked: Boolean;
    FText: string;
    FHovered: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(Value: Boolean);
    procedure SetText(const Value: string);
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure SetEnabled(Value: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Checked: Boolean read FChecked write SetChecked default False;
    property Text: string read FText write SetText;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property Enabled;
  end;

  { ---- TFHFlatEdit ---- }
  TFHFlatEdit = class(TCustomControl)
  private
    FEdit: TEdit;
    FFocused: Boolean;
    function GetText: string;
    procedure SetText(const Value: string);
    function GetHintText: string;
    procedure SetHintText(const Value: string);
    procedure PinEditFont;
    procedure UpdateEditBounds;
    procedure EditEnter(Sender: TObject);
    procedure EditExit(Sender: TObject);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure CreateWnd; override;
    procedure SetEnabled(Value: Boolean); override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SelectAll;
  published
    property Text: string read GetText write SetText;
    property HintText: string read GetHintText write SetHintText;
    property Enabled;
  end;

  { ---- TFHSegmented: 分段选择（替代下拉框; 选中段蓝底白字, 只有一个选中） ---- }
  TFHSegmented = class(TCustomControl)
  private
    FItems: TStringList;
    FItemIndex: Integer;
    FHot: Integer;
    FOnChange: TNotifyEvent;
    function GetItems: TStrings;
    procedure ItemsChanged(Sender: TObject);
    procedure SetItemIndex(Value: Integer);
    function IndexAtPos(X, Y: Integer): Integer;
    function SegmentRect(AIndex: Integer): TRect;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property Items: TStrings read GetItems;
  published
    property ItemIndex: Integer read FItemIndex write SetItemIndex default -1;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property Enabled;
  end;

  { ---- TFHFlatButton ---- }
  TFHFlatButtonStyle = (fbsPrimary, fbsText);

  TFHFlatButton = class(TCustomControl)
  private
    FCaption: string;
    FStyle: TFHFlatButtonStyle;
    FHovered: Boolean;
    FPressed: Boolean;
    FOnClick: TNotifyEvent;
    procedure SetCaption(const Value: string);
    procedure SetStyle(Value: TFHFlatButtonStyle);
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure SetEnabled(Value: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Caption: string read FCaption write SetCaption;
    property ButtonStyle: TFHFlatButtonStyle read FStyle write SetStyle
      default fbsPrimary;
    property OnClick: TNotifyEvent read FOnClick write FOnClick;
    property Enabled;
  end;

implementation

uses
  uFHChromeTabs;

{ ---- 绘制辅助 ------------------------------------------------------------ }

{ TColor → GDI+ ARGB（$FF000000 | R<<16 | G<<8 | B） }
function ColorToARGB(Color: TColor): ARGB;
var
  C: Cardinal;
begin
  C := ColorToRGB(Color);
  Result := ARGB($FF000000 or (GetRValue(C) shl 16) or
    (GetGValue(C) shl 8) or GetBValue(C));
end;

{ Canvas 设备 DC 的 DPI 缩放因子（DPI/96） }
function CtlScale(ACanvas: TCanvas): Single;
var
  DPI: Integer;
begin
  DPI := 96;
  if (ACanvas <> nil) and (ACanvas.Handle <> 0) then
    DPI := GetDeviceCaps(ACanvas.Handle, LOGPIXELSX);
  if DPI <= 0 then
    DPI := 96;
  Result := DPI / 96;
end;

function CtlScalePx(ACanvas: TCanvas; P: Integer): Integer;
begin
  Result := Round(P * CtlScale(ACanvas));
  if (P > 0) and (Result = 0) then
    Result := 1;
end;

procedure SetCanvasFontPx(ACanvas: TCanvas; APx: Integer; ABold: Boolean;
  AColor: TColor);
var
  PPI: Integer;
begin
  PPI := Round(96 * CtlScale(ACanvas));
  if PPI <= 0 then
    PPI := 96;
  ACanvas.Font.Name := 'Segoe UI';
  ACanvas.Font.PixelsPerInch := PPI;
  ACanvas.Font.Height := -MulDiv(APx, PPI, 96);
  if ABold then
    ACanvas.Font.Style := [fsBold]
  else
    ACanvas.Font.Style := [];
  ACanvas.Font.Color := AColor;
end;

{ 创建抗锯齿 GDI+ Graphics; Canvas 无句柄或 GDI+ 不可用时返回 nil }
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

{ 圆角矩形路径（四个圆角 + 连接弧的直线边）。坐标是路径中心线 }
procedure AddRoundRectPath(Path: TGPGraphicsPath;
  Lf, Tp, Rt, Bt, Rad: Single);
begin
  if Rad < 0.5 then
    Rad := 0.5;
  if Rad * 2 > Rt - Lf then
    Rad := (Rt - Lf) / 2;
  if Rad * 2 > Bt - Tp then
    Rad := (Bt - Tp) / 2;
  Path.AddArc(Lf, Tp, Rad * 2, Rad * 2, Single(180), Single(90));            // 左上
  Path.AddArc(Rt - Rad * 2, Tp, Rad * 2, Rad * 2, Single(270), Single(90));  // 右上
  Path.AddArc(Rt - Rad * 2, Bt - Rad * 2, Rad * 2, Rad * 2,
    Single(0), Single(90));                                                  // 右下
  Path.AddArc(Lf, Bt - Rad * 2, Rad * 2, Rad * 2, Single(90), Single(90));   // 左下
  Path.CloseFigure;
end;

function FillRoundRectAA(ACanvas: TCanvas; Lf, Tp, Rt, Bt, Rad: Single;
  FillColor, BorderColor: TColor; BorderW: Single): Boolean;
var
  G: TGPGraphics;
  Path: TGPGraphicsPath;
  B: TGPSolidBrush;
  P: TGPPen;
  Dl, Dt, Dr, Db: Single;
begin
  Result := False;
  G := CreateSmoothGraphics(ACanvas);
  if G = nil then
    Exit;
  try
    Dl := Lf;
    Dt := Tp;
    Dr := Rt;
    Db := Bt;
    if BorderW > 0 then
    begin
      { 描边中心线按笔宽内缩半像素: 墨迹恰好占满第 0 行..第 W-1 行,
        与 uFHBrowserControls.DrawPillGDIPlus 的换算一致 }
      Dl := Lf + BorderW / 2 - 0.5;
      Dt := Tp + BorderW / 2 - 0.5;
      Dr := Rt - 0.5 - BorderW / 2;
      Db := Bt - 0.5 - BorderW / 2;
    end;
    Path := TGPGraphicsPath.Create;
    try
      AddRoundRectPath(Path, Dl, Dt, Dr, Db, Rad);
      if FillColor <> clNone then
      begin
        B := TGPSolidBrush.Create(ColorToARGB(FillColor));
        try
          G.FillPath(B, Path);
        finally
          B.Free;
        end;
      end;
      if (BorderColor <> clNone) and (BorderW > 0) then
      begin
        P := TGPPen.Create(ColorToARGB(BorderColor), BorderW);
        try
          G.DrawPath(P, Path);
        finally
          P.Free;
        end;
      end;
      Result := True;
    finally
      Path.Free;
    end;
  finally
    G.Free;
  end;
end;

function FillEllipseAA(ACanvas: TCanvas; X, Y, W, H: Single;
  FillColor, BorderColor: TColor; BorderW: Single): Boolean;
var
  G: TGPGraphics;
  B: TGPSolidBrush;
  P: TGPPen;
  Dl, Dt, Dw, Dh: Single;
begin
  Result := False;
  G := CreateSmoothGraphics(ACanvas);
  if G = nil then
    Exit;
  try
    if FillColor <> clNone then
    begin
      B := TGPSolidBrush.Create(ColorToARGB(FillColor));
      try
        G.FillEllipse(B, X, Y, W, H);
      finally
        B.Free;
      end;
    end;
    if (BorderColor <> clNone) and (BorderW > 0) then
    begin
      Dl := X + BorderW / 2 - 0.5;
      Dt := Y + BorderW / 2 - 0.5;
      Dw := W - BorderW;
      Dh := H - BorderW;
      P := TGPPen.Create(ColorToARGB(BorderColor), BorderW);
      try
        G.DrawEllipse(P, Dl, Dt, Dw, Dh);
      finally
        P.Free;
      end;
    end;
    Result := True;
  finally
    G.Free;
  end;
end;

function DrawLineAA(ACanvas: TCanvas; X1, Y1, X2, Y2: Single;
  AColor: TColor; AWidth: Single; ARoundCap: Boolean): Boolean;
var
  G: TGPGraphics;
  P: TGPPen;
begin
  Result := False;
  G := CreateSmoothGraphics(ACanvas);
  if G = nil then
    Exit;
  try
    P := TGPPen.Create(ColorToARGB(AColor), AWidth);
    try
      if ARoundCap then
      begin
        P.SetStartCap(LineCapRound);
        P.SetEndCap(LineCapRound);
      end;
      G.DrawLine(P, X1, Y1, X2, Y2);
      Result := True;
    finally
      P.Free;
    end;
  finally
    G.Free;
  end;
end;

{ ============================ TFHToggleSwitch ============================= }

{ 构造: 默认 44x24 逻辑尺寸, 手型光标, 初始未选中 }
constructor TFHToggleSwitch.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  Width := Round(44 * (Screen.PixelsPerInch / 96));
  Height := Round(24 * (Screen.PixelsPerInch / 96));
  FChecked := False;
  FHovered := False;
  FPressed := False;
  Cursor := crHandPoint;
  TabStop := False;
end;

{ 选中态 setter: 值变化时重绘（不触发 OnChange, 程序赋值不算用户操作） }
procedure TFHToggleSwitch.SetChecked(Value: Boolean);
begin
  if FChecked <> Value then
  begin
    FChecked := Value;
    Invalidate;
  end;
end;

{ 鼠标进入: 记录悬停态并重绘（轨道变深） }
procedure TFHToggleSwitch.CMMouseEnter(var Message: TMessage);
begin
  FHovered := True;
  Invalidate;
end;

{ 鼠标离开: 清悬停/按下态并重绘 }
procedure TFHToggleSwitch.CMMouseLeave(var Message: TMessage);
begin
  FHovered := False;
  FPressed := False;
  Invalidate;
end;

{ 鼠标按下: 记录按下态并重绘 }
procedure TFHToggleSwitch.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
end;

{ 鼠标松开: 仍在控件内 = 切换选中并触发 OnChange（点外松开不算操作） }
procedure TFHToggleSwitch.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then Exit;
  FPressed := False;
  if PtInRect(ClientRect, Point(X, Y)) then
  begin
    FChecked := not FChecked;
    Invalidate;
    if Assigned(FOnChange) then
      FOnChange(Self);
  end
  else
    Invalidate;
end;

{ 自绘: 胶囊轨道（选中蓝/悬停深灰/常态浅灰）+ 白色圆钮
  （未选中带灰描边）; GDI+ 不可用回退 GDI }
procedure TFHToggleSwitch.Paint;
var
  W, H: Integer;
  Track: TColor;
  ThumbD, ThumbX, ThumbY: Integer;
  AaOk: Boolean;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Color := FH_BG;
  Canvas.FillRect(ClientRect);

  W := Width;
  H := Height;
  if FChecked then
    Track := FH_FOCUS
  else if FHovered then
    Track := FH_THUMB_EDGE
  else
    Track := FH_TRACK_OFF;

  AaOk := FillRoundRectAA(Canvas, 0, 0, W, H, H / 2, Track, clNone, 0);
  if not AaOk then
  begin
    Canvas.Brush.Color := Track;
    Canvas.Pen.Color := Track;
    Canvas.RoundRect(0, 0, W, H, H, H);
  end;

  ThumbD := H - CtlScalePx(Canvas, 6);
  if FChecked then
    ThumbX := W - CtlScalePx(Canvas, 3) - ThumbD
  else
    ThumbX := CtlScalePx(Canvas, 3);
  ThumbY := (H - ThumbD) div 2;

  if FChecked then
    AaOk := FillEllipseAA(Canvas, ThumbX, ThumbY, ThumbD, ThumbD,
      clWhite, clNone, 0)
  else
    AaOk := FillEllipseAA(Canvas, ThumbX, ThumbY, ThumbD, ThumbD,
      clWhite, FH_THUMB_EDGE, Max(1, CtlScalePx(Canvas, 1)));
  if not AaOk then
  begin
    Canvas.Brush.Color := clWhite;
    if FChecked then
      Canvas.Pen.Color := clWhite
    else
      Canvas.Pen.Color := FH_THUMB_EDGE;
    Canvas.Pen.Width := Max(1, CtlScalePx(Canvas, 1));
    Canvas.Ellipse(ThumbX, ThumbY, ThumbX + ThumbD, ThumbY + ThumbD);
    Canvas.Pen.Width := 1;
  end;
end;

{ ============================ TFHRadioDot ================================= }

{ 构造: 默认 24 逻辑高, 手型光标, 初始未选中 }
constructor TFHRadioDot.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  Height := Round(24 * (Screen.PixelsPerInch / 96));
  FChecked := False;
  FHovered := False;
  FText := '';
  Cursor := crHandPoint;
  TabStop := False;
end;

{ 选中态 setter: 值变化时重绘（互斥由宿主管理, 自绘单选无分组） }
procedure TFHRadioDot.SetChecked(Value: Boolean);
begin
  if FChecked <> Value then
  begin
    FChecked := Value;
    Invalidate;
  end;
end;

{ 文字 setter: 变化时重绘 }
procedure TFHRadioDot.SetText(const Value: string);
begin
  if FText <> Value then
  begin
    FText := Value;
    Invalidate;
  end;
end;

{ 鼠标进入: 记录悬停态并重绘（未选中外圈变深） }
procedure TFHRadioDot.CMMouseEnter(var Message: TMessage);
begin
  FHovered := True;
  Invalidate;
end;

{ 鼠标离开: 清悬停态并重绘 }
procedure TFHRadioDot.CMMouseLeave(var Message: TMessage);
begin
  FHovered := False;
  Invalidate;
end;

{ 鼠标松开: 控件内左键且原未选中 → 选中并触发 OnChange（整行可点） }
procedure TFHRadioDot.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then Exit;
  if not PtInRect(ClientRect, Point(X, Y)) then Exit;
  if not FChecked then
  begin
    FChecked := True;
    Invalidate;
    if Assigned(FOnChange) then
      FOnChange(Self);
  end;
end;

{ 自绘: 左侧 18px 圆点（选中 = 蓝圈蓝心, 未选中 = 灰圈/悬停深圈）
  + 右侧文字; GDI+ 不可用回退 GDI }
procedure TFHRadioDot.Paint;
var
  D, CX, CY, R: Integer;
  AaOk: Boolean;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Color := FH_BG;
  Canvas.FillRect(ClientRect);

  { 圆点: 直径 18（外圈）, 圆心贴左、垂直居中; 文字从圆点右侧 10px 处开始 }
  D := CtlScalePx(Canvas, 18);
  CX := D div 2;
  CY := Height div 2;

  if FChecked then
  begin
    AaOk := FillEllipseAA(Canvas, CX - D / 2, CY - D / 2, D, D,
      clNone, FH_FOCUS, Max(2, CtlScalePx(Canvas, 2)));
    if AaOk then
      AaOk := FillEllipseAA(Canvas, CX - CtlScalePx(Canvas, 5),
        CY - CtlScalePx(Canvas, 5), CtlScalePx(Canvas, 10),
        CtlScalePx(Canvas, 10), FH_FOCUS, clNone, 0);
    if not AaOk then
    begin
      Canvas.Pen.Width := Max(1, CtlScalePx(Canvas, 2));
      Canvas.Pen.Color := FH_FOCUS;
      Canvas.Brush.Color := FH_BG;
      Canvas.Ellipse(CX - D div 2, CY - D div 2, CX + D div 2, CY + D div 2);
      R := CtlScalePx(Canvas, 5);
      Canvas.Brush.Color := FH_FOCUS;
      Canvas.Pen.Color := FH_FOCUS;
      Canvas.Pen.Width := 1;
      Canvas.Ellipse(CX - R, CY - R, CX + R, CY + R);
    end;
  end
  else
  begin
    if FHovered then
      AaOk := FillEllipseAA(Canvas, CX - D / 2, CY - D / 2, D, D,
        clNone, FH_TEXT, Max(2, CtlScalePx(Canvas, 2)))
    else
      AaOk := FillEllipseAA(Canvas, CX - D / 2, CY - D / 2, D, D,
        clNone, FH_RADIO_EDGE, Max(2, CtlScalePx(Canvas, 2)));
    if not AaOk then
    begin
      if FHovered then
        Canvas.Pen.Color := FH_TEXT
      else
        Canvas.Pen.Color := FH_RADIO_EDGE;
      Canvas.Pen.Width := Max(1, CtlScalePx(Canvas, 2));
      Canvas.Brush.Color := FH_BG;
      Canvas.Ellipse(CX - D div 2, CY - D div 2, CX + D div 2, CY + D div 2);
      Canvas.Pen.Width := 1;
    end;
  end;

  if FText <> '' then
  begin
    SetCanvasFontPx(Canvas, 14, False, FH_TEXT);
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(CX + D div 2 + CtlScalePx(Canvas, 10),
      CY - Canvas.TextHeight(FText) div 2, FText);
    Canvas.Brush.Style := bsSolid;
  end;
end;

{ ============================ TFHCheckBox ================================= }

{ 构造: 默认 24 逻辑高, 手型光标, 初始未选中 }
constructor TFHCheckBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  Height := Round(24 * (Screen.PixelsPerInch / 96));
  FChecked := False;
  FHovered := False;
  FText := '';
  Cursor := crHandPoint;
  TabStop := False;
end;

{ 选中态 setter: 值变化时重绘（不触发 OnChange） }
procedure TFHCheckBox.SetChecked(Value: Boolean);
begin
  if FChecked <> Value then
  begin
    FChecked := Value;
    Invalidate;
  end;
end;

{ 文字 setter: 变化时重绘 }
procedure TFHCheckBox.SetText(const Value: string);
begin
  if FText <> Value then
  begin
    FText := Value;
    Invalidate;
  end;
end;

{ 启用态 setter: 联动重绘（禁用态边框/文字变浅灰） }
procedure TFHCheckBox.SetEnabled(Value: Boolean);
begin
  inherited SetEnabled(Value);
  Invalidate;
end;

{ 鼠标进入: 记录悬停态并重绘（未选中方框边框变深） }
procedure TFHCheckBox.CMMouseEnter(var Message: TMessage);
begin
  FHovered := True;
  Invalidate;
end;

{ 鼠标离开: 清悬停态并重绘 }
procedure TFHCheckBox.CMMouseLeave(var Message: TMessage);
begin
  FHovered := False;
  Invalidate;
end;

{ 鼠标松开: 控件内左键 → 切换选中并触发 OnChange（整行可点） }
procedure TFHCheckBox.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then Exit;
  if not PtInRect(ClientRect, Point(X, Y)) then Exit;
  FChecked := not FChecked;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

{ 自绘: 左侧 18px 圆角方框（选中 = 蓝底白对勾, 未选中 = 灰描边）
  + 右侧文字（禁用态变浅）; GDI+ 不可用回退 GDI }
procedure TFHCheckBox.Paint;
var
  Box, By, TextX, Rad, PenW: Integer;
  Edge, TxtColor: TColor;
  AaOk, LnOk: Boolean;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Color := FH_BG;
  Canvas.FillRect(ClientRect);

  { 勾选框: 18px 方形（Chrome 复选框）, 圆角 2; 选中 = 蓝底白勾 }
  Box := CtlScalePx(Canvas, 18);
  By := (Height - Box) div 2;
  Rad := CtlScalePx(Canvas, 2);
  PenW := Max(2, CtlScalePx(Canvas, 2));

  if FChecked then
  begin
    AaOk := FillRoundRectAA(Canvas, 0, By, Box, By + Box, Rad,
      FH_FOCUS, clNone, 0);
    if not AaOk then
    begin
      Canvas.Brush.Color := FH_FOCUS;
      Canvas.Pen.Color := FH_FOCUS;
      Canvas.RoundRect(0, By, Box, By + Box, Rad * 2, Rad * 2);
    end;
    { 白色对勾: 两条圆帽线段 (26%,56%) → (44%,74%) → (75%,28%) }
    LnOk := DrawLineAA(Canvas, Box * 0.26, By + Box * 0.56,
      Box * 0.44, By + Box * 0.74, clWhite, PenW);
    if LnOk then
      LnOk := DrawLineAA(Canvas, Box * 0.44, By + Box * 0.74,
        Box * 0.75, By + Box * 0.28, clWhite, PenW);
    if not LnOk then
    begin
      Canvas.Pen.Color := clWhite;
      Canvas.Pen.Width := PenW;
      Canvas.MoveTo(Round(Box * 0.26), Round(By + Box * 0.56));
      Canvas.LineTo(Round(Box * 0.44), Round(By + Box * 0.74));
      Canvas.LineTo(Round(Box * 0.75), Round(By + Box * 0.28));
      Canvas.Pen.Width := 1;
    end;
  end
  else
  begin
    if not Enabled then
      Edge := FH_BORDER_DIS
    else if FHovered then
      Edge := FH_TEXT
    else
      Edge := FH_RADIO_EDGE;
    AaOk := FillRoundRectAA(Canvas, 0, By, Box, By + Box, Rad,
      FH_BG, Edge, PenW);
    if not AaOk then
    begin
      Canvas.Brush.Color := FH_BG;
      Canvas.Pen.Color := Edge;
      Canvas.Pen.Width := PenW;
      Canvas.RoundRect(1, By + 1, Box - 1, By + Box - 1, Rad * 2, Rad * 2);
      Canvas.Pen.Width := 1;
    end;
  end;

  if FText <> '' then
  begin
    if Enabled then
      TxtColor := FH_TEXT
    else
      TxtColor := FH_TEXT_DIS;
    SetCanvasFontPx(Canvas, 14, False, TxtColor);
    TextX := Box + CtlScalePx(Canvas, 12);
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(TextX, (Height - Canvas.TextHeight(FText)) div 2, FText);
    Canvas.Brush.Style := bsSolid;
  end;
end;

{ ============================ TFHFlatEdit ================================= }

{ 构造: 内嵌无边框 TEdit（真正外观由 Paint 画圆角边框）, 默认 32 逻辑高 }
constructor TFHFlatEdit.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  Height := Round(32 * (Screen.PixelsPerInch / 96));
  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.BorderStyle := bsNone;
  FEdit.Color := clWhite;
  FEdit.Font.Name := 'Segoe UI';
  FEdit.Font.Color := FH_TEXT;
  FEdit.Font.Size := 9;          // 构造占位; 真正字号由 PinEditFont 按像素钉死
  FEdit.OnEnter := EditEnter;
  FEdit.OnExit := EditExit;
  FFocused := False;
  TabStop := False;
end;

{ 启用态 setter: 联动内嵌 Edit 并重绘（边框变浅灰） }
procedure TFHFlatEdit.SetEnabled(Value: Boolean);
begin
  inherited SetEnabled(Value);
  if FEdit <> nil then
    FEdit.Enabled := Value;
  Invalidate;
end;

{ 文本 getter/setter: 透传内嵌 Edit }
function TFHFlatEdit.GetText: string;
begin
  Result := FEdit.Text;
end;

{ 文本 setter: 透传内嵌 Edit }
procedure TFHFlatEdit.SetText(const Value: string);
begin
  FEdit.Text := Value;
end;

{ 占位提示 getter: 透传内嵌 Edit 的 TextHint }
function TFHFlatEdit.GetHintText: string;
begin
  Result := FEdit.TextHint;
end;

{ 占位提示 setter: 透传内嵌 Edit 的 TextHint }
procedure TFHFlatEdit.SetHintText(const Value: string);
begin
  FEdit.TextHint := Value;
end;

{ 聚焦内嵌 Edit 并全选文本 }
procedure TFHFlatEdit.SelectAll;
begin
  if FEdit.CanFocus then
    FEdit.SetFocus;
  FEdit.SelectAll;
end;

{ 内嵌 Edit 获得焦点: 记录态并重绘（边框变蓝加粗） }
procedure TFHFlatEdit.EditEnter(Sender: TObject);
begin
  FFocused := True;
  Invalidate;
end;

{ 内嵌 Edit 失去焦点: 记录态并重绘（边框回灰细线） }
procedure TFHFlatEdit.EditExit(Sender: TObject);
begin
  FFocused := False;
  Invalidate;
end;

{ 字号按像素钉死: VCL 的 SetParent/DPI 级联缩放会把构造时的磅值放大,
  用设备 DC 的真实 DPI 反算 Height(负=像素), 幂等 }
procedure TFHFlatEdit.PinEditFont;
var
  PPI: Integer;
  DC: HDC;
begin
  if FEdit = nil then Exit;
  PPI := 0;
  if HandleAllocated then
  begin
    DC := GetDC(Handle);
    PPI := GetDeviceCaps(DC, LOGPIXELSX);
    ReleaseDC(Handle, DC);
  end;
  if PPI <= 0 then
    PPI := Round(96 * (Screen.PixelsPerInch / 96));
  if PPI <= 0 then
    PPI := 96;
  FEdit.Font.Name := 'Segoe UI';
  FEdit.Font.PixelsPerInch := PPI;
  FEdit.Font.Height := -MulDiv(14, PPI, 96);
end;

{ 重排内嵌 Edit: 钉字号后按 DPI 留左右 10px 内边距, 垂直居中 }
procedure TFHFlatEdit.UpdateEditBounds;
var
  Inset, EH, Top: Integer;
begin
  if (FEdit = nil) or (Width <= 0) or (Height <= 0) then Exit;
  PinEditFont;
  Inset := CtlScalePx(Canvas, 10);
  EH := Height - CtlScalePx(Canvas, 6);
  if EH < 12 then
    EH := Height;
  Top := (Height - EH) div 2;
  FEdit.SetBounds(Inset, Top, Width - 2 * Inset, EH);
end;

{ 句柄创建后: 重排内嵌 Edit（DPI 此时才可查） }
procedure TFHFlatEdit.CreateWnd;
begin
  inherited CreateWnd;
  UpdateEditBounds;
end;

{ 尺寸变化: 重排内嵌 Edit 并重绘 }
procedure TFHFlatEdit.Resize;
begin
  inherited;
  UpdateEditBounds;
  Invalidate;
end;

{ DPI 变化（跨屏）: 钉字号并重排内嵌 Edit }
procedure TFHFlatEdit.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  PinEditFont;
  UpdateEditBounds;
end;

{ 自绘圆角边框: 聚焦蓝粗线 / 常态灰细线 / 禁用浅灰;
  GDI+ 不可用回退 GDI RoundRect }
procedure TFHFlatEdit.Paint;
var
  R: TRect;
  Rad: Integer;
  BorderColor: TColor;
  PenW: Integer;
begin
  R := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Color := FH_BG;
  Canvas.FillRect(R);

  Rad := CtlScalePx(Canvas, 8);
  if Enabled then
  begin
    if FFocused then
    begin
      BorderColor := FH_FOCUS;
      PenW := Max(2, CtlScalePx(Canvas, 2));
    end
    else
    begin
      BorderColor := FH_BORDER;
      PenW := 1;
    end;
  end
  else
  begin
    BorderColor := FH_BORDER_DIS;
    PenW := 1;
  end;

  { 圆角边框: GDI+ 抗锯齿（GDI RoundRect 的圆角有阶梯锯齿） }
  if not FillRoundRectAA(Canvas, 0, 0, Width, Height, Rad,
    clNone, BorderColor, PenW) then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Color := BorderColor;
    Canvas.Pen.Width := PenW;
    if PenW > 1 then
      Canvas.RoundRect(1, 1, Width - 1, Height - 1, 2 * Rad, 2 * Rad)
    else
      Canvas.RoundRect(0, 0, Width - 1, Height - 1, 2 * Rad, 2 * Rad);
    Canvas.Pen.Width := 1;
    Canvas.Brush.Style := bsSolid;
  end;
end;

{ ============================ TFHSegmented ================================ }

{ 构造: 建条目列表（变更自动夹取选中索引）, 默认 32 逻辑高, 手型光标 }
constructor TFHSegmented.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  Height := Round(32 * (Screen.PixelsPerInch / 96));
  FItems := TStringList.Create;
  FItems.OnChange := ItemsChanged;
  FItemIndex := -1;
  FHot := -1;
  Cursor := crHandPoint;
  TabStop := False;
end;

{ 析构: 释放条目列表 }
destructor TFHSegmented.Destroy;
begin
  FItems.Free;
  inherited;
end;

{ 条目列表 getter: 直接暴露内部 TStringList（宿主 Items.Add 填充） }
function TFHSegmented.GetItems: TStrings;
begin
  Result := FItems;
end;

{ 条目列表变化: 夹取选中索引到合法范围, 清悬停态并重绘 }
procedure TFHSegmented.ItemsChanged(Sender: TObject);
begin
  if FItemIndex >= FItems.Count then
    FItemIndex := FItems.Count - 1;
  FHot := -1;
  Invalidate;
end;

{ 选中索引 setter: 夹取到 [-1, Count-1], 变化时重绘（不触发 OnChange） }
procedure TFHSegmented.SetItemIndex(Value: Integer);
begin
  if Value < -1 then
    Value := -1;
  if Value >= FItems.Count then
    Value := FItems.Count - 1;
  if FItemIndex <> Value then
  begin
    FItemIndex := Value;
    Invalidate;
  end;
end;

{ 第 AIndex 段的矩形: 全宽均分 + 段间 4px 间隙, 最后一段吃掉除不尽的余量 }
function TFHSegmented.SegmentRect(AIndex: Integer): TRect;
var
  Gap, SW, X: Integer;
begin
  Gap := CtlScalePx(Canvas, 4);
  if (FItems.Count <= 0) or (AIndex < 0) then
    Exit(ClientRect);
  SW := (Width - Gap * (FItems.Count - 1)) div FItems.Count;
  X := AIndex * (SW + Gap);
  if AIndex = FItems.Count - 1 then
    Result := Rect(X, 0, Width, Height)     // 最后一段吃掉除不尽的余量
  else
    Result := Rect(X, 0, X + SW, Height);
end;

{ 坐标 → 段索引（命中哪一段）; 不在任何段上返回 -1 }
function TFHSegmented.IndexAtPos(X, Y: Integer): Integer;
var
  I: Integer;
  P: TPoint;
begin
  Result := -1;
  P := Point(X, Y);
  for I := 0 to FItems.Count - 1 do
    if PtInRect(SegmentRect(I), P) then
      Exit(I);
end;

{ 鼠标离开: 清悬停段并重绘 }
procedure TFHSegmented.CMMouseLeave(var Message: TMessage);
begin
  if FHot <> -1 then
  begin
    FHot := -1;
    Invalidate;
  end;
end;

{ 鼠标移动: 跟踪悬停段, 变化时重绘 }
procedure TFHSegmented.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited;
  I := IndexAtPos(X, Y);
  if I <> FHot then
  begin
    FHot := I;
    Invalidate;
  end;
end;

{ 鼠标松开: 左键命中新段 → 切换选中并触发 OnChange }
procedure TFHSegmented.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  I: Integer;
begin
  inherited;
  if Button <> mbLeft then Exit;
  I := IndexAtPos(X, Y);
  if (I >= 0) and (I <> FItemIndex) then
  begin
    FItemIndex := I;
    Invalidate;
    if Assigned(FOnChange) then
      FOnChange(Self);
  end;
end;

{ 自绘各段: 选中段蓝底白字, 其余白底灰边（悬停边框变深, 禁用文字变浅）;
  GDI+ 不可用回退 GDI }
procedure TFHSegmented.Paint;
var
  I, Rad: Integer;
  R, TR: TRect;
  Bg, Edge, Fg: TColor;
  AaOk: Boolean;
  Txt: string;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Color := FH_BG;
  Canvas.FillRect(ClientRect);

  Rad := CtlScalePx(Canvas, 8);
  for I := 0 to FItems.Count - 1 do
  begin
    R := SegmentRect(I);
    if I = FItemIndex then
    begin
      { 选中段: 蓝底白字（明确"只有一个选择"） }
      Bg := FH_FOCUS;
      Edge := FH_FOCUS;
      Fg := clWhite;
    end
    else
    begin
      Bg := FH_BG;
      if (I = FHot) and Enabled then
        Edge := FH_TEXT
      else
        Edge := FH_BORDER;
      Fg := FH_TEXT;
    end;
    if not Enabled then
      Fg := FH_TEXT_DIS;

    AaOk := FillRoundRectAA(Canvas, R.Left, R.Top, R.Right, R.Bottom, Rad,
      Bg, Edge, 1);
    if not AaOk then
    begin
      Canvas.Brush.Color := Bg;
      Canvas.Pen.Color := Edge;
      Canvas.RoundRect(R.Left, R.Top, R.Right - 1, R.Bottom - 1,
        Rad * 2, Rad * 2);
    end;

    Txt := FItems[I];
    if Txt <> '' then
    begin
      SetCanvasFontPx(Canvas, 13, False, Fg);
      TR := R;
      Canvas.Brush.Style := bsClear;
      Winapi.Windows.DrawText(Canvas.Handle, PChar(Txt), Length(Txt), TR,
        DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX or
        DT_END_ELLIPSIS);
      Canvas.Brush.Style := bsSolid;
    end;
  end;
end;

{ ============================ TFHFlatButton =============================== }

{ 构造: 默认 88x32 逻辑尺寸, 主按钮风格, 手型光标 }
constructor TFHFlatButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  Width := Round(88 * (Screen.PixelsPerInch / 96));
  Height := Round(32 * (Screen.PixelsPerInch / 96));
  FCaption := '';
  FStyle := fbsPrimary;
  FHovered := False;
  FPressed := False;
  Cursor := crHandPoint;
  TabStop := False;
end;

{ 标题 setter: 变化时重绘 }
procedure TFHFlatButton.SetCaption(const Value: string);
begin
  if FCaption <> Value then
  begin
    FCaption := Value;
    Invalidate;
  end;
end;

{ 风格 setter（主按钮/文字按钮）: 变化时重绘 }
procedure TFHFlatButton.SetStyle(Value: TFHFlatButtonStyle);
begin
  if FStyle <> Value then
  begin
    FStyle := Value;
    Invalidate;
  end;
end;

{ 启用态 setter: 手动重绘（CMEnabledChanged 不会触发自绘控件刷新） }
procedure TFHFlatButton.SetEnabled(Value: Boolean);
begin
  inherited SetEnabled(Value);
  { TWinControl.CMEnabledChanged 不会触发本控件的重绘（外观全靠 Paint） }
  Invalidate;
end;

{ 鼠标进入: 记录悬停态并重绘 }
procedure TFHFlatButton.CMMouseEnter(var Message: TMessage);
begin
  FHovered := True;
  Invalidate;
end;

{ 鼠标离开: 清悬停/按下态并重绘 }
procedure TFHFlatButton.CMMouseLeave(var Message: TMessage);
begin
  FHovered := False;
  FPressed := False;
  Invalidate;
end;

{ 鼠标按下: 记录按下态并重绘 }
procedure TFHFlatButton.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
end;

{ 鼠标松开: 仍在控件内则触发 OnClick（点外松开不算点击） }
procedure TFHFlatButton.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then Exit;
  FPressed := False;
  Invalidate;
  if PtInRect(ClientRect, Point(X, Y)) and Assigned(FOnClick) then
    FOnClick(Self);
end;

{ 自绘: 主按钮 = 蓝底白字胶囊（悬停/按下深蓝, 禁用浅灰底灰字）;
  文字按钮 = 蓝字（悬停浅蓝底）; GDI+ 不可用回退 GDI }
procedure TFHFlatButton.Paint;
var
  W, H, Rad: Integer;
  BgColor, FgColor: TColor;
  R: TRect;
  AaOk: Boolean;
begin
  W := Width;
  H := Height;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Color := FH_BG;
  Canvas.FillRect(ClientRect);
  Rad := H div 2;

  if FStyle = fbsPrimary then
  begin
    { 主按钮: 蓝底白字胶囊; 禁用 = 浅灰底灰字（同 Chrome 不可用按钮） }
    if not Enabled then
    begin
      BgColor := FH_BTN_DIS;
      FgColor := FH_TEXT_DIS;
    end
    else
    begin
      if FHovered or FPressed then
        BgColor := FH_FOCUS_DARK
      else
        BgColor := FH_FOCUS;
      FgColor := clWhite;
    end;
    AaOk := FillRoundRectAA(Canvas, 0, 0, W, H, H / 2, BgColor, clNone, 0);
    if not AaOk then
    begin
      Canvas.Brush.Color := BgColor;
      Canvas.Pen.Color := BgColor;
      Canvas.RoundRect(0, 0, W, H, Rad * 2, Rad * 2);
    end;
  end
  else
  begin
    { 文字按钮: 悬停浅蓝底, 蓝字; 禁用 = 灰字无底 }
    if not Enabled then
      FgColor := FH_TEXT_DIS
    else
    begin
      FgColor := FH_FOCUS;
      if FHovered or FPressed then
      begin
        AaOk := FillRoundRectAA(Canvas, 0, 0, W, H, H / 2,
          FH_HOVER_BG, clNone, 0);
        if not AaOk then
        begin
          Canvas.Brush.Color := FH_HOVER_BG;
          Canvas.Pen.Color := FH_HOVER_BG;
          Canvas.RoundRect(0, 0, W, H, Rad * 2, Rad * 2);
        end;
      end;
    end;
  end;

  SetCanvasFontPx(Canvas, 14, False, FgColor);
  R := Rect(0, 0, W, H);
  Canvas.Brush.Style := bsClear;
  Winapi.Windows.DrawText(Canvas.Handle, PChar(FCaption), Length(FCaption), R,
    DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);
  Canvas.Brush.Style := bsSolid;
end;

end.