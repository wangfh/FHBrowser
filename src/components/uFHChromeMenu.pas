{==============================================================================
  单元: uFHChromeMenu

  职责: Chrome 风格的弹出菜单（自绘的无边框窗体）, 替代系统 TPopupMenu。

  为什么不用 TPopupMenu:
    原生菜单是 Windows 主题绘制的 —— 行高紧贴系统字号、分隔线与留白、悬停底色、
    圆角跟随系统版本, 与 Chrome 的菜单观感对不上。本单元自己画一个圆角白底的
    顶层窗口, 只保留必要的能力（标题/快捷键右列/分隔线/禁用灰/勾选列）。

  对齐 Chrome 的取值（96 DPI 基准, 运行时按 ScaleFactor 换算）:
    行高 32; 菜单上下留白 6; 文字左右留白 12; 标题与快捷键列间距 24; 圆角 8
    底色 #FFFFFF / 分隔线 #DADCE0 / 文字 #3C4043 / 禁用 #9AA0A6
    悬停整行底 #E8EAED / 快捷键文字 #70757A

  用法:
    Menu := TFHMenu.Create(Self);
    Menu.Add('开发者工具', MnuDevToolsClick, 'F12');
    Menu.AddSeparator;
    Menu.Popup(X, Y);      // 屏幕坐标
==============================================================================}
unit uFHChromeMenu;

interface

uses
  System.Classes, System.SysUtils, System.Types, System.Math,
  System.Generics.Collections,
  Winapi.Windows, Winapi.Messages, Winapi.DwmApi,
  Vcl.Forms, Vcl.Controls, Vcl.Graphics,
  uFHDpi, uFHChromeWidgets;

type
  TFHMenu = class;

  { ---- 菜单图标: Chrome 风格 16px 线条图标（GDI+ 抗锯齿自绘, 见 DrawMenuIcon） ---- }
  TFHMenuIcon = (
    miNone,
    miNewTab,      // 新建标签页 / 在新标签页中打开: 页面 + 加号
    miFind,        // 查找: 放大镜
    miPrint,       // 打印: 打印机
    miHistory,     // 历史记录: 时钟
    miDownloads,   // 下载: 下箭头 + 底托
    miDeleteData,  // 删除浏览数据: 垃圾桶
    miBookmarks,   // 书签管理器: 五角星
    miDevTools,    // 开发者工具: < / >
    miSettings,    // 设置: 齿轮
    miAbout,       // 关于: (i)
    miReload,      // 重新加载: 循环箭头
    miDuplicate,   // 复制: 叠加双页
    miPin,         // 固定: 图钉
    miClose,       // 关闭: 叉
    miOpen,        // 打开: 右箭头
    miEdit,        // 编辑: 铅笔
    miDelete,      // 删除: 垃圾桶
    miFolder,      // 打开文件位置: 文件夹
    miLink,        // 复制链接: 链条
    miPage         // 书签条目: 页面
  );

  { 缩放行回调: ADelta = -1/+1（档位加减）或 0（点百分比 = 重置 100%）。
    ANewPct 由处理方返回新的百分比, 菜单据此刷新行内文字 —— 缩放行点击后
    菜单不关闭（Chrome 同款）, 所以不能用普通的 TNotifyEvent }
  TFHZoomEvent = procedure(Sender: TObject; ADelta: Integer;
    var ANewPct: Integer) of object;

  { 菜单项: 只保留 TMenuItem 里我们真正用到的那部分（够用, 不含子菜单） }
  TFHMenuItem = class
  private
    FCaption: string;
    FShortcut: string;
    FEnabled: Boolean;
    FVisible: Boolean;
    FChecked: Boolean;
    FSeparator: Boolean;
    FIsZoomRow: Boolean;
    FZoomPct: Integer;
    FZoomLabel: string;           // 缩放行前缀标签(如"缩放"), 空则不画
    FIcon: TFHMenuIcon;           // 行首图标(miNone = 无)
    FTag: NativeInt;
    FOnClick: TNotifyEvent;
    FOnZoom: TFHZoomEvent;
  public
    procedure Click;
    property Caption: string read FCaption write FCaption;
    property Shortcut: string read FShortcut write FShortcut;
    property Enabled: Boolean read FEnabled write FEnabled;
    property Visible: Boolean read FVisible write FVisible;
    property Checked: Boolean read FChecked write FChecked;
    property Separator: Boolean read FSeparator;
    property IsZoomRow: Boolean read FIsZoomRow;
    property ZoomPct: Integer read FZoomPct write FZoomPct;
    property ZoomLabel: string read FZoomLabel write FZoomLabel;
    property Icon: TFHMenuIcon read FIcon write FIcon;
    property Tag: NativeInt read FTag write FTag;
    property OnClick: TNotifyEvent read FOnClick write FOnClick;
    property OnZoom: TFHZoomEvent read FOnZoom write FOnZoom;
  end;

  { 弹出本体: 无边框 + 圆角 + 分层窗口阴影的顶层窗口 }
  TFHMenuWindow = class(TCustomForm)
  private
    FMenu: TFHMenu;
    FHot: Integer;                 // 当前高亮项索引（-1 = 无）
    FTops: TArray<Integer>;        // 每项顶边（含留白）
    FTextX: Integer;               // 标题列左边界（有打勾项时右移）
    FTextRight: Integer;           // 标题列右边界
    FShortcutX: Integer;           // 快捷键列左边界
    FShadowWnd: HWND;              // 阴影底板（分层窗口, 点击穿透）
    FHasHost: Boolean;             // 弹出时是否取到了宿主窗口矩形
    FHostRect: TRect;              // 宿主（主窗体）屏幕矩形, 阴影按它裁剪
    FHotZone: Integer;             // 缩放行内悬停分区: 0=− 1=百分比 2=+ (-1=无)
    FZoomLabelW: Integer;          // "缩放"标签像素宽(0=无标签), 缩放行减号右移让位
    FConfine: Boolean;             // 是否夹紧在宿主窗口内(来自 TFHMenu.ConfineToHost)
    function ScalePx(P: Integer): Integer;
    function RowHeight(AItem: TFHMenuItem): Integer;
    function IndexAtPos(Y: Integer): Integer;
    { 缩放行: 三个分区矩形 / X 坐标 → 分区号 / 执行缩放回调 }
    procedure ZoomZones(AIndex: Integer; out RM, RC, RP: TRect);
    function ZoneAtX(AX, AIndex: Integer): Integer;
    procedure DoZoom(AItem: TFHMenuItem; ADelta: Integer);
    procedure SetHot(AIndex: Integer);
    procedure ExecuteHot;
    procedure DrawCheck(X, Y: Integer; Color: TColor);
    procedure ApplyFont;                   // 按像素钉字号（须早于 LayoutPopup 量宽）
    procedure LayoutPopup(X, Y: Integer);
    { 自绘阴影: CS_DROPSHADOW 对 SetWindowRgn 的窗口无效（DWM 不画）,
      用分层窗口画四边渐变, 菜单本体盖在其上 }
    procedure ShowShadow;
    procedure HideShadow;
    procedure CMDeactivate(var Message: TCMDeactivate); message CM_DEACTIVATE;
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure WMLButtonUp(var Message: TWMLButtonUp); message WM_LBUTTONUP;
    procedure WMMouseMove(var Message: TWMMouseMove); message WM_MOUSEMOVE;
    procedure WMKeyDown(var Message: TWMKeyDown); message WM_KEYDOWN;
  protected
    { 可见性必须与 TCustomForm 一致(protected), 否则编译器 H2269 }
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure DoClose(var Action: TCloseAction); override;
    procedure Paint; override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
    procedure ShowAt(X, Y: Integer);
  end;

  { 菜单: 持有一组条目, 按需弹出 }
  TFHMenu = class(TComponent)
  private
    FItems: TObjectList<TFHMenuItem>;
    FWindow: TFHMenuWindow;
    FScale: Single;
    FConfineToHost: Boolean;
    function GetItem(Index: Integer): TFHMenuItem;
    function GetCount: Integer;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function Add(const ACaption: string; AOnClick: TNotifyEvent;
      const AShortcut: string = ''; AIcon: TFHMenuIcon = miNone): TFHMenuItem;
    function AddSeparator: TFHMenuItem;
    function AddZoomRow(AOnZoom: TFHZoomEvent): TFHMenuItem;
    procedure Popup(X, Y: Integer); overload;
    procedure Popup(const P: TPoint); overload;
    procedure ClosePopup;
    { 菜单窗口当前是否显示中（失焦保护/兜底关闭判断用）。
      TFHMenuWindow 关闭时自清 FWindow, 不会悬空 }
    function PopupVisible: Boolean;
    function HasCheckedItems: Boolean;
    { 是否存在带图标的可见项（决定布局是否预留图标列） }
    function HasIconItems: Boolean;
    function ScalePx(P: Integer): Integer;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TFHMenuItem read GetItem; default;
    { DPI 缩放系数(1.0 = 96 DPI); 不设就取 Screen.PixelsPerInch / 96 }
    property ScaleFactor: Single read FScale write FScale;
    { 是否夹紧在锚点所在顶层窗口（宿主）内。True（默认）= 不探出宿主窗口
      （Chrome 主窗口菜单形态）; False = 只按屏幕工作区夹紧, 可探出宿主 ——
      气泡/小浮层的行内菜单须设 False: 宿主反查会把浮层自身当宿主,
      菜单会被夹在浮层客户区内, 按钮下方放不下时翻到按钮上方 }
    property ConfineToHost: Boolean read FConfineToHost write FConfineToHost;
  end;

implementation

uses
  Winapi.GDIPAPI, Winapi.GDIPOBJ,
  uFHChromeTabs,      // EnsureGdiPlus: 共享的 GDI+ 懒启动会话(实现节循环引用, 合法)
  uLogger;


const
  { ---- 尺寸（96 DPI 基准） ---- }
  C_MENU_ROW_H      = 32;   // Chrome 菜单行高
  C_MENU_SEP_H      = 9;    // 分隔线占的行高
  C_MENU_PAD_Y      = 6;    // 菜单上下留白
  C_MENU_PAD_X      = 12;   // 文字左右留白
  C_MENU_SHORTCUT_GAP = 24; // 标题列与快捷键列的最小间距
  C_MENU_CHECK_W    = 20;   // 打勾列宽（只有存在勾选项时才占）
  C_MENU_ICON_W     = 26;   // 图标列宽（16 图标 + 10 与文字间距; 只有存在图标项时才占）
  C_MENU_ICON_SZ    = 16;   // 图标边长（96 DPI 基准, Chrome 同尺寸）
  C_MENU_RADIUS     = 8;    // 圆角
  C_MENU_MAX_TEXT   = 300;  // 标题列最大宽度（超出省略号）
  C_MENU_MIN_WIDTH  = 200;  // 菜单最小宽度（Chrome 的菜单不会窄成一条）
  C_MENU_EDGE_MARGIN = 4;   // 菜单与宿主窗口边缘至少留出的距离
  C_MENU_ROW_INSET  = 4;    // 悬停底色左右内缩
  { 缩放行: 档位上下限（与 CEF ZoomStepValues 档位表一致）, 用于 −/+ 置灰 }
  C_ZOOM_MIN_PCT    = 25;
  C_ZOOM_MAX_PCT    = 500;
  C_ZOOM_LABEL_GAP  = 10;   // "缩放"标签与减号按钮之间的间距(px)
  { 菜单字号 = 12px（Chrome 菜单在 Windows 上的字号, 比标签标题小一档）。
    注意这里是**像素**: Delphi 的 Font.Size 单位是磅, 写 12 会得到 12*96/72 = 16px,
    比 Chrome 大 1/3（原写法就是这么偏大的）, 所以按像素设 Font.Height }
  C_MENU_FONT_PX    = 12;
  C_MENU_FONT_NAME  = 'Segoe UI';

  { ---- 颜色: CSS 十六进制 → TColor($00BBGGRR) ---- }
  C_MENU_BG        = clWhite;
  C_MENU_BORDER    = TColor($E0DCDA);   // #DADCE0
  C_MENU_TEXT      = TColor($43403C);   // #3C4043
  C_MENU_TEXT_DIS  = TColor($A6A09A);   // #9AA0A6
  C_MENU_HOT       = TColor($EDEAE8);   // #E8EAED
  C_MENU_SHORTCUT  = TColor($7A7570);   // #70757A

  CS_DROPSHADOW = $00020000;

  { 自绘阴影（模仿 Chrome 的九宫格阴影贴图, 逻辑 px, 随 DPI 缩放）。
    Chrome 的阴影明显偏向下: 上缘几乎没有、左右很窄（约 6px）、下边最宽
    （约 12-15px）; 峰值 alpha 约 0.25, 渐变长度约 12px。
    注意: 若某方向外扩 < 渐变长度, 阴影在该方向会被窗口边缘截断 —— 这正是
    Chrome 的做法（上方近乎无阴影） }
  C_MENU_SHADOW_A    = 18;   // 峰值 alpha ≈ 0.25
  C_MENU_SHADOW_BLUR = 6;   // 渐变长度
  C_MENU_SHADOW_L    = 4;    // 左外扩
  C_MENU_SHADOW_T    = 2;    // 上外扩（近乎无）
  C_MENU_SHADOW_R    = 4;    // 右外扩
  C_MENU_SHADOW_B    = 8;   // 下外扩（最宽）

var
  { 用于"点击菜单外任意位置即关闭": WH_MOUSE_LL 不需要注入 DLL, 且事件会继续
    传给目标窗口（不像 SetCapture 会把点击吞掉） }
  GHook: HHOOK = 0;
  GPopup: TFHMenuWindow = nil;
  GShadowClassAtom: ATOM = 0;

{ 阴影底板的窗口过程: 一切鼠标命中都穿透（HTTRANSPARENT）, 点击落到下层窗口 }
function ShadowWndProc(hWnd: HWND; Msg: UINT; wParam: WPARAM;
  lParam: LPARAM): LRESULT; stdcall;
begin
  if Msg = WM_NCHITTEST then
    Exit(HTTRANSPARENT);
  Result := DefWindowProc(hWnd, Msg, wParam, lParam);
end;

{ 注册阴影底板窗口类 "FHMenuShadow"（进程内只注册一次） }
function EnsureShadowClass: Boolean;
var
  WC: TWndClass;
begin
  if GShadowClassAtom <> 0 then
    Exit(True);
  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @ShadowWndProc;
  WC.hInstance := HInstance;
  WC.lpszClassName := 'FHMenuShadow';
  WC.hCursor := 0;
  GShadowClassAtom := Winapi.Windows.RegisterClass(WC);
  Result := GShadowClassAtom <> 0;
end;

{ 低级鼠标钩子回调: 弹出期间点击菜单外任意位置 → 投 WM_CLOSE 收起菜单
  （事件继续传给目标窗口, 不吞点击） }
function MenuMouseProc(nCode: Integer; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  MI: PMouseHookStruct;
  R: TRect;
begin
  Result := CallNextHookEx(GHook, nCode, wParam, lParam);
  if (nCode < 0) or (GPopup = nil) or not GPopup.HandleAllocated then Exit;
  case wParam of
    WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN,
    WM_NCLBUTTONDOWN, WM_NCRBUTTONDOWN, WM_NCMBUTTONDOWN:
      begin
        MI := PMouseHookStruct(lParam);
        if GetWindowRect(GPopup.Handle, R) and not PtInRect(R, MI.pt) then
          PostMessage(GPopup.Handle, WM_CLOSE, 0, 0);
      end;
  end;
end;

{ 取锚点所在的顶层窗口（= 主浏览器窗口）的屏幕矩形。
  用锚点反查而不是记住 Owner, 是因为菜单的 Owner 可能是标签条这样的子控件,
  而"不越界"要相比的是整窗; GA_ROOT 正好给出顶层窗口。
  注意用**客户区**而不是 GetWindowRect: 主窗体是自绘边框, 左右下保留了
  系统缩放边框（~8px 不可见）, 且最大化时窗口矩形越出屏幕一个边框宽 ——
  两种情况 GetWindowRect 的右/下都比"可见窗口"大, 菜单和阴影会探出窗外;
  客户区（换算到屏幕坐标）正好就是可见 UI 区域 }
function HostWindowRect(X, Y: Integer; out R: TRect): Boolean;
var
  H: HWND;
begin
  Result := False;
  H := WindowFromPoint(Point(X, Y));
  if H <> 0 then
    H := GetAncestor(H, GA_ROOT);
  if H = 0 then Exit;
  Result := GetClientRect(H, R);
  if Result then
    MapWindowPoints(H, 0, R, 2);          // 客户区左上/右下 → 屏幕坐标
end;

{ ---- 菜单图标（GDI+ 抗锯齿自绘, Chrome 风格 16px 线条图标） ------------------
  所有图标按 16×16 设计网格定义, DrawMenuIcon 按目标尺寸等比缩放;
  GDI+ 不可用时跳过绘制 —— 图标是辅助信息, 文字仍可读 }
procedure DrawMenuIcon(ACanvas: TCanvas; AX, AY, ASize: Integer;
  AIcon: TFHMenuIcon; AColor: TColor);
const
  PEN_W = 1.6;                       // 16px 网格基准线宽(随 ASize 等比缩放)
var
  G: TGPGraphics;
  Pen: TGPPen;
  Brush: TGPSolidBrush;
  F: Single;                         // 设计网格 → 像素缩放因子
  I: Integer;
  X1, Y1, X2, Y2, A, Ex, Ey, Ta: Double;

  function PX(V: Single): Single;
  begin
    Result := AX + V * F;
  end;

  function PY(V: Single): Single;
  begin
    Result := AY + V * F;
  end;

  { 设计网格坐标线段 }
  procedure L(X1, Y1, X2, Y2: Single);
  begin
    G.DrawLine(Pen, PX(X1), PY(Y1), PX(X2), PY(Y2));
  end;

  { 设计网格坐标圆(外接矩形左上 + 宽高) }
  procedure Ell(X, Y, W, H: Single);
  begin
    G.DrawEllipse(Pen, PX(X), PY(Y), W * F, H * F);
  end;

  { 设计网格坐标实心小圆点(圆心 + 半径) }
  procedure Dot(X, Y, R: Single);
  begin
    G.FillEllipse(Brush, PX(X - R), PY(Y - R), 2 * R * F, 2 * R * F);
  end;

  { 五角星第 K 个顶点(0..9, 偶=外顶点 奇=内顶点), 中心(8,8.7) }
  procedure StarPt(K: Integer; out SX, SY: Double);
  var
    AA: Double;
  begin
    AA := (-90 + K * 36) * Pi / 180;
    if Odd(K) then
    begin
      SX := 8 + 2.6 * Cos(AA);
      SY := 8.7 + 2.6 * Sin(AA);
    end
    else
    begin
      SX := 8 + 6 * Cos(AA);
      SY := 8.7 + 6 * Sin(AA);
    end;
  end;

begin
  if (AIcon = miNone) or (ASize <= 0) or (ACanvas = nil) or
    (ACanvas.Handle = 0) then Exit;
  if not EnsureGdiPlus then Exit;
  G := TGPGraphics.Create(ACanvas.Handle);
  if G = nil then Exit;
  try
    G.SetSmoothingMode(SmoothingModeAntiAlias);
    F := ASize / 16;
    Pen := TGPPen.Create(ColorToARGB(AColor), PEN_W * F);
    Pen.SetStartCap(LineCapRound);
    Pen.SetEndCap(LineCapRound);
    Brush := TGPSolidBrush.Create(ColorToARGB(AColor));
    try
      case AIcon of
        miNewTab:                       // 页面 + 加号
          begin
            L(3.5, 2.5, 12.5, 2.5);   L(12.5, 2.5, 12.5, 13.5);
            L(12.5, 13.5, 3.5, 13.5); L(3.5, 13.5, 3.5, 2.5);
            L(8, 6, 8, 10);           L(6, 8, 10, 8);
          end;
        miFind:                         // 放大镜
          begin
            Ell(2.5, 2.5, 9, 9);
            L(10.2, 10.2, 13.5, 13.5);
          end;
        miPrint:                        // 打印机
          begin
            L(4.5, 6, 4.5, 2.5);    L(4.5, 2.5, 11.5, 2.5);
            L(11.5, 2.5, 11.5, 6);  L(2.5, 6, 2.5, 11);
            L(2.5, 11, 13.5, 11);   L(13.5, 11, 13.5, 6);
            L(13.5, 6, 2.5, 6);     L(5, 11, 5, 13.5);
            L(5, 13.5, 11, 13.5);   L(11, 13.5, 11, 11);
          end;
        miHistory:                      // 时钟
          begin
            Ell(2.5, 2.5, 11, 11);
            L(8, 8, 8, 5);
            L(8, 8, 10.5, 9.5);
          end;
        miDownloads:                    // 下载: 下箭头 + 底托
          begin
            L(8, 3, 8, 10.5);
            L(4.5, 7, 8, 10.5);     L(8, 10.5, 11.5, 7);
            L(3, 13.5, 13, 13.5);
          end;
        miDeleteData, miDelete:         // 垃圾桶
          begin
            L(4, 4.5, 12, 4.5);
            L(6.5, 4.5, 6.5, 2.5);  L(6.5, 2.5, 9.5, 2.5);
            L(9.5, 2.5, 9.5, 4.5);
            L(5.5, 6.5, 5.5, 13);   L(10.5, 6.5, 10.5, 13);
            L(5.5, 13, 10.5, 13);   L(8, 8, 8, 11.5);
          end;
        miBookmarks:                    // 五角星(描边)
          for I := 0 to 9 do
          begin
            StarPt(I, X1, Y1);
            StarPt((I + 1) mod 10, X2, Y2);
            L(X1, Y1, X2, Y2);
          end;
        miDevTools:                     // < / >
          begin
            L(4.5, 4.5, 7.5, 8);    L(4.5, 11.5, 7.5, 8);
            L(11.5, 4.5, 8.5, 8);   L(11.5, 11.5, 8.5, 8);
          end;
        miSettings:                     // 齿轮: 中心圆 + 8 根齿线
          begin
            Ell(5.4, 5.4, 5.2, 5.2);
            for I := 0 to 7 do
            begin
              A := I * Pi / 4;
              L(8 + 3.8 * Cos(A), 8 + 3.8 * Sin(A),
                8 + 6.2 * Cos(A), 8 + 6.2 * Sin(A));
            end;
          end;
        miAbout:                        // (i)
          begin
            Ell(2, 2, 12, 12);
            Dot(8, 5.2, 0.75);
            L(8, 7.5, 8, 11.2);
          end;
        miReload:                       // 循环箭头(弧 + 终点箭头)
          begin
            G.DrawArc(Pen, PX(3), PY(3), 10 * F, 10 * F, -55, 290);
            A := 235 * Pi / 180;        // 弧终点角(start -55 + sweep 290)
            Ex := 8 + 5 * Cos(A);
            Ey := 8 + 5 * Sin(A);
            Ta := 325 * Pi / 180;       // 终点处顺时针切向(终点角 + 90°)
            L(Ex + 2.8 * Cos(Ta + 150 * Pi / 180),
              Ey + 2.8 * Sin(Ta + 150 * Pi / 180), Ex, Ey);
            L(Ex + 2.8 * Cos(Ta - 150 * Pi / 180),
              Ey + 2.8 * Sin(Ta - 150 * Pi / 180), Ex, Ey);
          end;
        miDuplicate:                    // 叠加双页
          begin
            L(6, 2.5, 13.5, 2.5);   L(13.5, 2.5, 13.5, 10);
            L(13.5, 10, 10.5, 10);  L(6, 2.5, 6, 5.5);
            L(2.5, 5.5, 10.5, 5.5);   L(10.5, 5.5, 10.5, 13.5);
            L(10.5, 13.5, 2.5, 13.5); L(2.5, 13.5, 2.5, 5.5);
          end;
        miPin:                          // 图钉: 环 + 双翼 + 针
          begin
            Ell(4.8, 1.8, 6.4, 6.4);
            L(8, 8.2, 8, 14);
            L(5.6, 8.9, 8, 8.2);    L(8, 8.2, 10.4, 8.9);
          end;
        miClose:                        // 叉
          begin
            L(4, 4, 12, 12);
            L(12, 4, 4, 12);
          end;
        miOpen:                         // 右箭头
          begin
            L(3, 8, 12.5, 8);
            L(9, 4.5, 12.5, 8);     L(9, 11.5, 12.5, 8);
          end;
        miEdit:                         // 铅笔(笔尖朝左下)
          begin
            { 以图标中心为原点旋转 135° 后画水平铅笔, 坐标直接乘 F }
            G.TranslateTransform(PX(8), PY(8));
            G.RotateTransform(135);
            try
              G.DrawLine(Pen, -5.5 * F, -2 * F, 1.5 * F, -2 * F);
              G.DrawLine(Pen, -5.5 * F, 2 * F, 1.5 * F, 2 * F);
              G.DrawLine(Pen, -5.5 * F, -2 * F, -5.5 * F, 2 * F);
              G.DrawLine(Pen, 1.5 * F, -2 * F, 5 * F, 0);
              G.DrawLine(Pen, 1.5 * F, 2 * F, 5 * F, 0);
              G.DrawLine(Pen, 1.5 * F, -2 * F, 1.5 * F, 2 * F);
            finally
              G.ResetTransform;
            end;
          end;
        miFolder:                       // 文件夹
          begin
            L(2.5, 3.5, 6, 3.5);    L(6, 3.5, 7.5, 5);
            L(7.5, 5, 13.5, 5);     L(13.5, 5, 13.5, 12.5);
            L(13.5, 12.5, 2.5, 12.5); L(2.5, 12.5, 2.5, 3.5);
          end;
        miLink:                         // 链条: 两个相扣的链环
          begin
            Ell(1.5, 6, 7, 5);
            Ell(7.5, 6, 7, 5);
          end;
        miPage:                         // 页面(带折角)
          begin
            L(4.5, 2.5, 9.5, 2.5);  L(9.5, 2.5, 11.5, 4.5);
            L(11.5, 4.5, 11.5, 13.5); L(11.5, 13.5, 4.5, 13.5);
            L(4.5, 13.5, 4.5, 2.5);
            L(9.5, 2.5, 9.5, 4.5);  L(9.5, 4.5, 11.5, 4.5);
          end;
      end;
    finally
      Brush.Free;
      Pen.Free;
    end;
  finally
    G.Free;
  end;
end;

{ ---- TFHMenuItem ---------------------------------------------------------- }

{ 触发本项的 OnClick（由菜单窗口在关闭后调用） }
procedure TFHMenuItem.Click;
begin
  if Assigned(FOnClick) then
    FOnClick(Self);
end;

{ ---- TFHMenu -------------------------------------------------------------- }

{ 构造: 建条目列表（拥有式）, 默认夹紧宿主, 按屏幕 DPI 取缩放系数 }
constructor TFHMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FItems := TObjectList<TFHMenuItem>.Create(True);
  FConfineToHost := True;
  if Screen <> nil then
    FScale := Screen.PixelsPerInch / 96
  else
    FScale := 1;
end;

{ 析构: 连同弹出窗口与条目列表一起释放 }
destructor TFHMenu.Destroy;
begin
  FreeAndNil(FWindow);
  FreeAndNil(FItems);
  inherited;
end;

{ 条目索引器实现 }
function TFHMenu.GetItem(Index: Integer): TFHMenuItem;
begin
  Result := FItems[Index];
end;

{ 条目数实现 }
function TFHMenu.GetCount: Integer;
begin
  Result := FItems.Count;
end;

{ 新增普通菜单项（AShortcut 可选, 右对齐浅色列; AIcon 可选, 行首图标）;
  返回项便于之后改状态 }
function TFHMenu.Add(const ACaption: string; AOnClick: TNotifyEvent;
  const AShortcut: string; AIcon: TFHMenuIcon): TFHMenuItem;
begin
  Result := TFHMenuItem.Create;
  Result.FCaption := ACaption;
  Result.FOnClick := AOnClick;
  Result.FShortcut := AShortcut;
  Result.FIcon := AIcon;
  Result.FEnabled := True;
  Result.FVisible := True;
  FItems.Add(Result);
end;

{ 新增分隔线行 }
function TFHMenu.AddSeparator: TFHMenuItem;
begin
  Result := TFHMenuItem.Create;
  Result.FSeparator := True;
  Result.FEnabled := True;
  Result.FVisible := True;
  FItems.Add(Result);
end;

{ 缩放行: " −  100%  + " 一行三个点击区（−/+ 调档, 点百分比重置 100%）。
  点击后菜单不关闭, 百分比由 OnZoom 处理方通过 ANewPct 回填刷新 }
function TFHMenu.AddZoomRow(AOnZoom: TFHZoomEvent): TFHMenuItem;
begin
  Result := TFHMenuItem.Create;
  Result.FIsZoomRow := True;
  Result.FZoomPct := 100;
  Result.FZoomLabel := '缩放';
  Result.FIcon := miFind;              // Chrome 同款: 缩放行带放大镜图标
  Result.FEnabled := True;
  Result.FVisible := True;
  Result.FOnZoom := AOnZoom;
  FItems.Add(Result);
end;

{ 是否存在可见的勾选项（决定布局是否预留打勾列） }
function TFHMenu.HasCheckedItems: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FItems.Count - 1 do
    if FItems[I].Visible and FItems[I].Checked then
      Exit(True);
end;

{ 是否存在带图标的可见项（决定布局是否预留图标列） }
function TFHMenu.HasIconItems: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FItems.Count - 1 do
    if FItems[I].Visible and (FItems[I].Icon <> miNone) then
      Exit(True);
end;

{ 96 DPI 基准逻辑像素 → 按 ScaleFactor 换算（支持自定义缩放系数） }
function TFHMenu.ScalePx(P: Integer): Integer;
begin
  { 换算实现统一在 uFHDpi; 本方法保留只为支持自定义 ScaleFactor 属性 }
  Result := FHScalePxBy(P, FScale);
end;

{ 在屏幕坐标 (X,Y) 处弹出菜单: 先收掉旧弹窗, 再建菜单窗口显示 }
procedure TFHMenu.Popup(X, Y: Integer);
begin
  ClosePopup;
  if FItems.Count = 0 then Exit;
  FWindow := TFHMenuWindow.CreateNew(Self, 0);
  FWindow.FMenu := Self;
  FWindow.FConfine := FConfineToHost;
  FWindow.ShowAt(X, Y);
end;

{ TPoint 版弹出（转调 X/Y 版） }
procedure TFHMenu.Popup(const P: TPoint);
begin
  Popup(P.X, P.Y);
end;

{ 主动收起菜单（菜单窗口关闭时会自清 FWindow） }
procedure TFHMenu.ClosePopup;
begin
  if FWindow <> nil then
  begin
    FWindow.Close;
    FWindow := nil;
  end;
end;

function TFHMenu.PopupVisible: Boolean;
begin
  Result := (FWindow <> nil) and FWindow.Visible;
end;

{ ---- TFHMenuWindow -------------------------------------------------------- }

{ 构造: 无边框弹出窗体, 双缓冲防悬停闪烁, 不参与 VCL 自动缩放 }
constructor TFHMenuWindow.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  FHot := -1;
  FHotZone := -1;
  FConfine := True;
  BorderStyle := bsNone;
  Color := C_MENU_BG;
  { 悬停高亮走整窗 Invalidate: 无双缓冲时"先擦白再重绘"会闪烁,
    双缓冲 + WM_ERASEBKGND 抑制后一次上屏 }
  DoubleBuffered := True;
  Font.Name := C_MENU_FONT_NAME;
  Font.Color := C_MENU_TEXT;
  // 不参与各自的 VCL 尺寸/字体缩放: 本窗口所有数值已按 ScalePx 手动换算
  Position := poDesigned;
end;

{ 析构: 摘低级鼠标钩子、清全局弹出指针、销毁阴影底板并自清宿主 FWindow }
destructor TFHMenuWindow.Destroy;
begin
  if GHook <> 0 then
  begin
    UnhookWindowsHookEx(GHook);
    GHook := 0;
  end;
  if GPopup = Self then
    GPopup := nil;
  if FShadowWnd <> 0 then
  begin
    DestroyWindow(FShadowWnd);
    FShadowWnd := 0;
  end;
  if (FMenu <> nil) and (FMenu.FWindow = Self) then
    FMenu.FWindow := nil;
  inherited;
end;

{ 逻辑像素换算: 委托给宿主 TFHMenu（用它的 ScaleFactor） }
function TFHMenuWindow.ScalePx(P: Integer): Integer;
begin
  if FMenu <> nil then
    Result := FMenu.ScalePx(P)
  else
    Result := P;
end;

procedure TFHMenuWindow.ApplyFont;
var
  PPI: Integer;
begin
  { 字号必须在 LayoutPopup（量文字宽度）之前生效, 所以不能放在构造函数里:
    那时 FMenu 还没赋值, 拿不到 DPI 比例 }
  PPI := ScalePx(96);
  if PPI <= 0 then
    PPI := 96;
  Font.Name := C_MENU_FONT_NAME;
  Font.PixelsPerInch := PPI;       // 先设 PPI: SetPixelsPerInch 会按磅值重算 Height
  Font.Height := -MulDiv(C_MENU_FONT_PX, PPI, 96);
  Font.Color := C_MENU_TEXT;
end;

{ 行高: 分隔线行 9px, 普通行 32px（96 DPI 基准） }
function TFHMenuWindow.RowHeight(AItem: TFHMenuItem): Integer;
begin
  if AItem.Separator then
    Result := ScalePx(C_MENU_SEP_H)
  else
    Result := ScalePx(C_MENU_ROW_H);
end;

{ WS_POPUP 顶层窗 + 不进任务栏 + CS_SAVEBITS（被菜单遮住的区域免重绘） }
procedure TFHMenuWindow.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := WS_POPUP or WS_CLIPSIBLINGS or WS_CLIPCHILDREN;
  Params.ExStyle := WS_EX_TOOLWINDOW or WS_EX_CONTROLPARENT;  // 不进任务栏
  { 阴影不用 CS_DROPSHADOW: SetWindowRgn 的窗口 DWM 不画它（实测）,
    阴影由 ShowShadow 的分层窗口自绘 }
  Params.WindowClass.style := Params.WindowClass.style or CS_SAVEBITS;
end;

{ 句柄创建后: 设圆角裁剪区域并恢复 DWM 非客户区渲染（细节见体内注释） }
procedure TFHMenuWindow.CreateWnd;
var
  Rgn: HRGN;
  R: Integer;
  Pol: DWORD;
begin
  inherited;
  try
    { 圆角靠区域裁剪（这是唯一能让无边框窗口真正缺角的方式）。
      注意 +1: 实测 CreateRoundRectRgn(0,0,Width,Height) 的区域**不含**最右列/
      最下行（按 inclusive 处理）, 边框线和 DWM 阴影会缺右/下 —— 区域多给 1px
      才能盖满整个窗口矩形 }
    R := ScalePx(C_MENU_RADIUS);
    Rgn := CreateRoundRectRgn(0, 0, Width + 1, Height + 1, R * 2, R * 2);
    if Rgn <> 0 then
      SetWindowRgn(Handle, Rgn, True);
    { SetWindowRgn 会让 DWM 停掉本窗口的 CS_DROPSHADOW 阴影（实测右/下窗外
      全白）—— 显式要求恢复非客户区渲染（阴影），Win7 DWM 关闭时调用无害 }
    Pol := DWMNCRP_ENABLED;
    DwmSetWindowAttribute(Handle, DWMWA_NCRENDERING_POLICY, @Pol, SizeOf(Pol));
  except
    on E: Exception do
      Logger.Error('菜单窗口圆角/边框设置失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 阴影底板: 按四个方向不对称外扩的分层窗口（模仿 Chrome 九宫格阴影:
  上≈无、左右窄、下宽）, 内容 = 菜单圆角矩形向外的 alpha 渐变
  （premultiplied ARGB, UpdateLayeredWindow 一次性上屏）。
  WS_EX_TRANSPARENT + WM_NCHITTEST=HTTRANSPARENT 双保险点击穿透;
  SW_SHOWNOACTIVATE + WS_EX_NOACTIVATE 不抢菜单焦点 }
procedure TFHMenuWindow.ShowShadow;
var
  ML, MT, MR, MB, W, H, x, y, SL, ST: Integer;
  R, Blur: Double;
  qx, qy, Dist: Double;
  X1, Y1, X2, Y2, px, py: Double;
  Bits: PByteArray;
  MemDC: HDC;
  Bmp: HBITMAP;
  OldBmp: HGDIOBJ;
  BI: TBitmapInfo;
  Blend: TBlendFunction;
  PptDst, PptSrc: TPoint;
  Sizer: TSize;
  A: Integer;
begin
  if not EnsureShadowClass then Exit;
  ML := ScalePx(C_MENU_SHADOW_L);
  MT := ScalePx(C_MENU_SHADOW_T);
  MR := ScalePx(C_MENU_SHADOW_R);
  MB := ScalePx(C_MENU_SHADOW_B);
  W := Width + ML + MR;
  H := Height + MT + MB;
  SL := Left - ML;
  ST := Top - MT;
  { 阴影不越出宿主窗口: 主菜单贴着窗体右缘弹出时, 右侧阴影会探出窗外
    （Chrome 的做法就是阴影被窗口边缘直接裁掉 —— 分层窗口缩边即可,
      SDF 仍以菜单矩形定位, 被裁方向的渐变自然截断） }
  if FHasHost then
  begin
    if SL + W > FHostRect.Right then
      W := FHostRect.Right - SL;
    if ST + H > FHostRect.Bottom then
      H := FHostRect.Bottom - ST;
    if SL < FHostRect.Left then
    begin
      W := W - (FHostRect.Left - SL);
      SL := FHostRect.Left;
    end;
    if ST < FHostRect.Top then
    begin
      H := H - (FHostRect.Top - ST);
      ST := FHostRect.Top;
    end;
  end;
  if (W <= 0) or (H <= 0) then Exit;
  if FShadowWnd = 0 then
    FShadowWnd := CreateWindowEx(
      WS_EX_LAYERED or WS_EX_TRANSPARENT or WS_EX_TOOLWINDOW or
      WS_EX_NOACTIVATE or WS_EX_TOPMOST,
      'FHMenuShadow', '', WS_POPUP,
      SL, ST, W, H, 0, 0, HInstance, nil);
  if FShadowWnd = 0 then Exit;
  SetWindowPos(FShadowWnd, 0, SL, ST, W, H,
    SWP_NOACTIVATE or SWP_NOZORDER);

  { 内容: 32bpp 预乘 ARGB, 圆角矩形 SDF → alpha 渐变 }
  ZeroMemory(@BI, SizeOf(BI));
  BI.bmiHeader.biSize := SizeOf(BI.bmiHeader);
  BI.bmiHeader.biWidth := W;
  BI.bmiHeader.biHeight := -H;          // top-down
  BI.bmiHeader.biPlanes := 1;
  BI.bmiHeader.biBitCount := 32;
  BI.bmiHeader.biCompression := BI_RGB;
  MemDC := CreateCompatibleDC(0);
  Bmp := CreateDIBSection(MemDC, BI, DIB_RGB_COLORS, Pointer(Bits), 0, 0);
  if (Bmp = 0) or (Bits = nil) then
  begin
    if Bmp <> 0 then DeleteObject(Bmp);
    DeleteDC(MemDC);
    Exit;
  end;
  try
    try
      R := ScalePx(C_MENU_RADIUS);          // 菜单圆角半径
      Blur := ScalePx(C_MENU_SHADOW_BLUR);  // 渐变长度
    { 阴影坐标系里的菜单矩形（圆角矩形 SDF 用它定位）;
      用 Left-SL 而不是固定 ML, 是因为 SL 可能被宿主左缘裁剪过 }
    X1 := Left - SL; Y1 := Top - ST;
    X2 := X1 + Width; Y2 := Y1 + Height;
    for y := 0 to H - 1 do
    begin
      py := y + 0.5;
      for x := 0 to W - 1 do
      begin
        { 标准圆角矩形有向距离场（正值在外）, 相对菜单矩形而非窗口中心 }
        px := x + 0.5;
        qx := Max(X1 + R - px, px - (X2 - R));
        qy := Max(Y1 + R - py, py - (Y2 - R));
        Dist := Min(Max(qx, qy), 0) + Hypot(Max(qx, 0), Max(qy, 0)) - R;
        if Dist <= 0 then
          A := C_MENU_SHADOW_A            // 菜单本体内(含圆角缝隙): 恒定
        else if Dist >= Blur then
          A := 0
        else
          A := Round(C_MENU_SHADOW_A * (1 - Dist / Blur));
        if A > 0 then
        begin
          Bits[(y * W + x) * 4 + 0] := 0;          // B (预乘后黑)
          Bits[(y * W + x) * 4 + 1] := 0;          // G
          Bits[(y * W + x) * 4 + 2] := 0;          // R
          Bits[(y * W + x) * 4 + 3] := A;          // alpha
        end
        else
          PCardinal(@Bits[(y * W + x) * 4])^ := 0;
      end;
    end;
    OldBmp := SelectObject(MemDC, Bmp);
    ZeroMemory(@Blend, SizeOf(Blend));
    Blend.BlendOp := AC_SRC_OVER;
    Blend.SourceConstantAlpha := 255;
    Blend.AlphaFormat := AC_SRC_ALPHA;
    PptDst := Point(SL, ST);
    PptSrc := Point(0, 0);
    Sizer.cx := W;
    Sizer.cy := H;
    UpdateLayeredWindow(FShadowWnd, 0, @PptDst, @Sizer, MemDC, @PptSrc,
      0, @Blend, ULW_ALPHA);
    SelectObject(MemDC, OldBmp);
    finally
      DeleteObject(Bmp);
      DeleteDC(MemDC);
    end;
  except
    on E: Exception do
      Logger.Error('菜单阴影绘制失败: %s - %s', [E.ClassName, E.Message]);
  end;
  ShowWindow(FShadowWnd, SW_SHOWNOACTIVATE);
end;

{ 隐藏阴影底板（菜单收起时同步调用） }
procedure TFHMenuWindow.HideShadow;
begin
  if FShadowWnd <> 0 then
    ShowWindow(FShadowWnd, SW_HIDE);
end;

{ 关闭: 隐藏阴影 + 自清宿主 FWindow（防悬空）+ 释放窗口 }
procedure TFHMenuWindow.DoClose(var Action: TCloseAction);
begin
  inherited;
  HideShadow;              // 菜单收起时阴影同步消失
  if FMenu <> nil then
    FMenu.FWindow := nil;   // 自清: 防 TFHMenu.FWindow 悬空（Destroy 二次释放/
  Action := caFree;         // PopupVisible 误判都源于此）
end;

{ 弹出前布局: 量各列文字宽度定菜单尺寸, 记录每项顶边;
  再按宿主窗口/屏幕工作区两级夹紧位置（下方放不下翻到锚点上方） }
procedure TFHMenuWindow.LayoutPopup(X, Y: Integer);
var
  I, W, H, CapMax, ShortMax, T: Integer;
  Item: TFHMenuItem;
  Mon: TMonitor;
  WA, WB: TRect;
  Avail, EM: Integer;
  HasCheck, HasIcon, HasHost: Boolean;
  Meas: TBitmap;                     // 量文字用: 窗口句柄尚未创建, 不能用 Canvas
  PctW, ZoomRowW, HRow: Integer;
begin
  Meas := TBitmap.Create;
  try
    Meas.Canvas.Font.Assign(Font);
    HasCheck := (FMenu <> nil) and FMenu.HasCheckedItems;
    HasIcon := (FMenu <> nil) and FMenu.HasIconItems;
    FZoomLabelW := 0;

    CapMax := 0;
    ShortMax := 0;
    for I := 0 to FMenu.Count - 1 do
    begin
      Item := FMenu.Items[I];
      if not Item.Visible or Item.Separator then Continue;
      T := Meas.Canvas.TextWidth(Item.Caption);
      if T > CapMax then CapMax := T;
      if Item.Shortcut <> '' then
      begin
        T := Meas.Canvas.TextWidth(Item.Shortcut);
        if T > ShortMax then ShortMax := T;
      end;
      if Item.IsZoomRow and (Item.ZoomLabel <> '') and (FZoomLabelW = 0) then
        FZoomLabelW := Meas.Canvas.TextWidth(Item.ZoomLabel);
    end;
    { 缩放行最宽百分比 "500%" 的像素宽, 用于保障菜单宽度容得下整行 }
    PctW := Meas.Canvas.TextWidth('500%');
  finally
    Meas.Free;
  end;
  CapMax := Min(CapMax, ScalePx(C_MENU_MAX_TEXT));

  { 宿主（主窗体）矩形在这里提前取: 宽度要先按窗体可用宽度压过, 才能排文字列。
    FConfine=False（气泡/小浮层）时跳过宿主逻辑 —— 宿主反查会把浮层自身
    当宿主, 菜单会被夹在浮层内、下方放不下时翻到按钮上方 }
  HasHost := FConfine and HostWindowRect(X, Y, WB);
  FHasHost := HasHost;                  // 记下来给 ShowShadow 裁剪阴影用
  if HasHost then FHostRect := WB;

  W := ScalePx(C_MENU_PAD_X) * 2;
  FTextX := ScalePx(C_MENU_PAD_X);
  if HasCheck then
  begin
    Inc(W, ScalePx(C_MENU_CHECK_W));
    Inc(FTextX, ScalePx(C_MENU_CHECK_W));
  end;
  { 图标列在打勾列右侧: 图标 16px + 与文字的间距(Chrome 同款布局) }
  if HasIcon then
  begin
    Inc(W, ScalePx(C_MENU_ICON_W));
    Inc(FTextX, ScalePx(C_MENU_ICON_W));
  end;
  Inc(W, CapMax);
  if ShortMax > 0 then
    Inc(W, ScalePx(C_MENU_SHORTCUT_GAP) + ShortMax);
  { Chrome 的菜单不会窄成一条: 给个最小宽度（多余宽度落在标题列与快捷键列之间） }
  if W < ScalePx(C_MENU_MIN_WIDTH) then
    W := ScalePx(C_MENU_MIN_WIDTH);
  { 缩放行: "缩放"标签 + 间距 + 减号 + 百分比 + 加号, 保证菜单宽够容下整行 }
  if FZoomLabelW > 0 then
  begin
    HRow := ScalePx(C_MENU_ROW_H);
    ZoomRowW := FTextX + FZoomLabelW + ScalePx(C_ZOOM_LABEL_GAP) +
                HRow + PctW + HRow + ScalePx(C_MENU_ROW_INSET);
    if W < ZoomRowW then
      W := ZoomRowW;
  end;
  { 反之: 窗口比菜单还窄时（拉到极窄）压到窗宽, 保住"不越界"（标题自动省略号） }
  if HasHost then
  begin
    Avail := (WB.Right - WB.Left) - 2 * ScalePx(C_MENU_EDGE_MARGIN);
    if (Avail > 0) and (W > Avail) then
      W := Avail;
  end;
  { 布局统一从右缘推: 快捷键右对齐在右留白内缘, 标题右边界与快捷键列隔半个间距。
    注意 FShortcutX 必须先扣掉快捷键自身宽度 —— Paint 里快捷键矩形的左边界就是
    FShortcutX, 若只设成 W-PadX, 矩形宽度为 0, F12 会整个画不出来（踩过） }
  FShortcutX := W - ScalePx(C_MENU_PAD_X);
  if ShortMax > 0 then
  begin
    Dec(FShortcutX, ShortMax);
    FTextRight := FShortcutX - ScalePx(C_MENU_SHORTCUT_GAP div 2);
  end
  else
    FTextRight := FShortcutX;

  H := ScalePx(C_MENU_PAD_Y) * 2;
  SetLength(FTops, FMenu.Count);
  for I := 0 to FMenu.Count - 1 do
  begin
    Item := FMenu.Items[I];
    FTops[I] := 0;
    if not Item.Visible then Continue;
    FTops[I] := H;
    Inc(H, RowHeight(Item));
  end;

  { 贴着屏幕/工作区边缘时自动收位, 免得被任务栏或屏边裁掉 }
  Mon := nil;
  if Screen <> nil then
    Mon := Screen.MonitorFromPoint(Point(X, Y));
  if Mon <> nil then
    WA := Mon.WorkareaRect
  else
    WA := Rect(0, 0, Screen.Width, Screen.Height);
  { 1) 主窗体边界（Chrome 的菜单不探出浏览器窗口: 尤其是右侧的 ⋮ 菜单,
        从按钮左缘向右展开时很容易越过窗口右缘） }
  if HasHost then
  begin
    EM := ScalePx(C_MENU_EDGE_MARGIN);
    if X + W > WB.Right - EM then
      X := WB.Right - EM - W;         // 右缘收回窗内（留边距）
    if X < WB.Left + EM then
      X := WB.Left + EM;
    if Y + H > WB.Bottom - EM then
    begin
      Y := Y - H;                     // 下方放不下 → 翻到锚点上方（同 Chrome）
      if Y < WB.Top + EM then
        Y := WB.Bottom - EM - H;      // 上方也不够 → 贴窗体底缘
    end;
  end;

  { 2) 屏幕工作区: 宿主窗口本身贴边/任务栏占位的兜底 }
  if X + W > WA.Right then X := WA.Right - W;
  if Y + H > WA.Bottom then Y := WA.Bottom - H;
  if X < WA.Left then X := WA.Left;
  if Y < WA.Top then Y := WA.Top;

  SetBounds(X, Y, W, H);
end;

{ 显示入口: 钉字号 → 布局 → 显示 → 阴影垫底 → 取焦点 → 挂"点外关闭"钩子 }
procedure TFHMenuWindow.ShowAt(X, Y: Integer);
begin
  ApplyFont;                             // 先钉字号, 再量文字宽度排布
  LayoutPopup(X, Y);
  Show;
  ShowShadow;                            // 阴影垫底（不激活不穿透）
  { z 序: 菜单 > 阴影 > 其余窗口 —— 阴影同为 TOPMOST 时, 若宿主窗体也是
    TOPMOST 且先显示, 阴影环带会被宿主盖住（实测踩到）, 这里显式插到菜单后 }
  if FShadowWnd <> 0 then
    SetWindowPos(FShadowWnd, Handle, 0, 0, 0, 0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  Winapi.Windows.SetFocus(Handle);   // 方向键需要输入焦点（TWinControl.SetFocus 无参）
  GPopup := Self;
  GHook := SetWindowsHookEx(WH_MOUSE_LL, MenuMouseProc, HInstance, 0);
end;

{ 客户区 y → 命中的菜单项索引（跳过不可见项与分隔线）; 未命中返回 -1 }
function TFHMenuWindow.IndexAtPos(Y: Integer): Integer;
var
  I: Integer;
  Item: TFHMenuItem;
begin
  Result := -1;
  if FMenu = nil then Exit;
  for I := 0 to FMenu.Count - 1 do
  begin
    Item := FMenu.Items[I];
    if not Item.Visible or Item.Separator then Continue;
    if (Y >= FTops[I]) and (Y < FTops[I] + RowHeight(Item)) then
      Exit(I);
  end;
end;

{ 缩放行的三个分区矩形: − 在左（方形 = 行高）, + 在右, 百分比居中占其余空间 }
procedure TFHMenuWindow.ZoomZones(AIndex: Integer; out RM, RC, RP: TRect);
var
  H, Inset, LeftX: Integer;
begin
  H := RowHeight(FMenu.Items[AIndex]);
  Inset := ScalePx(C_MENU_ROW_INSET);
  { 有"缩放"标签时, 标签起点对齐其他菜单文字列 FTextX, 减号区从标签右 + 间距起;
    无标签则减号贴左内缩(原行为) }
  if FZoomLabelW > 0 then
    LeftX := FTextX + FZoomLabelW + ScalePx(C_ZOOM_LABEL_GAP)
  else
    LeftX := Inset;
  RM := Rect(LeftX, FTops[AIndex], LeftX + H, FTops[AIndex] + H);
  RP := Rect(ClientWidth - Inset - H, FTops[AIndex], ClientWidth - Inset,
    FTops[AIndex] + H);
  RC := Rect(RM.Right, FTops[AIndex], RP.Left, FTops[AIndex] + H);
end;

{ 缩放行 x → 分区号（0=− 1=百分比 2=+）; 不在任一分区返回 -1 }
function TFHMenuWindow.ZoneAtX(AX, AIndex: Integer): Integer;
var
  RM, RC, RP: TRect;
begin
  Result := -1;
  if (FMenu = nil) or (AIndex < 0) or (AIndex >= FMenu.Count) then Exit;
  ZoomZones(AIndex, RM, RC, RP);
  if (AX >= RM.Left) and (AX < RM.Right) then
    Result := 0
  else if (AX >= RP.Left) and (AX < RP.Right) then
    Result := 2
  else if (AX >= RC.Left) and (AX < RC.Right) then
    Result := 1;
end;

{ 执行缩放回调并刷新百分比显示。菜单保持打开 —— Chrome 的缩放按钮点了不收菜单。
  注意必须无条件 Invalidate: 回调方可能已经直接改过 ZoomPct（返回的 NewPct 与
  当前值相同）, 靠"值变了才重绘"会漏掉这次刷新（实测比例文字不即时更新） }
procedure TFHMenuWindow.DoZoom(AItem: TFHMenuItem; ADelta: Integer);
var
  NewPct: Integer;
begin
  if (AItem = nil) or not AItem.IsZoomRow or not Assigned(AItem.FOnZoom) then Exit;
  NewPct := AItem.FZoomPct;
  try
    AItem.FOnZoom(Self, ADelta, NewPct);
  except
    on E: Exception do
      Logger.Error('缩放回调执行失败 (delta=%d): %s - %s', [ADelta, E.ClassName, E.Message]);
  end;
  AItem.FZoomPct := NewPct;
  Invalidate;
end;

{ 设置高亮项: 禁用/不可见项不给高亮; 变化时重绘 }
procedure TFHMenuWindow.SetHot(AIndex: Integer);
var
  Item: TFHMenuItem;
begin
  if (AIndex >= 0) and (FMenu <> nil) then
  begin
    Item := FMenu.Items[AIndex];
    if not Item.Enabled or not Item.Visible then
      AIndex := -1;
  end;
  if AIndex <> FHot then
  begin
    FHot := AIndex;
    Invalidate;
  end;
end;

{ 执行当前高亮项: 缩放行走 DoZoom（不关菜单）, 普通项先关菜单再触发 OnClick }
procedure TFHMenuWindow.ExecuteHot;
var
  Item: TFHMenuItem;
begin
  if (FHot < 0) or (FMenu = nil) then Exit;
  Item := FMenu.Items[FHot];
  if Item.IsZoomRow then
  begin
    DoZoom(Item, 0);       // 回车/空格 = 点百分比 = 重置 100%（不关菜单）
    Exit;
  end;
  Close;
  { 先关再执行: 处理逻辑里可能再次弹出菜单或改变窗口焦点 }
  try
    Item.Click;
  except
    on E: Exception do
      Logger.Error('菜单项 "%s" 点击处理失败: %s - %s',
        [Item.Caption, E.ClassName, E.Message]);
  end;
end;

{ 勾选符号 ✓（打勾列; 颜色随所在行的文字状态） }
procedure TFHMenuWindow.DrawCheck(X, Y: Integer; Color: TColor);
var
  A: Integer;
begin
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := Color;
  Canvas.Pen.Width := Max(1, ScalePx(2));
  A := ScalePx(3);
  Canvas.MoveTo(X, Y);
  Canvas.LineTo(X + A, Y + A);
  Canvas.MoveTo(X + A, Y + A);
  Canvas.LineTo(X + A * 3, Y - A);
end;

{ 全件自绘: 逐行画分隔线/缩放行（三分区圆底悬停）/普通行（悬停底 +
  勾选列 + 图标列 + 标题 + 快捷键列）, 最后描圆角边框（细节见体内注释） }
procedure TFHMenuWindow.Paint;
var
  I, Y, CX, CY, D: Integer;
  Item: TFHMenuItem;
  R, HotR, RM, RC, RP, LR: TRect;
  Clr: TColor;
  HasCheck, HasIcon: Boolean;
  S: string;

  { 行首图标: 图标列起点在打勾列右侧, 垂直居中; 颜色随行状态 }
  procedure DrawItemIcon(AItem: TFHMenuItem; ARowTop: Integer; AColor: TColor);
  var
    IX: Integer;
  begin
    if not HasIcon or (AItem.Icon = miNone) then Exit;
    IX := ScalePx(C_MENU_PAD_X);
    if HasCheck then
      Inc(IX, ScalePx(C_MENU_CHECK_W));
    DrawMenuIcon(Canvas, IX,
      ARowTop + (RowHeight(AItem) - ScalePx(C_MENU_ICON_SZ)) div 2,
      ScalePx(C_MENU_ICON_SZ), AItem.Icon, AColor);
  end;

begin
  Canvas.Lock;
  try
  try
    Canvas.Font.Assign(Font);
    HasCheck := (FMenu <> nil) and FMenu.HasCheckedItems;
    HasIcon := (FMenu <> nil) and FMenu.HasIconItems;

    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := C_MENU_BG;
    Canvas.Pen.Style := psClear;
    Canvas.FillRect(ClientRect);

    for I := 0 to FMenu.Count - 1 do
    begin
      Item := FMenu.Items[I];
      if not Item.Visible then Continue;
      Y := FTops[I];

      if Item.Separator then
      begin
        Canvas.Pen.Style := psSolid;
        Canvas.Pen.Color := C_MENU_BORDER;
        Canvas.Pen.Width := 1;
        Canvas.MoveTo(ScalePx(C_MENU_PAD_X), Y + RowHeight(Item) div 2);
        Canvas.LineTo(ClientWidth - ScalePx(C_MENU_PAD_X),
          Y + RowHeight(Item) div 2);
        Canvas.Pen.Style := psClear;
        Continue;
      end;

      if Item.IsZoomRow then
      begin
        { 缩放行: " −  100%  + ", 三个分区。悬停画**正圆**底（Chrome 同款,
          不做整行高亮）; 到达档位边界的一侧置灰。
          圆以各分区中心为圆心、直径统一 = 行高 - 6 —— 之前用分区矩形直接
          Ellipse(32x28) 是椭圆, 不像 Chrome 的圆形按钮 }
        ZoomZones(I, RM, RC, RP);
        { 行首图标(Chrome 缩放行带放大镜) }
        DrawItemIcon(Item, Y, C_MENU_TEXT);
        { "缩放"标签: 起点对齐其他菜单文字列 FTextX, 左对齐垂直居中 }
        if FZoomLabelW > 0 then
        begin
          Canvas.Font.Color := C_MENU_TEXT;
          S := Item.ZoomLabel;
          LR := Rect(FTextX, RM.Top, FTextX + FZoomLabelW, RM.Bottom);
          Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), LR,
            DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_NOPREFIX);
        end;
        Canvas.Pen.Style := psClear;
        Canvas.Brush.Style := bsSolid;
        Canvas.Brush.Color := C_MENU_HOT;
        D := RowHeight(Item) - ScalePx(6);
        if (I = FHot) and (FHotZone = 0) and (Item.ZoomPct > C_ZOOM_MIN_PCT) then
        begin
          CX := (RM.Left + RM.Right) div 2;
          CY := (RM.Top + RM.Bottom) div 2;
          { GDI+ 抗锯齿圆底; 失败回退 GDI Ellipse }
          if not FillEllipseAA(Canvas, CX - D / 2, CY - D / 2, D, D,
            C_MENU_HOT, clNone, 0) then
          begin
            Canvas.Brush.Style := bsSolid;
            Canvas.Brush.Color := C_MENU_HOT;
            Canvas.Pen.Color := C_MENU_HOT;
            Canvas.Ellipse(CX - D div 2, CY - D div 2,
              CX + D div 2, CY + D div 2);
          end;
        end;
        if (I = FHot) and (FHotZone = 2) and (Item.ZoomPct < C_ZOOM_MAX_PCT) then
        begin
          CX := (RP.Left + RP.Right) div 2;
          CY := (RP.Top + RP.Bottom) div 2;
          if not FillEllipseAA(Canvas, CX - D / 2, CY - D / 2, D, D,
            C_MENU_HOT, clNone, 0) then
          begin
            Canvas.Brush.Style := bsSolid;
            Canvas.Brush.Color := C_MENU_HOT;
            Canvas.Pen.Color := C_MENU_HOT;
            Canvas.Ellipse(CX - D div 2, CY - D div 2,
              CX + D div 2, CY + D div 2);
          end;
        end;
        if (I = FHot) and (FHotZone = 1) then
        begin
          CX := (RC.Left + RC.Right) div 2;
          CY := (RC.Top + RC.Bottom) div 2;
          if not FillEllipseAA(Canvas, CX - D / 2, CY - D / 2, D, D,
            C_MENU_HOT, clNone, 0) then
          begin
            Canvas.Brush.Style := bsSolid;
            Canvas.Brush.Color := C_MENU_HOT;
            Canvas.Pen.Color := C_MENU_HOT;
            Canvas.Ellipse(CX - D div 2, CY - D div 2,
              CX + D div 2, CY + D div 2);
          end;
        end;

        Canvas.Brush.Style := bsClear;
        { − : 左分区居中, 到底置灰 }
        if Item.ZoomPct > C_ZOOM_MIN_PCT then
          Clr := C_MENU_TEXT
        else
          Clr := C_MENU_TEXT_DIS;
        Canvas.Font.Color := Clr;
        S := string(Char($2212));                 // U+2212 数学减号（Chrome 同款）
        Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), RM,
          DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);

        { 百分比: 居中（点它 = 重置 100%） }
        Canvas.Font.Color := C_MENU_TEXT;
        S := IntToStr(Item.ZoomPct) + '%';
        Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), RC,
          DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);

        { + : 右分区居中, 到顶置灰 }
        if Item.ZoomPct < C_ZOOM_MAX_PCT then
          Clr := C_MENU_TEXT
        else
          Clr := C_MENU_TEXT_DIS;
        Canvas.Font.Color := Clr;
        S := '+';
        Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), RP,
          DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);
        Canvas.Brush.Style := bsSolid;
        Continue;
      end;

      if I = FHot then
      begin
        HotR := Rect(ScalePx(C_MENU_ROW_INSET), Y,
          ClientWidth - ScalePx(C_MENU_ROW_INSET), Y + RowHeight(Item));
        Canvas.Brush.Color := C_MENU_HOT;
        Canvas.FillRect(HotR);
      end;

      if Item.Enabled then
        Clr := C_MENU_TEXT
      else
        Clr := C_MENU_TEXT_DIS;
      Canvas.Font.Color := Clr;

      if HasCheck and Item.Checked then
        DrawCheck(ScalePx(C_MENU_PAD_X), Y + RowHeight(Item) div 2, Clr);

      { 行首图标: 颜色随行状态(禁用灰) }
      DrawItemIcon(Item, Y, Clr);

      { 标题: 到标题列右边界为止, 过长打省略号 }
      R := Rect(FTextX, Y, FTextRight, Y + RowHeight(Item));
      Canvas.Brush.Style := bsClear;
      Winapi.Windows.DrawText(Canvas.Handle, PChar(Item.Caption),
        Length(Item.Caption), R,
        DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_END_ELLIPSIS or DT_NOPREFIX);

      { 快捷键: 右对齐的浅色列（Chrome 同款, 比标题暗一档） }
      if Item.Shortcut <> '' then
      begin
        Canvas.Font.Color := C_MENU_SHORTCUT;
        R := Rect(FShortcutX, Y, ClientWidth - ScalePx(C_MENU_PAD_X),
          Y + RowHeight(Item));
        Winapi.Windows.DrawText(Canvas.Handle, PChar(Item.Shortcut),
          Length(Item.Shortcut), R,
          DT_SINGLELINE or DT_VCENTER or DT_RIGHT or DT_NOPREFIX);
      end;
      Canvas.Brush.Style := bsSolid;
    end;

    { 边框画最后: 圆角窗口的边框比内容更容易被行底色压到 }
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Style := psSolid;
    Canvas.Pen.Width := 1;
    Canvas.Pen.Color := C_MENU_BORDER;
    Canvas.RoundRect(0, 0, ClientWidth, ClientHeight,
      ScalePx(C_MENU_RADIUS) * 2, ScalePx(C_MENU_RADIUS) * 2);
    Canvas.Pen.Style := psClear;
  except
    on E: Exception do
      Logger.Error('菜单绘制失败: %s - %s', [E.ClassName, E.Message]);
  end;
  finally
    Canvas.Unlock;
  end;
end;

procedure TFHMenuWindow.CMDeactivate(var Message: TCMDeactivate);
begin
  inherited;
  { 焦点被别处抢走（Alt-Tab / 点了别的窗口）→ 和 Chrome 一样收掉菜单 }
  Close;
end;

{ 抑制背景擦除: Paint 开头就 FillRect 全客户区, 系统擦白只会造成闪烁 }
procedure TFHMenuWindow.WMEraseBkgnd(var Message: TWMEraseBkgnd);
begin
  Message.Result := 1;
end;

{ 鼠标移动: 更新高亮项; 缩放行另跟踪悬停分区（画圆形悬停底） }
procedure TFHMenuWindow.WMMouseMove(var Message: TWMMouseMove);
var
  I, Z: Integer;
begin
  inherited;
  I := IndexAtPos(Message.YPos);
  SetHot(I);
  { 缩放行: 悬停分区（画圆形悬停底）而不是整行高亮 }
  Z := -1;
  if (I >= 0) and FMenu.Items[I].IsZoomRow then
    Z := ZoneAtX(Message.XPos, I);
  if Z <> FHotZone then
  begin
    FHotZone := Z;
    Invalidate;
  end;
end;

{ 鼠标左键松开: 点在窗内 → 执行高亮项（缩放行按分区调档且不关菜单）;
  点在窗外 → 关闭 }
procedure TFHMenuWindow.WMLButtonUp(var Message: TWMLButtonUp);
var
  Inside: Boolean;
  Item: TFHMenuItem;
  Z: Integer;
begin
  Inside := (Message.XPos >= 0) and (Message.YPos >= 0) and
            (Message.XPos < ClientWidth) and (Message.YPos < ClientHeight);
  if Inside then
  begin
    if (FHot >= 0) and (FMenu <> nil) then
    begin
      Item := FMenu.Items[FHot];
      if Item.IsZoomRow then
      begin
        Z := ZoneAtX(Message.XPos, FHot);
        case Z of
          0: DoZoom(Item, -1);   // − : 缩小一档
          2: DoZoom(Item, 1);    // + : 放大一档
          1: DoZoom(Item, 0);    // 点百分比: 重置 100%
        end;
        Exit;                    // 缩放行点击不关菜单（Chrome 同款）
      end;
    end;
    ExecuteHot
  end
  else
    Close;
end;

{ 键盘: Esc 关闭, 回车/空格执行高亮项, 方向键/Home/End 移动高亮
  （跳过禁用与分隔线, 最多绕一圈防死循环） }
procedure TFHMenuWindow.WMKeyDown(var Message: TWMKeyDown);

  function Selectable(AIndex: Integer): Boolean;
  begin
    Result := (FMenu <> nil) and (AIndex >= 0) and (AIndex < FMenu.Count) and
      FMenu.Items[AIndex].Visible and (not FMenu.Items[AIndex].Separator) and
      FMenu.Items[AIndex].Enabled;
  end;

var
  I, Step: Integer;
begin
  inherited;
  case Message.CharCode of
    VK_ESCAPE:
      Close;
    VK_RETURN, VK_SPACE:
      ExecuteHot;
    VK_UP, VK_DOWN, VK_HOME, VK_END:
      begin
        if FMenu = nil then Exit;
        I := FHot;
        { 最多绕一圈: 全部禁用时不会死循环 }
        for Step := 1 to FMenu.Count do
        begin
          case Message.CharCode of
            VK_HOME: I := 0;
            VK_END:  I := FMenu.Count - 1;
            VK_DOWN: begin Inc(I); if I >= FMenu.Count then I := 0; end;
          else      begin Dec(I); if I < 0 then I := FMenu.Count - 1; end;
          end;
          if Selectable(I) then
          begin
            SetHot(I);
            Exit;
          end;
        end;
      end;
  end;
end;

end.
