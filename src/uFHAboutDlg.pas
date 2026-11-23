{==============================================================================
  单元: uFHAboutDlg
  ----------------------------------------------------------------------------
  职责: ⋮ 菜单"关于 飞花浏览器"对话框。显示:
    - 当前软件（exe）版本 —— 读自身 exe 的版本资源（dproj VerInfo 生成）
    - 内核版本 —— 读 exe 同目录 libcef.dll 的 ProductVersion（Chromium 版本号）,
      读取失败回退编译期已知版本

  UI: 与清除浏览数据/设置对话框同一套无边框四件套自绘（白底 + 44px 自绘
      标题栏 + 1px 边框线 + 关闭 ×）, 正文 FormPaint 居中自绘,
      底部"确定"蓝底胶囊主按钮（TFHFlatButton）。
=============================================================================}
unit uFHAboutDlg;

interface

uses
  System.Classes, System.SysUtils, System.Math,
  Winapi.Windows, Winapi.Messages,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.Graphics,
  uFHDpi, uFHChromeWidgets;

{ version.dll 版本资源 API（Delphi 无对应标准单元, 直接声明 W 版） }
function GetFileVersionInfoSizeW(lpFileName: LPCWSTR;
  lpdwHandle: PDWORD): DWORD; stdcall; external 'version.dll';
function GetFileVersionInfoW(lpFileName: LPCWSTR; dwHandle, dwLen: DWORD;
  lpData: Pointer): BOOL; stdcall; external 'version.dll';
function VerQueryValueW(pBlock: Pointer; lpSubBlock: LPCWSTR;
  var lplpBuffer: Pointer; var puLen: UINT): BOOL; stdcall;
  external 'version.dll';

type
  TFHAboutDlg = class(TForm)
  private
    FCloseHot: Boolean;              // 鼠标悬停在标题栏关闭按钮上
    FBtnOk: TFHFlatButton;
    FExeVersion: string;             // 当前软件版本（读 exe 版本资源）
    FKernelVersion: string;          // 内核版本（读 libcef.dll ProductVersion）
    function ScaleCaptionY(P: Integer): Integer;
    function CaptionH: Integer;
    function CloseBtnRect: TRect;
    procedure BuildUi;
    procedure DoOk(Sender: TObject);
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

{ 弹出"关于"对话框（模态） }
procedure ShowAboutDlg;

implementation

const
  { ---- 布局（96 DPI 逻辑坐标） ---- }
  C_DLG_W = 360;
  C_DLG_H = 248;              // 44px 自绘标题栏 + 204px 内容
  { 弹窗边框线（Chrome 灰 #DADCE0, 与其他弹窗一致） }
  C_DL_EDGE = TColor($E0DCDA);
  { libcef.dll 版本资源读取失败时的回退（本项目固定使用 Chromium 109） }
  C_FALLBACK_KERNEL = '109.0.5414.176';
  { ---- 品牌信息（中文名 + slogan；技术标识仍用 FHBrowser） ---- }
  C_APP_NAME     = '飞花浏览器';
  C_APP_SLOGAN   = '轻如飞花，浏览无界';
  C_APP_COPYRIGHT = '© 2026 飞花浏览器';

{ 读 PE 文件版本资源: AFileVer=FileVersion, AProductVer=ProductVersion。
  语言无关: 先取 VarFileInfo\Translation 动态拼 StringFileInfo 路径 }
function ReadFileVersions(const APath: string; out AFileVer,
  AProductVer: string): Boolean;
var
  Size, Dummy: DWORD;
  Data, Buf: Pointer;
  Lang: Pointer;
  LangStr: string;
  Len: UINT;
begin
  Result := False;
  AFileVer := '';
  AProductVer := '';
  if not FileExists(APath) then Exit;
  Dummy := 0;
  Size := GetFileVersionInfoSizeW(PChar(APath), @Dummy);
  if Size = 0 then Exit;
  GetMem(Data, Size);
  try
    if not GetFileVersionInfoW(PChar(APath), 0, Size, Data) then
      Exit;
    Lang := nil;
    Len := 0;
    if VerQueryValueW(Data, '\VarFileInfo\Translation', Lang, Len) and
      (Len >= 4) then
      LangStr := IntToHex(PWord(Lang)^, 4) + IntToHex(PWord(NativeUInt(Lang) + 2)^, 4)
    else
      LangStr := '040904B0';        // 兜底: en-US Unicode
    if VerQueryValueW(Data,
      PChar('\StringFileInfo\' + LangStr + '\FileVersion'), Buf, Len) then
      AFileVer := string(PChar(Buf));
    if VerQueryValueW(Data,
      PChar('\StringFileInfo\' + LangStr + '\ProductVersion'), Buf, Len) then
      AProductVer := string(PChar(Buf));
    Result := (AFileVer <> '') or (AProductVer <> '');
  finally
    FreeMem(Data);
  end;
end;

{ 当前软件版本: 读自身 exe 的 FileVersion（由 dproj VerInfo_Keys 生成） }
function GetExeVersion: string;
begin
  if not ReadFileVersions(ParamStr(0), Result, string(Result)) then
    Result := ''
  else if Result = '' then
    Result := '0.0.0.0';
end;

{ 内核版本: 读 exe 同目录 libcef.dll 的 ProductVersion。
  CEF 构建的版本串是复合格式（如 109.1.18+gf1c41e4+chromium-109.0.5414.120）,
  提取 "chromium-" 后的 Chromium 版本号; 普通格式原样返回;
  读取/解析失败回退编译期已知版本 }
function GetKernelVersion: string;
var
  FV, PV: string;
  P: Integer;
begin
  if ReadFileVersions(ExtractFileDir(ParamStr(0)) + '\libcef.dll', FV, PV) then
  begin
    if PV = '' then
      PV := FV;
    P := Pos('chromium-', PV);
    if P > 0 then
      Exit(Copy(PV, P + Length('chromium-'), MaxInt));
    if PV <> '' then
      Exit(PV);
  end;
  Result := C_FALLBACK_KERNEL;
end;

{ 弹出"关于"对话框（模态, 声明处注释见 interface 区） }
procedure ShowAboutDlg;
var
  Dlg: TFHAboutDlg;
begin
  Dlg := TFHAboutDlg.CreateNew(Application);
  try
    Dlg.ShowModal;
  finally
    Dlg.Free;
  end;
end;

{ 构造: 读 exe/libcef.dll 版本号, 配置无边框 Chrome 弹窗四件套并构建 UI }
constructor TFHAboutDlg.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  { 与其他 Chrome 风格弹窗一致: 关掉 VCL 自动缩放, 坐标/字号手动按屏幕 DPI 换算 }
  Scaled := False;

  Caption := '关于';
  FExeVersion := GetExeVersion;
  FKernelVersion := GetKernelVersion;
  { 无边框 Chrome 弹窗四件套: WS_POPUP + 吞 NCCALCSIZE + 自绘 1px 边框线 +
    NCACTIVATE 哨兵（docs\01_UI开发规范.md 6~9 条）;
    bsSizeable 仅为保留 WS_THICKFRAME（边缘八向调整大小） }
  BorderStyle := bsSizeable;
  BorderIcons := [];
  Position := poScreenCenter;
  Color := FH_BG;
  ClientWidth := FHScalePx(C_DLG_W);
  ClientHeight := FHScalePx(C_DLG_H);
  Constraints.MaxWidth := FHScalePx(C_DLG_W);
  Constraints.MaxHeight := FHScalePx(C_DLG_H);
  DoubleBuffered := True;
  OnPaint := FormPaint;
  OnMouseDown := FormMouseDown;
  OnMouseMove := FormMouseMove;
  KeyPreview := True;
  OnKeyDown := DlgKeyDown;
  BuildUi;
end;


{ 内容区 y → 客户区 y: 内容布局按"标题栏下方"的 96 DPI 逻辑坐标书写 }
function TFHAboutDlg.ScaleCaptionY(P: Integer): Integer;
begin
  Result := FHScalePx(P) + CaptionH();
end;

{ ---- 无边框四件套（与其他弹窗同款） ---- }

{ 无边框: 去 WS_CAPTION/WS_SYSMENU 保留 WS_THICKFRAME; 必须 or WS_POPUP ——
  user32 对带 WS_THICKFRAME 的非 popup 顶层窗口会强制补回 WS_CAPTION }
procedure TFHAboutDlg.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := (Params.Style or WS_POPUP) and (not WS_CAPTION)
    and (not WS_SYSMENU);
end;

{ 标题栏高度（自绘, 96 DPI 基准 44px） }
function TFHAboutDlg.CaptionH: Integer;
begin
  Result := FHScalePx(44);
end;

{ 标题栏右上角关闭按钮矩形: 32x32, 距右 8px, 垂直居中于标题栏 }
function TFHAboutDlg.CloseBtnRect: TRect;
var
  Btn: Integer;
begin
  Btn := FHScalePx(32);
  Result := Rect(ClientWidth - FHScalePx(40), (CaptionH() - Btn) div 2,
    ClientWidth - FHScalePx(40) + Btn, (CaptionH() + Btn) div 2);
end;

{ 边缘 resize 优先采用系统结果; 标题栏空白区 → HTCAPTION（拖动）;
  关闭按钮留 HTCLIENT 走鼠标事件 }
procedure TFHAboutDlg.WMNCHitTest(var Message: TWMNCHitTest);
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

{ 吞掉顶部 resize 边框带: 客户区=整窗, 标题栏贴物理顶边 }
procedure TFHAboutDlg.WMNCCalcSize(var Message: TWMNCCalcSize);
begin
  if Message.CalcValidRects then
    Message.Result := 0
  else
    inherited;
end;

{ 失活不重绘 NC（否则弹菜单等浮层时窗口边缘出现缝隙） }
procedure TFHAboutDlg.WMNCActivate(var Message: TWMNCActivate);
begin
  Message.Unused := -1;
  inherited;
end;

{ 双击标题栏: 不做最大化/还原（对话框语义） }
procedure TFHAboutDlg.WndProc(var Message: TMessage);
begin
  if (Message.Msg = WM_NCLBUTTONDBLCLK) and (Message.WParam = HTCAPTION) then
    Exit;
  inherited WndProc(Message);
end;

{ 鼠标离开窗体: 清关闭按钮悬停态并重绘 }
procedure TFHAboutDlg.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FCloseHot := False;
  Invalidate;
end;

{ 构建底部"确定"主按钮 }
procedure TFHAboutDlg.BuildUi;
begin
  FBtnOk := TFHFlatButton.Create(Self);
  FBtnOk.Parent := Self;
  FBtnOk.ButtonStyle := fbsPrimary;
  FBtnOk.Caption := '确定';
  FBtnOk.SetBounds(FHScalePx((C_DLG_W - 88) div 2), ScaleCaptionY(156),
    FHScalePx(88), FHScalePx(32));
  FBtnOk.OnClick := DoOk;
end;

{ "确定"按钮: 关闭对话框 }
procedure TFHAboutDlg.DoOk(Sender: TObject);
begin
  ModalResult := mrOk;
end;

{ 键盘: Esc/回车 = 确定（对话框惯例） }
procedure TFHAboutDlg.DlgKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if (Key = VK_ESCAPE) or (Key = VK_RETURN) then
  begin
    ModalResult := mrOk;
    Key := 0;
  end;
end;

{ 全窗自绘: 标题栏 + 1px 边框线 + 居中正文（产品名/版本/内核/版权）
  + 分隔线 + 右上角关闭按钮 ×（各段见体内注释） }
procedure TFHAboutDlg.FormPaint(Sender: TObject);
var
  R: TRect;
  PW, CX, CY, D: Integer;
  Clr: TColor;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FH_BG;
  Canvas.Pen.Style := psClear;
  Canvas.FillRect(Rect(0, 0, ClientWidth, CaptionH()));

  { 标题文字 }
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.PixelsPerInch := FHScalePx(96);
  Canvas.Font.Height := -FHScalePx(20);
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := FH_TEXT;
  R := Rect(FHScalePx(16), 0, ClientWidth - FHScalePx(220), CaptionH());
  Winapi.Windows.DrawText(Canvas.Handle, PChar(Caption),
    Length(Caption), R,
    DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_NOPREFIX);

  { 四周 1px 边框线 }
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := C_DL_EDGE;
  Canvas.Pen.Width := 1;
  Canvas.MoveTo(0, 0);
  Canvas.LineTo(ClientWidth - 1, 0);
  Canvas.LineTo(ClientWidth - 1, ClientHeight - 1);
  Canvas.LineTo(0, ClientHeight - 1);
  Canvas.LineTo(0, 0);
  Canvas.Pen.Style := psClear;

  { ---- 正文（居中）: 产品名 / slogan / 软件版本 / 内核版本 / 版权 ---- }
  SetBkMode(Canvas.Handle, TRANSPARENT);

  Canvas.Font.Height := -FHScalePx(22);
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := FH_TEXT;
  R := Rect(0, ScaleCaptionY(16), ClientWidth, ScaleCaptionY(44));
  Winapi.Windows.DrawText(Canvas.Handle, PChar(C_APP_NAME), Length(C_APP_NAME), R,
    DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);

  Canvas.Font.Height := -FHScalePx(12);
  Canvas.Font.Style := [];
  Canvas.Font.Color := FH_TEXT2;
  R := Rect(0, ScaleCaptionY(46), ClientWidth, ScaleCaptionY(64));
  Winapi.Windows.DrawText(Canvas.Handle, PChar(C_APP_SLOGAN),
    Length(C_APP_SLOGAN), R,
    DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);

  Canvas.Font.Height := -FHScalePx(13);
  Canvas.Font.Color := FH_TEXT;
  R := Rect(0, ScaleCaptionY(68), ClientWidth, ScaleCaptionY(86));
  Winapi.Windows.DrawText(Canvas.Handle,
    PChar('版本 ' + FExeVersion), Length('版本 ' + FExeVersion), R,
    DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);

  Canvas.Font.Height := -FHScalePx(12);
  Canvas.Font.Color := FH_TEXT2;
  R := Rect(0, ScaleCaptionY(90), ClientWidth, ScaleCaptionY(108));
  Winapi.Windows.DrawText(Canvas.Handle,
    PChar('内核 Chromium ' + FKernelVersion),
    Length('内核 Chromium ' + FKernelVersion), R,
    DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);

  Canvas.Font.Height := -FHScalePx(11);
  R := Rect(0, ScaleCaptionY(112), ClientWidth, ScaleCaptionY(130));
  Winapi.Windows.DrawText(Canvas.Handle, PChar(C_APP_COPYRIGHT),
    Length(C_APP_COPYRIGHT), R,
    DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);

  { 按钮上方分隔线 }
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := C_DL_EDGE;
  Canvas.Pen.Width := 1;
  Canvas.MoveTo(FHScalePx(32), ScaleCaptionY(136));
  Canvas.LineTo(ClientWidth - FHScalePx(32), ScaleCaptionY(136));
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

{ 鼠标按下: 命中关闭按钮则关闭对话框 }
procedure TFHAboutDlg.FormMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  if PtInRect(CloseBtnRect(), Point(X, Y)) then
  begin
    FCloseHot := False;
    ModalResult := mrOk;
    Exit;
  end;
end;

{ 鼠标移动: 跟踪关闭按钮悬停态, 变化时重绘 }
procedure TFHAboutDlg.FormMouseMove(Sender: TObject; Shift: TShiftState;
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