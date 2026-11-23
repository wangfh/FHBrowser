{==============================================================================
  单元: uFHBrowsingDataDlg
  ----------------------------------------------------------------------------
  职责: 弹出 Chrome 风格对话框让用户选择要清除的浏览数据类型和时间范围，
        返回勾选结果。纯 UI 单元，不做实际清理（清理逻辑在
        uBrowserMain.DoClearBrowsingData）。

  UI: 与设置对话框同一套自绘控件（uFHChromeWidgets）——
      白底 + 大标题 + 分隔线 + 14px 行文字 + 12px 说明,
      时间范围为圆角下拉框, 数据类型为方型复选（选中蓝底白勾）,
      底部"取消"（文字按钮）/"清除数据"（蓝底胶囊主按钮, 无勾选时禁用）。
      "浏览历史"和"表单数据"在即时清理模式下无法清理（CEF 运行时占用磁盘
      SQLite 文件），默认不勾选并标注"需重启"。时间范围对下载记录生效
      （按 StartTime 过滤）；Cookie 和缓存因 CEF API 限制只能全部清除。
==============================================================================}
unit uFHBrowsingDataDlg;

interface

uses
  System.Classes, System.SysUtils, System.Math,
  Winapi.Windows, Winapi.Messages,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  uFHDpi, uFHChromeWidgets;

type
  TFHBrowsingDataOption = (bdoHistory, bdoCookies, bdoCache, bdoFormData, bdoDownloads);
  TFHBrowsingDataOptions = set of TFHBrowsingDataOption;

  { 时间范围（Chrome 同款5档） }
  TFHBrowsingTimeRange = (btrLastHour, btrLast24Hours, btrLast7Days, btrLast4Weeks, btrAllTime);

  TFHBrowsingDataDlg = class(TForm)
  private

    FCloseHot: Boolean;              // 鼠标悬停在标题栏关闭按钮上
    FSegTimeRange: TFHSegmented;
    FChkHistory: TFHCheckBox;
    FChkCookies: TFHCheckBox;
    FChkCache: TFHCheckBox;
    FChkFormData: TFHCheckBox;
    FChkDownloads: TFHCheckBox;
    FBtnClear: TFHFlatButton;
    FBtnCancel: TFHFlatButton;

    function ScaleCaptionY(P: Integer): Integer;
    function CaptionH: Integer;
    function CloseBtnRect: TRect;
    function NewLabel(const ACaption: string; X, Y, W, H, APx: Integer;
      ABold: Boolean; AColor: TColor): TLabel;
    procedure NewDivider(Y: Integer);
    procedure PinLabelFont(ALabel: TLabel; APx: Integer; ABold: Boolean;
      AColor: TColor);
    procedure BuildUi;
    procedure AnyCheckClick(Sender: TObject);
    procedure UpdateClearButton;
    procedure DoClear(Sender: TObject);
    procedure DoCancel(Sender: TObject);
    procedure DlgKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormPaint(Sender: TObject);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
    procedure WMNCCalcSize(var Message: TWMNCCalcSize); message WM_NCCALCSIZE;
    procedure WMNCActivate(var Message: TWMNCActivate); message WM_NCACTIVATE;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure WndProc(var Message: TMessage); override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    function SelectedOptions: TFHBrowsingDataOptions;
    function SelectedTimeRange: TFHBrowsingTimeRange;
  end;

{ 弹出清除浏览数据对话框。
  True = 用户点了"清除数据"；AOptions 返回勾选类型，ATimeRange 返回时间范围 }
function ShowBrowsingDataDlg(out AOptions: TFHBrowsingDataOptions;
  out ATimeRange: TFHBrowsingTimeRange): Boolean;

{ 把时间范围换算成"截止时间点"（仅在此时间点之后的数据才删）。
  btrAllTime → 0（远古）；其余 → Now - 对应时长 }
function BrowsingTimeRangeSince(ATimeRange: TFHBrowsingTimeRange): TDateTime;

implementation

const
  { ---- 布局（96 DPI 逻辑坐标） ---- }
  C_DLG_W     = 520;
  C_DLG_H     = 424;              // 44px 自绘标题栏 + 380px 内容
  C_MARGIN    = 32;
  C_CONTENT_W = C_DLG_W - C_MARGIN * 2;
  C_ROW_STEP  = 30;          // 复选行行距
  { 弹窗边框线（Chrome 灰 #DADCE0, 与历史记录/下载内容窗口一致） }
  C_DL_EDGE   = TColor($E0DCDA);
  { 底部提示文案（FormPaint 自绘 DT_WORDBREAK 两行; TLabel.WordWrap 实测不换行） }
  C_HINT_TEXT = '提示：表单数据需重启程序才能清理，将跳过。时间范围对浏览历史' +
    '与下载记录生效，Cookie 和缓存将全部清除。';

function ShowBrowsingDataDlg(out AOptions: TFHBrowsingDataOptions;
  out ATimeRange: TFHBrowsingTimeRange): Boolean;
var
  Dlg: TFHBrowsingDataDlg;
begin
  Dlg := TFHBrowsingDataDlg.CreateNew(Application);
  try
    Result := Dlg.ShowModal = mrOk;
    if Result then
    begin
      AOptions    := Dlg.SelectedOptions;
      ATimeRange  := Dlg.SelectedTimeRange;
    end
    else
    begin
      AOptions   := [];
      ATimeRange := btrAllTime;
    end;
  finally
    Dlg.Free;
  end;
end;

function BrowsingTimeRangeSince(ATimeRange: TFHBrowsingTimeRange): TDateTime;
begin
  case ATimeRange of
    btrLastHour:     Result := Now - 1  / HoursPerDay;          // 过去1小时
    btrLast24Hours:  Result := Now - 1;                          // 过去24小时（1天）
    btrLast7Days:    Result := Now - 7;                          // 过去7天
    btrLast4Weeks:   Result := Now - 28;                         // 过去4周
  else
    Result := 0;                                                 // 全部时间
  end;
end;

{ 构造: 配置无边框 Chrome 弹窗四件套并构建 UI（坐标全部按屏幕 DPI 换算） }
constructor TFHBrowsingDataDlg.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  { 与设置对话框一致: 关闭 VCL 自动缩放, 坐标/字号全部手动按屏幕 DPI 换算 }
  Scaled := False;

  Caption := '清除浏览数据';
  { 无边框 Chrome 弹窗（参考历史记录窗口四件套: WS_POPUP + 吞 NCCALCSIZE
    + 自绘 1px 边框线 + NCACTIVATE 哨兵, docs\01_UI开发规范.md 6~9 条）;
    bsSizeable 仅为保留 WS_THICKFRAME（边缘八向调整大小） }
  BorderStyle := bsSizeable;
  BorderIcons := [];
  Position := poScreenCenter;
  Color := FH_BG;
  ClientWidth := FHScalePx(C_DLG_W);
  ClientHeight := FHScalePx(C_DLG_H);      // C_DLG_H 已含 44px 自绘标题栏
  DoubleBuffered := True;
  OnPaint := FormPaint;
  OnMouseDown := FormMouseDown;
  OnMouseMove := FormMouseMove;
  KeyPreview := True;
  OnKeyDown := DlgKeyDown;
  BuildUi;
end;


{ 内容区 y → 客户区 y: 内容布局仍按"标题栏下方"的 96 DPI 逻辑坐标书写,
  统一在此偏移自绘标题栏高度 }
function TFHBrowsingDataDlg.ScaleCaptionY(P: Integer): Integer;
begin
  Result := FHScalePx(P) + CaptionH();
end;

{ 统一设置标签字体: Segoe UI + 指定像素字号/加粗/颜色, 透明底 }
procedure TFHBrowsingDataDlg.PinLabelFont(ALabel: TLabel; APx: Integer;
  ABold: Boolean; AColor: TColor);
var
  PPI: Integer;
begin
  PPI := FHScalePx(96);
  if PPI <= 0 then
    PPI := 96;
  ALabel.Font.Name := 'Segoe UI';
  ALabel.Font.PixelsPerInch := PPI;
  ALabel.Font.Height := -MulDiv(APx, PPI, 96);
  if ABold then
    ALabel.Font.Style := [fsBold]
  else
    ALabel.Font.Style := [];
  ALabel.Font.Color := AColor;
  ALabel.Transparent := True;
  ALabel.AutoSize := False;
end;

{ 新建一个标签（坐标为 96 DPI 逻辑值, 内部换算） }
function TFHBrowsingDataDlg.NewLabel(const ACaption: string;
  X, Y, W, H, APx: Integer; ABold: Boolean; AColor: TColor): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(FHScalePx(X), ScaleCaptionY(Y), FHScalePx(W), FHScalePx(H));
  Result.Caption := ACaption;
  Result.Layout := tlTop;
  PinLabelFont(Result, APx, ABold, AColor);
end;

{ 在指定 y 画一条全宽 1px 分隔线（用 TPanel 实现） }
procedure TFHBrowsingDataDlg.NewDivider(Y: Integer);
var
  Sep: TPanel;
begin
  Sep := TPanel.Create(Self);
  Sep.Parent := Self;
  Sep.SetBounds(FHScalePx(C_MARGIN), ScaleCaptionY(Y), FHScalePx(C_CONTENT_W), 1);
  Sep.BevelOuter := bvNone;
  Sep.Color := FH_DIVIDER;
end;

{ 构建内容区: 时间范围分段选择 + 五类数据复选 + 底部按钮（布局见体内注释） }
procedure TFHBrowsingDataDlg.BuildUi;
var
  Y: Integer;


  function MakeCheck(const ACaption: string; AChecked: Boolean;
    AY: Integer): TFHCheckBox;
  begin
    Result := TFHCheckBox.Create(Self);
    Result.Parent := Self;
    Result.Text := ACaption;
    Result.Checked := AChecked;
    Result.SetBounds(FHScalePx(C_MARGIN), ScaleCaptionY(AY),
      FHScalePx(C_CONTENT_W), FHScalePx(24));
    Result.OnChange := AnyCheckClick;
  end;

begin
  { 大标题"清除浏览数据"已移入 44px 自绘标题栏（FormPaint 画）;
    内容区从"时间范围"直接开始 }

  { ---- 时间范围 ---- }
  NewLabel('时间范围', C_MARGIN, 24, C_CONTENT_W, 20, 14, False, FH_TEXT);
  { 分段选择（全宽 5 段）: 全自绘, 不再内嵌系统下拉框 —— 原"外框 + 系统
    ComboBox 自带边框/箭头"会叠成两层框的观感 }
  FSegTimeRange := TFHSegmented.Create(Self);
  FSegTimeRange.Parent := Self;
  FSegTimeRange.SetBounds(FHScalePx(C_MARGIN), ScaleCaptionY(48),
    FHScalePx(C_CONTENT_W), FHScalePx(32));
  FSegTimeRange.Items.Add('过去1小时');
  FSegTimeRange.Items.Add('过去24小时');
  FSegTimeRange.Items.Add('过去7天');
  FSegTimeRange.Items.Add('过去4周');
  FSegTimeRange.Items.Add('全部时间');
  FSegTimeRange.ItemIndex := 4;      // 默认"全部时间"（Chrome 同款默认）

  NewDivider(94);

  { ---- 数据类型复选（Chrome 顺序：历史/Cookie/缓存/表单/下载） ---- }
  Y := 106;
  FChkHistory := MakeCheck('浏览历史', True, Y);
  Inc(Y, C_ROW_STEP);
  FChkCookies := MakeCheck('Cookie 及其他网站数据', True, Y);
  Inc(Y, C_ROW_STEP);
  FChkCache := MakeCheck('缓存的图片和文件', True, Y);
  Inc(Y, C_ROW_STEP);
  FChkFormData := MakeCheck('表单数据和自动填充（需重启程序才能清理）', False, Y);
  Inc(Y, C_ROW_STEP);
  FChkDownloads := MakeCheck('下载记录（仅清列表，不删已下载文件）', True, Y);

  { ---- 提示（12px 两行）: 不用 TLabel —— WordWrap 实测不换行,
    文案与绘制移入 FormPaint（DrawText DT_WORDBREAK 自绘, 区域 Y 260~300） ---- }

  { ---- 底部按钮 ---- }
  NewDivider(308);

  FBtnCancel := TFHFlatButton.Create(Self);
  FBtnCancel.Parent := Self;
  FBtnCancel.ButtonStyle := fbsText;
  FBtnCancel.Caption := '取消';
  FBtnCancel.SetBounds(FHScalePx(C_DLG_W - C_MARGIN - 96 - 8 - 76), ScaleCaptionY(320),
    FHScalePx(76), FHScalePx(32));
  FBtnCancel.OnClick := DoCancel;

  FBtnClear := TFHFlatButton.Create(Self);
  FBtnClear.Parent := Self;
  FBtnClear.ButtonStyle := fbsPrimary;
  FBtnClear.Caption := '清除数据';
  FBtnClear.SetBounds(FHScalePx(C_DLG_W - C_MARGIN - 96), ScaleCaptionY(320),
    FHScalePx(96), FHScalePx(32));
  FBtnClear.OnClick := DoClear;

  UpdateClearButton;
end;

{ 任一复选状态变化: 刷新"清除数据"按钮可用态 }
procedure TFHBrowsingDataDlg.AnyCheckClick(Sender: TObject);
begin
  UpdateClearButton;
end;

{ "清除数据"按钮可用态: 至少勾选一项才允许清除 }
procedure TFHBrowsingDataDlg.UpdateClearButton;
begin
  { 至少勾一项才允许清除（禁用态由 TFHFlatButton 自绘为浅灰底灰字） }
  FBtnClear.Enabled := FChkHistory.Checked or FChkCookies.Checked or
    FChkCache.Checked or FChkFormData.Checked or FChkDownloads.Checked;
end;

{ "清除数据"按钮: 以 mrOk 关闭对话框 }
procedure TFHBrowsingDataDlg.DoClear(Sender: TObject);
begin
  if FBtnClear.Enabled then
    ModalResult := mrOk;
end;

{ "取消"按钮: 以 mrCancel 关闭对话框 }
procedure TFHBrowsingDataDlg.DoCancel(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

{ 键盘: Esc = 取消; 回车 = 清除（与按钮同样受"至少勾一项"约束） }
procedure TFHBrowsingDataDlg.DlgKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  { Esc = 取消; 回车 = 清除（与"清除数据"按钮同样受"至少勾一项"约束） }
  if Key = VK_ESCAPE then
  begin
    ModalResult := mrCancel;
    Key := 0;
  end
  else if (Key = VK_RETURN) and FBtnClear.Enabled then
  begin
    ModalResult := mrOk;
    Key := 0;
  end;
end;

{ 收集勾选的数据类型集合 }
function TFHBrowsingDataDlg.SelectedOptions: TFHBrowsingDataOptions;
begin
  Result := [];
  if FChkHistory.Checked   then Include(Result, bdoHistory);
  if FChkCookies.Checked   then Include(Result, bdoCookies);
  if FChkCache.Checked     then Include(Result, bdoCache);
  if FChkFormData.Checked  then Include(Result, bdoFormData);
  if FChkDownloads.Checked then Include(Result, bdoDownloads);
end;

{ 分段选择当前项 → 时间范围枚举 }
function TFHBrowsingDataDlg.SelectedTimeRange: TFHBrowsingTimeRange;
begin
  case FSegTimeRange.ItemIndex of
    0:  Result := btrLastHour;
    1:  Result := btrLast24Hours;
    2:  Result := btrLast7Days;
    3:  Result := btrLast4Weeks;
  else
    Result := btrAllTime;
  end;
end;

{ ---- 无边框四件套（参考历史记录窗口, docs\01_UI开发规范.md 第 6~9 条） ---- }

{ 无边框: 去 WS_CAPTION/WS_SYSMENU 保留 WS_THICKFRAME; 必须 or WS_POPUP ——
  user32 对带 WS_THICKFRAME 的非 popup 顶层窗口会在 CreateWindowEx 内部
  强制补回 WS_CAPTION（规范第 7 条） }
procedure TFHBrowsingDataDlg.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := (Params.Style or WS_POPUP) and (not WS_CAPTION)
    and (not WS_SYSMENU);
end;

{ 标题栏高度（自绘, 96 DPI 基准 44px） }
function TFHBrowsingDataDlg.CaptionH: Integer;
begin
  Result := FHScalePx(44);
end;

{ 标题栏右上角关闭按钮: 32x32, 距右 8px, 垂直居中于标题栏 }
function TFHBrowsingDataDlg.CloseBtnRect: TRect;
var
  Btn: Integer;
begin
  Btn := FHScalePx(32);
  Result := Rect(ClientWidth - FHScalePx(40), (CaptionH() - Btn) div 2,
    ClientWidth - FHScalePx(40) + Btn, (CaptionH() + Btn) div 2);
end;

{ 边缘 resize 优先采用系统结果; 标题栏空白区 → HTCAPTION（拖动）;
  关闭按钮留 HTCLIENT 走鼠标事件 }
procedure TFHBrowsingDataDlg.WMNCHitTest(var Message: TWMNCHitTest);
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
procedure TFHBrowsingDataDlg.WMNCCalcSize(var Message: TWMNCCalcSize);
begin
  if Message.CalcValidRects then
    Message.Result := 0
  else
    inherited;
end;

{ 失活不重绘 NC（规范第 9 条: 否则弹菜单等弹窗时窗口边缘出现缝隙） }
procedure TFHBrowsingDataDlg.WMNCActivate(var Message: TWMNCActivate);
begin
  Message.Unused := -1;
  inherited;
end;

{ 双击标题栏: 不做最大化/还原（对话框语义, 与 Chrome 清除数据弹窗一致） }
procedure TFHBrowsingDataDlg.WndProc(var Message: TMessage);
begin
  if (Message.Msg = WM_NCLBUTTONDBLCLK) and (Message.WParam = HTCAPTION) then
    Exit;
  inherited WndProc(Message);
end;

{ 鼠标离开窗体: 清关闭按钮悬停态并重绘 }
procedure TFHBrowsingDataDlg.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FCloseHot := False;
  Invalidate;
end;

{ 标题栏自绘: 白底 + 四周 1px 边框线 + 底部分隔线 + 左侧标题
  + 右上角关闭按钮 ×（悬停浅灰圆角底 + 深色） }
procedure TFHBrowsingDataDlg.FormPaint(Sender: TObject);
var
  R: TRect;
  PW, CX, CY, D: Integer;
  Clr: TColor;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Style := psClear;
  Canvas.FillRect(Rect(0, 0, ClientWidth, CaptionH()));

  { 标题文字（左侧垂直居中） }
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.PixelsPerInch := FHScalePx(96);
  Canvas.Font.Height := -FHScalePx(20);
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := FH_TEXT;
  R := Rect(FHScalePx(16), 0, ClientWidth - FHScalePx(220), CaptionH());
  Winapi.Windows.DrawText(Canvas.Handle, '清除浏览数据', 6, R,
    DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_NOPREFIX);

  { 四周 1px 边框线（吞 NCCALCSIZE 后系统不再画任何非客户区边框） }
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := C_DL_EDGE;
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

  { 底部提示（12px 灰字, DT_WORDBREAK 自动两行; GDI 直调绕开 TLabel.WordWrap） }
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.PixelsPerInch := FHScalePx(96);
  Canvas.Font.Height := -FHScalePx(12);
  Canvas.Font.Style := [];
  Canvas.Font.Color := FH_TEXT2;
  SetBkMode(Canvas.Handle, TRANSPARENT);
  R := Rect(FHScalePx(C_MARGIN), ScaleCaptionY(260),
    FHScalePx(C_MARGIN + C_CONTENT_W), ScaleCaptionY(300));
  Winapi.Windows.DrawText(Canvas.Handle, C_HINT_TEXT, Length(C_HINT_TEXT), R,
    DT_WORDBREAK or DT_LEFT or DT_NOPREFIX);

  { 关闭按钮 ×: 悬停浅灰圆角底 + ×（GDI+ 抗锯齿, 失败回退 GDI） }
  R := CloseBtnRect();
  if FCloseHot then
    FillRoundRectAA(Canvas, R.Left, R.Top, R.Right, R.Bottom, FHScalePx(8),
      FH_HOVER_GRAY, FH_HOVER_GRAY, 0);
  D := FHScalePx(10);
  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  if FCloseHot then
    Clr := FH_TEXT
  else
    Clr := FH_TEXT2;
  PW := Max(1, FHScalePx(1));
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

{ 鼠标按下: 命中关闭按钮则以 mrCancel 关闭对话框 }
procedure TFHBrowsingDataDlg.FormMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  if PtInRect(CloseBtnRect(), Point(X, Y)) then
  begin
    FCloseHot := False;
    ModalResult := mrCancel;
    Exit;
  end;
end;

{ 鼠标移动: 跟踪关闭按钮悬停态, 变化时重绘 }
procedure TFHBrowsingDataDlg.FormMouseMove(Sender: TObject; Shift: TShiftState;
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

end.