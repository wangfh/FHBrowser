unit uFHChromeTabs;

{==============================================================================
  FHChromeTabs —— Chrome 风格标签条控件（核心单元）
  ----------------------------------------------------------------------------
  对应需求文档 docs/需求文档.md:
    - 第 4 节 界面规格（药丸顶路径/分隔线/悬停/配色 Token）
    - 第 6.1 节 事件清单（10 个事件全部触发）
    - FR-1..FR-10 功能需求（数据模型/新建/激活/关闭/拖拽/Pin/溢出/菜单/Hint/图标）
  约定:
    - 零 CEF 依赖: 本单元不得 uses 任何 uCEF* 单元（文档 14.1 集成总则）
    - Win7 兼容: 仅用 GDI/msimg32 基础 API（NFR-8）
    - 已实现阶段: S1 绘制 / S2 悬停点击 / S3 拖拽+Pin / S4 溢出+菜单+Hint
      待办: S5 单测工程; S7 favicon 桥接（宿主侧）
==============================================================================}

interface

uses
  Winapi.Windows, Winapi.Messages, System.Classes, System.SysUtils,
  System.Types, System.UITypes, System.Math, Vcl.Controls, Vcl.Graphics,
  Vcl.ImgList, Vcl.Forms, Vcl.ExtCtrls,
  Winapi.GDIPOBJ, Winapi.GDIPAPI,
  uFHDpi, uFHChromeMenu;

{ EnsureGdiPlus: 懒启动 GDI+（进程内共享同一份 token）。
  返回 False = GDI+ 不可用, 调用方应退化到 GDI 绘制。
  公开目的: 同一套自绘控件（地址栏胶囊/导航图标）直接复用这份会话做抗锯齿绘制 }
function EnsureGdiPlus: Boolean;

const
  { 96 DPI 基准像素常量（文档 4.1 / 4.2）; 运行时经 ScalePx 换算。

    以下数值对齐 Supermium 144 / Chromium 138+（即 Chrome Refresh GM3 之后的
    新版 UI）: chrome/browser/ui/layout_constants.cc 的 SetLayoutConstantsFallback()
    与 chrome/browser/ui/tabs/tab_style.cc:
      TABSTRIP_TOOLBAR_OVERLAP  = 1
      TAB_HEIGHT                = 34 + overlap        = 35
      TAB_STRIP_PADDING         = 6   (标签上方留白)
      TAB_STRIP_HEIGHT          = TAB_HEIGHT + padding = 41
      TAB_WIDTH                 = 240 (+ 2*BottomRadius = 264)
      TAB_TOP_CORNER_RADIUS     = 10, TAB_BOTTOM_CORNER_RADIUS = 12
      ContentsInsets 左右 = BottomRadius(12) + TAB_HORIZONTAL_PADDING(8) = 20
      GetStandardWidth          = 264, GetMinimumActiveWidth = 56
      GetPinnedWidth            = 24 + 20*2            = 64
      NewTabButton::kButtonSize = 28x28, TAB_CLOSE_BUTTON_SIZE = 16 }
  C_FH_BarHeight       = 41;   // TAB_STRIP_HEIGHT = 35 + 6
  C_FH_TabStripTopPad  = 6;    // TAB_STRIP_PADDING: 标签起点与条顶的距离
  C_FH_DefaultTabWidth = 264;  // TAB_WIDTH(240) + 2*BottomRadius(12)
  C_FH_MaxTabWidth     = 264;  // 同标准宽: 少标签时不拉宽
  C_FH_MinTabWidth     = 56;   // GetMinimumActiveWidth = Close(16) + 20*2
  C_FH_PinnedTabWidth  = 64;   // 24 + 20*2
  C_FH_NewBtnSize      = 28;   // NewTabButton::kButtonSize
  C_FH_CloseBtnSize    = 16;   // TAB_CLOSE_BUTTON_SIZE（热区, 不是符号本身）
  { 符号尺寸（96 DPI 基准的"半长"）: 原来 × 是贴着 16 热区两角画, 实际长度约 12;
    + 是 ±8。都偏大, 按 Chrome 观感收敛到 ×总长 8 / +总长 12 }
  C_FH_CloseCrossHalf  = 4;
  C_FH_NewPlusHalf     = 6;
  C_FH_GlyphStroke     = 1.5;  // 符号描边(逻辑px, 浮点): GDI+ 抗锯齿下与 Chrome 观感一致;
                               // 旧值 1 在两个屏幕上都偏细（GDI 时代用 2 会糊, AA 下不会）
  C_FH_IconSize        = 16;   // 标签 favicon
  { 标签标题字号 = 12px（Chrome 在 Windows 上的标签标题字号; 96 DPI 基准的"像素"）。
    注意: Delphi 的 Font.Size 单位是**磅(pt)**, 写 9 恰好得到 12px,
    但磅值跨 DPI 换算易错 —— 统一按像素设 Font.Height, 与地址栏 C_FH_EditFontPx 同法 }
  C_FH_TabTitleFontPx  = 12;
  C_FH_FontName        = 'Segoe UI';   // Chrome 用系统 UI 字体（Win）
  C_FH_TabTopRadius    = 10;   // TAB_TOP_CORNER_RADIUS（形状, 可调）
  C_FH_TabBottomFlare  = 6;    // 对应 BottomRadius 12 的外扩弧（形状, 可调）
  C_FH_TabPadLeft      = 20;   // ContentsInsets 左 = 12 + 8
  C_FH_TabTextGap      = 8;    // TAB_PRE_TITLE_PADDING
  C_FH_ClosePadRight   = 20;   // ContentsInsets 右
  C_FH_BarPadding      = 4;
  C_FH_DragThreshold   = 4;    // 拖拽启动阈值（FR-5）
  C_FH_ArrowWidth      = 18;   // 溢出滚动箭头宽（文档 4.6）
  C_FH_ArrowScrollStep = 40;   // 箭头滚动步长（文档 4.6）
  C_FH_ScrollTimerMS   = 80;   // 箭头悬停滚动间隔（文档 4.6）

type
  TFHChromeTabs = class;   // 前置声明

  { ---- 事件类型（文档 6.1） --------------------------------------------- }
  TFHTabIndexEvent     = procedure(Sender: TObject; TabIndex: Integer) of object;
  TFHTabAllowEvent     = procedure(Sender: TObject; TabIndex: Integer;
                                   var Allow: Boolean) of object;
  TFHTabSwitchingEvent = procedure(Sender: TObject; OldIndex, NewIndex: Integer;
                                   var AllowChange: Boolean) of object;
  TFHTabSwitchEvent    = procedure(Sender: TObject; OldIndex, NewIndex: Integer) of object;
  TFHTabMoveEvent      = procedure(Sender: TObject; FromIndex, ToIndex: Integer) of object;
  TFHTabPinEvent       = procedure(Sender: TObject; TabIndex: Integer;
                                   Pinned: Boolean) of object;
  TFHTabMenuEvent      = procedure(Sender: TObject; TabIndex: Integer;
                                   var Handled: Boolean) of object;

  { ---- TFHChromeTab: 单个标签数据（文档 FR-1） -------------------------- }
  TFHChromeTab = class(TCollectionItem)
  private
    FCaption: string;
    FImageIndex: System.UITypes.TImageIndex;
    FIcon: TIcon;
    FPinned: Boolean;
    FData: TObject;
    FVisible: Boolean;
    procedure SetCaption(const Value: string);
    procedure SetImageIndex(Value: System.UITypes.TImageIndex);
    procedure SetIcon(Value: TIcon);
    procedure SetPinned(Value: Boolean);
    procedure SetVisible(Value: Boolean);
  protected
    function GetDisplayName: string; override;
  public
    constructor Create(Collection: TCollection); override;
    destructor Destroy; override;
    { Data: 宿主挂任意对象; 所有权归宿主, 本组件不释放（文档 FR-1） }
    property Data: TObject read FData write FData;
  published
    property Caption: string read FCaption write SetCaption;
    property ImageIndex: System.UITypes.TImageIndex read FImageIndex write SetImageIndex default -1;
    { Icon: 独立图标, 所有权归本 Tab, 销毁时释放（文档 FR-10） }
    property Icon: TIcon read FIcon write SetIcon;
    property Pinned: Boolean read FPinned write SetPinned default False;
    property Visible: Boolean read FVisible write SetVisible default True;
  end;

  { ---- TFHChromeTabCollection: 标签集合（文档 8） ----------------------- }
  TFHChromeTabCollection = class(TOwnedCollection)
  private
    function GetItem(Index: Integer): TFHChromeTab;
  protected
    { 集合任何变更 → 主控件重排（含设计时集合编辑器, FR-1） }
    procedure Update(Item: TCollectionItem); override;
  public
    function Add: TFHChromeTab;
    function Insert(Index: Integer): TFHChromeTab;
    { IndexOf: 对象引用解析——Page↔Tab 关联基础（文档 3.3.1） }
    function IndexOf(ATab: TFHChromeTab): Integer;
    { Move: 重排标签（TCollection 本身无 Move——那是 TList 的; 用 Item.Index 实现,
      单次 Update 触发一次重排） }
    procedure Move(FromIndex, ToIndex: Integer);
    property Items[Index: Integer]: TFHChromeTab read GetItem; default;
  end;

  { ---- TFHChromeTabsTheme: 配色 Token 集（文档 4.4） -------------------- }
  TFHChromeTabsTheme = class(TPersistent)
  private
    FBarBackground: TColor;
    FTabActiveFill: TColor;
    FTabInactiveFill: TColor;
    FTabHoverFill: TColor;
    FTabTextColor: TColor;
    FTabTextInactiveColor: TColor;
    FSeparatorColor: TColor;
    FCloseBtnColor: TColor;
    FCloseBtnHoverBg: TColor;
    FCloseBtnHoverColor: TColor;
    FNewBtnColor: TColor;
    FNewBtnHoverBg: TColor;
    FFocusIndicator: TColor;
    FPageHostColor: TColor;
    FOnChange: TNotifyEvent;
    procedure ApplyColor(var Target: TColor; Value: TColor);
    procedure SetBarBackground(Value: TColor);
    procedure SetTabActiveFill(Value: TColor);
    procedure SetTabInactiveFill(Value: TColor);
    procedure SetTabHoverFill(Value: TColor);
    procedure SetTabTextColor(Value: TColor);
    procedure SetTabTextInactiveColor(Value: TColor);
    procedure SetSeparatorColor(Value: TColor);
    procedure SetCloseBtnColor(Value: TColor);
    procedure SetCloseBtnHoverBg(Value: TColor);
    procedure SetCloseBtnHoverColor(Value: TColor);
    procedure SetNewBtnColor(Value: TColor);
    procedure SetNewBtnHoverBg(Value: TColor);
    procedure SetFocusIndicator(Value: TColor);
    procedure SetPageHostColor(Value: TColor);
  public
    constructor Create;
    procedure Assign(Source: TPersistent); override;
    procedure SetLightTheme;   // 浅色（默认, 文档 4.4）
    procedure SetDarkTheme;    // 深色（文档 4.4）
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  published
    property BarBackground: TColor read FBarBackground write SetBarBackground;
    property TabActiveFill: TColor read FTabActiveFill write SetTabActiveFill;
    property TabInactiveFill: TColor read FTabInactiveFill write SetTabInactiveFill;
    property TabHoverFill: TColor read FTabHoverFill write SetTabHoverFill;
    property TabTextColor: TColor read FTabTextColor write SetTabTextColor;
    property TabTextInactiveColor: TColor read FTabTextInactiveColor write SetTabTextInactiveColor;
    property SeparatorColor: TColor read FSeparatorColor write SetSeparatorColor;
    property CloseBtnColor: TColor read FCloseBtnColor write SetCloseBtnColor;
    property CloseBtnHoverBg: TColor read FCloseBtnHoverBg write SetCloseBtnHoverBg;
    property CloseBtnHoverColor: TColor read FCloseBtnHoverColor write SetCloseBtnHoverColor;
    property NewBtnColor: TColor read FNewBtnColor write SetNewBtnColor;
    property NewBtnHoverBg: TColor read FNewBtnHoverBg write SetNewBtnHoverBg;
    property FocusIndicator: TColor read FFocusIndicator write SetFocusIndicator;
    { PageHostColor: 供 TFHChromePageHost 取用（文档 4.4 一体观感） }
    property PageHostColor: TColor read FPageHostColor write SetPageHostColor;
  end;

  { ---- 布局记录（文档 8 布局层; X 为内容坐标, 绘制时平移 -ScrollOffset） -- }
  TFHTabLayoutRec = record
    TabIndex: Integer;
    X: Integer;
    Width: Integer;
  end;

  { ---- 命中区域分类（交互层内部） --------------------------------------- }
  TFHHitKind = (hkNone, hkTab, hkClose, hkNew, hkArrowLeft, hkArrowRight);

  { ---- TFHChromeTabs: 主控件（标签条） ---------------------------------- }
  TFHChromeTabs = class(TCustomControl)
  private
    FTabs: TFHChromeTabCollection;
    FTheme: TFHChromeTabsTheme;
    FImages: TCustomImageList;
    FChangeLink: TChangeLink;          // ImageList 变更联动（FR-10）
    FActiveIndex: Integer;             // -1 = 无（FR-3）
    FUpdateCount: Integer;             // BeginUpdate/EndUpdate 计数（FR-1）
    FLayout: TArray<TFHTabLayoutRec>;  // 可见标签布局（MeasureLayout 输出）
    FLastTabRight: Integer;            // 内容总宽右缘（+按钮定位, 非溢出）
    FScaleFactor: Single;              // DPI 缩放（System DPI 基线, NFR-2）
    FPaintCount: Integer;              // Paint 执行计数（诊断用, 见 PaintCount 属性）
    FOverflow: Boolean;                // 溢出模式（FR-7）
    FMaxScroll: Integer;
    FScrollOffset: Integer;
    FScrollTimer: TTimer;              // 箭头悬停持续滚动（文档 4.6）
    FScrollDir: Integer;               // 悬停滚动方向: -1 左 / 1 右
    FMenu: TFHMenu;                    // 内置右键菜单（FR-8, 按需创建, Chrome 风格）
    FMenuTabIndex: Integer;
    FMenuNewRight, FMenuReload, FMenuDup: TFHMenuItem;
    FMenuPin, FMenuClose, FMenuOthers, FMenuRight, FMenuLeft: TFHMenuItem;
    FSuppressTabMoved: Boolean;        // Pin 重排期间抑制 OnTabMoved（非用户拖拽）
    // GDI+ 复用对象（每帧重建代价高: 原实现每标签每帧 new 三次）
    FPath: TGPGraphicsPath;
    FBrush: TGPSolidBrush;
    // 悬停状态（S2, 文档 4.5 状态矩阵）
    FHoverKind: TFHHitKind;
    FHoverIndex: Integer;              // hkTab/hkClose 时的集合索引
    // 按压/拖拽状态机（S3, FR-5）
    FPressKind: TFHHitKind;
    FPressIndex: Integer;
    FPressPos: TPoint;
    FDragging: Boolean;
    FKeyFocusVisible: Boolean;         // 焦点环只在键盘交互时显示（鼠标点击/拖拽后不残留蓝框）
    FDragTab: TFHChromeTab;            // 被拖对象引用（免疫 Move 位移）
    FDragFromIndex: Integer;
    FDragX: Integer;                   // 幽灵标签左缘（鼠标驱动）
    FGrabDX: Integer;                  // 按下点距标签左缘偏移
    FDragMoved: Boolean;
    // 功能开关存储（文档 7.1 published 属性）
    FShowCloseButtons: Boolean;
    FShowNewButton: Boolean;
    FShowScrollArrows: Boolean;
    FRightReserved: Integer;          // 右侧预留宽度（标题栏按钮区避让）
    FCaptionArea: Boolean;            // 空白区按标题栏处理（命中穿透给宿主窗体）
    FShowContextMenu: Boolean;
    FTabDefaultWidth: Integer;
    FTabMaxWidth: Integer;
    FTabMinWidth: Integer;
    FPinnedTabWidth: Integer;
    FScrollStep: Integer;
    // 事件存储（文档 6.1）
    FOnTabClick: TFHTabIndexEvent;
    FOnTabDblClick: TFHTabIndexEvent;
    FOnActiveTabChanging: TFHTabSwitchingEvent;
    FOnActiveTabChange: TFHTabSwitchEvent;
    FOnTabClosing: TFHTabAllowEvent;
    FOnTabClosed: TFHTabIndexEvent;
    FOnTabMoved: TFHTabMoveEvent;
    FOnTabPinChanged: TFHTabPinEvent;
    FOnNewButtonClick: TNotifyEvent;
    FOnTabContextMenu: TFHTabMenuEvent;
    { 右键菜单里三个"要动浏览器"的动作: 组件不依赖 CEF, 交给宿主实现。
      TabIndex = 右键的那个标签索引 }
    FOnTabNewToRight: TFHTabIndexEvent;   // 在右侧新增标签页
    FOnTabReload: TFHTabIndexEvent;       // 重新加载
    FOnTabDuplicate: TFHTabIndexEvent;    // 复制（同 URL 开新标签）
    FOnThemeChanged: TNotifyEvent;      // 主题变更通知（供 PageHost 等联动底色）
    // 属性 setter
    procedure SetTabs(Value: TFHChromeTabCollection);
    procedure SetTheme(Value: TFHChromeTabsTheme);
    procedure SetActiveTabIndex(Value: Integer);
    procedure SetImages(Value: TCustomImageList);
    procedure SetShowCloseButtons(Value: Boolean);
    procedure SetShowNewButton(Value: Boolean);
    procedure SetShowScrollArrows(Value: Boolean);
    procedure SetRightReserved(Value: Integer);
    procedure SetShowContextMenu(Value: Boolean);
    procedure SetTabDefaultWidth(Value: Integer);
    procedure SetTabMaxWidth(Value: Integer);
    procedure SetTabMinWidth(Value: Integer);
    procedure SetPinnedTabWidth(Value: Integer);
    procedure SetScrollStep(Value: Integer);
    procedure ThemeChanged(Sender: TObject);
    { 把 VCL 的铺底画刷(Color)同步为当前主题条底色 }
    procedure SyncColorToTheme;
    procedure ImagesChanged(Sender: TObject);
    // 几何与命中
    function ViewLeft: Integer;        // 标签视口左缘（含箭头占位）
    function ViewRight: Integer;       // 标签视口右缘（减 +按钮占位）
    function NewButtonRect: TRect;
    function ArrowRect(LeftSide: Boolean): TRect;
    function CloseBtnRect(TabIndex: Integer): TRect;   // 屏幕坐标（已含滚动平移）
    function HitTest(X, Y: Integer; out TabIndex: Integer): TFHHitKind;
    procedure LayoutChanged;
    procedure ClampScroll;
    procedure ScrollBy(Delta: Integer);
    procedure EnsureTabVisible(TabIndex: Integer);
    procedure ScrollTimerTick(Sender: TObject);
    // 拖拽（FR-5）
    procedure UpdateDragPosition(X: Integer);
    procedure FinishDrag(Cancel: Boolean);
    function DragTargetIndex(X: Integer): Integer;
    // 菜单（FR-8）
    procedure EnsureContextMenu;
    procedure ShowContextMenuAt(TabIndex: Integer);
    procedure MenuPinClick(Sender: TObject);
    procedure MenuNewRightClick(Sender: TObject);
    procedure MenuReloadClick(Sender: TObject);
    procedure MenuDuplicateClick(Sender: TObject);
    procedure MenuCloseClick(Sender: TObject);
    procedure MenuCloseOthersClick(Sender: TObject);
    procedure MenuCloseRightClick(Sender: TObject);
    procedure MenuCloseLeftClick(Sender: TObject);
    // 事件触发器
    procedure DoTabClick(TabIndex: Integer);
    procedure DoTabDblClick(TabIndex: Integer);
    procedure DoActiveTabChanging(OldIndex, NewIndex: Integer; var AllowChange: Boolean);
    procedure DoActiveTabChange(OldIndex, NewIndex: Integer);
    procedure DoTabClosing(TabIndex: Integer; var AllowClose: Boolean);
    procedure DoTabClosed(TabIndex: Integer);
    procedure DoTabMoved(FromIndex, ToIndex: Integer);
    procedure DoTabPinChanged(TabIndex: Integer; Pinned: Boolean);
    procedure DoNewButtonClick;
    procedure DoTabContextMenu(TabIndex: Integer; var Handled: Boolean);
    // 内部
    procedure InternalActivate(NewIndex: Integer);
    function GetActiveTab: TFHChromeTab;
    procedure SetHover(Kind: TFHHitKind; TabIndex: Integer);
    procedure SwitchTab(Delta: Integer);   // 键盘切换（跳过隐藏项, 走完整事件链）
    procedure PinTabFont;                  // 按像素固定标签标题字号（DPI 变化时重钉）
  protected
    procedure Paint; override;
    procedure Resize; override;
    { VCL 在 SetParent 时会对运行期创建的控件自动调用
      ScaleForPPI(GetParentCurrentDpi) → ChangeScale(NewPPI, DesignPPI=96),
      把 Left/Top/Width/Height 再乘一次 DPI 比例。本控件的尺寸是由 ScalePx
      自行按 DPI 换算好的设备像素, 再乘一次 = 双重缩放（实测 150%: 62→93）。
      这里接管: 更新基准比例后按基准常量重算, 保证任何时机都只缩放一次。 }
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure WMMouseHWheel(var Message: TWMMouseWheel); message WM_MOUSEHWHEEL;
    procedure CMEnter(var Message: TCMEnter); message CM_ENTER;
    procedure CMExit(var Message: TCMExit); message CM_EXIT;
    procedure WMGetDlgCode(var Message: TWMGetDlgCode); message WM_GETDLGCODE;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    procedure CMHintShow(var Message: TCMHintShow); message CM_HINTSHOW;
    procedure WMDPICHANGED(var Message: TMessage); message WM_DPICHANGED;
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
    { VCL 给窗口控件铺底时用的是 Color 画刷（TWinControl.WMPaint 先用
      FBrush 填充 DWM 缓冲/内存位图, 之后才轮到 Paint）; 不接管就会出现
      "最小化后恢复时标签栏黑一帧"。详见 PaintEraseBkgnd 注释 }
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    procedure MeasureLayout;           // 压缩/溢出计算（文档 8 布局算法要点）
    procedure PaintTabPath(X, W, ABottom: Integer; FillColor: TColor);
    { 标签体顶边: Chrome 新版 TabStrip 顶部有 TAB_STRIP_PADDING(6) 的留白,
      标签本身高 = C_FH_BarHeight - C_FH_TabStripTopPad = 35 }
    function TabTopY: Integer;
    { 标签内容/按钮的纵向居中: 在 [TabTopY..Height] 这个标签体内居中 }
    function CenterTop(H: Integer): Integer;
    // 药丸顶路径（GDI+ 抗锯齿填充, 文档 4.3/第 2 节技术约束）
    procedure PaintTab(Tab: TFHChromeTab; X, W: Integer; Active, DragGhost: Boolean);
    procedure PaintSeparators(DragIdx: Integer);      // 非激活标签间中缝线
    function TabWidthOf(Tab: TFHChromeTab): Integer; // 拖拽幽灵宽度查询
    function IdxToLayout(TabIndex: Integer): Integer; // 集合索引→布局下标
    procedure PaintNewButton;
    procedure PaintArrows;
    procedure PaintFocusRing;                            // 键盘焦点环（FocusIndicator）
    procedure BlendRect(const R: TRect; Color: TColor; Alpha: Byte); // 幽灵 60% 透明
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure BeginUpdate;             // 批量改动挂起重排（文档 FR-1）
    procedure EndUpdate;
    function TabAt(X, Y: Integer): Integer;   // 命中测试→集合索引; -1 无
    { HitKindAt: 公开完整命中类型查询（hkTab/hkClose/hkNew/hkArrow*/hkNone）,
      供宿主实现"标签条空白区拖动窗口"等自定义行为 }
    function HitKindAt(X, Y: Integer; out TabIndex: Integer): TFHHitKind;
    { CloseTab: 完整关闭流程（含 OnTabClosing 可取消, 文档 FR-4） }
    procedure CloseTab(TabIndex: Integer);
    { ForceCloseTab: 跳过 OnTabClosing 直接删除, 完整触发 OnTabClosed + 激活修正;
      供异步关闭场景（CEF 两段式关闭的阶段二, 文档 14.4） }
    procedure ForceCloseTab(TabIndex: Integer);
    property ActiveTab: TFHChromeTab read GetActiveTab;
    property ScrollOffset: Integer read FScrollOffset;
    property ScaleFactor: Single read FScaleFactor;
    { PaintCount: Paint 执行计数——诊断"数据已变更但界面未刷新"类问题
      （ Invalidate 后此值不增长 ⇒ WM_PAINT 未派发/被吞; 用途见 Demo /DIAG ） }
    property PaintCount: Integer read FPaintCount;
    { ScalePx: 96 DPI 基准像素 → 当前 DPI 实际像素（宿主布局用, 文档 4.1） }
    function ScalePx(P: Integer): Integer;
  published
    property Align default alTop;
    property Height default 41;   // = C_FH_BarHeight（TAB_STRIP_HEIGHT = 35 + 6）
    property Images: TCustomImageList read FImages write SetImages;
    property Theme: TFHChromeTabsTheme read FTheme write SetTheme;
    { Tabs / ActiveTabIndex 必须 published, 否则集合与激活项不进 DFM,
      设计期 Object Inspector 也看不到（原为 public → 设计期编辑能力缺失） }
    property Tabs: TFHChromeTabCollection read FTabs write SetTabs;
    property ActiveTabIndex: Integer read FActiveIndex write SetActiveTabIndex default -1;
    property ShowCloseButtons: Boolean read FShowCloseButtons write SetShowCloseButtons default True;
    property ShowNewButton: Boolean read FShowNewButton write SetShowNewButton default True;
    property ShowScrollArrows: Boolean read FShowScrollArrows write SetShowScrollArrows default True;
    property RightReserved: Integer read FRightReserved write SetRightReserved default 0;
    { CaptionArea: True = 标签条空白区按标题栏处理（命中穿透给宿主窗体）。
      宿主需在自身 WM_NCHITTEST 中把标签条区域判为 htCaption, 才能由系统
      原生接管"按住拖动窗口"与"双击最大化"（自己发 SC_DRAGMOVE 无效）。 }
    property CaptionArea: Boolean read FCaptionArea write FCaptionArea default False;
    property ShowContextMenu: Boolean read FShowContextMenu write SetShowContextMenu default True;
    property TabDefaultWidth: Integer read FTabDefaultWidth write SetTabDefaultWidth default 160;
    property TabMaxWidth: Integer read FTabMaxWidth write SetTabMaxWidth default 240;
    property TabMinWidth: Integer read FTabMinWidth write SetTabMinWidth default 60;
    property PinnedTabWidth: Integer read FPinnedTabWidth write SetPinnedTabWidth default 36;
    property ScrollStep: Integer read FScrollStep write SetScrollStep default 120;
    property Font;
    property OnClick;
    property OnDblClick;
    property OnMouseEnter;
    property OnMouseLeave;
    property OnMouseMove;
    property OnMouseDown;
    property OnMouseUp;
    property OnTabClick: TFHTabIndexEvent read FOnTabClick write FOnTabClick;
    property OnTabDblClick: TFHTabIndexEvent read FOnTabDblClick write FOnTabDblClick;
    property OnActiveTabChanging: TFHTabSwitchingEvent read FOnActiveTabChanging write FOnActiveTabChanging;
    property OnActiveTabChange: TFHTabSwitchEvent read FOnActiveTabChange write FOnActiveTabChange;
    property OnTabClosing: TFHTabAllowEvent read FOnTabClosing write FOnTabClosing;
    property OnTabClosed: TFHTabIndexEvent read FOnTabClosed write FOnTabClosed;
    property OnTabMoved: TFHTabMoveEvent read FOnTabMoved write FOnTabMoved;
    property OnTabPinChanged: TFHTabPinEvent read FOnTabPinChanged write FOnTabPinChanged;
    property OnNewButtonClick: TNotifyEvent read FOnNewButtonClick write FOnNewButtonClick;
    property OnTabContextMenu: TFHTabMenuEvent read FOnTabContextMenu write FOnTabContextMenu;
    { 右键菜单三项浏览器动作的宿主回调（未挂 saddEventHandler 时菜单项自动禁用） }
    property OnTabNewToRight: TFHTabIndexEvent read FOnTabNewToRight write FOnTabNewToRight;
    property OnTabReload: TFHTabIndexEvent read FOnTabReload write FOnTabReload;
    property OnTabDuplicate: TFHTabIndexEvent read FOnTabDuplicate write FOnTabDuplicate;
    { OnThemeChanged: Theme 任一 token 变更后触发（宿主导出联动, 如页面底色） }
    property OnThemeChanged: TNotifyEvent read FOnThemeChanged write FOnThemeChanged;
  end;

implementation

{ GDI+ 懒初始化（实现在文件末尾; 声明见 interface, 供外部控件复用） }

{ ---- GDI+ 抗锯齿小工具（标签条自绘: 悬停圆底/×/+ 图标线条） ----
  用户在第二显示器（不同 DPI）反馈"图标细、发虚、圆底锯齿":
  纯 GDI 的 Ellipse/Line 无抗锯齿, 且整数笔宽在高 DPI 下会半像素错位。
  这里统一走 GDI+, 笔宽用浮点（1 × 缩放因子 = 1.5px 等）;
  GDI+ 不可用时回退 GDI（Win7 兜底） }

{ TColor($00BBGGRR) → GDI+ ARGB($AARRGGBB) }
function GlyphColorToARGB(C: TColor): ARGB;
var
  RGB: TColorRef;
begin
  RGB := ColorToRGB(C);
  Result := $FF000000 or (GetRValue(RGB) shl 16) or
    (GetGValue(RGB) shl 8) or GetBValue(RGB);
end;

{ 抗锯齿实心圆（悬停按钮底） }
procedure GlyphFillCircleAA(ACanvas: TCanvas; const R: TRect; AColor: TColor);
var
  G: TGPGraphics;
  B: TGPSolidBrush;
begin
  if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;
  G := nil;
  if EnsureGdiPlus then
  begin
    G := TGPGraphics.Create(ACanvas.Handle);
    G.SetSmoothingMode(SmoothingModeAntiAlias);
  end;
  if G = nil then
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := AColor;
    ACanvas.Pen.Style := psClear;
    ACanvas.Ellipse(R);
    ACanvas.Brush.Style := bsClear;
    Exit;
  end;
  try
    B := TGPSolidBrush.Create(GlyphColorToARGB(AColor));
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

{ 抗锯齿图标线条（圆头; AWidth 用浮点, 适配 125%/150%/175% DPI） }
procedure GlyphLineAA(ACanvas: TCanvas; X1, Y1, X2, Y2: Integer;
  AColor: TColor; AWidth: Single);
var
  G: TGPGraphics;
  P: TGPPen;
begin
  if AWidth < 1 then
    AWidth := 1;
  G := nil;
  if EnsureGdiPlus then
  begin
    G := TGPGraphics.Create(ACanvas.Handle);
    G.SetSmoothingMode(SmoothingModeAntiAlias);
  end;
  if G = nil then
  begin
    ACanvas.Pen.Style := psSolid;
    ACanvas.Pen.Color := AColor;
    ACanvas.Pen.Width := Round(AWidth);
    ACanvas.MoveTo(X1, Y1);
    ACanvas.LineTo(X2, Y2);
    Exit;
  end;
  try
    P := TGPPen.Create(GlyphColorToARGB(AColor), AWidth);
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

{ ============================ TFHChromeTab ============================== }

constructor TFHChromeTab.Create(Collection: TCollection);
begin
  inherited Create(Collection);
  // 根因修复（2026-10-23 实证）: inherited 阶段 InsertItem→Changed→Update→
  // LayoutChanged→MeasureLayout 会执行, 但那时本构造函数体尚未跑、FVisible
  // 仍为零初始化 False → MeasureLayout 把新标签当隐藏项跳过; 构造体里
  // FVisible := True 是直接字段赋值不再触发通知 → FLayout 停留在旧布局,
  // 表现为"点 + 后 Count+1 但新标签不可见, 拉大窗口(Resize→LayoutChanged)
  // 才出现"。构造完成后补发一次变更通知, 此时字段已就绪:
  FIcon := TIcon.Create;
  FImageIndex := -1;
  FVisible := True;
  FPinned := False;
  Changed(False);   // → 集合 Update → 控件 LayoutChanged(此时 Visible=True)
end;

{ 析构: 释放自有 Icon（所有权归本 Tab） }
destructor TFHChromeTab.Destroy;
begin
  FIcon.Free;   // Icon 所有权归本 Tab（文档 FR-10）
  inherited Destroy;
end;

{ 标题 setter: 变化时通知集合重排（标题宽度影响布局） }
procedure TFHChromeTab.SetCaption(const Value: string);
begin
  if FCaption = Value then Exit;
  FCaption := Value;
  Changed(False);
end;

{ ImageList 索引 setter: 变化时通知重绘 }
procedure TFHChromeTab.SetImageIndex(Value: System.UITypes.TImageIndex);
begin
  if FImageIndex = Value then Exit;
  FImageIndex := Value;
  Changed(False);
end;

procedure TFHChromeTab.SetIcon(Value: TIcon);
begin
  // FIcon 恒非 nil（构造即建）: Value=nil 时重建空图标, 避免 Assign(nil) 抛异常
  if Value = nil then
  begin
    FIcon.Free;
    FIcon := TIcon.Create;
  end
  else
    FIcon.Assign(Value);   // 复制内容, 不接管引用
  Changed(False);
end;

procedure TFHChromeTab.SetPinned(Value: Boolean);
var
  Tabs: TFHChromeTabCollection;
  Ctrl: TFHChromeTabs;
  OldIdx, Target, I: Integer;
begin
  if FPinned = Value then Exit;
  FPinned := Value;
  Tabs := TFHChromeTabCollection(Collection);
  if (Tabs <> nil) and (Tabs.Owner is TFHChromeTabs) then
  begin
    Ctrl := TFHChromeTabs(Tabs.Owner);
    OldIdx := Index;
    // 目标位 = "其它固定标签的个数" = 固定区右边界:
    //   Pin   → 固定区末尾;  Unpin → 普通区最左。两者都是该下标（文档 FR-6）
    // 旧实现"从头扫到首个非固定项"在 Unpin 最左侧固定标签时得到 0 → 不移动,
    // 结果固定标签被普通标签夹在中间（固定区不连续, 测量/绘制全乱）
    Target := 0;
    for I := 0 to Tabs.Count - 1 do
      if (I <> OldIdx) and Tabs[I].Pinned then
        Inc(Target);
    if OldIdx <> Target then
    begin
      // Pin 重排不是用户拖拽: 抑制 OnTabMoved, 由 OnTabPinChanged 通知宿主
      Ctrl.FSuppressTabMoved := True;
      try
        Tabs.Move(OldIdx, Target);   // Move 触发 Update → LayoutChanged → 重绘
      finally
        Ctrl.FSuppressTabMoved := False;
      end;
    end;
    // 同单元可访问私有方法: 事件带变化前索引（文档 FR-6）
    Ctrl.DoTabPinChanged(OldIdx, Value);
  end
  else
    Changed(False);
end;

{ 可见性 setter: 隐藏项不占宽但保留集合索引 }
procedure TFHChromeTab.SetVisible(Value: Boolean);
begin
  if FVisible = Value then Exit;
  FVisible := Value;
  Changed(False);
end;

function TFHChromeTab.GetDisplayName: string;
begin
  // 设计时集合编辑器显示项名称（FR-1 验收）
  if FCaption <> '' then
    Result := FCaption
  else
    Result := inherited GetDisplayName;
end;

{ ======================= TFHChromeTabCollection ========================= }

function TFHChromeTabCollection.Add: TFHChromeTab;
begin
  Result := TFHChromeTab(inherited Add);
  // 双保险: 构造期 Update 早于字段初始化（TFHChromeTab.Create 尾已补 Changed,
  // 此处再显式重排一次, 防御构造器将来被改动/宿主处于 BeginUpdate 时的时序）
  if Owner is TFHChromeTabs then
    TFHChromeTabs(Owner).LayoutChanged;
end;

function TFHChromeTabCollection.Insert(Index: Integer): TFHChromeTab;
begin
  Result := TFHChromeTab(inherited Insert(Index));
  // 同 Add: 构造完成后显式重排（根因见 TFHChromeTab.Create 注释）
  if Owner is TFHChromeTabs then
    TFHChromeTabs(Owner).LayoutChanged;
end;

{ 索引器实现: 下标 → TFHChromeTab }
function TFHChromeTabCollection.GetItem(Index: Integer): TFHChromeTab;
begin
  Result := TFHChromeTab(inherited GetItem(Index));
end;

function TFHChromeTabCollection.IndexOf(ATab: TFHChromeTab): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to Count - 1 do
    if GetItem(I) = ATab then
      Exit(I);
end;

procedure TFHChromeTabCollection.Move(FromIndex, ToIndex: Integer);
var
  Item, ActiveTab: TFHChromeTab;
  Ctrl: TFHChromeTabs;
  ActiveIdx: Integer;
begin
  if (FromIndex = ToIndex) or (FromIndex < 0) or (FromIndex >= Count) then Exit;
  Ctrl := nil;
  ActiveTab := nil;
  if Owner is TFHChromeTabs then
  begin
    Ctrl := TFHChromeTabs(Owner);
    ActiveIdx := Ctrl.FActiveIndex;
    if (ActiveIdx >= 0) and (ActiveIdx < Count) then
      ActiveTab := GetItem(ActiveIdx);   // 先抓住激活对象, 重排后再按对象定位
  end;
  BeginUpdate;
  try
    Item := GetItem(FromIndex);
    if (ToIndex < 0) then
      ToIndex := 0
    else if (ToIndex >= Count) then
      ToIndex := Count - 1;
    Item.Index := ToIndex;   // TCollectionItem.Index setter 内部完成重排
  finally
    EndUpdate;
  end;
  // 重排后激活态跟随"对象": 否则 Pin / 拖拽移动激活标签后, FActiveIndex 仍是
  // 旧数字 → 高亮落在别的标签上（Chrome 语义是激活页跟着标签走）
  if (Ctrl <> nil) and (ActiveTab <> nil) then
    Ctrl.FActiveIndex := IndexOf(ActiveTab);
  // 编程式重排通知容器同步页面（拖拽预览的 Move 不发——由 FinishDrag 发最终值,
  // 避免 UpdateDragPosition 连续 Move 的事件风暴; Pin 重排由 OnTabPinChanged 通知）
  if (Ctrl <> nil) and (not Ctrl.FDragging) and (not Ctrl.FSuppressTabMoved) then
    Ctrl.DoTabMoved(FromIndex, ToIndex);
end;

procedure TFHChromeTabCollection.Update(Item: TCollectionItem);
begin
  inherited Update(Item);
  if Owner is TFHChromeTabs then
    TFHChromeTabs(Owner).LayoutChanged;
end;

{ ========================== TFHChromeTabsTheme ========================== }

{ 构造: 默认浅色主题 }
constructor TFHChromeTabsTheme.Create;
begin
  inherited Create;
  SetLightTheme;
end;

{ 颜色 setter 公共实现: 值变化时触发 OnChange（宿主联动刷新） }
procedure TFHChromeTabsTheme.ApplyColor(var Target: TColor; Value: TColor);
begin
  if Target <> Value then
  begin
    Target := Value;
    if Assigned(FOnChange) then
      FOnChange(Self);
  end;
end;

{ 条底色 setter }
procedure TFHChromeTabsTheme.SetBarBackground(Value: TColor);
begin
  ApplyColor(FBarBackground, Value);
end;

{ 激活标签填充色 setter }
procedure TFHChromeTabsTheme.SetTabActiveFill(Value: TColor);
begin
  ApplyColor(FTabActiveFill, Value);
end;

{ 非激活标签填充色 setter }
procedure TFHChromeTabsTheme.SetTabInactiveFill(Value: TColor);
begin
  ApplyColor(FTabInactiveFill, Value);
end;

{ 悬停增量色 setter }
procedure TFHChromeTabsTheme.SetTabHoverFill(Value: TColor);
begin
  ApplyColor(FTabHoverFill, Value);
end;

{ 标签文字色 setter }
procedure TFHChromeTabsTheme.SetTabTextColor(Value: TColor);
begin
  ApplyColor(FTabTextColor, Value);
end;

{ 非激活标签文字色 setter }
procedure TFHChromeTabsTheme.SetTabTextInactiveColor(Value: TColor);
begin
  ApplyColor(FTabTextInactiveColor, Value);
end;

{ 分隔线色 setter }
procedure TFHChromeTabsTheme.SetSeparatorColor(Value: TColor);
begin
  ApplyColor(FSeparatorColor, Value);
end;

{ 关闭按钮色 setter }
procedure TFHChromeTabsTheme.SetCloseBtnColor(Value: TColor);
begin
  ApplyColor(FCloseBtnColor, Value);
end;

{ 关闭按钮悬停底色 setter }
procedure TFHChromeTabsTheme.SetCloseBtnHoverBg(Value: TColor);
begin
  ApplyColor(FCloseBtnHoverBg, Value);
end;

{ 关闭按钮悬停符号色 setter }
procedure TFHChromeTabsTheme.SetCloseBtnHoverColor(Value: TColor);
begin
  ApplyColor(FCloseBtnHoverColor, Value);
end;

{ "+"按钮符号色 setter }
procedure TFHChromeTabsTheme.SetNewBtnColor(Value: TColor);
begin
  ApplyColor(FNewBtnColor, Value);
end;

{ "+"按钮悬停底色 setter }
procedure TFHChromeTabsTheme.SetNewBtnHoverBg(Value: TColor);
begin
  ApplyColor(FNewBtnHoverBg, Value);
end;

{ 键盘焦点环色 setter }
procedure TFHChromeTabsTheme.SetFocusIndicator(Value: TColor);
begin
  ApplyColor(FFocusIndicator, Value);
end;

{ 页面容器底色 setter（供 PageHost 联动取用） }
procedure TFHChromeTabsTheme.SetPageHostColor(Value: TColor);
begin
  ApplyColor(FPageHostColor, Value);
end;

{ 复制整套主题 Token 并触发 OnChange }
procedure TFHChromeTabsTheme.Assign(Source: TPersistent);
begin
  if Source is TFHChromeTabsTheme then
  begin
    FBarBackground        := TFHChromeTabsTheme(Source).FBarBackground;
    FTabActiveFill        := TFHChromeTabsTheme(Source).FTabActiveFill;
    FTabInactiveFill      := TFHChromeTabsTheme(Source).FTabInactiveFill;
    FTabHoverFill         := TFHChromeTabsTheme(Source).FTabHoverFill;
    FTabTextColor         := TFHChromeTabsTheme(Source).FTabTextColor;
    FTabTextInactiveColor := TFHChromeTabsTheme(Source).FTabTextInactiveColor;
    FSeparatorColor       := TFHChromeTabsTheme(Source).FSeparatorColor;
    FCloseBtnColor        := TFHChromeTabsTheme(Source).FCloseBtnColor;
    FCloseBtnHoverBg      := TFHChromeTabsTheme(Source).FCloseBtnHoverBg;
    FCloseBtnHoverColor   := TFHChromeTabsTheme(Source).FCloseBtnHoverColor;
    FNewBtnColor          := TFHChromeTabsTheme(Source).FNewBtnColor;
    FNewBtnHoverBg        := TFHChromeTabsTheme(Source).FNewBtnHoverBg;
    FFocusIndicator       := TFHChromeTabsTheme(Source).FFocusIndicator;
    FPageHostColor        := TFHChromeTabsTheme(Source).FPageHostColor;
    if Assigned(FOnChange) then
      FOnChange(Self);
  end
  else
    inherited Assign(Source);
end;

procedure TFHChromeTabsTheme.SetLightTheme;
begin
  { 浅色主题 Token —— 对齐 Chrome（GM3 新版 UI, 从真机截图取色; TColor 为
    $BBGGRR 序）: 条底 #D3E3FD 淡蓝, 激活标签纯白与白色工具栏/页面融为一体;
    非激活标签 = 条底色（Chrome 里非激活标签是"透明"的, 悬停才显形） }
  FBarBackground        := TColor($FDE3D3);   // #D3E3FD
  FTabActiveFill        := TColor($FFFFFF);   // #FFFFFF
  FTabInactiveFill      := TColor($FDE3D3);   // 与条底一致（隐形）
  FTabHoverFill         := TColor($FDEBE1);   // #E1EBFD 悬停浅亮
  FTabTextColor         := TColor($242120);   // #202124
  FTabTextInactiveColor := TColor($68635F);   // #5F6368
  FSeparatorColor       := TColor($D6B1A3);   // #A3B1D6 非激活标签间分隔线
  FCloseBtnColor        := TColor($43403C);   // #3C4043 加深, 淡蓝条上更清晰
  FCloseBtnHoverBg      := TColor($FCEDE4);   // #E4EDFC 悬停浅蓝圆（同 Chrome）
  FCloseBtnHoverColor   := TColor($242120);   // #202124 悬停时叉更深
  FNewBtnColor          := TColor($43403C);   // #3C4043 加深
  FNewBtnHoverBg        := TColor($FAC7A8);   // #A8C7FA 悬停偏蓝, 比条底 #D3E3FD 深一档
  FFocusIndicator       := TColor($D0570B);   // #0B57D0 Google Blue
  FPageHostColor        := TColor($FFFFFF);   // #FFFFFF
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TFHChromeTabsTheme.SetDarkTheme;
begin
  { 深色主题 Token（文档 4.4 深色说明） }
  FBarBackground        := TColor($242120);
  FTabActiveFill        := TColor($3A3635);
  FTabInactiveFill      := TColor($2F2C2B);
  FTabHoverFill         := TColor($3E3B3A);
  FTabTextColor         := TColor($EDEAE8);
  FTabTextInactiveColor := TColor($A6A09A);
  FSeparatorColor       := TColor($4F4C4A);
  FCloseBtnColor        := TColor($A6A09A);
  FCloseBtnHoverBg      := TColor($43403C);
  FCloseBtnHoverColor   := TColor($EDEAE8);
  FNewBtnColor          := TColor($A6A09A);
  FNewBtnHoverBg        := TColor($43403C);
  FFocusIndicator       := TColor($F8B48A);
  FPageHostColor        := TColor($2D2A29);
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

{ ============================ TFHChromeTabs ============================= }

constructor TFHChromeTabs.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;              // 双缓冲防闪烁（NFR-1）
  FScaleFactor := Screen.PixelsPerInch / 96;   // System DPI 基线（NFR-2）
  FTheme := TFHChromeTabsTheme.Create;
  FTheme.OnChange := ThemeChanged;
  FTabs := TFHChromeTabCollection.Create(Self, TFHChromeTab);
  FActiveIndex := -1;
  FUpdateCount := 0;
  FLastTabRight := ScalePx(C_FH_BarPadding);
  FTabDefaultWidth := C_FH_DefaultTabWidth;
  FTabMaxWidth := C_FH_MaxTabWidth;
  FTabMinWidth := C_FH_MinTabWidth;
  FPinnedTabWidth := C_FH_PinnedTabWidth;
  FScrollStep := 120;
  FShowCloseButtons := True;
  FKeyFocusVisible := False;
  FShowNewButton := True;
  FShowScrollArrows := True;
  FShowContextMenu := True;
  FMenuTabIndex := -1;
  FSuppressTabMoved := False;
  FHoverKind := hkNone;
  FPressKind := hkNone;
  Align := alTop;
  Height := ScalePx(C_FH_BarHeight);
  Width := ScalePx(400);
  // TabStop=True: 键盘可聚焦（Ctrl+Tab / Ctrl+方向键切换、Delete 关闭、
  // 拖拽时 ESC 取消都需要焦点; 原 TabStop=False 使这些按键永远收不到）
  TabStop := True;
  // 截断标题的 Hint 需要 ShowHint 为真才会走 CM_HINTSHOW（FR-9）
  ShowHint := True;
  PinTabFont;                          // 字号按像素对齐 Chrome（见 C_FH_TabTitleFontPx）
  StyleElements := [];                 // 全自绘, 不跟随 VCL 主题
  SyncColorToTheme;                    // VCL 铺底画刷必须等于主题条底色（防黑帧）
  // ImageList 变更联动（FR-10）
  FChangeLink := TChangeLink.Create;
  FChangeLink.OnChange := ImagesChanged;
  // 箭头悬停持续滚动（文档 4.6: 80ms 一次 40px）
  FScrollTimer := TTimer.Create(Self);
  FScrollTimer.Enabled := False;
  FScrollTimer.Interval := C_FH_ScrollTimerMS;
  FScrollTimer.OnTimer := ScrollTimerTick;
end;

{ 析构: 解除 ImageList 联动, 释放 GDI+ 复用对象/集合/主题
  （GDI+ 对象须在单元 finalization 的 GdiplusShutdown 之前释放） }
destructor TFHChromeTabs.Destroy;
begin
  SetImages(nil);
  FChangeLink.Free;
  FPath.Free;      // GDI+ 对象须在单元 finalization(GdiplusShutdown) 之前释放
  FBrush.Free;
  FTabs.Free;
  FTheme.Free;
  inherited Destroy;
end;

procedure TFHChromeTabs.BeginUpdate;
begin
  Inc(FUpdateCount);
end;

procedure TFHChromeTabs.EndUpdate;
begin
  if FUpdateCount > 0 then
  begin
    Dec(FUpdateCount);
    if FUpdateCount = 0 then
      LayoutChanged;
  end;
end;

{ Tabs setter: 复制集合内容（控件始终拥有 FTabs）, 夹取激活索引并重排 }
procedure TFHChromeTabs.SetTabs(Value: TFHChromeTabCollection);
begin
  if (Value = nil) or (Value = FTabs) then Exit;
  FTabs.Assign(Value);   // 代码赋值/DFM 流加载: 复制集合内容, 控件始终拥有 FTabs
  if FActiveIndex >= FTabs.Count then
    FActiveIndex := FTabs.Count - 1;
  LayoutChanged;
end;

{ Theme setter: 复制值而不替换对象（控件始终拥有 FTheme） }
procedure TFHChromeTabs.SetTheme(Value: TFHChromeTabsTheme);
begin
  // 复制值而不替换对象: 控件始终拥有 FTheme
  if Value <> nil then
    FTheme.Assign(Value);
end;

{ Images setter: 解除/注册变更联动 + FreeNotification
  （防 ImageList 先释放时 FImages 悬垂, 见体内注释） }
procedure TFHChromeTabs.SetImages(Value: TCustomImageList);
begin
  if Value = FImages then Exit;
  if FImages <> nil then
    FImages.UnRegisterChanges(FChangeLink);   // 解除旧列表联动
  FImages := Value;
  if FImages <> nil then
  begin
    FImages.RegisterChanges(FChangeLink);
    // 关键: 没有 FreeNotification 就不会收到 Notification(opRemove) →
    // ImageList 先于控件释放时 FImages 成悬垂指针, 下次 Paint 即 AV
    FImages.FreeNotification(Self);
  end;
  Invalidate;
end;

{ ImageList 内容/尺寸变更 → 重绘 }
procedure TFHChromeTabs.ImagesChanged(Sender: TObject);
begin
  Invalidate;   // ImageList 内容/尺寸变更 → 重绘（FR-10）
end;

{ 组件通知: ImageList 被释放时安全解除引用 }
procedure TFHChromeTabs.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FImages) then
    SetImages(nil);   // ImageList 被释放, 安全解除
end;

{ 关闭按钮显示开关 setter: 变化时重绘 }
procedure TFHChromeTabs.SetShowCloseButtons(Value: Boolean);
begin
  if FShowCloseButtons = Value then Exit;
  FShowCloseButtons := Value;
  Invalidate;
end;

{ "+"按钮显示开关 setter: 变化时重排（占位变化） }
procedure TFHChromeTabs.SetShowNewButton(Value: Boolean);
begin
  if FShowNewButton = Value then Exit;
  FShowNewButton := Value;
  LayoutChanged;
end;

{ 溢出箭头显示开关 setter: 变化时重排（视口宽度变化） }
procedure TFHChromeTabs.SetShowScrollArrows(Value: Boolean);
begin
  if FShowScrollArrows = Value then Exit;
  FShowScrollArrows := Value;
  LayoutChanged;
end;

{ 右侧预留宽度 setter（标题栏按钮区避让）: 变化时重排 }
procedure TFHChromeTabs.SetRightReserved(Value: Integer);
begin
  if FRightReserved = Value then Exit;
  FRightReserved := Value;
  LayoutChanged;
end;

{ 内置右键菜单开关 setter（不触发重绘） }
procedure TFHChromeTabs.SetShowContextMenu(Value: Boolean);
begin
  FShowContextMenu := Value;
end;

{ 标签默认宽 setter: 变化时重排 }
procedure TFHChromeTabs.SetTabDefaultWidth(Value: Integer);
begin
  if FTabDefaultWidth = Value then Exit;
  FTabDefaultWidth := Value;
  LayoutChanged;
end;

{ 标签最大宽 setter: 变化时重排 }
procedure TFHChromeTabs.SetTabMaxWidth(Value: Integer);
begin
  if FTabMaxWidth = Value then Exit;
  FTabMaxWidth := Value;
  LayoutChanged;
end;

{ 标签最小宽 setter（压缩下限）: 变化时重排 }
procedure TFHChromeTabs.SetTabMinWidth(Value: Integer);
begin
  if FTabMinWidth = Value then Exit;
  FTabMinWidth := Value;
  LayoutChanged;
end;

{ 固定标签宽 setter: 变化时重排 }
procedure TFHChromeTabs.SetPinnedTabWidth(Value: Integer);
begin
  if FPinnedTabWidth = Value then Exit;
  FPinnedTabWidth := Value;
  LayoutChanged;
end;

{ 滚轮滚动步长 setter（不触发重排） }
procedure TFHChromeTabs.SetScrollStep(Value: Integer);
begin
  FScrollStep := Value;
end;

procedure TFHChromeTabs.WMEraseBkgnd(var Message: TWMEraseBkgnd);
begin
  { VCL 的 TWinControl.WMPaint 在重绘时先给"缓冲"铺底再调用 Paint:
      FillRect(MemDC, PS.rcPaint, FBrush.Handle)  // FBrush 用的是 Color
      Perform(WM_ERASEBKGND, MemDC, MemDC)
      Perform(WM_PRINTCLIENT, ...)                // 才轮到本控件自绘
    本控件只设了 csOpaque, 从没设过 Color → Color 取到 VCL 默认黑,
    于是"最小化后从任务栏恢复"那一帧先露出黑底（实测 47ms 处 rgb=(0,0,0),
    后续帧才恢复成 (211,227,253)）。
    这里显式铺主题底色 + 同步 Color, 任何铺底路径都不会再是黑。 }
  SyncColorToTheme;
  if Message.DC <> 0 then
  begin
    var Brush := CreateSolidBrush(ColorToRGB(FTheme.BarBackground));
    FillRect(Message.DC, ClientRect, Brush);
    DeleteObject(Brush);
  end;
  Message.Result := 1;   // 已处理, 阻止 DefWindowProc 再用窗口类画刷涂一遍
end;

procedure TFHChromeTabs.SyncColorToTheme;
begin
  { VCL 铺底用的 Color 必须跟着主题走（浅色 #D3E3FD / 深色 #202124） }
  if Assigned(FTheme) and (Color <> FTheme.BarBackground) then
    Color := FTheme.BarBackground;
end;

{ 主题变更: 同步 VCL 铺底色 + 重绘 + 通知宿主联动（页面底色等） }
procedure TFHChromeTabs.ThemeChanged(Sender: TObject);
begin
  SyncColorToTheme;
  Invalidate;
  // 通知宿主联动（TFHChromePageHost 用它刷新页面/容器底色, 否则深色主题下
  // 标签条变暗而页面仍是白底）
  if Assigned(FOnThemeChanged) then
    FOnThemeChanged(Self);
end;

{ 激活索引 setter: 越界抛异常（-1 合法 = 清空激活）, 走完整切换链 }
procedure TFHChromeTabs.SetActiveTabIndex(Value: Integer);
begin
  if Value = FActiveIndex then Exit;
  // FR-3: 写不存在的索引抛异常（-1 合法 = 清空激活）
  if (Value <> -1) and ((Value < 0) or (Value >= FTabs.Count)) then
    raise EArgumentOutOfRangeException.CreateFmt(
      'ActiveTabIndex %d 越界（Tabs.Count=%d）', [Value, FTabs.Count]);
  InternalActivate(Value);
end;

{ 激活切换内核: OnActiveTabChanging 可取消 → 更新索引 →
  溢出时滚入视口 → 重绘 → OnActiveTabChange }
procedure TFHChromeTabs.InternalActivate(NewIndex: Integer);
var
  Old: Integer;
  Allow: Boolean;
begin
  if NewIndex = FActiveIndex then Exit;
  Old := FActiveIndex;
  Allow := True;
  DoActiveTabChanging(Old, NewIndex, Allow);   // 可取消（文档 FR-3）
  if not Allow then Exit;
  FActiveIndex := NewIndex;
  if FOverflow then
    EnsureTabVisible(NewIndex);   // 激活标签滚入视口（FR-7）
  Invalidate;
  DoActiveTabChange(Old, NewIndex);
end;

{ 当前激活标签对象; 无激活返回 nil }
function TFHChromeTabs.GetActiveTab: TFHChromeTab;
begin
  if (FActiveIndex >= 0) and (FActiveIndex < FTabs.Count) then
    Result := FTabs[FActiveIndex]
  else
    Result := nil;
end;

function TFHChromeTabs.ScalePx(P: Integer): Integer;
begin
  { 换算实现统一在 uFHDpi; 本方法保留只为支持自定义 FScaleFactor }
  Result := FHScalePxBy(P, FScaleFactor);
end;

procedure TFHChromeTabs.PinTabFont;
var
  PPI: Integer;
begin
  { 字号按"像素"钉住: Font.Size 是磅, 换成像素要 /72*PPI, 换算两次容易错;
    直接给 Font.Height（设备像素）最直观。顺序必须是先 PixelsPerInch 再 Height:
    TFont.SetPixelsPerInch 会按新旧 PPI 把 Height 重算一遍（保持磅值不变）,
    后设 Height 才是最终像素值（与地址栏 PinEditFont 同法） }
  PPI := Round(96 * FScaleFactor);
  if PPI <= 0 then
    PPI := 96;
  Font.Name := C_FH_FontName;
  Font.PixelsPerInch := PPI;
  Font.Height := -MulDiv(C_FH_TabTitleFontPx, PPI, 96);
end;

function TFHChromeTabs.TabTopY: Integer;
begin
  Result := ScalePx(C_FH_TabStripTopPad);
end;

function TFHChromeTabs.CenterTop(H: Integer): Integer;
begin
  // 标签体 = [TabTopY .. Height]; 在其内部居中
  Result := TabTopY + (Height - TabTopY - H) div 2;
  if Result < TabTopY then
    Result := TabTopY;
end;

{ 布局失效入口: 夹取激活索引 → 重算布局 → 溢出时激活标签滚入视口 → 重绘;
  BeginUpdate 期间挂起 }
procedure TFHChromeTabs.LayoutChanged;
begin
  if FUpdateCount > 0 then
    Exit;
  if FActiveIndex >= FTabs.Count then
    FActiveIndex := FTabs.Count - 1;
  MeasureLayout;
  if FOverflow then
    EnsureTabVisible(FActiveIndex);
  Invalidate;
end;

{ 尺寸变化: 重算布局 }
procedure TFHChromeTabs.Resize;
begin
  inherited Resize;
  LayoutChanged;
end;

procedure TFHChromeTabs.WMDPICHANGED(var Message: TMessage);
begin
  // Win10+ 跨屏 DPI 刷新（NFR-2; Win7 不触发, System DPI 基线在构造器已算）
  FScaleFactor := LoWord(Message.WParam) / 96;
  PinTabFont;                            // 字号跟着新 DPI 重钉（否则跨屏后偏小）
  MeasureLayout;
  Invalidate;
end;

procedure TFHChromeTabs.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  { VCL 的自动 DPI 缩放（SetParent → ScaleForPPI → ChangeScale, 见 Vcl.Controls
    Line 6382）会把本控件按 NewPPI/96 再放大一次; 但本控件的尺寸已经是自己
    换算好的设备像素, 再乘就双重缩放了（150%: 62 → 93, 实测确认）。
    做法: 先让 inherited 照常跑（字体/锚点等通用处理）, 再按基准常量把高度
    重算一遍覆盖掉继承来的结果 —— 无论被调用几次, 最终始终是 ScalePx(41)。 }
  inherited;
  if (M > 0) and (D <> M) then
    FScaleFactor := M / 96;
  PinTabFont;                            // inherited 按 M/D 缩放过字体, 这里按像素重新钉
  Height := ScalePx(C_FH_BarHeight);
  MeasureLayout;
  Invalidate;
end;

procedure TFHChromeTabs.WMNCHitTest(var Message: TWMNCHitTest);
var
  P: TPoint;
  Idx: Integer;
begin
  inherited;
  // 标签条占用标题栏: 空白区域（非标签/非 + /非箭头）让宿主窗体判定为标题栏。
  // 关键: 本控件是子窗口, 子窗口直接返回 htCaption 不会产生 WM_NCLBUTTONDOWN,
  // 拖动依然无效; 必须返回 HTTRANSPARENT 把命中测试交给父窗体,
  // 由父窗体的 WM_NCHITTEST 给出 htCaption, 系统才会原生接管拖动与双击最大化。
  if (Message.Result = htClient) and FCaptionArea then
  begin
    P := ScreenToClient(Point(Message.XPos, Message.YPos));
    if HitTest(P.X, P.Y, Idx) = hkNone then
      Message.Result := HTTRANSPARENT;
  end;
end;

{ ---- 布局与几何（文档 8 布局算法要点） ----------------------------------- }

function TFHChromeTabs.ViewLeft: Integer;
begin
  Result := ScalePx(C_FH_BarPadding);
  if FOverflow and FShowScrollArrows then
    Inc(Result, ScalePx(C_FH_ArrowWidth));   // 左箭头占位
end;

function TFHChromeTabs.ViewRight: Integer;
begin
  Result := Width - ScalePx(C_FH_BarPadding) - FRightReserved;
  if FShowNewButton then
    Dec(Result, ScalePx(C_FH_NewBtnSize) + ScalePx(C_FH_BarPadding));   // +按钮占位
  if FOverflow and FShowScrollArrows then
    Dec(Result, ScalePx(C_FH_ArrowWidth));   // 右箭头占位
end;

procedure TFHChromeTabs.MeasureLayout;
var
  I, X, PinnedW, NormCount, NormW, Avail, ContentW: Integer;
  Rec: TFHTabLayoutRec;
begin
  { 压缩策略（文档 8 要点 2）: Pinned 固定宽不压缩; 普通标签均匀压缩至
    TabMinWidth 下限; 仍不够 → 溢出模式（视口滚动, FR-7） }
  SetLength(FLayout, 0);
  FOverflow := False;
  PinnedW := 0;
  NormCount := 0;
  for I := 0 to FTabs.Count - 1 do
    if FTabs[I].Visible then
    begin
      if FTabs[I].Pinned then
        Inc(PinnedW, ScalePx(FPinnedTabWidth))
      else
        Inc(NormCount);
    end;
  if NormCount = 0 then
    NormW := 0
  else
  begin
    Avail := ViewRight - ViewLeft - PinnedW;
    NormW := Avail div NormCount;
    // 单标签有效上限 = Min(TabDefaultWidth, TabMaxWidth):
    // 原实现只用了 DefaultWidth, TabMaxWidth/C_FH_MaxTabWidth 完全没参与布局
    if NormW > ScalePx(FTabMaxWidth) then
      NormW := ScalePx(FTabMaxWidth);
    if NormW > ScalePx(FTabDefaultWidth) then
      NormW := ScalePx(FTabDefaultWidth)
    else if NormW < ScalePx(FTabMinWidth) then
    begin
      NormW := ScalePx(FTabMinWidth);
      FOverflow := True;   // 压到下限仍放不下 → 溢出（FR-7）
    end;
    if NormW < 1 then
      NormW := 1;   // 极端宽度防御（NFR-4）
  end;
  // 布局: Pinned 先（集合序）, 普通随后; X 为内容坐标
  X := ScalePx(C_FH_BarPadding);
  for I := 0 to FTabs.Count - 1 do
  begin
    if not FTabs[I].Visible then
      Continue;   // 隐藏项不占宽但保留集合索引（文档 FR-1）
    Rec.TabIndex := I;
    Rec.X := X;
    if FTabs[I].Pinned then
      Rec.Width := ScalePx(FPinnedTabWidth)
    else
      Rec.Width := NormW;
    SetLength(FLayout, Length(FLayout) + 1);
    FLayout[High(FLayout)] := Rec;
    Inc(X, Rec.Width);
  end;
  FLastTabRight := X;
  ContentW := X - ScalePx(C_FH_BarPadding);
  if FOverflow then
    FMaxScroll := Max(0, ContentW - (ViewRight - ViewLeft))
  else
    FMaxScroll := 0;
  ClampScroll;
end;

{ 夹紧滚动偏移到 [0, MaxScroll]; 非溢出模式归零 }
procedure TFHChromeTabs.ClampScroll;
begin
  if FScrollOffset > FMaxScroll then
    FScrollOffset := FMaxScroll;
  if FScrollOffset < 0 then
    FScrollOffset := 0;
  if not FOverflow then
    FScrollOffset := 0;
end;

{ 按增量滚动（仅溢出模式生效）并重绘 }
procedure TFHChromeTabs.ScrollBy(Delta: Integer);
begin
  if not FOverflow then Exit;
  FScrollOffset := EnsureRange(FScrollOffset + Delta, 0, FMaxScroll);
  Invalidate;
end;

{ 把指定标签滚入视口（激活切换/布局变化后调用） }
procedure TFHChromeTabs.EnsureTabVisible(TabIndex: Integer);
var
  I, VP: Integer;
begin
  if (TabIndex < 0) or (not FOverflow) then Exit;
  for I := 0 to High(FLayout) do
    if FLayout[I].TabIndex = TabIndex then
    begin
      VP := FLayout[I].X - FScrollOffset;   // 视口坐标
      if VP < ViewLeft then
        ScrollBy(VP - ViewLeft)                     // 左对齐滚入（FR-7）
      else if VP + FLayout[I].Width > ViewRight then
        ScrollBy(VP + FLayout[I].Width - ViewRight);
      Break;
    end;
end;

{ 箭头悬停持续滚动定时器: 每 80ms 滚一档 }
procedure TFHChromeTabs.ScrollTimerTick(Sender: TObject);
begin
  // 箭头悬停持续滚动（文档 4.6: 每 80ms 一次 40px）
  ScrollBy(FScrollDir * ScalePx(C_FH_ArrowScrollStep));
end;

function TFHChromeTabs.TabAt(X, Y: Integer): Integer;
var
  Kind: TFHHitKind;
begin
  Kind := HitTest(X, Y, Result);
  // 关闭按钮区域也算"命中该标签": 中键/右键/双击落在关闭按钮上时仍应作用于该标签
  if (Kind <> hkTab) and (Kind <> hkClose) then
    Result := -1;
end;

function TFHChromeTabs.HitKindAt(X, Y: Integer; out TabIndex: Integer): TFHHitKind;
begin
  Result := HitTest(X, Y, TabIndex);
end;

{ 完整命中测试: 判定 +/箭头/标签/关闭按钮, 返回命中类型与集合索引
  （关闭按钮优先于标签, 溢出时视口外不命中, 细节见体内注释） }
function TFHChromeTabs.HitTest(X, Y: Integer; out TabIndex: Integer): TFHHitKind;
var
  I, CX: Integer;
begin
  Result := hkNone;
  TabIndex := -1;
  // "+" 按钮命中必须先判 FShowNewButton: 否则按钮隐藏时其矩形仍吃点击,
  // 且此时 ViewRight 不再为按钮让位 → 最后一个标签右侧被误判成"新建"
  if FShowNewButton and PtInRect(NewButtonRect, Point(X, Y)) then
    Exit(hkNew);
  if FOverflow and FShowScrollArrows then
  begin
    if PtInRect(ArrowRect(True), Point(X, Y)) then
      Exit(hkArrowLeft);
    if PtInRect(ArrowRect(False), Point(X, Y)) then
      Exit(hkArrowRight);
  end;
  // 与 Paint 的裁剪范围保持一致（Paint 只看 FOverflow, 不看 FShowScrollArrows）:
  // 否则关掉箭头后, 被裁掉看不见的标签仍可点击/中键关闭
  if FOverflow and ((X < ViewLeft) or (X > ViewRight)) then
    Exit(hkNone);
  CX := X + FScrollOffset;   // 内容坐标
  for I := 0 to High(FLayout) do
    if (CX >= FLayout[I].X) and (CX < FLayout[I].X + FLayout[I].Width) then
    begin
      TabIndex := FLayout[I].TabIndex;
      // 关闭按钮命中优先（文档 FR-4 入口 1）
      if FShowCloseButtons and (not FTabs[TabIndex].Pinned) and
         PtInRect(CloseBtnRect(TabIndex), Point(X, Y)) then
        Exit(hkClose);
      Exit(hkTab);
    end;
end;

{ "+"按钮矩形: 非溢出跟随最后标签, 溢出时固定贴视口右缘（位置稳定） }
function TFHChromeTabs.NewButtonRect: TRect;
var
  S: Integer;
begin
  // "+"（文档 4.1: 位于最后一个标签右侧 4px）: 非溢出跟随最后标签;
  // 溢出模式标签区被滚动视口化 → 固定贴视口右缘（与滚动内容无关, 位置稳定）
  S := ScalePx(C_FH_NewBtnSize);
  if FOverflow then
    Result.Left := ViewRight + ScalePx(C_FH_BarPadding)
  else
    Result.Left := FLastTabRight + ScalePx(C_FH_BarPadding) - FScrollOffset;
  Result.Right := Result.Left + S;
  Result.Top := CenterTop(S);
  Result.Bottom := Result.Top + S;
end;

{ 溢出滚动箭头矩形: 宽 18px 贴视口两端, 全高（防标签从边缘漏出） }
function TFHChromeTabs.ArrowRect(LeftSide: Boolean): TRect;
begin
  // 溢出滚动箭头: 宽 18px 贴标签视口两端; 高度铺满标签条（文档 4.6）
  // 遮罩矩形全高——否则上下各漏几 px 标签内容从箭头边缘"漏出"
  Result.Top := 0;
  Result.Bottom := Height;
  if LeftSide then
  begin
    Result.Left := ScalePx(C_FH_BarPadding);
    Result.Right := Result.Left + ScalePx(C_FH_ArrowWidth);
  end
  else
  begin
    Result.Right := ViewRight;
    Result.Left := Result.Right - ScalePx(C_FH_ArrowWidth);
  end;
end;

{ 指定标签的关闭按钮矩形（含滚动平移, 屏幕坐标） }
function TFHChromeTabs.CloseBtnRect(TabIndex: Integer): TRect;
var
  I, S: Integer;
begin
  // 关闭按钮: 距右 6px 垂直居中, 屏幕坐标（含滚动平移; 文档 4.2）
  Result := Rect(0, 0, 0, 0);
  for I := 0 to High(FLayout) do
    if FLayout[I].TabIndex = TabIndex then
    begin
      S := ScalePx(C_FH_CloseBtnSize);
      Result.Right := FLayout[I].X + FLayout[I].Width -
        ScalePx(C_FH_ClosePadRight) - FScrollOffset;
      Result.Left := Result.Right - S;
      Result.Top := CenterTop(S);
      Result.Bottom := Result.Top + S;
      Break;
    end;
end;

{ ---- 绘制 ---------------------------------------------------------------- }

{ 全件自绘: 铺条底色 → 溢出裁剪 → 非激活标签 → 分隔线 → 激活标签
  → 拖拽幽灵 → 箭头与 + 按钮 → 键盘焦点环（绘制顺序见体内注释） }
procedure TFHChromeTabs.Paint;
var
  I, DragIdx: Integer;
  Tab: TFHChromeTab;
  ClipRgn, SavedRgn: HRGN;
  HasSaved: Boolean;
begin
  Inc(FPaintCount);   // 诊断: Paint 执行计数（外部验证重绘链是否通畅）
  Canvas.Font.Assign(Font);
  // 状态自愈: 上轮 Paint 可能遗留 bsClear（文本透明背景用）, 填充原语前必须
  // 复位 bsSolid, 否则 FillRect/FillPath 拿 NULL 画刷 → 背景/标签全部不绘制
  // （截屏"线框怪色"根因; Canvas 画刷风格是 DC 级跨调用状态）
  Canvas.Brush.Style := bsSolid;
  // 1) 标签条底色铺满整高（文档 8 绘制顺序）。
  //    不再画底缘线: GM3 条底与白色工具栏之间本来就没有线, 画一条浅色线反而
  //    把条的可见高度削掉 1px, 而右侧不透明的窗口按钮盖不住这条线时,
  //    按钮就会显得比标签条"高出一截"（用户可见的错位）。
  //    激活标签下探照常与白色工具栏/页面融合。
  Canvas.Brush.Color := FTheme.BarBackground;
  Canvas.FillRect(Rect(0, 0, Width, Height));

  DragIdx := -1;
  if FDragging and (FDragTab <> nil) then
    DragIdx := FTabs.IndexOf(FDragTab);

  // 溢出时裁剪标签绘制到视口 [ViewLeft, ViewRight]——标签不画到箭头区域,
  // 箭头区保持底色干净（Chrome 做法: 裁剪而非遮罩, 避免标签从遮罩边缘漏出）
  // 先保存原裁剪区（VCL 的无效区裁剪）, 绘制结束再恢复——直接 SelectClipRgn(…,0)
  // 会把无效区裁剪一并丢掉
  SavedRgn := 0;
  HasSaved := False;
  if FOverflow then
  begin
    SavedRgn := CreateRectRgn(0, 0, 0, 0);
    HasSaved := GetClipRgn(Canvas.Handle, SavedRgn) = 1;   // 1 = 已保存到 SavedRgn
    if not HasSaved then
    begin
      DeleteObject(SavedRgn);
      SavedRgn := 0;
    end;
    ClipRgn := CreateRectRgn(ViewLeft, 0, ViewRight, Height);
    SelectClipRgn(Canvas.Handle, ClipRgn);
    DeleteObject(ClipRgn);   // SelectClipRgn 已拷贝内容
  end;
  try
    // 2) 非激活标签（先画; 拖拽中的标签跳过, 最后画幽灵）
    for I := 0 to High(FLayout) do
      if (FLayout[I].TabIndex <> FActiveIndex) and (FLayout[I].TabIndex <> DragIdx) then
        PaintTab(FTabs[FLayout[I].TabIndex],
          FLayout[I].X - FScrollOffset, FLayout[I].Width, False, False);

    // 3) 非激活标签间分隔线（激活标签两侧让位; 文档 4.5）
    PaintSeparators(DragIdx);

    // 4) 激活标签最后画（盖住两侧分隔线, Chrome 观感）
    for I := 0 to High(FLayout) do
      if (FLayout[I].TabIndex = FActiveIndex) and (FLayout[I].TabIndex <> DragIdx) then
        PaintTab(FTabs[FLayout[I].TabIndex],
          FLayout[I].X - FScrollOffset, FLayout[I].Width, True, False);

    // 5) 拖拽幽灵标签: 60% 透明跟随鼠标（文档 FR-5）
    if FDragging and (FDragTab <> nil) then
    begin
      Tab := FDragTab;
      if Tab.Pinned then
        I := ScalePx(FPinnedTabWidth)
      else
        I := TabWidthOf(Tab);
      PaintTab(Tab, FDragX, I, FActiveIndex = DragIdx, True);
    end;
  finally
    if FOverflow then
    begin
      if HasSaved then
      begin
        SelectClipRgn(Canvas.Handle, SavedRgn);   // 还原 VCL 无效区裁剪
        DeleteObject(SavedRgn);
      end
      else
        SelectClipRgn(Canvas.Handle, 0);   // 原本无裁剪, 箭头/按钮不受限
    end;
  end;

  // 6) 溢出滚动箭头与 "+" 按钮（裁剪已取消, 直接画在干净底色上）
  if FOverflow and FShowScrollArrows then
    PaintArrows;
  if FShowNewButton then
    PaintNewButton;
  // 7) 键盘焦点环（覆盖在标签之上, 使用主题 FocusIndicator token）
  PaintFocusRing;
end;

function TFHChromeTabs.TabWidthOf(Tab: TFHChromeTab): Integer;
var
  I: Integer;
begin
  Result := ScalePx(FTabDefaultWidth);
  for I := 0 to High(FLayout) do
    if FLayout[I].TabIndex = FTabs.IndexOf(Tab) then
      Exit(FLayout[I].Width);
end;

procedure TFHChromeTabs.PaintSeparators(DragIdx: Integer);
var
  I, X: Integer;
  Prev: TFHChromeTab;
begin
  // 分隔线画在相邻两个非激活标签交界（文档 4.1"共享中缝线"）
  Canvas.Pen.Color := FTheme.SeparatorColor;
  Prev := nil;
  for I := 0 to High(FLayout) do
  begin
    if (FLayout[I].TabIndex = FActiveIndex) or (FLayout[I].TabIndex = DragIdx) then
    begin
      Prev := nil;   // 激活/拖拽标签两侧无线
      Continue;
    end;
    // 固定标签之间不画分隔线（Chrome 行为: 固定区是紧凑图标组）
    if (Prev <> nil) and (not (Prev.Pinned and FTabs[FLayout[I].TabIndex].Pinned)) then
    begin
      X := FLayout[I].X - FScrollOffset;
      if (X >= ViewLeft) and (X <= ViewRight) then   // 视口内才画
      begin
        // 新版 Chrome: 分隔线在标签体内再上下内缩 TAB_STRIP_PADDING(6)
        Canvas.MoveTo(X, TabTopY + ScalePx(6));
        Canvas.LineTo(X, Height - ScalePx(6));
      end;
    end;
    Prev := FTabs[FLayout[I].TabIndex];
  end;
end;

procedure TFHChromeTabs.PaintTabPath(X, W, ABottom: Integer; FillColor: TColor);
var
  R, Flare, K, T: Integer;
  G: TGPGraphics;
  C: Cardinal;
begin
  { 药丸顶路径（文档 4.3）: 顶部圆角 + 底部外扩凹弧, 底边贴 ABottom;
    顶边不再是 0, 而是 TabTopY（Chrome 新版 TAB_STRIP_PADDING=6 的留白）。
    GDI+ 抗锯齿填充——GDI FillPath 无 AA, 斜弧线锯齿在激活标签上呈
    "顶部不规则/白色锯齿/梯形斜切"（真机截图实证; 文档第 2 节明确
    允许 GDI+ 画路径圆角, Win7 原生 gdiplus.dll, NFR-8 兼容）。 }
  if W <= 0 then Exit;
  R := Min(ScalePx(C_FH_TabTopRadius), W div 2);
  Flare := ScalePx(C_FH_TabBottomFlare);
  K := Flare * 2;
  T := TabTopY;
  if not EnsureGdiPlus then
  begin
    // GDI+ 启动失败: 退化为 GDI 直角填充（丢圆角, 但不会整块不画/黑块）
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := FillColor;
    Canvas.Pen.Color := FillColor;
    Canvas.Rectangle(X, T, X + W, ABottom);
    Canvas.Brush.Style := bsClear;
    Exit;
  end;
  // 路径/画刷对象复用（每帧只重建路径内容）: 原实现每标签每帧 new 三份 GDI+ 对象
  if FPath = nil then
    FPath := TGPGraphicsPath.Create;
  if FBrush = nil then
    FBrush := TGPSolidBrush.Create($FF000000);
  FPath.Reset;
  // 左底外扩凹弧: (X-Flare,ABottom)→(X,ABottom-K), 先水平后垂直
  FPath.AddBezier(X - Flare, ABottom, X, ABottom, X, ABottom - K, X, ABottom - K);
  // 左边线
  FPath.AddLine(X, ABottom - K, X, T + R);
  // 左上圆角: 包围盒(X,T,2R,2R) 180°→270°（GDI+ 正角=顺时针, y 向下）
  FPath.AddArc(X, T, 2 * R, 2 * R, 180, 90);
  // 顶边
  FPath.AddLine(X + R, T, X + W - R, T);
  // 右上圆角: 270°→360°
  FPath.AddArc(X + W - 2 * R, T, 2 * R, 2 * R, 270, 90);
  // 右边线
  FPath.AddLine(X + W, T + R, X + W, ABottom - K);
  // 右底外扩凹弧
  FPath.AddBezier(X + W, ABottom - K, X + W, ABottom, X + W, ABottom,
    X + W + Flare, ABottom);
  C := ColorToRGB(FillColor);
  // ARGB = $AARRGGBB（TGPColor 为 ARGB 别名; R-G-B 各就各位）
  FBrush.SetColor($FF000000 or (GetRValue(C) shl 16) or
    (GetGValue(C) shl 8) or GetBValue(C));
  G := TGPGraphics.Create(Canvas.Handle);
  try
    G.SetSmoothingMode(SmoothingModeAntiAlias);
    G.FillPath(FBrush, FPath);
  finally
    G.Free;
  end;
end;

procedure TFHChromeTabs.PaintTab(Tab: TFHChromeTab; X, W: Integer;
  Active, DragGhost: Boolean);
var
  R, TR, CR: TRect;
  S, IconX, IconY, TextX, CX, CY, K: Integer;
  HoverTab, HoverClose: Boolean;
  HasIcon: Boolean;
  Clr: TColor;
  StrokeW: Single;
begin
  if W <= 0 then Exit;
  // 悬停判定（文档 4.5 状态矩阵）
  HoverTab := (FHoverKind = hkTab) and (FHoverIndex = FTabs.IndexOf(Tab));
  HoverClose := (FHoverKind = hkClose) and (FHoverIndex = FTabs.IndexOf(Tab));

  // 填充: 激活 TabActiveFill; 非激活 TabInactiveFill; 悬停增量 TabHoverFill
  // bsSolid 复位: 上一标签填充后设了 bsClear（文本透明）, 本标签 FillPath
  // 前必须恢复, 否则 NULL 画刷导致路径不填充（只出轮廓线的"梯形"观感）
  Canvas.Brush.Style := bsSolid;
  if Active then
    Canvas.Brush.Color := FTheme.TabActiveFill
  else if HoverTab then
    Canvas.Brush.Color := FTheme.TabHoverFill
  else
    Canvas.Brush.Color := FTheme.TabInactiveFill;
  // 形状（对齐 Chrome 真实渲染）:
  //   激活标签 = 药丸顶路径 + 底部外扩弧 + 下探贴满（骑在底线上, 文档 4.3）
  //   非激活标签 = 平顶矩形、留 2px 底缝——外扩弧仅激活标签绘制, 否则相邻
  //   标签路径各外伸 4px 互相重叠, 产生"梯形/阴影/宽窄不均"错视觉（实证）
  if Active or DragGhost then
    PaintTabPath(X, W, IfThen(Active, Height, Height - ScalePx(2)),
      Canvas.Brush.Color)
  else
    Canvas.FillRect(Rect(X, TabTopY, X + W, Height - ScalePx(2)));
  Canvas.Brush.Style := bsClear;

  S := ScalePx(C_FH_IconSize);
  // 图标来源: Images 优先, 其次 Icon（文档 FR-10）
  HasIcon := False;
  IconX := X + ScalePx(C_FH_TabPadLeft);
  IconY := CenterTop(S);
  if Tab.Pinned then
  begin
    // Pinned: 仅图标居中, 无标题无关闭按钮（文档 FR-6）
    IconX := X + (W - S) div 2;
    if Assigned(FImages) and (Tab.ImageIndex >= 0) then
    begin
      FImages.Draw(Canvas, IconX, IconY, Tab.ImageIndex, dsTransparent, itImage);
      HasIcon := True;
    end
    else if (Tab.Icon <> nil) and (not Tab.Icon.Empty) then
    begin
      Canvas.StretchDraw(Rect(IconX, IconY, IconX + S, IconY + S), Tab.Icon);
      HasIcon := True;
    end;
    if not HasIcon and (Tab.Caption <> '') then
    begin
      // 无图标画标题首字符居中（文档 FR-6）
      Canvas.Font.Color := FTheme.TabTextColor;
      R := Rect(X, TabTopY, X + W, Height);
      DrawText(Canvas.Handle, PChar(Tab.Caption), 1, R,
        DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);
    end;
    Exit;
  end;

  // ---- 普通标签: 图标 + 标题 + 关闭按钮 ----
  if Assigned(FImages) and (Tab.ImageIndex >= 0) then
  begin
    FImages.Draw(Canvas, IconX, IconY, Tab.ImageIndex, dsTransparent, itImage);
    HasIcon := True;
  end
  else if (Tab.Icon <> nil) and (not Tab.Icon.Empty) then
  begin
    Canvas.StretchDraw(Rect(IconX, IconY, IconX + S, IconY + S), Tab.Icon);
    HasIcon := True;
  end;

  // 关闭按钮（悬停圆形背景; 文档 4.2/4.5）
  if FShowCloseButtons then
  begin
    CR := CloseBtnRect(FTabs.IndexOf(Tab));
    if HoverClose then
    begin
      // 悬停圆直径 24（Chrome 观感）: 16px 热区外扩 4; GDI+ 抗锯齿
      GlyphFillCircleAA(Canvas, Rect(CR.Left - ScalePx(4), CR.Top - ScalePx(4),
        CR.Right + ScalePx(4), CR.Bottom + ScalePx(4)), FTheme.CloseBtnHoverBg);
      Clr := FTheme.CloseBtnHoverColor;
    end
    else
      Clr := FTheme.CloseBtnColor;
    { 以热区中心为基准、按半长画 ×: 原来贴着热区两角画, 符号几乎撑满 16px 热区
      （实际约 12px）, 观感偏大; 现在总长 8px, 与 Chrome 的 × 相当。
      GDI+ 圆头抗锯齿 + 浮点笔宽: 高 DPI 副屏上不再细/半像素发虚 }
    CX := (CR.Left + CR.Right) div 2;
    CY := (CR.Top + CR.Bottom) div 2;
    K  := ScalePx(C_FH_CloseCrossHalf);
    StrokeW := Max(1.0, C_FH_GlyphStroke * FScaleFactor);
    GlyphLineAA(Canvas, CX - K, CY - K, CX + K, CY + K, Clr, StrokeW);
    GlyphLineAA(Canvas, CX + K, CY - K, CX - K, CY + K, Clr, StrokeW);
  end;

  // 标题: 单行截断 + 省略号（文档 4.2）
  TextX := IconX;
  if HasIcon then
    Inc(TextX, S + ScalePx(C_FH_TabTextGap));
  R := Rect(TextX, TabTopY, X + W, Height);
  if FShowCloseButtons then
    R.Right := R.Right - ScalePx(C_FH_CloseBtnSize) -
      ScalePx(C_FH_ClosePadRight) - ScalePx(2);
  TR := R;
  if Active or HoverTab then
    Canvas.Font.Color := FTheme.TabTextColor
  else
    Canvas.Font.Color := FTheme.TabTextInactiveColor;
  DrawText(Canvas.Handle, PChar(Tab.Caption), -1, TR,
    DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);

  // 拖拽幽灵: 60% 透明（覆盖 40% 底色遮罩, 文档 FR-5）
  if DragGhost then
    BlendRect(Rect(X - ScalePx(C_FH_TabBottomFlare), TabTopY,
      X + W + ScalePx(C_FH_TabBottomFlare), Height),
      FTheme.BarBackground, 102);
end;

{ 画 "+"按钮: 悬停圆底 + 十字符号（GDI+ 抗锯齿浮点笔宽） }
procedure TFHChromeTabs.PaintNewButton;
var
  R: TRect;
  C: TPoint;
  K: Integer;
  Clr: TColor;
  StrokeW: Single;
begin
  R := NewButtonRect;
  C := Point((R.Left + R.Right) div 2, (R.Top + R.Bottom) div 2);
  // 悬停圆形背景（文档 FR-2）; GDI+ 抗锯齿（纯 GDI Ellipse 在高 DPI 副屏有锯齿）
  if FHoverKind = hkNew then
  begin
    GlyphFillCircleAA(Canvas, R, FTheme.NewBtnHoverBg);
    Clr := FTheme.TabTextColor;
  end
  else
    Clr := FTheme.NewBtnColor;
  // 与 × 同一套描边; 半长 6（总长 12）; GDI+ 圆头抗锯齿 + 浮点笔宽
  K := ScalePx(C_FH_NewPlusHalf);
  StrokeW := Max(1.0, C_FH_GlyphStroke * FScaleFactor);
  GlyphLineAA(Canvas, C.X, C.Y - K, C.X, C.Y + K, Clr, StrokeW);
  GlyphLineAA(Canvas, C.X - K, C.Y, C.X + K, C.Y, Clr, StrokeW);
end;

{ 画键盘焦点环: 仅"有焦点且最近是键盘交互"时画在激活标签内侧 }
procedure TFHChromeTabs.PaintFocusRing;
var
  I: Integer;
  R: TRect;
  L, RT: Integer;
begin
  // 焦点环: 只在"控件有焦点 且 最近是键盘交互"时画在激活标签内侧
  // （FocusIndicator token 原为死配置; 拖拽启动时为收 ESC 必须 SetFocus,
  //   此前只要 Focused 就画 → 拖拽结束蓝框常驻）
  if not (Focused and FKeyFocusVisible) then Exit;
  for I := 0 to High(FLayout) do
    if FLayout[I].TabIndex = FActiveIndex then
    begin
      L := FLayout[I].X - FScrollOffset + ScalePx(3);
      RT := FLayout[I].X - FScrollOffset + FLayout[I].Width - ScalePx(3);
      if L < ViewLeft then L := ViewLeft;
      if RT > ViewRight then RT := ViewRight;
      if RT - L < ScalePx(6) then Exit;
      R := Rect(L, ScalePx(3), RT, Height - ScalePx(4));
      Canvas.Brush.Style := bsClear;
      Canvas.Pen.Style := psSolid;
      Canvas.Pen.Width := Max(1, ScalePx(2));
      Canvas.Pen.Color := FTheme.FocusIndicator;
      Canvas.Rectangle(R.Left, R.Top, R.Right, R.Bottom);
      Canvas.Pen.Width := 1;
      Exit;
    end;
end;

{ 画溢出滚动箭头（左/右, 悬停圆底, 到边界置灰） }
procedure TFHChromeTabs.PaintArrows;

  procedure PaintOne(const R: TRect; LeftSide, Hot, Disabled: Boolean);
  var
    CX, CY: Integer;
    HoverR: TRect;
    ArrowColor: TColor;
  begin
    // 裁剪方案下箭头区域已是干净底色, 无需遮罩 FillRect（Chrome 做法）
    CX := (R.Left + R.Right) div 2;
    CY := (R.Top + R.Bottom) div 2;   // 全高中心 = 标签条中心
    if Hot and (not Disabled) then
    begin
      // 悬停圆形背景: 以中心为圆心 26x26（非全高椭圆）
      HoverR := Rect(CX - ScalePx(13), CY - ScalePx(13),
                     CX + ScalePx(13), CY + ScalePx(13));
      { GDI+ 抗锯齿圆底（纯 GDI Ellipse 在边缘有锯齿） }
      GlyphFillCircleAA(Canvas, HoverR, FTheme.NewBtnHoverBg);
      Canvas.Brush.Style := bsClear;
    end;
    // 颜色必须在"画箭头之前"决定: 原实现在画完后改 Pen.Color 等于没效果,
    // 且用双边条件把两个箭头一起判死（左到头时右箭头也灰）
    if Disabled then
      ArrowColor := FTheme.SeparatorColor
    else if Hot then
      ArrowColor := FTheme.TabTextColor
    else
      ArrowColor := FTheme.NewBtnColor;
    Canvas.Pen.Color := ArrowColor;
    Canvas.Pen.Width := 1;
    Canvas.Pen.Style := psSolid;
    Canvas.Brush.Style := bsClear;
    if LeftSide then
    begin
      // 左箭头 "<"
      Canvas.MoveTo(CX + ScalePx(3), CY - ScalePx(4));
      Canvas.LineTo(CX - ScalePx(3), CY);
      Canvas.LineTo(CX + ScalePx(3), CY + ScalePx(4));
    end
    else
    begin
      // 右箭头 ">"
      Canvas.MoveTo(CX - ScalePx(3), CY - ScalePx(4));
      Canvas.LineTo(CX + ScalePx(3), CY);
      Canvas.LineTo(CX - ScalePx(3), CY + ScalePx(4));
    end;
  end;

begin
  PaintOne(ArrowRect(True), True, FHoverKind = hkArrowLeft, FScrollOffset <= 0);
  PaintOne(ArrowRect(False), False, FHoverKind = hkArrowRight,
    FScrollOffset >= FMaxScroll);
end;

{ AlphaBlend 半透明矩形覆盖（拖拽幽灵 60% 透明; 1x1 源位图拉伸, 见体内注释） }
procedure TFHChromeTabs.BlendRect(const R: TRect; Color: TColor; Alpha: Byte);
var
  DC, MemDC: HDC;
  BMI: TBitmapInfo;
  Bits: Pointer;
  Bmp, OldBmp: HBITMAP;
  BF: TBlendFunction;
  Q: PRGBQuad;
  RGBV: Cardinal;
begin
  { AlphaBlend 半透明覆盖（幽灵标签 60% 透明; msimg32, Win7 原生可用）。
    源位图用 1x1 纯色 + AlphaBlend 拉伸: 原实现按标签宽高逐像素填充,
    拖拽时每帧 O(W*H) 次赋值, 是掉帧主因 }
  if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;
  DC := Canvas.Handle;
  FillChar(BMI, SizeOf(BMI), 0);
  BMI.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  BMI.bmiHeader.biWidth := 1;
  BMI.bmiHeader.biHeight := 1;
  BMI.bmiHeader.biPlanes := 1;
  BMI.bmiHeader.biBitCount := 32;
  MemDC := CreateCompatibleDC(DC);
  if MemDC = 0 then Exit;
  try
    Bmp := CreateDIBSection(0, BMI, DIB_RGB_COLORS, Bits, 0, 0);
    if (Bmp = 0) or (Bits = nil) then
    begin
      if Bmp <> 0 then
        DeleteObject(Bmp);
      Exit;
    end;
    try
      OldBmp := SelectObject(MemDC, Bmp);
      RGBV := ColorToRGB(Color);
      Q := PRGBQuad(Bits);
      Q.rgbBlue := GetBValue(RGBV);
      Q.rgbGreen := GetGValue(RGBV);
      Q.rgbRed := GetRValue(RGBV);
      Q.rgbReserved := Alpha;
      BF.BlendOp := AC_SRC_OVER;
      BF.BlendFlags := 0;
      BF.SourceConstantAlpha := 255;
      BF.AlphaFormat := AC_SRC_ALPHA;
      AlphaBlend(DC, R.Left, R.Top, R.Right - R.Left,
        R.Bottom - R.Top, MemDC, 0, 0, 1, 1, BF);
      SelectObject(MemDC, OldBmp);
    finally
      DeleteObject(Bmp);
    end;
  finally
    DeleteDC(MemDC);
  end;
end;

{ Hint 定制: 截断标题悬停显示完整 Caption（未截断不弹） }
procedure TFHChromeTabs.CMHintShow(var Message: TCMHintShow);
var
  Idx, CX: Integer;
  Tab: TFHChromeTab;
  Kind: TFHHitKind;
  LayoutR: TRect;
  TextW: Integer;
  Truncated: Boolean;
begin
  // 截断标题悬停显示完整 Caption（文档 FR-9）; 未截断不弹
  Idx := -1;
  Kind := HitTest(Message.HintInfo.CursorPos.X, Message.HintInfo.CursorPos.Y, Idx);
  if (Kind = hkTab) and (Idx >= 0) and (Idx < FTabs.Count) then
  begin
    Tab := FTabs[Idx];
    Truncated := Tab.Pinned;   // Pinned 无标题也显示（文档 FR-9）
    if not Truncated then
    begin
      // 布局宽是否容不下完整标题 → 截断
      for CX := 0 to High(FLayout) do
        if FLayout[CX].TabIndex = Idx then
        begin
          Canvas.Font.Assign(Font);
          TextW := Canvas.TextWidth(Tab.Caption) + ScalePx(C_FH_TabPadLeft);
          if FShowCloseButtons and (not Tab.Pinned) then
            Inc(TextW, ScalePx(C_FH_CloseBtnSize) + ScalePx(C_FH_ClosePadRight));
          Truncated := TextW > FLayout[CX].Width;
          Break;
        end;
    end;
    if Truncated then
    begin
      Message.HintInfo.HintStr := Tab.Caption;
      LayoutR := Rect(0, 0, Width, Height);
      MapWindowPoints(Handle, 0, LayoutR, 2);
      Message.HintInfo.HintPos := Point(LayoutR.Left + Message.HintInfo.CursorPos.X,
        LayoutR.Bottom + ScalePx(4));
      Message.Result := 1;
      Exit;
    end;
  end;
  inherited;
end;

{ ---- 交互（S2/S3: 点击/悬停/拖拽状态机, 文档 FR-3/FR-5） ------------------ }

{ 更新悬停态: 箭头悬停启动/停止持续滚动定时器, 变化时重绘 }
procedure TFHChromeTabs.SetHover(Kind: TFHHitKind; TabIndex: Integer);
begin
  if (FHoverKind = Kind) and (FHoverIndex = TabIndex) then Exit;
  FHoverKind := Kind;
  FHoverIndex := TabIndex;
  // 箭头悬停启动/停止持续滚动（文档 4.6）; 到边界的一侧不再空转定时器
  case Kind of
    hkArrowLeft:
      begin
        FScrollDir := -1;
        FScrollTimer.Enabled := FOverflow and (FScrollOffset > 0);
      end;
    hkArrowRight:
      begin
        FScrollDir := 1;
        FScrollTimer.Enabled := FOverflow and (FScrollOffset < FMaxScroll);
      end;
  else
    FScrollTimer.Enabled := False;
  end;
  Invalidate;
end;

{ 鼠标按下: 左键记录按压/拖拽候选（双击走 OnTabDblClick）,
  中键关闭标签, 右键弹菜单（细节见体内注释） }
procedure TFHChromeTabs.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Idx: Integer;
  Kind: TFHHitKind;
  Handled: Boolean;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
  begin
    // 鼠标交互: 隐藏键盘焦点环（Chrome 行为——焦点环只用于键盘导航,
    // 否则拖拽启动时的 SetFocus 会让蓝框一直挂在激活标签上）
    if FKeyFocusVisible then
    begin
      FKeyFocusVisible := False;
      Invalidate;
    end;
    // 双击（ssDouble: WM_LBUTTONDBLCLK 的第二击）→ OnTabDblClick（文档 6.1）
    if ssDouble in Shift then
    begin
      Idx := TabAt(X, Y);
      if Idx >= 0 then
        DoTabDblClick(Idx);
      // 清掉第一击遗留的按压态, 避免随后的 MouseUp 再走一次点击/激活分支
      FPressKind := hkNone;
      FPressIndex := -1;
      FDragTab := nil;
      Exit;
    end;
    Kind := HitTest(X, Y, Idx);
    FPressKind := Kind;
    FPressIndex := Idx;
    FPressPos := Point(X, Y);
    FDragging := False;
    FDragMoved := False;
    case Kind of
      hkTab:
        begin
          // 记录拖拽候选: 超阈值启动（FR-5, 4px）
          FDragTab := FTabs[Idx];
          FDragFromIndex := Idx;
          FGrabDX := X - (FLayout[IdxToLayout(Idx)].X - FScrollOffset);
          FDragX := X - FGrabDX;
        end;
    else
      FDragTab := nil;
    end;
  end
  else if Button = mbMiddle then
  begin
    // 入口2: 中键关闭（Pinned 不可关, Chrome 行为; 文档 FR-4）
    Idx := TabAt(X, Y);
    if (Idx >= 0) and (not FTabs[Idx].Pinned) then
      CloseTab(Idx);
  end
  else if Button = mbRight then
  begin
    // 入口3/4: 右键菜单（FR-8）
    Idx := TabAt(X, Y);
    if Idx >= 0 then
    begin
      Handled := False;
      DoTabContextMenu(Idx, Handled);   // 宿主可接管（文档 FR-8）
      if (not Handled) and FShowContextMenu then
        ShowContextMenuAt(Idx);
    end;
  end;
end;

function TFHChromeTabs.IdxToLayout(TabIndex: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FLayout) do
    if FLayout[I].TabIndex = TabIndex then
      Exit(I);
end;

{ 鼠标移动: 拖拽中幽灵跟随换位; 否则跟踪悬停, 按住超阈值启动拖拽 }
procedure TFHChromeTabs.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Idx: Integer;
  Kind: TFHHitKind;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragging then
  begin
    UpdateDragPosition(X);   // 拖拽中: 幽灵跟随 + 实时换位预览
    Exit;
  end;
  // 悬停跟踪（文档 4.5 状态矩阵）
  Kind := HitTest(X, Y, Idx);
  if Kind = hkClose then
    SetHover(hkClose, Idx)
  else if Kind = hkTab then
    SetHover(hkTab, Idx)
  else
    SetHover(Kind, -1);
  // 按住未释放 + 超阈值 → 启动拖拽（FR-5: 4px 阈值）
  if (FPressKind = hkTab) and (FPressIndex >= 0) and (FDragTab <> nil) then
  begin
    if (Abs(X - FPressPos.X) > ScalePx(C_FH_DragThreshold)) or
       (Abs(Y - FPressPos.Y) > ScalePx(C_FH_DragThreshold)) then
    begin
      FDragging := True;
      FDragMoved := False;
      // 拖拽期间必须拿到键盘焦点, 否则 KeyDown(VK_ESCAPE) 永远收不到 → 取消无效
      if CanFocus then SetFocus;
      SetHover(hkNone, -1);
      UpdateDragPosition(X);
    end;
  end;
end;

{ 拖拽中: 幽灵左缘跟随鼠标, 越过中点实时换位预览（FTabs.Move 触发重排） }
procedure TFHChromeTabs.UpdateDragPosition(X: Integer);
var
  Target, Cur: Integer;
begin
  // 幽灵标签左缘 = 鼠标 - 抓取偏移（仅横向, Y 锁定标签条内; FR-5）
  FDragX := X - FGrabDX;
  if FDragX < ScalePx(C_FH_BarPadding) then
    FDragX := ScalePx(C_FH_BarPadding);
  Target := DragTargetIndex(X);
  Cur := FTabs.IndexOf(FDragTab);
  if (Target >= 0) and (Target <> Cur) and (Target < FTabs.Count) then
  begin
    // Pinned/普通区不可跨界（FR-5）: DragTargetIndex 已夹紧
    FTabs.Move(Cur, Target);   // 触发 Update → LayoutChanged → 重绘
    FDragMoved := True;
  end;
  Invalidate;
end;

{ 由幽灵中心算目标插入位; Pinned 区与普通区不可跨界, 越界夹紧（细节见体内注释） }
function TFHChromeTabs.DragTargetIndex(X: Integer): Integer;
var
  CX, I, Target, GhostW: Integer;
  TabIsPinned: Boolean;
  FirstNorm: Integer;   // 首个非 Pinned 索引 = Pinned 区边界
begin
  { 由"幽灵标签中心"落在哪两个标签中点之间决定插入位——用鼠标点判定会因
    抓取偏移而滞后; Pinned 区与普通区不可跨界拖放, 越界夹紧到最近合法位
    （文档 FR-5） }
  Result := -1;
  if FDragTab = nil then Exit;
  TabIsPinned := FDragTab.Pinned;
  FirstNorm := 0;
  for I := 0 to FTabs.Count - 1 do
    if FTabs[I].Pinned then
      Inc(FirstNorm)
    else
      Break;
  if TabIsPinned then
    GhostW := ScalePx(FPinnedTabWidth)
  else
    GhostW := TabWidthOf(FDragTab);
  CX := FDragX + GhostW div 2 + FScrollOffset;   // 幽灵中心的内容坐标
  Target := 0;
  for I := 0 to High(FLayout) do
    if CX > FLayout[I].X + FLayout[I].Width div 2 then
      Target := I + 1;
  // 转集合索引; 越过最后一个标签时夹到 Count-1——
  // 原实现返回 Count 后被 UpdateDragPosition 的 "< Count" 条件丢弃,
  // 导致标签永远拖不到最右端
  if (Target >= 0) and (Target <= High(FLayout)) then
    Target := FLayout[Target].TabIndex
  else if FTabs.Count > 0 then
    Target := FTabs.Count - 1;
  // 区夹紧: Pinned 只能在 [0, FirstNorm-1] 内移; 普通只能在 [FirstNorm, Count-1]
  if TabIsPinned then
  begin
    if Target > FirstNorm - 1 then
      Target := FirstNorm - 1;
  end
  else
  begin
    if Target < FirstNorm then
      Target := FirstNorm;
  end;
  if Target > FTabs.Count - 1 then
    Target := FTabs.Count - 1;
  if Target < 0 then
    Target := 0;
  Result := Target;
end;

{ 鼠标松开: 拖拽落位发 OnTabMoved; 否则按"按下与释放命中一致"语义
  执行新建/关闭/箭头滚动/激活+单击 }
procedure TFHChromeTabs.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Idx: Integer;
  Kind: TFHHitKind;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if FDragging then
  begin
    FinishDrag(False);   // 落位: 发 OnTabMoved（FR-5）
    Exit;
  end;
  Kind := HitTest(X, Y, Idx);
  // 按下与释放命中一致才生效（标准按钮语义）
  case FPressKind of
    hkNew:
      if Kind = hkNew then
        DoNewButtonClick;   // "+"只发事件, 控件自身不添加 Tab（FR-2）
    hkClose:
      if (Kind = hkClose) and (Idx = FPressIndex) then
        CloseTab(Idx);     // 入口1: 关闭按钮（FR-4）
    hkArrowLeft:
      if Kind = hkArrowLeft then
        ScrollBy(-ScalePx(C_FH_ArrowScrollStep));
    hkArrowRight:
      if Kind = hkArrowRight then
        ScrollBy(ScalePx(C_FH_ArrowScrollStep));
    hkTab:
      if (Kind = hkTab) and (Idx = FPressIndex) then
      begin
        InternalActivate(Idx);   // 左键激活（FR-3）
        DoTabClick(Idx);         // 单击（非拖拽）事件（文档 6.1）
      end;
  end;
  FPressKind := hkNone;
  FPressIndex := -1;
  FDragTab := nil;
end;

{ 结束拖拽: Cancel=True（ESC）恢复原序; 否则移动过才发 OnTabMoved;
  清全部拖拽/按压态 }
procedure TFHChromeTabs.FinishDrag(Cancel: Boolean);
var
  Cur, From: Integer;
begin
  if not FDragging then Exit;
  Cur := FTabs.IndexOf(FDragTab);
  From := FDragFromIndex;
  if Cancel then
  begin
    // ESC 取消: 恢复原序（文档 FR-5 验收）
    if (Cur >= 0) and (Cur <> From) then
      FTabs.Move(Cur, From);
  end
  else if FDragMoved and (Cur >= 0) and (Cur <> From) then
    DoTabMoved(From, Cur);   // 均为移动前/最终集合索引（文档 FR-5）
  FDragging := False;
  FDragTab := nil;
  FDragMoved := False;
  FKeyFocusVisible := False;   // 拖拽结束: 焦点环不残留（拖拽启动曾 SetFocus）
  FPressKind := hkNone;
  FPressIndex := -1;
  Invalidate;
end;

{ 键盘: ESC 取消拖拽, Delete 关闭激活标签, Ctrl+Tab/方向键切换,
  Ctrl+Home/End 首末标签 }
procedure TFHChromeTabs.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);   // 宿主 OnKeyDown 优先（可置 Key := 0 吞掉）
  if Key = 0 then Exit;
  // 键盘交互: 显示焦点环（Chrome 行为; 鼠标点击/拖拽后不残留蓝框）
  if not FKeyFocusVisible then
  begin
    FKeyFocusVisible := True;
    Invalidate;
  end;
  case Key of
    VK_ESCAPE:
      if FDragging then
      begin
        FinishDrag(True);   // 拖拽中 ESC 取消（FR-5）
        Key := 0;
      end;
    VK_DELETE:
      if FActiveIndex >= 0 then
      begin
        CloseTab(FActiveIndex);   // 键盘关闭, 仍走 OnTabClosing 可取消
        Key := 0;
      end;
    VK_TAB:
      if ssCtrl in Shift then
      begin
        if ssShift in Shift then
          SwitchTab(-1)
        else
          SwitchTab(1);
        Key := 0;
      end;
    VK_LEFT, VK_UP:
      begin
        SwitchTab(-1);   // 焦点在标签条上时, 方向键即切换标签
        Key := 0;
      end;
    VK_RIGHT, VK_DOWN:
      begin
        SwitchTab(1);
        Key := 0;
      end;
    VK_HOME:
      if ssCtrl in Shift then
      begin
        if FTabs.Count > 0 then
          SetActiveTabIndex(0);
        Key := 0;
      end;
    VK_END:
      if ssCtrl in Shift then
      begin
        if FTabs.Count > 0 then
          SetActiveTabIndex(FTabs.Count - 1);
        Key := 0;
      end;
  end;
end;

procedure TFHChromeTabs.SwitchTab(Delta: Integer);
var
  I, Idx: Integer;
begin
  if FTabs.Count = 0 then Exit;
  Idx := FActiveIndex;
  for I := 1 to FTabs.Count do
  begin
    Inc(Idx, Delta);
    if Idx < 0 then
      Idx := FTabs.Count - 1
    else if Idx >= FTabs.Count then
      Idx := 0;
    if FTabs[Idx].Visible then
    begin
      SetActiveTabIndex(Idx);   // 走完整 OnActiveTabChanging/Change 链
      Exit;
    end;
  end;
end;

{ 获得焦点: 重绘（焦点环） }
procedure TFHChromeTabs.CMEnter(var Message: TCMEnter);
begin
  inherited;
  Invalidate;   // 焦点环
end;

{ 失去焦点: 重绘（焦点环消失） }
procedure TFHChromeTabs.CMExit(var Message: TCMExit);
begin
  inherited;
  Invalidate;
end;

{ 声明方向键归本控件处理（不吞 Tab 键, 见体内注释） }
procedure TFHChromeTabs.WMGetDlgCode(var Message: TWMGetDlgCode);
begin
  // 方向键归本控件处理（否则被窗体当对话框导航键拿走）;
  // 不声明 DLGC_WANTTAB: 否则 Tab 键无法离开本控件
  Message.Result := DLGC_WANTARROWS;
end;

{ 鼠标离开: 清悬停态并停止持续滚动定时器 }
procedure TFHChromeTabs.CMMouseLeave(var Message: TMessage);
begin
  SetHover(hkNone, -1);
  FScrollTimer.Enabled := False;
  inherited;
end;

{ 垂直滚轮 → 横向滚动（Chrome 行为）; 未溢出时交回父级（见体内注释） }
function TFHChromeTabs.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  // 垂直滚轮映射为横向滚动（Chrome 行为, 文档 FR-7）;
  // 未溢出时必须交回父级, 否则鼠标在标签条上滚页面完全没反应（原实现恒 True）
  if FOverflow then
  begin
    ScrollBy(-WheelDelta * FScrollStep div 120);
    Result := True;
  end
  else
    Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
end;

{ 横向滚轮滚动; 未溢出时不吞消息 }
procedure TFHChromeTabs.WMMouseHWheel(var Message: TWMMouseWheel);
begin
  // 横向滚轮（文档 FR-7）; 未溢出时不吞消息, 按默认流程处理
  if FOverflow then
  begin
    ScrollBy(Message.WheelDelta * FScrollStep div 120);
    Message.Result := 1;
  end;
end;

{ ---- 关闭流程（文档 FR-4） ----------------------------------------------- }

procedure TFHChromeTabs.CloseTab(TabIndex: Integer);
var
  Allow: Boolean;
begin
  if (TabIndex < 0) or (TabIndex >= FTabs.Count) then Exit;
  if FTabs[TabIndex].Pinned then Exit;   // Pinned 不可关（FR-4/FR-6）
  Allow := True;
  DoTabClosing(TabIndex, Allow);         // 宿主可拒（如未保存确认）
  if Allow then
    ForceCloseTab(TabIndex);
end;

procedure TFHChromeTabs.ForceCloseTab(TabIndex: Integer);
var
  OldActive, NewActive: Integer;
begin
  // 供异步关闭（CEF 14.4）: 跳过 OnTabClosing, 其余链路完整
  if (TabIndex < 0) or (TabIndex >= FTabs.Count) then Exit;
  OldActive := FActiveIndex;
  // 激活修正（文档 FR-3: 右邻优先; 关最后一个→左邻; 全关→-1）
  // 注: 删除非最后标签后, 右邻左移恰好落在被删索引位 → NewActive = TabIndex
  if OldActive = TabIndex then
  begin
    if TabIndex >= FTabs.Count - 1 then
      NewActive := TabIndex - 1
    else
      NewActive := TabIndex;
  end
  else
  begin
    NewActive := OldActive;
    if OldActive > TabIndex then
      Dec(NewActive);   // 删除点左侧位移修正
  end;
  FActiveIndex := NewActive;
  FTabs.Delete(TabIndex);
  // 悬停/按压索引可能指向已删除项 → 复位, 否则残留高亮/命中错位
  if FHoverIndex >= FTabs.Count then
    SetHover(hkNone, -1);
  if FPressIndex >= FTabs.Count then
    FPressIndex := -1;
  LayoutChanged;
  DoTabClosed(TabIndex);   // TabIndex = 删除前索引（文档 FR-4）
  if NewActive <> OldActive then
    DoActiveTabChange(OldActive, NewActive);   // 位移通知宿主同步（FR-3）
end;

{ ---- 右键菜单（文档 FR-8） ----------------------------------------------- }

{ 按需创建内置右键菜单（分组排列与 Chrome 一致, 见体内注释） }
procedure TFHChromeTabs.EnsureContextMenu;
begin
  if FMenu = nil then
  begin
    FMenu := TFHMenu.Create(Self);   // 组件私有, 随控件释放（NFR-3）
    FMenu.ScaleFactor := FScaleFactor;   // 与标签条同一套 DPI 换算
    { 分组排列与 Chrome 一致: 新建 / 分隔 / 页面操作(重新加载·复制·固定) / 分隔 /
      关闭 / 分隔 / 批量关闭 }
    FMenuNewRight := FMenu.Add('在右侧新增标签页', MenuNewRightClick, '', miNewTab);
    FMenu.AddSeparator;
    FMenuReload := FMenu.Add('重新加载', MenuReloadClick, '', miReload);
    FMenuDup    := FMenu.Add('复制', MenuDuplicateClick, '', miDuplicate);
    FMenuPin    := FMenu.Add('固定标签页', MenuPinClick, '', miPin);
    FMenu.AddSeparator;
    FMenuClose  := FMenu.Add('关闭标签页', MenuCloseClick, '', miClose);
    FMenu.AddSeparator;
    FMenuOthers := FMenu.Add('关闭其他标签页', MenuCloseOthersClick, '', miClose);
    FMenuRight  := FMenu.Add('关闭右侧标签页', MenuCloseRightClick, '', miClose);
    FMenuLeft   := FMenu.Add('关闭左侧标签页', MenuCloseLeftClick, '', miClose);
  end;
end;

{ 弹标签右键菜单: 记录目标索引并按标签状态刷新各菜单项可用态 }
procedure TFHChromeTabs.ShowContextMenuAt(TabIndex: Integer);
begin
  EnsureContextMenu;
  FMenuTabIndex := TabIndex;
  // 菜单项状态随目标标签刷新（文档 FR-8: Pin 切换文案/Pinned 禁用关闭）
  if FTabs[TabIndex].Pinned then
    FMenuPin.Caption := '取消固定'
  else
    FMenuPin.Caption := '固定标签页';
  FMenuClose.Enabled := not FTabs[TabIndex].Pinned;
  { 三项浏览器动作由宿主实现: 没挂回调就灰掉（组件本身不依赖 CEF） }
  FMenuNewRight.Enabled := Assigned(FOnTabNewToRight);
  FMenuReload.Enabled := Assigned(FOnTabReload);
  FMenuDup.Enabled := Assigned(FOnTabDuplicate);
  // 无可操作目标时禁用（Chrome 行为: 单项/末位标签的批量关闭项变灰）
  FMenuOthers.Enabled := FTabs.Count > 1;
  FMenuRight.Enabled := TabIndex < FTabs.Count - 1;
  FMenuLeft.Enabled := TabIndex > 0;
  FMenu.Popup(Mouse.CursorPos);
end;

{ == 右键菜单三项浏览器动作 ===================================================
  组件只负责"把用户的意图告诉宿主", 具体 CEF 行为由宿主实现（保持组件零 CEF
  依赖, 见 NFR-2 的分层）。三个 handler 结构一致: 取出右键时的标签索引复位后,
  以该索引回调; 索引无效则不动作。 }

procedure TFHChromeTabs.MenuNewRightClick(Sender: TObject);
begin
  if Assigned(FOnTabNewToRight) and (FMenuTabIndex >= 0) and
     (FMenuTabIndex < FTabs.Count) then
    FOnTabNewToRight(Self, FMenuTabIndex);
  FMenuTabIndex := -1;
end;

procedure TFHChromeTabs.MenuReloadClick(Sender: TObject);
begin
  if Assigned(FOnTabReload) and (FMenuTabIndex >= 0) and
     (FMenuTabIndex < FTabs.Count) then
    FOnTabReload(Self, FMenuTabIndex);
  FMenuTabIndex := -1;
end;

procedure TFHChromeTabs.MenuDuplicateClick(Sender: TObject);
begin
  if Assigned(FOnTabDuplicate) and (FMenuTabIndex >= 0) and
     (FMenuTabIndex < FTabs.Count) then
    FOnTabDuplicate(Self, FMenuTabIndex);
  FMenuTabIndex := -1;
end;

{ 菜单"固定/取消固定": 切换 Pinned（内含固定区重排 + OnTabPinChanged） }
procedure TFHChromeTabs.MenuPinClick(Sender: TObject);
var
  Tab: TFHChromeTab;
begin
  // Pin 切换: SetPinned 内含 Pinned 区重排 + OnTabPinChanged（FR-6）
  if (FMenuTabIndex >= 0) and (FMenuTabIndex < FTabs.Count) then
  begin
    Tab := FTabs[FMenuTabIndex];
    FMenuTabIndex := -1;
    Tab.Pinned := not Tab.Pinned;
  end;
end;

{ 菜单"关闭标签页": 走完整 CloseTab 链（OnTabClosing 可取消） }
procedure TFHChromeTabs.MenuCloseClick(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := FMenuTabIndex;
  FMenuTabIndex := -1;
  if (Idx >= 0) and (Idx < FTabs.Count) then
    CloseTab(Idx);
end;

{ 菜单"关闭其他标签页": 倒序逐个走 CloseTab（宿主可拒任意一个） }
procedure TFHChromeTabs.MenuCloseOthersClick(Sender: TObject);
var
  I: Integer;
begin
  // 批量关闭逐个走 OnTabClosing（宿主可拒任意一个, 文档 FR-8）
  if (FMenuTabIndex < 0) or (FMenuTabIndex >= FTabs.Count) then Exit;
  for I := FTabs.Count - 1 downto 0 do
    if (I <> FMenuTabIndex) and (not FTabs[I].Pinned) then
      CloseTab(I);
  FMenuTabIndex := -1;
end;

{ 菜单"关闭右侧标签页": 倒序关目标右侧（Pinned 除外） }
procedure TFHChromeTabs.MenuCloseRightClick(Sender: TObject);
var
  I: Integer;
begin
  if (FMenuTabIndex < 0) or (FMenuTabIndex >= FTabs.Count) then Exit;
  for I := FTabs.Count - 1 downto FMenuTabIndex + 1 do
    if not FTabs[I].Pinned then   // 目标右侧 Pinned 除外（文档 FR-8）
      CloseTab(I);
  FMenuTabIndex := -1;
end;

{ 菜单"关闭左侧标签页": 倒序关目标左侧（Pinned 除外） }
procedure TFHChromeTabs.MenuCloseLeftClick(Sender: TObject);
var
  I: Integer;
begin
  if (FMenuTabIndex < 0) or (FMenuTabIndex >= FTabs.Count) then Exit;
  // 逐个走 OnTabClosing（宿主可拒任意一个, 文档 FR-8）; Pinned 不关
  for I := FMenuTabIndex - 1 downto 0 do
    if not FTabs[I].Pinned then
      CloseTab(I);
  FMenuTabIndex := -1;
end;

{ ---- 事件触发器 ---------------------------------------------------------- }

{ 触发 OnTabClick（单击标签, 非拖拽） }
procedure TFHChromeTabs.DoTabClick(TabIndex: Integer);
begin
  if Assigned(FOnTabClick) then
    FOnTabClick(Self, TabIndex);
end;

{ 触发 OnTabDblClick（双击标签） }
procedure TFHChromeTabs.DoTabDblClick(TabIndex: Integer);
begin
  if Assigned(FOnTabDblClick) then
    FOnTabDblClick(Self, TabIndex);
end;

{ 触发 OnActiveTabChanging（切换前, 宿主可取消） }
procedure TFHChromeTabs.DoActiveTabChanging(OldIndex, NewIndex: Integer;
  var AllowChange: Boolean);
begin
  if Assigned(FOnActiveTabChanging) then
    FOnActiveTabChanging(Self, OldIndex, NewIndex, AllowChange);
end;

{ 触发 OnActiveTabChange（切换完成） }
procedure TFHChromeTabs.DoActiveTabChange(OldIndex, NewIndex: Integer);
begin
  if Assigned(FOnActiveTabChange) then
    FOnActiveTabChange(Self, OldIndex, NewIndex);
end;

{ 触发 OnTabClosing（关闭前, 宿主可拒） }
procedure TFHChromeTabs.DoTabClosing(TabIndex: Integer; var AllowClose: Boolean);
begin
  if Assigned(FOnTabClosing) then
    FOnTabClosing(Self, TabIndex, AllowClose);
end;

{ 触发 OnTabClosed（关闭完成, TabIndex 为删除前索引） }
procedure TFHChromeTabs.DoTabClosed(TabIndex: Integer);
begin
  if Assigned(FOnTabClosed) then
    FOnTabClosed(Self, TabIndex);
end;

{ 触发 OnTabMoved（拖拽落位/编程式重排） }
procedure TFHChromeTabs.DoTabMoved(FromIndex, ToIndex: Integer);
begin
  if Assigned(FOnTabMoved) then
    FOnTabMoved(Self, FromIndex, ToIndex);
end;

{ 触发 OnTabPinChanged（固定状态变化, 带变化前索引） }
procedure TFHChromeTabs.DoTabPinChanged(TabIndex: Integer; Pinned: Boolean);
begin
  if Assigned(FOnTabPinChanged) then
    FOnTabPinChanged(Self, TabIndex, Pinned);
end;

{ 触发 OnNewButtonClick（"+"按钮, 控件自身不添加 Tab） }
procedure TFHChromeTabs.DoNewButtonClick;
begin
  if Assigned(FOnNewButtonClick) then
    FOnNewButtonClick(Self);
end;

{ 触发 OnTabContextMenu（右键菜单前, 宿主可接管） }
procedure TFHChromeTabs.DoTabContextMenu(TabIndex: Integer; var Handled: Boolean);
begin
  if Assigned(FOnTabContextMenu) then
    FOnTabContextMenu(Self, TabIndex, Handled);
end;

{ ---- GDI+ 引擎初始化（抗锯齿路径填充, Win7 原生 gdiplus.dll） ------------ }
{ 懒初始化: 不在单元 initialization 段启动——包被 IDE 加载时该段运行在 DllMain
  上下文, GDI+ 官方禁止在此启动（可能死锁/启动失败）; 首次绘制时再启动,
  并检查返回值, 失败则退化 GDI 绘制。 }

var
  FHGdiPlusToken: ULONG_PTR = 0;

function EnsureGdiPlus: Boolean;
var
  SI: TGdiplusStartupInput;
begin
  if FHGdiPlusToken <> 0 then Exit(True);
  FillChar(SI, SizeOf(SI), 0);
  SI.GdiplusVersion := 1;
  Result := GdiplusStartup(FHGdiPlusToken, @SI, nil) = Ok;
  if not Result then
    FHGdiPlusToken := 0;
end;

initialization
  { 启动阶段不做任何事: GDI+ 在首次绘制时懒启动（见 EnsureGdiPlus） }

finalization
  if FHGdiPlusToken <> 0 then
  begin
    GdiplusShutdown(FHGdiPlusToken);
    FHGdiPlusToken := 0;
  end;

end.