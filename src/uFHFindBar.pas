unit uFHFindBar;

{==============================================================================
  TFHFindBar —— Chrome 风格页面内查找条
  ----------------------------------------------------------------------------
  UI 参照 Chromium 109 find bar: 悬浮在内容区右上角, 白底圆角条;
  输入框左侧放大镜, 右侧匹配计数 (当前/总数) + 上一个/下一个/关闭按钮。
  输入即查, 无匹配时输入框与计数转红; 关闭时由宿主清掉页面高亮。
  键盘: Enter / F3 下一个, Shift+Enter / Shift+F3 上一个, Esc 关闭。
============================================================================== }

interface

uses
  System.Classes, System.SysUtils, System.Types, System.UITypes, System.TypInfo,
  Winapi.Windows, Winapi.Messages, Winapi.GDIPOBJ, Winapi.GDIPAPI,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.StdCtrls,
  uFHChromeTabs, uFHBrowserControls;

type
  TFHFindBar = class(TCustomControl)
  private
    FEdit: TEdit;
    FBtnPrev: TFHNavButton;
    FBtnNext: TFHNavButton;
    FBtnCase: TFHNavButton;
    FBtnClose: TFHNavButton;
    FMatchCount: Integer;
    FActiveMatch: Integer;
    FResultReady: Boolean;
    FFocused: Boolean;
    FOnSearch: TNotifyEvent;
    FOnFindNext: TNotifyEvent;
    FOnFindPrev: TNotifyEvent;
    FOnClose: TNotifyEvent;
    function Px(V: Integer): Integer;
    function ParentBackColor: TColor;
    function SearchBoxRect: TRect;
    function HasNoMatch: Boolean;
    function MatchesText: string;
    procedure PinEditFont;
    procedure LayoutChildren;
    procedure EditChanged(Sender: TObject);
    procedure EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure EditEnter(Sender: TObject);
    procedure EditExit(Sender: TObject);
    procedure BtnPrevClick(Sender: TObject);
    procedure BtnNextClick(Sender: TObject);
    procedure BtnCaseClick(Sender: TObject);
    procedure BtnCloseClick(Sender: TObject);
    procedure DrawCard;
    procedure DrawSearchBox;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure CreateWnd; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure FocusSearch;
    { 宿主把 CEF 的查找结果回填进来（OnFindResult）; 无匹配时计数与边框转红 }
    procedure SetResult(ACount, AActive: Integer);
    function SearchText: string;
    function GetMatchCase: Boolean;
    { 显示前定位到宿主客户区右上角（宽度不足时收缩自身） }
    procedure AlignToTopRight;
    property MatchCase: Boolean read GetMatchCase;
    property OnSearch: TNotifyEvent read FOnSearch write FOnSearch;
    property OnFindNext: TNotifyEvent read FOnFindNext write FOnFindNext;
    property OnFindPrev: TNotifyEvent read FOnFindPrev write FOnFindPrev;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
  end;

implementation

{ TColor → GDI+ ARGB（$FF000000 | R<<16 | G<<8 | B） }
function ColorToARGB(Color: TColor): ARGB;
var
  C: Cardinal;
begin
  C := ColorToRGB(Color);
  Result := ARGB($FF000000 or (GetRValue(C) shl 16) or
    (GetGValue(C) shl 8) or GetBValue(C));
end;

{ 由 VCL Canvas 创建抗锯齿 GDI+ Graphics; GDI+ 不可用时返回 nil（调用方回退 GDI） }
function MakeGraphics(ACanvas: TCanvas): TGPGraphics;
begin
  Result := nil;
  if (ACanvas = nil) or (ACanvas.Handle = 0) or not EnsureGdiPlus then Exit;
  Result := TGPGraphics.Create(ACanvas.Handle);
  Result.SetSmoothingMode(SmoothingModeAntiAlias);
end;

{ 构造圆角矩形 GDI+ 路径（四角圆弧, 半像素内缩让 1px 边框不裁剪） }
function RoundRectPath(const R: TRect; ARadius: Single): TGPGraphicsPath;
var
  L, T, Rt, Bt, D: Single;
begin
  L := R.Left + 0.5;
  T := R.Top + 0.5;
  Rt := R.Right - 0.5;
  Bt := R.Bottom - 0.5;
  D := ARadius * 2;
  Result := TGPGraphicsPath.Create;
  Result.AddArc(L, T, D, D, 180, 90);
  Result.AddArc(Rt - D, T, D, D, 270, 90);
  Result.AddArc(Rt - D, Bt - D, D, D, 0, 90);
  Result.AddArc(L, Bt - D, D, D, 90, 90);
  Result.CloseFigure;
end;

{ 抗锯齿画圆角矩形（填充 + 可选描边）; GDI+ 不可用回退 GDI RoundRect }
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
  G := MakeGraphics(ACanvas);
  if G = nil then
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := AFill;
    ACanvas.Pen.Color := ABorder;
    ACanvas.Pen.Width := ABorderW;
    ACanvas.RoundRect(RR.Left, RR.Top, RR.Right, RR.Bottom, ARadius * 2, ARadius * 2);
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

{ ============================ TFHFindBar ================================= }

{ 构造: 建输入框 + 上一个/下一个/关闭/区分大小写四个按钮并挂接事件
  （初始隐藏, 由宿主 ShowFindBar 显示） }
constructor TFHFindBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  Width := MulDiv(300, Screen.PixelsPerInch, 96);
  Height := MulDiv(40, Screen.PixelsPerInch, 96);
  Visible := False;
  TabStop := False;
  Font.Name := 'Segoe UI';

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.BorderStyle := bsNone;
  FEdit.AutoSize := False;
  FEdit.Align := alNone;
  FEdit.Color := TColor($F4F3F1);        // #F1F3F4
  FEdit.Font.Name := 'Segoe UI';
  FEdit.Font.Size := 9;
  FEdit.Font.Color := TColor($242120);   // #202124
  FEdit.TextHint := '在页面中查找';
  FEdit.OnChange := EditChanged;
  FEdit.OnKeyDown := EditKeyDown;
  FEdit.OnEnter := EditEnter;
  FEdit.OnExit := EditExit;

  FBtnPrev := TFHNavButton.Create(Self);
  FBtnPrev.Parent := Self;
  FBtnPrev.ButtonType := nbtChevronUp;
  FBtnPrev.BackColor := clWhite;
  FBtnPrev.Hint := '上一个';
  FBtnPrev.ShowHint := True;
  FBtnPrev.TabStop := False;
  FBtnPrev.OnClick := BtnPrevClick;

  FBtnNext := TFHNavButton.Create(Self);
  FBtnNext.Parent := Self;
  FBtnNext.ButtonType := nbtChevronDown;
  FBtnNext.BackColor := clWhite;
  FBtnNext.Hint := '下一个';
  FBtnNext.ShowHint := True;
  FBtnNext.TabStop := False;
  FBtnNext.OnClick := BtnNextClick;

  FBtnClose := TFHNavButton.Create(Self);
  FBtnClose.Parent := Self;
  FBtnClose.ButtonType := nbtStop;
  FBtnClose.BackColor := clWhite;
  FBtnClose.Hint := '关闭';
  FBtnClose.ShowHint := True;
  FBtnClose.TabStop := False;
  FBtnClose.OnClick := BtnCloseClick;

  FBtnCase := TFHNavButton.Create(Self);
  FBtnCase.Parent := Self;
  FBtnCase.ButtonType := nbtMatchCase;
  FBtnCase.BackColor := clWhite;
  FBtnCase.Hint := '区分大小写';
  FBtnCase.ShowHint := True;
  FBtnCase.TabStop := False;
  FBtnCase.OnClick := BtnCaseClick;
  FBtnCase.Visible := False;

  FMatchCount := 0;
  FActiveMatch := 0;
  FResultReady := False;
  FBtnPrev.Enabled := False;
  FBtnNext.Enabled := False;
end;

{ 96 DPI 基准逻辑像素 → 当前 DPI 实际像素 }
function TFHFindBar.Px(V: Integer): Integer;
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

{ 取父控件背景色（查找条外圈透出父底色, 用 RTTI 读父的 Color） }
function TFHFindBar.ParentBackColor: TColor;
var
  Prop: PPropInfo;
begin
  Result := clWhite;
  if Parent = nil then Exit;
  Prop := GetPropInfo(Parent, 'Color');
  if (Prop <> nil) and (Prop^.PropType^.Kind = tkInteger) then
    Result := TColor(GetOrdProp(Parent, Prop));
end;

{ 搜索框矩形（含放大镜图标区, 不含右侧计数与三个按钮） }
function TFHFindBar.SearchBoxRect: TRect;
var
  Btn, Pad, BoxH, Counter, Gap, ButtonsLeft, BoxTop: Integer;
begin
  Btn := Px(24);
  Pad := Px(8);
  BoxH := Px(28);
  Counter := Px(46);
  Gap := 0;
  ButtonsLeft := Width - Pad - 3 * Btn - 2 * Gap;
  BoxTop := (Height - BoxH) div 2;
  Result := Rect(Pad, BoxTop, ButtonsLeft - Counter - Px(4), BoxTop + BoxH);
end;

{ 是否处于"有搜索词但零匹配"态（输入框与计数转红的条件） }
function TFHFindBar.HasNoMatch: Boolean;
begin
  Result := FResultReady and (SearchText <> '') and (FMatchCount = 0);
end;

{ 计数文本 "当前/总数"; 结果未就绪时返回空 }
function TFHFindBar.MatchesText: string;
begin
  if not FResultReady then
    Exit('');
  Result := Format('%d/%d', [FActiveMatch, FMatchCount]);
end;

{ 按当前 DPI 固定输入框字号（13px 逻辑值） }
procedure TFHFindBar.PinEditFont;
var
  PPI: Integer;
begin
  if FEdit = nil then Exit;
  PPI := Px(96);
  FEdit.Font.PixelsPerInch := PPI;
  FEdit.Font.Height := -MulDiv(13, PPI, 96);
end;

{ 重排子控件: 右侧三个按钮贴右缘, 输入框落在搜索框内（避开放大镜区） }
procedure TFHFindBar.LayoutChildren;
var
  Btn, Pad, BoxH, Gap, BoxTop, BtnTop, BoxLeft, BoxRight, EditW: Integer;
  R: TRect;
begin
  if (FEdit = nil) or (Width <= 0) or (Height <= 0) then Exit;
  Btn := Px(24);
  Pad := Px(8);
  BoxH := Px(28);
  Gap := 0;
  BoxTop := (Height - BoxH) div 2;
  BtnTop := BoxTop + (BoxH - Btn) div 2;

  FBtnClose.SetBounds(Width - Pad - Btn, BtnTop, Btn, Btn);
  FBtnNext.SetBounds(Width - Pad - 2 * Btn - Gap, BtnTop, Btn, Btn);
  FBtnPrev.SetBounds(Width - Pad - 3 * Btn - 2 * Gap, BtnTop, Btn, Btn);

  PinEditFont;
  R := SearchBoxRect;
  BoxLeft := R.Left;
  BoxRight := R.Right;
  EditW := BoxRight - BoxLeft - Px(26) - Px(8);
  if EditW < Px(40) then
    EditW := Px(40);
  FEdit.SetBounds(BoxLeft + Px(26), BoxTop + Px(4),
    EditW, BoxH - Px(8));
end;

procedure TFHFindBar.AlignToTopRight;
var
  MaxW: Integer;
begin
  if Parent = nil then Exit;
  MaxW := Parent.ClientWidth - 2 * Px(8);
  if MaxW < Px(200) then
    MaxW := Px(200);
  if Width > MaxW then
    Width := MaxW;
  Left := Parent.ClientWidth - Width - Px(8);
  if Left < Px(8) then
    Left := Px(8);
  Top := Px(8);
  LayoutChildren;
end;

{ 焦点交给输入框并全选当前文本（再次 Ctrl+F 便于直接覆盖输入） }
procedure TFHFindBar.FocusSearch;
begin
  if FEdit.CanFocus then
    FEdit.SetFocus;
  FEdit.SelectAll;
end;

{ 当前搜索词 }
function TFHFindBar.SearchText: string;
begin
  if FEdit = nil then
    Result := ''
  else
    Result := FEdit.Text;
end;

procedure TFHFindBar.SetResult(ACount, AActive: Integer);
begin
  FResultReady := True;
  FBtnPrev.Enabled := ACount > 0;
  FBtnNext.Enabled := ACount > 0;
  if (FMatchCount = ACount) and (FActiveMatch = AActive) then
    Exit;
  FMatchCount := ACount;
  FActiveMatch := AActive;
  Invalidate;
end;

{ "区分大小写"按钮当前态 }
function TFHFindBar.GetMatchCase: Boolean;
begin
  Result := (FBtnCase <> nil) and FBtnCase.Checked;
end;

{ 输入变化: 清旧计数并触发宿主 OnSearch（输入即查） }
procedure TFHFindBar.EditChanged(Sender: TObject);
begin
  FResultReady := False;
  FMatchCount := 0;
  FActiveMatch := 0;
  Invalidate;
  if Assigned(FOnSearch) then
    FOnSearch(Self);
end;

{ 输入框按键: Enter/F3 下一个, Shift+Enter/Shift+F3 上一个, Esc 关闭 }
procedure TFHFindBar.EditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  case Key of
    VK_RETURN:
      begin
        Key := 0;
        if ssShift in Shift then
        begin
          if Assigned(FOnFindPrev) then FOnFindPrev(Self);
        end
        else if Assigned(FOnFindNext) then
          FOnFindNext(Self);
      end;
    VK_ESCAPE:
      begin
        Key := 0;
        if Assigned(FOnClose) then FOnClose(Self);
      end;
    VK_F3:
      begin
        Key := 0;
        if ssShift in Shift then
        begin
          if Assigned(FOnFindPrev) then FOnFindPrev(Self);
        end
        else if Assigned(FOnFindNext) then
          FOnFindNext(Self);
      end;
  end;
end;

{ 输入框获得焦点: 记录态并重绘（搜索框换白底蓝框） }
procedure TFHFindBar.EditEnter(Sender: TObject);
begin
  FFocused := True;
  Invalidate;
end;

{ 输入框失去焦点: 记录态并重绘（搜索框回灰底无边框） }
procedure TFHFindBar.EditExit(Sender: TObject);
begin
  FFocused := False;
  Invalidate;
end;

{ "上一个"按钮: 触发 OnFindPrev 后焦点回输入框 }
procedure TFHFindBar.BtnPrevClick(Sender: TObject);
begin
  if Assigned(FOnFindPrev) then
    FOnFindPrev(Self);
  if FEdit.CanFocus then
    FEdit.SetFocus;
end;

{ "下一个"按钮: 触发 OnFindNext 后焦点回输入框 }
procedure TFHFindBar.BtnNextClick(Sender: TObject);
begin
  if Assigned(FOnFindNext) then
    FOnFindNext(Self);
  if FEdit.CanFocus then
    FEdit.SetFocus;
end;

{ "区分大小写"按钮: 切换选中态并重新发起查找 }
procedure TFHFindBar.BtnCaseClick(Sender: TObject);
begin
  FBtnCase.Checked := not FBtnCase.Checked;
  FResultReady := False;
  Invalidate;
  if Assigned(FOnSearch) then
    FOnSearch(Self);
  if FEdit.CanFocus then
    FEdit.SetFocus;
end;

{ "关闭"按钮: 触发 OnClose（宿主负责隐藏并清页面高亮） }
procedure TFHFindBar.BtnCloseClick(Sender: TObject);
begin
  if Assigned(FOnClose) then
    FOnClose(Self);
end;

{ 画整条白色圆角卡片底 + 灰边框; GDI+ 不可用回退 GDI }
procedure TFHFindBar.DrawCard;
var
  G: TGPGraphics;
  Path: TGPGraphicsPath;
  Brush: TGPSolidBrush;
  Pen: TGPPen;
  R: TRect;
begin
  R := ClientRect;
  G := MakeGraphics(Canvas);
  if G = nil then
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := clWhite;
    Canvas.Pen.Color := TColor($E0DCDA);
    Canvas.Pen.Width := 1;
    Canvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, Px(16), Px(16));
    Exit;
  end;
  Path := RoundRectPath(R, Px(8));
  try
    Brush := TGPSolidBrush.Create(ColorToARGB(clWhite));
    try
      G.FillPath(Brush, Path);
    finally
      Brush.Free;
    end;
    Pen := TGPPen.Create(ColorToARGB(TColor($E0DCDA)), 1);   // #DADCE0
    try
      G.DrawPath(Pen, Path);
    finally
      Pen.Free;
    end;
  finally
    Path.Free;
    G.Free;
  end;
end;

{ 画搜索框: 灰底/聚焦白底蓝框/零匹配红框三态 + 左侧放大镜图标 }
procedure TFHFindBar.DrawSearchBox;
var
  R: TRect;
  Fill, Border: TColor;
  PenW, Rd, CX, CY, Hx, Hy, Lx, Ly: Integer;
  G: TGPGraphics;

  Pen: TGPPen;
  NeedBorder: Boolean;
  NoMatch: Boolean;
begin
  R := SearchBoxRect;
  NoMatch := HasNoMatch;
  NeedBorder := FFocused or NoMatch;
  if NoMatch then
    Border := TColor($2530D9)          // #D93025
  else
    Border := TColor($E8731A);         // #1A73E8
  if FFocused then
    Fill := clWhite
  else
    Fill := TColor($F4F3F1);           // #F1F3F4
  PenW := Px(2);

  if NeedBorder then
    DrawRoundRect(Canvas, R, Px(6), Fill, Border, PenW)
  else
    DrawRoundRect(Canvas, R, Px(6), Fill, Border, 0);

  FEdit.Color := Fill;

  Rd := Px(4);
  CX := R.Left + Px(13);
  CY := (R.Top + R.Bottom) div 2 - Px(1);
  Lx := CX + Px(3);
  Ly := CY + Px(3);
  Hx := Px(4);
  Hy := Px(4);

  G := MakeGraphics(Canvas);
  if G <> nil then
  try
    Pen := TGPPen.Create(ColorToARGB(TColor($68635F)), Px(1) + 0.5);
    try
      G.DrawEllipse(Pen, CX - Rd, CY - Rd, 2 * Rd, 2 * Rd);
      G.DrawLine(Pen, Lx, Ly, Lx + Hx, Ly + Hy);
    finally
      Pen.Free;
    end;
  finally
    G.Free;
  end
  else
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Color := TColor($68635F);
    Canvas.Pen.Width := 1;
    Canvas.Ellipse(CX - Rd, CY - Rd, CX + Rd, CY + Rd);
    Canvas.MoveTo(Lx, Ly);
    Canvas.LineTo(Lx + Hx, Ly + Hy);
  end;
end;

{ 全件自绘: 父底色清场 → 卡片 → 搜索框 → 匹配计数文字（零匹配转红） }
procedure TFHFindBar.Paint;
var
  R: TRect;
  S: string;
  TW, X, Y, ButtonsLeft: Integer;
begin
  R := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := ParentBackColor;
  Canvas.Pen.Color := Canvas.Brush.Color;
  Canvas.FillRect(R);

  DrawCard;
  DrawSearchBox;

  S := MatchesText;
  if S <> '' then
  begin

    ButtonsLeft := Width - Px(8) - 3 * Px(24);
    Canvas.Brush.Style := bsClear;
    Canvas.Font := Self.Font;
    Canvas.Font.PixelsPerInch := Px(96);
    Canvas.Font.Height := -Px(12);
    if HasNoMatch then
      Canvas.Font.Color := TColor($2530D9)     // #D93025
    else
      Canvas.Font.Color := TColor($68635F);    // #5F6368
    TW := Canvas.TextWidth(S);
    X := ButtonsLeft - Px(6) - TW;
    Y := (Height - Canvas.TextHeight(S)) div 2;
    Canvas.TextOut(X, Y, S);
  end;
end;

{ 尺寸变化: 重排子控件并重绘 }
procedure TFHFindBar.Resize;
begin
  inherited;
  LayoutChildren;
  Invalidate;
end;

{ 句柄创建后: 重排子控件（DPI 此时才可查） }
procedure TFHFindBar.CreateWnd;
begin
  inherited CreateWnd;
  LayoutChildren;
end;

{ DPI 变化（跨屏）: 重排子控件并重绘 }
procedure TFHFindBar.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  LayoutChildren;
  Invalidate;
end;

{ 鼠标点搜索框区域: 焦点交给输入框（点图标区也能进入输入） }
procedure TFHFindBar.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if PtInRect(SearchBoxRect, Point(X, Y)) and FEdit.CanFocus then
    FEdit.SetFocus;
end;

{ 控件级按键: Esc 关闭（输入框外的 Esc 在此处理） }
procedure TFHFindBar.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited;
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    if Assigned(FOnClose) then
      FOnClose(Self);
  end;
end;

end.