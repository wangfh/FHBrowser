{==============================================================================
  单元: uFHSettingsDlg
  职责: "设置"对话框（Chrome 设置页风格, 纯代码 BuildUi）。
        编辑项:
        1. 浏览器首页
        2. 新标签页: 打开指定网址 / 打开空白页
        3. 下载文件前询问保存位置（默认是）+ 默认下载位置
        4. 启用 GPU 加速（默认不启用; CEF 启动参数, 需重启浏览器生效）

  UI: 自绘控件与配色来自 uFHChromeWidgets（开关/单选/圆角输入框/胶囊按钮,
      GDI+ 抗锯齿）。布局 96 DPI 基准, 运行时按屏幕 DPI 手动换算;
      Scaled := False 关闭 VCL 自动缩放, 避免双重放大。
==============================================================================}
unit uFHSettingsDlg;

interface

uses
  System.Classes, System.SysUtils, System.Math,
  Winapi.Windows, Winapi.Messages,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  Vcl.Dialogs, Vcl.FileCtrl,
  uFHDpi, uFHChromeWidgets, uFHSettings;

type
  TFHSettingsDlg = class(TForm)
  private

    FCloseHot: Boolean;              // 鼠标悬停在标题栏关闭按钮上
    FEdtHomepage: TFHFlatEdit;
    FRadNewTabUrl: TFHRadioDot;
    FRadNewTabBlank: TFHRadioDot;
    FEdtNewTabUrl: TFHFlatEdit;
    FSwAskSave: TFHToggleSwitch;
    FEdtDlDir: TFHFlatEdit;
    FBtnBrowseDl: TFHFlatButton;
    FSwGPU: TFHToggleSwitch;
    FBtnSave: TFHFlatButton;
    FBtnCancel: TFHFlatButton;

    function ScaleCaptionY(P: Integer): Integer;
    function CaptionH: Integer;
    function CloseBtnRect: TRect;
    function NewLabel(const ACaption: string; X, Y, W, H, APx: Integer;
      ABold: Boolean; AColor: TColor): TLabel;
    procedure NewDivider(Y: Integer);
    procedure NewGroupTitle(const ATitle, ADesc: string; Y: Integer);
    procedure PinLabelFont(ALabel: TLabel; APx: Integer; ABold: Boolean;
      AColor: TColor);
    procedure BuildUi;
    procedure FillFromSettings;
    procedure ApplyToSettings;
    procedure NewTabModeChange(Sender: TObject);
    procedure UpdateNewTabUrlEnabled;
    procedure BrowseDlDir(Sender: TObject);
    procedure DoSave(Sender: TObject);
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
  end;

{ 弹出设置对话框。True = 用户点了"保存"（设置已写回并持久化） }
function ShowSettingsDlg: Boolean;

implementation

uses
  uLogger;

const
  { ---- 布局（96 DPI 逻辑坐标; 内容区 y 从标题栏下起算, ScaleCaptionY 补 44px 标题栏） ---- }
  C_DLG_W       = 520;
  C_DLG_H       = 578;            // 44px 自绘标题栏 + 534px 内容
                                        // （2026-11-18 两轮收紧: 首组距标题栏
                                        //  12px, 与书签/历史窗口内容首元素
                                        //  间隙统一; 原 70px 观感太远）
  C_MARGIN      = 32;
  C_CONTENT_W   = C_DLG_W - C_MARGIN * 2;
  { 弹窗边框线（Chrome 灰 #DADCE0, 与历史记录/下载/清除数据窗口一致） }
  C_DL_EDGE     = TColor($E0DCDA);

{ ============================ TFHSettingsDlg ============================== }

{ 构造: 关闭 VCL 自动缩放, 配置无边框 Chrome 弹窗四件套, 构建 UI 并回填当前设置 }
constructor TFHSettingsDlg.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  { 关键: 关闭 VCL 自动按 PixelsPerInch 缩放 —— 本对话框所有坐标/字号已由
    uFHDpi.FHFHScalePx(屏幕 DPI) 手动换算, 再让 VCL 缩放一次就是双重放大（高 DPI 下
    控件错位、按钮/输入框尺寸与绘制不一致） }
  Scaled := False;
  Caption := '设置';
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
  FillFromSettings;
end;


{ 内容区 y → 客户区 y: 内容布局仍按"标题栏下方"的 96 DPI 逻辑坐标书写,
  统一在此偏移自绘标题栏高度 }
function TFHSettingsDlg.ScaleCaptionY(P: Integer): Integer;
begin
  Result := FHScalePx(P) + CaptionH();
end;

{ 统一设置标签字体: Segoe UI + 指定像素字号/加粗/颜色, 透明底 }
procedure TFHSettingsDlg.PinLabelFont(ALabel: TLabel; APx: Integer;
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
function TFHSettingsDlg.NewLabel(const ACaption: string;
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
procedure TFHSettingsDlg.NewDivider(Y: Integer);
var
  Sep: TPanel;
begin
  Sep := TPanel.Create(Self);
  Sep.Parent := Self;
  Sep.SetBounds(FHScalePx(C_MARGIN), ScaleCaptionY(Y), FHScalePx(C_CONTENT_W), 1);
  Sep.BevelOuter := bvNone;
  Sep.Color := FH_DIVIDER;
end;

{ 组标题: 14px 深灰标题 + 12px 说明（Chrome 设置页行头样式） }
procedure TFHSettingsDlg.NewGroupTitle(const ATitle, ADesc: string; Y: Integer);
var
  L: TLabel;
begin
  L := NewLabel(ATitle, C_MARGIN, Y, C_CONTENT_W, 20, 14, False, FH_TEXT);
  L.Layout := tlCenter;
  if ADesc <> '' then
    NewLabel(ADesc, C_MARGIN, Y + 20, C_CONTENT_W, 16, 12, False, FH_TEXT2);
end;

{ 构建内容区: 首页/新标签页/下载/GPU 四组设置项 + 底部按钮（布局见体内注释） }
procedure TFHSettingsDlg.BuildUi;

  function MakeEdit(X, Y, W, H: Integer; const AHint: string): TFHFlatEdit;
  begin
    Result := TFHFlatEdit.Create(Self);
    Result.Parent := Self;
  Result.SetBounds(FHScalePx(X), ScaleCaptionY(Y), FHScalePx(W), FHScalePx(H));
    Result.HintText := AHint;
  end;

  function MakeToggle(X, Y: Integer): TFHToggleSwitch;
  begin
    Result := TFHToggleSwitch.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(FHScalePx(X), ScaleCaptionY(Y), FHScalePx(44), FHScalePx(24));
  end;

begin
  { 大标题"设置"已移入 44px 自绘标题栏（FormPaint 画）;
    内容区从"首页"组直接开始 }

  { ---- 1. 首页 ---- }
  NewGroupTitle('首页', '启动浏览器时打开的网页', 12);
  FEdtHomepage := MakeEdit(C_MARGIN, 52, C_CONTENT_W, 32, 'https://…');

  NewDivider(96);

  { ---- 2. 新标签页 ---- }
  NewGroupTitle('新标签页', '新建标签页时打开的内容', 108);
  FRadNewTabUrl := TFHRadioDot.Create(Self);
  FRadNewTabUrl.Parent := Self;
  FRadNewTabUrl.Text := '打开指定网址';
  FRadNewTabUrl.SetBounds(FHScalePx(C_MARGIN), ScaleCaptionY(148),
    FHScalePx(C_CONTENT_W), FHScalePx(24));
  FRadNewTabUrl.OnChange := NewTabModeChange;

  FEdtNewTabUrl := MakeEdit(C_MARGIN + 28, 176, C_CONTENT_W - 28, 32, 'https://…');

  FRadNewTabBlank := TFHRadioDot.Create(Self);
  FRadNewTabBlank.Parent := Self;
  FRadNewTabBlank.Text := '打开空白页';
  FRadNewTabBlank.SetBounds(FHScalePx(C_MARGIN), ScaleCaptionY(216),
    FHScalePx(C_CONTENT_W), FHScalePx(24));
  FRadNewTabBlank.OnChange := NewTabModeChange;

  NewDivider(252);

  { ---- 3. 下载 ---- }
  NewGroupTitle('下载', '', 264);
  NewLabel('下载文件前询问保存位置', C_MARGIN, 294, C_CONTENT_W - 60,
    24, 14, False, FH_TEXT);
  FSwAskSave := MakeToggle(C_DLG_W - C_MARGIN - 44, 294);

  NewLabel('默认下载位置', C_MARGIN, 336, C_CONTENT_W - 60, 20, 12, False, FH_TEXT2);
  FEdtDlDir := MakeEdit(C_MARGIN, 356, C_CONTENT_W - 84, 32, '系统"下载"文件夹');
  FBtnBrowseDl := TFHFlatButton.Create(Self);
  FBtnBrowseDl.Parent := Self;
  FBtnBrowseDl.ButtonStyle := fbsText;
  FBtnBrowseDl.Caption := '浏览…';
  FBtnBrowseDl.SetBounds(FHScalePx(C_DLG_W - C_MARGIN - 76), ScaleCaptionY(356),
    FHScalePx(76), FHScalePx(32));
  FBtnBrowseDl.OnClick := BrowseDlDir;

  NewDivider(404);

  { ---- 4. GPU 加速（一行开关 + 说明, 不另起组标题） ---- }
  NewLabel('GPU 加速', C_MARGIN, 416, C_CONTENT_W - 60, 24, 14, False, FH_TEXT);
  FSwGPU := MakeToggle(C_DLG_W - C_MARGIN - 44, 416);
  NewLabel('启用 GPU 加速渲染；需重启浏览器后生效，部分显卡驱动下可能显示异常',
    C_MARGIN, 444, C_CONTENT_W, 16, 12, False, FH_TEXT2);

  { ---- 底部按钮 ---- }
  NewDivider(472);

  FBtnCancel := TFHFlatButton.Create(Self);
  FBtnCancel.Parent := Self;
  FBtnCancel.ButtonStyle := fbsText;
  FBtnCancel.Caption := '取消';
  FBtnCancel.SetBounds(FHScalePx(C_DLG_W - C_MARGIN - 88 - 8 - 76), ScaleCaptionY(484),
    FHScalePx(76), FHScalePx(32));
  FBtnCancel.OnClick := DoCancel;

  FBtnSave := TFHFlatButton.Create(Self);
  FBtnSave.Parent := Self;
  FBtnSave.ButtonStyle := fbsPrimary;
  FBtnSave.Caption := '保存';
  FBtnSave.SetBounds(FHScalePx(C_DLG_W - C_MARGIN - 88), ScaleCaptionY(484),
    FHScalePx(88), FHScalePx(32));
  FBtnSave.OnClick := DoSave;
end;

{ 打开对话框时把当前设置回填到各控件 }
procedure TFHSettingsDlg.FillFromSettings;
begin
  FEdtHomepage.Text := Settings.EffectiveHomepage;
  FEdtNewTabUrl.Text := Settings.EffectiveNewTabUrl;
  FSwAskSave.Checked := Settings.AskDownloadLocation;
  { DownloadDir 为空 = 跟随系统; 编辑框展示实际生效目录, 保存时若未改动则回填空串 }
  if Settings.DownloadDir = '' then
    FEdtDlDir.Text := Settings.EffectiveDownloadDir
  else
    FEdtDlDir.Text := Settings.DownloadDir;
  FSwGPU.Checked := Settings.EnableGPU;
  if Settings.NewTabMode = ntmBlank then
  begin
    FRadNewTabBlank.Checked := True;
    FRadNewTabUrl.Checked := False;
  end
  else
  begin
    FRadNewTabUrl.Checked := True;
    FRadNewTabBlank.Checked := False;
  end;
  UpdateNewTabUrlEnabled;
end;

{ "保存"确认后把控件值写回 Settings（持久化由 ShowSettingsDlg 统一做） }
procedure TFHSettingsDlg.ApplyToSettings;
begin
  Settings.Homepage := Trim(FEdtHomepage.Text);
  if FRadNewTabBlank.Checked then
    Settings.NewTabMode := ntmBlank
  else
    Settings.NewTabMode := ntmUrl;
  Settings.NewTabUrl := Trim(FEdtNewTabUrl.Text);
  Settings.AskDownloadLocation := FSwAskSave.Checked;
  { 下载目录等于系统默认时存空串（= 跟随系统, 以后系统目录变了也跟随） }
  if SameText(Trim(FEdtDlDir.Text), Settings.EffectiveDownloadDir) then
    Settings.DownloadDir := ''
  else
    Settings.DownloadDir := Trim(FEdtDlDir.Text);
  Settings.EnableGPU := FSwGPU.Checked;
end;

{ 新标签页模式单选切换: 保证两单选互斥并联动网址输入框可用态 }
procedure TFHSettingsDlg.NewTabModeChange(Sender: TObject);
begin
  { 自绘单选无系统的分组互斥, 由宿主保证二选一 }
  if Sender = FRadNewTabUrl then
  begin
    FRadNewTabUrl.Checked := True;
    FRadNewTabBlank.Checked := False;
  end
  else
  begin
    FRadNewTabBlank.Checked := True;
    FRadNewTabUrl.Checked := False;
  end;
  UpdateNewTabUrlEnabled;
end;

{ 新标签页网址输入框可用态: 仅"打开指定网址"模式可编辑 }
procedure TFHSettingsDlg.UpdateNewTabUrlEnabled;
begin
  FEdtNewTabUrl.Enabled := FRadNewTabUrl.Checked;
end;

{ "浏览…"按钮: 弹系统目录选择对话框选默认下载位置 }
procedure TFHSettingsDlg.BrowseDlDir(Sender: TObject);
var
  Dir: string;
begin
  Dir := Trim(FEdtDlDir.Text);
  if SelectDirectory('选择默认下载位置', '', Dir) then
    FEdtDlDir.Text := Dir;
end;

{ "保存"按钮: 以 mrOk 关闭对话框 }
procedure TFHSettingsDlg.DoSave(Sender: TObject);
begin
  ModalResult := mrOk;
end;

{ "取消"按钮: 以 mrCancel 关闭对话框（不写回设置） }
procedure TFHSettingsDlg.DoCancel(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

{ 键盘: Esc = 取消, 回车 = 保存（输入框内回车同样保存, Chrome 同款） }
procedure TFHSettingsDlg.DlgKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  { Esc = 取消; 回车 = 保存（输入框内回车同样保存, Chrome 同款） }
  if Key = VK_ESCAPE then
  begin
    ModalResult := mrCancel;
    Key := 0;
  end
  else if Key = VK_RETURN then
  begin
    ModalResult := mrOk;
    Key := 0;
  end;
end;

{ ---- 无边框四件套（参考历史记录窗口, docs\01_UI开发规范.md 第 6~9 条） ---- }

{ 无边框: 去 WS_CAPTION/WS_SYSMENU 保留 WS_THICKFRAME; 必须 or WS_POPUP ——
  user32 对带 WS_THICKFRAME 的非 popup 顶层窗口会在 CreateWindowEx 内部
  强制补回 WS_CAPTION（规范第 7 条） }
procedure TFHSettingsDlg.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := (Params.Style or WS_POPUP) and (not WS_CAPTION)
    and (not WS_SYSMENU);
end;

{ 标题栏高度（自绘, 96 DPI 基准 44px） }
function TFHSettingsDlg.CaptionH: Integer;
begin
  Result := FHScalePx(44);
end;

{ 标题栏右上角关闭按钮: 32x32, 距右 8px, 垂直居中于标题栏 }
function TFHSettingsDlg.CloseBtnRect: TRect;
var
  Btn: Integer;
begin
  Btn := FHScalePx(32);
  Result := Rect(ClientWidth - FHScalePx(40), (CaptionH() - Btn) div 2,
    ClientWidth - FHScalePx(40) + Btn, (CaptionH() + Btn) div 2);
end;

{ 边缘 resize 优先采用系统结果; 标题栏空白区 → HTCAPTION（拖动）;
  关闭按钮留 HTCLIENT 走鼠标事件 }
procedure TFHSettingsDlg.WMNCHitTest(var Message: TWMNCHitTest);
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
procedure TFHSettingsDlg.WMNCCalcSize(var Message: TWMNCCalcSize);
begin
  if Message.CalcValidRects then
    Message.Result := 0
  else
    inherited;
end;

{ 失活不重绘 NC（规范第 9 条: 否则弹菜单等弹窗时窗口边缘出现缝隙） }
procedure TFHSettingsDlg.WMNCActivate(var Message: TWMNCActivate);
begin
  Message.Unused := -1;
  inherited;
end;

{ 双击标题栏: 不做最大化/还原（对话框语义, 与 Chrome 设置弹窗一致） }
procedure TFHSettingsDlg.WndProc(var Message: TMessage);
begin
  if (Message.Msg = WM_NCLBUTTONDBLCLK) and (Message.WParam = HTCAPTION) then
    Exit;
  inherited WndProc(Message);
end;

{ 鼠标离开窗体: 清关闭按钮悬停态并重绘 }
procedure TFHSettingsDlg.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FCloseHot := False;
  Invalidate;
end;

{ 标题栏自绘: 白底 + 四周 1px 边框线 + 底部分隔线 + 左侧标题
  + 右上角关闭按钮 ×（悬停浅灰圆角底 + 深色） }
procedure TFHSettingsDlg.FormPaint(Sender: TObject);
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
  Winapi.Windows.DrawText(Canvas.Handle, '设置', 2, R,
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
procedure TFHSettingsDlg.FormMouseDown(Sender: TObject; Button: TMouseButton;
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
procedure TFHSettingsDlg.FormMouseMove(Sender: TObject; Shift: TShiftState;
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

{ 弹出设置对话框（模态）。用户点"保存"时写回 Settings 并持久化到 INI }
function ShowSettingsDlg: Boolean;
var
  Dlg: TFHSettingsDlg;
begin
  Dlg := TFHSettingsDlg.CreateNew(Application);
  try
    Result := Dlg.ShowModal = mrOk;
    if Result then
    begin
      Dlg.ApplyToSettings;
      try
        Settings.Save;
      except
        on E: Exception do
          Logger.Error('保存设置失败: %s - %s', [E.ClassName, E.Message]);
      end;
    end;
  finally
    Dlg.Free;
  end;
end;

end.