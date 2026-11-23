unit uBrowserMain;

{==============================================================================
  FHBrowser 主窗体 —— 多标签 CEF 浏览器
  ----------------------------------------------------------------------------
  CEF 集成模式（验证成功的单标签模式扩展为多标签）:
    - 每标签 = TFHChromePage + TCEFWindowParent(alClient) + TChromium
    - CreateBrowser 在 Timer 里调（窗体已显示, WinParent 有句柄/尺寸）
    - OnAfterCreated → PostMessage(CEF_AFTERCREATED) → 异步 UpdateSize
    - OnClose → PostMessage(CEF_DESTROY, LParam=0) → 释放 WinParent → OnBeforeClose
    - OnBeforeClose → PostMessage(CEF_DESTROY, LParam=1) → 消息上下文 ForceCloseTab
      ⚠ CEF 回调栈内禁止销毁 VCL 控件: 回调运行在 CEF 的 C++ 帧深处,
        DestroyWindow 会同步泵消息造成重入, 进程被静默终止（关标签即整程序
        退出, 无报错）—— Tab/Page 释放只允许在 VCL 消息循环顶层执行,
        与 TabbedBrowser2 demo 的 CEF_DESTROYTAB 模式一致
    - ForceCloseTab 配合 KeepPagesOnClose: Page 只进隐藏池不销毁, 关闭链的
      激活切换/地址栏刷新完整走完（否则 Page.Free 一抛异常, DoActiveTabChange
      被跳过 → 激活标签空白、地址栏残留被关页 URL）; Page 真正销毁延迟一轮
      消息（CEF_FREEPAGE）错开 CEF UI 线程收尾, 仍失败则记 OS 错误码进日志
==============================================================================}

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, System.Types,
  System.Math,
  Winapi.Windows, Winapi.Messages, Vcl.Forms, Vcl.Controls, Vcl.ExtCtrls,
  Vcl.Graphics, Vcl.StdCtrls, Vcl.Dialogs, Winapi.GDIPOBJ, Winapi.GDIPAPI,
  uCEFChromium, uCEFChromiumEvents, uCEFWindowParent, uCEFInterfaces,
  uCEFTypes, uCEFConstants, uCEFApplication,
  uFHChromeTabs, uFHChromePageHost, uFHBrowserControls, uFHChromeMenu, uLogger,
  uFHDownloads, uFHBrowsingDataDlg, uFHSettings, uFHSettingsDlg,
  uFHAboutDlg,
  uFHHistoryDB, uFHHistory, uFHFindBar, uFHBookmarks;

const
  DEFAULT_URL = 'https://www.baidu.com';
  CEF_INITIALIZED = WM_APP + $A50;
  CEF_RESTOREREFRESH = WM_APP + $A51;   // 从最小化恢复后再补一次页面刷新
  CEF_OPENDEVTOOLS   = WM_APP + $A52;   // 页面里按下 F12 → 打开开发者工具
  CEF_NEWTAB         = WM_APP + $A53;   // 弹窗链接转新标签（OnBeforePopup 拦截后）
  CEF_CLEARBROWSINGDATA = WM_APP + $A54; // 页面里按下 Ctrl+Shift+Del → 清除浏览数据
  CEF_PRINT             = WM_APP + $A55; // 页面里按下 Ctrl+P → 打印
  CEF_DOWNLOADS         = WM_APP + $A56; // 页面里按下 Ctrl+J → 打开下载窗口
  CEF_FREEPAGE          = WM_APP + $A57; // 标签关闭链末尾: 延迟释放 Page（见 BrowserDestroyMsg）
  CEF_FIND              = WM_APP + $A58; // 打开页面内查找栏（页面里按 Ctrl+F / F3）
  CEF_FINDCLOSE         = WM_APP + $A59; // 关闭查找栏（页面导航/按 Esc）
  CEF_HISTORY           = WM_APP + $A5A; // 页面里按下 Ctrl+H → 打开历史记录窗口
  CEF_BOOKMARK          = WM_APP + $A5B; // 页面里按下 Ctrl+D → 添加/修改书签气泡
  CEF_BOOKMARKSMGR      = WM_APP + $A5C; // 页面里按下 Ctrl+Shift+O → 书签管理器
  CEF_FOCUSADDR         = WM_APP + $A5D; // 空白新标签页: CEF 抢焦点后异步还回地址栏


procedure GlobalCEFApp_OnContextInitialized;

type
  { TCEFWindowParent 在 CEF 子窗口存在时跳过 WM_ERASEBKGND（防闪烁）, 但页面区
    伸缩（书签栏显隐等）后 CEF 内部布局是异步追赶的, 追赶期子窗口未完全覆盖
    宿主, 露出区域无背景擦除显示为黑色 —— 启动时窗口底部黑色条即此根因。
    这里恢复擦除: 用 Color（=clWhite）填充, 与页面区底色一致, 追赶期露出
    区域显示白色而非黑色 }
  TFHCEFWindowParent = class(TCEFWindowParent)
  protected
    procedure WndProc(var Message: TMessage); override;
  end;

  TBrowserForm = class(TForm)
    pnlAddressBar: TPanel;
    procedure FormShow(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FBtnBackClick(Sender: TObject);
    procedure FBtnForwardClick(Sender: TObject);
    procedure FBtnReloadClick(Sender: TObject);
    procedure FBtnHomeClick(Sender: TObject);
    procedure FBtnGoClick(Sender: TObject);
    procedure FBtnMenuClick(Sender: TObject);
    procedure MnuDevToolsClick(Sender: TObject);
    procedure DoPrint(Sender: TObject);
    procedure DoShowDownloads(Sender: TObject);
    procedure DoShowDownloadsBubble(Sender: TObject);      // 下载按钮 → 近期下载记录气泡
    procedure ShowDownloadsBubbleAtButton(AAutoShow: Boolean);
    procedure UpdateDownloadButton;                        // 按下载状态切换图标/提示
    procedure DoShowHistory(Sender: TObject);
    procedure DoShowSettings(Sender: TObject);             // ⋮ 菜单 → 设置对话框
    procedure DoShowAbout(Sender: TObject);                // ⋮ 菜单 → 关于对话框
    { ---- 书签 ---- }
    procedure DoStarClick(Sender: TObject);                // 地址栏星标 → 添加/修改书签气泡
    procedure DoBookmarksChanged(Sender: TObject);         // 书签增删改后 → 刷星标态
    procedure UpdateStarButton;                            // 按当前页 URL 切换星标实心/空心
    procedure DoShowBookmarksManager(Sender: TObject);     // ⋮ 菜单/Ctrl+Shift+O → 书签管理器

    procedure OpenHistoryUrl(Sender: TObject; const AUrl: string);         // 历史窗口: 当前标签页打开
    procedure OpenHistoryUrlNewTab(Sender: TObject; const AUrl: string);   // 历史窗口: 新标签页打开
    procedure DoClearBrowsingData(Sender: TObject);
    procedure MenuZoom(Sender: TObject; ADelta: Integer; var ANewPct: Integer);
    procedure ApplyZoom(ADelta: Integer);   // 缩放当前页一档/重置（菜单行与快捷键共用）
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FAddressBarKeyPress(Sender: TObject; var Key: Char);
  private
    FTabs: TFHChromeTabs;
    FHost: TFHChromePageHost;
    FPendingCreate: TList<TFHChromePage>;
    FChromiumSeq: Integer;           // 浏览器/父窗命名序号: 只增不减 —— 若用 Tabs.Count,
                                     // 关掉几个标签再新增时序号会撞名 → EComponentError
    FRetryTimer: TTimer;
    FFocusAddrTimer: TTimer;         // 空白新标签页焦点兜底重试（见 FocusAddrRetryTick）
    FFocusAddrRetries: Integer;
    FEnsureHomeTimer: TTimer;        // 启动兜底: 保证至少有一个首页标签
    FURLs: TDictionary<TChromium, string>;
    FIconURLs: TDictionary<TChromium, string>;   // 各页当前 favicon URL（变化才重新下载）
    FFavIconCache: TDictionary<TChromium, TIcon>;  // 各页上次成功下载的 favicon（loading 结束时恢复）
    FLoadingTabs: TList<TChromium>;              // 正在加载的标签（驱动 spinner 动画）
    FLoadingTimer: TTimer;                       // spinner 动画驱动
    FResizeTimer: TTimer;                        // 拖拽/缩放结束后的延迟刷新（CEF 合成为异步）
    FLoadingFrame: Integer;                      // spinner 当前帧 0..11
    FStatusPanel: TPanel;                        // 链接悬停提示: 浮在页面左下角显示链接 URL
    FFindBar: TFHFindBar;                        // 页面内查找条（右上角浮层）
    FFindChromium: TChromium;                    // 查找条当前作用的页面（切页时清掉它的高亮）
    FCanClose: Boolean;
    FPendingPopupUrls: TStringList;  // 弹窗转新标签的 URL 队列（OnBeforePopup 里不能直接建浏览器）
    FPopupTabs: TList<TChromium>;    // 弹窗转来的标签（若是下载链接, 下载开始后关掉, 不留空白页）
    FMenuCmdNewTab: Integer;         // CEF(Chrome) 右键菜单"在新标签页中打开链接"的命令 ID
    FMenuCmdNewWindow: Integer;      // "在新窗口中打开链接"的命令 ID（单窗口应用也当新标签）
    // Chrome 风格自绘控件
    FBtnBack: TFHNavButton;
    FBtnForward: TFHNavButton;
    FBtnReload: TFHNavButton;
    FBtnHome: TFHNavButton;
    FBtnDownload: TFHNavButton;    // 下载按钮（图标随下载状态切换）
    FBtnMenu: TFHNavButton;        // ⋮ 主菜单按钮
    FMenuPopup: TFHMenu;           // ⋮ 主菜单（开发者工具等, 自绘 Chrome 风格）
    FZoomItem: TFHMenuItem;        // 主菜单里的缩放行（打开菜单前同步当前页百分比）
    FBookmarkBar: TFHBookmarkBar;  // 书签栏（仅空白页/新标签页显示, SyncBookmarkBar 自动显隐）
    FDevToolsHosts: TDictionary<TChromium, TCEFWindowParent>;  // 每个开了 DevTools 的标签 → 其停靠容器
    FDevToolsSplitters: TDictionary<TChromium, TSplitter>;     // 同上 → 对应分隔条
    FAddressBar: TFHAddressBar;
    FToolbarLine: TPanel;      // 工具栏下边框（1px 灰线）
    FBtnMin: TFHCaptionButton;
    FBtnMax: TFHCaptionButton;
    FBtnClose: TFHCaptionButton;
    FWasMinimized: Boolean;      // 是否处于"最小化后刚恢复"的状态
    procedure CreateNavButtons;
    procedure CreateCaptionButtons;
    procedure CreateMainMenu;      // ⋮ 主菜单（开发者工具等）
    procedure TimerTick(Sender: TObject);
    { 空白新标签页焦点兜底: 定时检查 Win32 焦点是否还在地址栏, 被 CEF
      渲染窗口/window parent 转发抢走则夺回（最多 FFocusAddrRetries 轮） }
    procedure FocusAddrRetryTick(Sender: TObject);
    { 聚焦地址栏（带诊断）: VCL SetFocus 未生效时用 Win32 API 兜底;
      返回是否真正聚焦成功（GetFocus = Edit 句柄） }
    function TryFocusAddressBar: Boolean;
    procedure DoNewTab(Sender: TObject);
    procedure DoTabClosing(Sender: TObject; TabIndex: Integer; var AllowClose: Boolean);
    { 标签右键菜单三项: 组件把意图回调过来, 这里做真正的浏览器动作 }
    procedure DoTabNewToRight(Sender: TObject; TabIndex: Integer);
    procedure DoTabReload(Sender: TObject; TabIndex: Integer);
    procedure DoTabDuplicate(Sender: TObject; TabIndex: Integer);
    procedure DoFind(Sender: TObject);
    procedure ShowFindBar;
    procedure HideFindBar;
    procedure DoFindSearch(Sender: TObject);
    procedure DoFindNext(Sender: TObject);
    procedure DoFindPrev(Sender: TObject);
    procedure DoFindClose(Sender: TObject);
    procedure FindStep(AForward: Boolean);
    function NextInsertIndex(TabIndex: Integer): Integer;
    procedure NewBrowserTabAt(AIndex: Integer; const AUrl: string);
    procedure ReloadPageAt(TabIndex: Integer);
    procedure DoPageChanged(Sender: TObject; OldIndex, NewIndex: Integer);
    function ChromiumOfPage(Page: TFHChromePage): TChromium;
    function TabIndexOfChromium(Chromium: TChromium): Integer;
    function CurrentChromium: TChromium;
    procedure UpdateAddressBar;
    { 书签栏可见性同步: 当前标签空白页(空/about:blank)显示, 网页隐藏 }
    procedure SyncBookmarkBar;
    procedure SetReloadButtonLoading(ALoading: Boolean);
    { 启动兜底: 还没有任何标签且 CEF 上下文已就绪时补建首页 }
    procedure EnsureHomeTick(Sender: TObject);
    { 让所有页面重新出帧: 同步宿主尺寸 + 向 CEF 请求立即重绘 }
    procedure RefreshPageSurfaces;
    // CEF 事件
    procedure ChromiumAfterCreated(Sender: TObject; const browser: ICefBrowser);
    procedure ChromiumClose(Sender: TObject; const browser: ICefBrowser; var aAction: TCefCloseBrowserAction);
    procedure ChromiumBeforeClose(Sender: TObject; const browser: ICefBrowser);
    { 下载: OnBeforeDownload 定目标路径, OnDownloadUpdated 刷进度 }
    procedure ChromiumBeforeDownload(Sender: TObject; const browser: ICefBrowser;
      const downloadItem: ICefDownloadItem; const suggestedName: ustring;
      const callback: ICefBeforeDownloadCallback);
    procedure ChromiumDownloadUpdated(Sender: TObject; const browser: ICefBrowser;
      const downloadItem: ICefDownloadItem; const callback: ICefDownloadItemCallback);
    { 释放某标签的 CEF 宿主控件并关掉标签（alloy/chrome 两种运行时共用） }
    procedure DestroyBrowserForChromium(Chromium: TChromium);
    procedure ChromiumTitleChange(Sender: TObject; const browser: ICefBrowser; const title: ustring);
    { CEF 渲染窗口获得焦点时触发 —— 空白新标签页场景把焦点还给地址栏 }
    procedure ChromiumGotFocus(Sender: TObject; const browser: ICefBrowser);
    { CEF 渲染窗口"即将"获得焦点（导航/系统激活前）—— 空白新标签页返回 True
      取消该请求, 焦点留在地址栏（CEF 抢焦点的根治拦截点） }
    procedure ChromiumSetFocus(Sender: TObject; const browser: ICefBrowser;
      source: TCefFocusSource; out Result: Boolean);
    procedure ChromiumAddressChange(Sender: TObject; const browser: ICefBrowser; const frame: ICefFrame; const url: ustring);
    procedure ChromiumLoadingStateChange(Sender: TObject; const browser: ICefBrowser; isLoading, canGoBack, canGoForward: Boolean);
    procedure ChromiumFindResult(Sender: TObject; const browser: ICefBrowser;
      identifier, count: Integer; const selectionRect: PCefRect;
      activeMatchOrdinal: Integer; finalUpdate: Boolean);
    { 加载失败(超时/DNS/连接拒绝等): 注入中文错误页, 含错误码+描述+重试链接 }
    procedure ChromiumLoadError(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; errorCode: TCefErrorCode;
      const errorText, failedUrl: ustring);
    { 鼠标悬停链接: CEF 把链接 URL 作为 status message 发来(移开时发空串),
      在当前页面左下角浮一个提示显示; 空串则隐藏 }
    procedure ChromiumStatusMessage(Sender: TObject; const browser: ICefBrowser;
      const value: ustring);
    { renderer/GPU 子进程异常终止: 记日志, 不让主进程跟着静默退出 }
    procedure ChromiumRenderProcessTerminated(Sender: TObject;
      const browser: ICefBrowser; status: TCefTerminationStatus);

    { 焦点在页面里时按键不会到 VCL 窗体, F12 只能在这里截（CEF 自己的按键前处理） }
    procedure ChromiumPreKeyEvent(Sender: TObject; const browser: ICefBrowser;
      const event: PCefKeyEvent; osEvent: TCefEventHandle;
      out isKeyboardShortcut: Boolean; out Result: Boolean);
    { favicon: 页面报告图标 URL → DownloadImage 异步取图 → 完成后写 Tab.Icon }
    procedure ChromiumFavIconURLChange(Sender: TObject; const browser: ICefBrowser;
      const iconUrls: TStrings);
    procedure ChromiumDownloadImageFinished(Sender: TObject; const imageUrl: ustring;
      httpStatusCode: Integer; const image: ICefImage);
    function CefImageToIcon(const AImage: ICefImage; ATargetPx: Integer): TIcon;
    { loading spinner: 加载中在标签上画旋转点环, 加载完恢复 favicon }
    function MakeLoadingIcon(ASize, AFrame: Integer): TIcon;
    procedure LoadingTimerTick(Sender: TObject);
    { 统一写 favicon: 更新缓存, 且仅在该标签不在 loading 时才落到 Tab.Icon
      （loading 期间 Tab.Icon 由 spinner 占用, favicon 只更新缓存） }
    procedure ApplyFavIcon(C: TChromium; AIcon: TIcon);
    procedure RestoreFavIcon(C: TChromium);
    { 打开/关闭开发者工具（F12 或菜单）; 默认停靠在当前页面右侧 }
    procedure OpenDevTools;
    procedure CloseDevTools(AChromium: TChromium);

    procedure OpenDevToolsMsg(var Message: TMessage); message CEF_OPENDEVTOOLS;
    procedure NewTabMsg(var Message: TMessage); message CEF_NEWTAB;
    procedure ClearBrowsingDataMsg(var Message: TMessage); message CEF_CLEARBROWSINGDATA;
    procedure PrintMsg(var Message: TMessage); message CEF_PRINT;
    procedure DownloadsMsg(var Message: TMessage); message CEF_DOWNLOADS;
    procedure FreePageMsg(var Message: TMessage); message CEF_FREEPAGE;
    procedure FindBarMsg(var Message: TMessage); message CEF_FIND;
    procedure FindBarCloseMsg(var Message: TMessage); message CEF_FINDCLOSE;
    procedure HistoryMsg(var Message: TMessage); message CEF_HISTORY;
    procedure BookmarkMsg(var Message: TMessage); message CEF_BOOKMARK;
    procedure BookmarksMgrMsg(var Message: TMessage); message CEF_BOOKMARKSMGR;

    { 网页右键菜单: 找出并接管 CEF 自带的"在新标签页/新窗口中打开链接" }
    procedure ChromiumBeforeContextMenu(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; const params: ICefContextMenuParams;
      const model: ICefMenuModel);
    procedure ChromiumContextMenuCommand(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; const params: ICefContextMenuParams;
      commandId: Integer; eventFlags: TCefEventFlags; out Result: Boolean);
    { 弹窗类链接（target=_blank / window.open 等）不在新窗口打开, 转为本窗口新标签 }
    procedure ChromiumBeforePopup(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; const targetUrl, targetFrameName: ustring;
      targetDisposition: TCefWindowOpenDisposition; userGesture: Boolean;
      const popupFeatures: TCefPopupFeatures; var windowInfo: TCefWindowInfo;
      var client: ICefClient; var settings: TCefBrowserSettings;
      var extra_info: ICefDictionaryValue; var noJavascriptAccess: Boolean;
      var Result: Boolean);
    procedure BrowserCreatedMsg(var Message: TMessage); message CEF_AFTERCREATED;
    procedure FocusAddrMsg(var Message: TMessage); message CEF_FOCUSADDR;
    procedure BrowserDestroyMsg(var Message: TMessage); message CEF_DESTROY;
    procedure CEFInitializedMsg(var Message: TMessage); message CEF_INITIALIZED;
    procedure RestoreRefreshMsg(var Message: TMessage); message CEF_RESTOREREFRESH;
    procedure WMNCCalcSize(var Message: TWMNCCalcSize); message WM_NCCALCSIZE;
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
    { 从最小化恢复后通知 CEF 重新出帧, 消除页面白屏（详见实现处注释） }
    procedure WMSize(var Message: TWMSize); message WM_SIZE;
    { 跨屏拖动后通知 CEF compositor 重建渲染表面, 否则页面白屏 }
    procedure WMMove(var Message: TMessage); message WM_MOVE;
    { 跨到不同 DPI 的显示器后同步 CEF 原生子窗口尺寸 }
    procedure WMDpiChanged(var Message: TMessage); message WM_DPICHANGED;
    { 拖拽/缩放开始: 通知 CEF 进入交互式 resize, 由它自行节流渲染 }
    procedure WMEnterSizeMove(var Message: TMessage); message WM_ENTERSIZEMOVE;
    { 拖拽/缩放结束: 同步尺寸 + WasResized + 延迟一轮补帧 }
    procedure WMExitSizeMove(var Message: TMessage); message WM_EXITSIZEMOVE;
    procedure ResizeSettledTick(Sender: TObject);
    procedure OnCaptionBtnClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { 新建标签并加载 AUrl（空 = 首页 DEFAULT_URL）, 追加到末尾并激活 }
    procedure NewBrowserTab(const AUrl: string = '');
  end;

var
  BrowserForm: TBrowserForm;

implementation

{$R *.dfm}

{ ---- TFHCEFWindowParent --------------------------------------------------- }

procedure TFHCEFWindowParent.WndProc(var Message: TMessage);
var
  BkBrush: HBRUSH;
  R: TRect;
begin
  if (Message.Msg = WM_ERASEBKGND) and HandleAllocated then
  begin
    // 无条件擦除（基类仅在无 CEF 子窗口时才擦）: 布局追赶期露出的区域
    // 擦成 Color（白）, 消除底部黑色条; 子窗口完全覆盖时擦除被盖住, 无闪烁
    R := ClientRect;
    BkBrush := CreateSolidBrush(ColorToRGB(Color));
    FillRect(HDC(Message.WParam), R, BkBrush);
    DeleteObject(BkBrush);
    Message.Result := 1;
  end
  else
    inherited WndProc(Message);
end;

{ ---- CEF 上下文就绪回调（dpr 里挂给 GlobalCEFApp.OnContextInitialized） -------- }

procedure GlobalCEFApp_OnContextInitialized;
begin
  // CEF 全局上下文就绪后异步通知窗体（TabbedBrowser2 同模式, 不用 Timer 轮询）
  if (BrowserForm <> nil) and BrowserForm.HandleAllocated then
    PostMessage(BrowserForm.Handle, CEF_INITIALIZED, 0, 0);
end;

{ ---- 关联解析 ------------------------------------------------------------- }

{ 页面 → 浏览器反查: Tab.Data 里挂的就是该页的 TChromium; 无关联返回 nil }
function TBrowserForm.ChromiumOfPage(Page: TFHChromePage): TChromium;
begin
  if (Page <> nil) and (Page.Tab <> nil) and (Page.Tab.Data is TChromium) then
    Result := TChromium(Page.Tab.Data)
  else
    Result := nil;
end;

{ 浏览器 → 标签集合索引反查（CEF 回调里只有 Sender）; 未找到返回 -1 }
function TBrowserForm.TabIndexOfChromium(Chromium: TChromium): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to FTabs.Tabs.Count - 1 do
    if FTabs.Tabs[I].Data = TObject(Chromium) then
      Exit(I);
end;

{ 当前激活标签的浏览器; 无激活标签/页返回 nil }
function TBrowserForm.CurrentChromium: TChromium;
begin
  Result := ChromiumOfPage(FHost.PageAtTabIndex(FTabs.ActiveTabIndex));
end;

{ 把激活页的 URL/后退前进可用性/加载态/状态栏提示同步到工具栏（切页与导航后调用） }
procedure TBrowserForm.UpdateAddressBar;
var
  C: TChromium;
  URL: string;
begin
  SyncBookmarkBar;   // 书签栏随当前标签空白/网页态显隐（切页入口）
  C := CurrentChromium;
  if C = nil then
  begin
    FAddressBar.Text := '';
    FBtnBack.Enabled := False;
    FBtnForward.Enabled := False;
    SetReloadButtonLoading(False);
    FStatusPanel.Visible := False;   // 无激活页: 状态栏一并清掉
    Exit;
  end;
  if FURLs.TryGetValue(C, URL) then
  begin
    { 空白页(about:blank)在地址栏显示为空, 而不是把 about:blank 露出来 }
    if SameText(URL, 'about:blank') then
      FAddressBar.Text := ''
    else
      FAddressBar.Text := URL;
  end
  else
    FAddressBar.Text := '';
  FBtnBack.Enabled := C.CanGoBack;
  FBtnForward.Enabled := C.CanGoForward;
  SetReloadButtonLoading(C.IsLoading);
  FStatusPanel.Visible := False;   // 切页/导航清状态栏(Chrome 行为), 新页悬停后重新显示
  UpdateStarButton;                // 星标随当前页 URL 同步实心/空心
end;

{ 按当前页 URL 切换地址栏星标: 已收藏 = 实心蓝星, 未收藏 = 空心灰星。
  切页 / 导航 / 书签增删改（DoBookmarksChanged）都会走到这里 }
procedure TBrowserForm.UpdateStarButton;
var
  C: TChromium;
  URL: string;
begin
  if FAddressBar = nil then Exit;
  C := CurrentChromium;
  if (C <> nil) and FURLs.TryGetValue(C, URL) and (URL <> '') then
    FAddressBar.Starred := HistoryDB.BookmarkExists(URL)
  else
    FAddressBar.Starred := False;
end;

{ 书签栏可见性 = 当前标签是否空白页（Chrome "仅在新标签页上显示书签栏"）:
  新建标签页(URL 空 / about:blank)时显示, 网页打开后自动隐藏; 切页
  (UpdateAddressBar) 与导航(ChromiumAddressChange)都会走到这里,
  alTop 显隐时页面区由 VCL 自动伸缩 }
procedure TBrowserForm.SyncBookmarkBar;
var
  C: TChromium;
  URL: string;
  IsBlank: Boolean;
begin
  if FBookmarkBar = nil then Exit;
  C := CurrentChromium;
  { 无激活页分两种: 标签已全部关闭 → 空白窗口, 显示书签栏（原行为）;
    建标签瞬间（InsertPage 触发本函数时 Tab.Data/FURLs 尚未注册,
    Tabs.Count>0）→ 不动书签栏。原先后者被"视同空白页→显示", 启动建
    首页标签时书签栏闪现, 首航 OnAddressChange 到来又隐藏 —— 页面区
    随 alTop 显隐伸缩, CEF 内部布局异步追赶期底部露出无背景区域,
    即"启动时底部黑色条"的跳变源 }
  if C = nil then
  begin
    if (FTabs <> nil) and (FTabs.Tabs.Count = 0) and
      (not FBookmarkBar.Visible) then
      FBookmarkBar.Visible := True;
    Exit;
  end;
  if not FURLs.TryGetValue(C, URL) then Exit;   // URL 未注册: 建标签瞬间, 不动
  IsBlank := (URL = '') or SameText(URL, 'about:blank');
  if FBookmarkBar.Visible <> IsBlank then
    FBookmarkBar.Visible := IsBlank;
end;

{ 刷新按钮两态切换: 加载中 = 停止(×), 空闲 = 重新加载(↻) }
procedure TBrowserForm.SetReloadButtonLoading(ALoading: Boolean);
begin
  if FBtnReload = nil then Exit;
  if ALoading then
  begin
    FBtnReload.ButtonType := nbtStop;
    FBtnReload.Hint := '停止加载';
  end
  else
  begin
    FBtnReload.ButtonType := nbtReload;
    FBtnReload.Hint := '重新加载';
  end;
end;

{ ---- 新建标签 ------------------------------------------------------------- }

{ 新建标签并加载 AUrl, 追加到末尾并激活（实现细节见 NewBrowserTabAt） }
procedure TBrowserForm.NewBrowserTab(const AUrl: string);
begin
  NewBrowserTabAt(-1, AUrl);   // -1 = 追加到末尾（原行为）
end;

{ 在指定位置新建标签: 建 Page + TChromium + CEF 宿主并挂接全部事件;
  浏览器创建统一延迟到 FRetryTimer（见 TimerTick）, 首航 URL 走 DefaultUrl }
procedure TBrowserForm.NewBrowserTabAt(AIndex: Integer; const AUrl: string);
var
  Page: TFHChromePage;
  WinParent: TCEFWindowParent;
  Chromium: TChromium;
begin
  try
    Page := FHost.InsertPage(AIndex);
    Page.Caption := '新标签页';

    Chromium := TChromium.Create(Self);
    Inc(FChromiumSeq);
    Chromium.Name := Format('Chromium%d', [FChromiumSeq]);
    { 首航 URL 走 DefaultUrl: CreateBrowser 时 CEF 直接以它做初始导航。
      不能等 AfterCreated 再 LoadURL —— 那与 CEF 的 about:blank 初始加载有竞态,
      LoadURL 时好时坏被静默丢弃（表现为新标签停在空白页, 实测踩到） }
    Chromium.DefaultUrl := AUrl;
    Chromium.OnAfterCreated := ChromiumAfterCreated;
    Chromium.OnClose := ChromiumClose;
    Chromium.OnBeforeClose := ChromiumBeforeClose;
    Chromium.OnTitleChange := ChromiumTitleChange;
    Chromium.OnGotFocus := ChromiumGotFocus;
    Chromium.OnSetFocus := ChromiumSetFocus;
    Chromium.OnAddressChange := ChromiumAddressChange;
    Chromium.OnLoadingStateChange := ChromiumLoadingStateChange;
    Chromium.OnFindResult := ChromiumFindResult;
    Chromium.OnLoadError := ChromiumLoadError;
    Chromium.OnStatusMessage := ChromiumStatusMessage;
    Chromium.OnRenderProcessTerminated := ChromiumRenderProcessTerminated;
    Chromium.OnPreKeyEvent := ChromiumPreKeyEvent;
    Chromium.OnFavIconUrlChange := ChromiumFavIconURLChange;
    Chromium.OnDownloadImageFinished := ChromiumDownloadImageFinished;
    Chromium.OnBeforeDownload := ChromiumBeforeDownload;
    Chromium.OnDownloadUpdated := ChromiumDownloadUpdated;
    Chromium.OnBeforePopup := ChromiumBeforePopup;
    Chromium.OnBeforeContextMenu := ChromiumBeforeContextMenu;
    Chromium.OnContextMenuCommand := ChromiumContextMenuCommand;
    Page.Tab.Data := Chromium;
    FURLs.AddOrSetValue(Chromium, AUrl);          // 供"复制"取当前 URL（导航前也有值）

    WinParent := TFHCEFWindowParent.Create(Page);
    WinParent.Name := Format('CEFParent%d', [FChromiumSeq]);
    WinParent.Parent := Page;
    WinParent.Color := clWhite;
    WinParent.Align := alClient;
    Chromium.Tag := NativeInt(WinParent);
  except
    on E: Exception do
    begin
      Logger.Error('新建标签失败 (url=%s, index=%d): %s - %s',
        [AUrl, AIndex, E.ClassName, E.Message]);
      raise;   // 记录后上抛: 创建失败必须显式可见, 不能留下半残的标签
    end;
  end;

  // 建浏览器统一走 FRetryTimer（延迟 300ms, 消息队列空闲后）:
  // CEF 全局上下文未就绪时 CreateBrowser 必失败, 本来就要重试; 统一入口后
  // "立即建"与"失败重试"两条路径合一, 句柄检查也集中在 TimerTick 里做
  FPendingCreate.Add(Page);
  FRetryTimer.Enabled := True;
end;

{ FRetryTimer 落点: CEF 上下文就绪后为待建页逐个 CreateBrowser,
  失败的留在队列里下轮重试 }
procedure TBrowserForm.TimerTick(Sender: TObject);
var
  I: Integer;
  Page: TFHChromePage;
  Chromium: TChromium;
  WinParent: TCEFWindowParent;
begin
  // 关键: 等 CEF 全局上下文就绪后才 CreateBrowser（TabbedBrowser 同模式）
  // GlobalContextInitialized=False 时 CreateBrowser 必失败——盲目重试无意义
  if not GlobalCEFApp.GlobalContextInitialized then
    Exit;   // 保持 Timer Enabled, 下次再试

  FRetryTimer.Enabled := False;
  for I := FPendingCreate.Count - 1 downto 0 do
  begin
    Page := FPendingCreate[I];
    Chromium := ChromiumOfPage(Page);
    if Chromium = nil then Continue;
    WinParent := TCEFWindowParent(Chromium.Tag);
    if WinParent = nil then Continue;
    if not WinParent.HandleAllocated then
      WinParent.Handle;
    if Chromium.CreateBrowser(WinParent, '') then
      FPendingCreate.Delete(I);   // URL 由 BrowserCreatedMsg 统一加载
  end;
  if FPendingCreate.Count > 0 then
    FRetryTimer.Enabled := True;
end;

{ ---- 标签条事件 ----------------------------------------------------------- }

{ 标签条 + 按钮 / 菜单"新建标签页"入口 }
procedure TBrowserForm.DoNewTab(Sender: TObject);
begin
  { 新标签页打开什么由设置决定: 指定网址（默认） / 空白页 }
  if Settings.NewTabMode = ntmBlank then
  begin
    NewBrowserTab('about:blank');
    { 空白新标签页: 焦点直接给地址栏准备输入网址（Chrome 同款）。
      CEF 渲染窗口 300ms 后才创建可能抢走焦点, BrowserCreatedMsg 里再补一次 }
    FAddressBar.Edit.SetFocus;
  end
  else
    NewBrowserTab(Settings.EffectiveNewTabUrl);
end;

{ == 标签右键菜单三项 ===================================================== }

{ 从 TabIndex 起右移跳过固定标签, 算出非固定新标签的安全插入位置 }
function TBrowserForm.NextInsertIndex(TabIndex: Integer): Integer;
begin
  Result := TabIndex + 1;
  { 固定标签始终排在左端（SetPinned 会把它挪进固定区末尾）, 所以从目标位置往右
    跳过连续的固定标签, 免得新开的非固定页落在固定区里 }
  while (Result < FTabs.Tabs.Count) and FTabs.Tabs[Result].Pinned do
    Inc(Result);
end;

{ 标签右键"向右新建标签页": 在当前标签右侧（避开固定区）开新页 }
procedure TBrowserForm.DoTabNewToRight(Sender: TObject; TabIndex: Integer);
begin
  NewBrowserTabAt(NextInsertIndex(TabIndex), DEFAULT_URL);
end;

{ 标签右键"重新加载": 重载指定标签的页面 }
procedure TBrowserForm.DoTabReload(Sender: TObject; TabIndex: Integer);
begin
  ReloadPageAt(TabIndex);
end;

{ 标签右键"复制": 取当前页 URL 在右侧开同址新标签（无 URL 退回首页） }
procedure TBrowserForm.DoTabDuplicate(Sender: TObject; TabIndex: Integer);
var
  C: TChromium;
  URL: string;
begin
  C := ChromiumOfPage(FHost.PageAtTabIndex(TabIndex));
  if (C = nil) or not FURLs.TryGetValue(C, URL) or (URL = '') then
    URL := DEFAULT_URL;
  NewBrowserTabAt(NextInsertIndex(TabIndex), URL);
end;

{ 重载指定标签的页面; 是激活标签时同步把刷新按钮切成加载中 }
procedure TBrowserForm.ReloadPageAt(TabIndex: Integer);
var
  C: TChromium;
begin
  C := ChromiumOfPage(FHost.PageAtTabIndex(TabIndex));
  if C <> nil then
  begin
    C.Reload;
    if (TabIndex = FTabs.ActiveTabIndex) and C.Initialized then
      SetReloadButtonLoading(True);
  end;
end;

{ 标签关闭前: 已初始化的浏览器走 CEF 两段式关闭（先关 DevTools,
  拒绝立即删标签 —— 真正删除在 OnBeforeClose 之后的消息里做） }
procedure TBrowserForm.DoTabClosing(Sender: TObject; TabIndex: Integer;
  var AllowClose: Boolean);
var
  Chromium: TChromium;
begin
  Chromium := ChromiumOfPage(FHost.PageAtTabIndex(TabIndex));
  if (Chromium <> nil) and Chromium.Initialized then
  begin
    AllowClose := False;
    CloseDevTools(Chromium);          // 先关这个标签挂着 DevTools 窗口
    Chromium.CloseBrowser(True);
  end;
end;

{ 激活标签切换: 收查找条 + 同步地址栏/导航按钮/书签栏 }
procedure TBrowserForm.DoPageChanged(Sender: TObject; OldIndex, NewIndex: Integer);
begin
  HideFindBar;
  UpdateAddressBar;
  { DevTools 不需要在这里处理: 每个标签的 DevTools 容器挂在各自 Page 上,
    切标签时 Page 的 Visible 翻转自然带动 DevTools 面板显隐 —— 开着 DevTools
    的标签切回去时面板还在, 网络记录保留（DevTools 实例没关） }
end;

{ ---- CEF 事件 ------------------------------------------------------------- }

{ CEF 浏览器创建完成: 转投 CEF_AFTERCREATED 消息处理（不在回调栈内动 VCL） }
procedure TBrowserForm.ChromiumAfterCreated(Sender: TObject;
  const browser: ICefBrowser);
begin
  PostMessage(Handle, CEF_AFTERCREATED, NativeUInt(Sender), 0);
end;

{ CEF_AFTERCREATED 落点: 同步渲染窗口尺寸 + 空白新标签页补焦点地址栏 }
procedure TBrowserForm.BrowserCreatedMsg(var Message: TMessage);
var
  Chromium: TChromium;
  WinParent: TCEFWindowParent;
begin
  Chromium := TChromium(Message.WParam);
  if Chromium = nil then Exit;

  WinParent := TCEFWindowParent(Chromium.Tag);
  if WinParent <> nil then
    WinParent.UpdateSize;

  { 空白新标签页: CEF 渲染窗口创建时会把焦点抢到网页, 补回地址栏。
    用异步消息 —— 此时正处于 CreateBrowser 调用栈内, 同步 SetFocus 会被
    CEF 随后的内部 SetFocus 覆盖（实测焦点到不了地址栏的根因） }
  if (Chromium = CurrentChromium) and
    SameText(string(Chromium.DefaultUrl), 'about:blank') then
    PostMessage(Handle, CEF_FOCUSADDR, 0, 0);

  { 首航不在这里做: URL 已经通过 Chromium.DefaultUrl 交给 CreateBrowser,
    CEF 创建浏览器时直接导航（见 NewBrowserTabAt 注释）。这里只负责把 CEF
    渲染窗口尺寸对齐到 WinParent。
    （历史: 曾在这里 LoadURL, 但那与 CEF 的 about:blank 初始加载有竞态,
      时好时坏被静默丢弃 —— "双击程序有时打不开首页"/新标签停在空白页） }
end;

{ CEF 渲染窗口获得焦点（浏览器内部 SetFocus / 用户点击页面）。
  空白新标签页把焦点还给地址栏: 判断"当前 URL 仍是 about:blank"而非
  DefaultUrl —— 用户从地址栏导航到真实网页后 URL 已变, 不再抢焦点 }
procedure TBrowserForm.ChromiumGotFocus(Sender: TObject;
  const browser: ICefBrowser);
var
  C: TChromium;
  URL: string;
begin
  C := Sender as TChromium;
  if C <> CurrentChromium then Exit;
  if not (FURLs.TryGetValue(C, URL) and SameText(URL, 'about:blank')) then
    Exit;
  { 异步: 不在 CEF 回调栈内直接 SetFocus（会被 CEF 后续逻辑覆盖） }
  PostMessage(Handle, CEF_FOCUSADDR, 0, 0);
end;

{ CEF 渲染窗口"即将"获得焦点（导航完成/系统激活触发, source 区分来源）。
  空白新标签页返回 True **取消**该请求（CEF 语义: 非 0 = 拒绝浏览器拿焦点）,
  并异步把焦点交地址栏 —— 这是焦点转移发生前的拦截点; 此前
  AfterCreated/GotFocus/加载完成后"夺回"方案均被 CEF 随后的焦点动作覆盖。
  真实网页的焦点请求照常放行（导航后 FURLs 已更新为真实 URL） }
procedure TBrowserForm.ChromiumSetFocus(Sender: TObject;
  const browser: ICefBrowser; source: TCefFocusSource; out Result: Boolean);
var
  C: TChromium;
  URL: string;
begin
  Result := False;
  C := Sender as TChromium;
  if C <> CurrentChromium then Exit;
  if not (FURLs.TryGetValue(C, URL) and SameText(URL, 'about:blank')) then
    Exit;
  Result := True;                        // 取消 CEF 渲染窗口获取焦点
  PostMessage(Handle, CEF_FOCUSADDR, 0, 0);
end;

{ 聚焦地址栏。实测: 焦点在 CEF 渲染窗口上时 VCL 的 SetFocus 完全无效
  （调用后 GetFocus 不变）, 必须走 Win32: 顶层窗口置前 + 直接
  SetFocus(Edit.Handle)。返回 True = GetFocus 已等于 Edit 句柄;
  失败时记录当前焦点窗口类名便于排查 }
function TBrowserForm.TryFocusAddressBar: Boolean;
var
  Prev: THandle;
  FocusH: THandle;
  Cls: array [0..255] of Char;
begin
  if FAddressBar.Edit.CanFocus then
    FAddressBar.Edit.SetFocus;
  if GetFocus <> FAddressBar.Edit.Handle then
  begin
    { VCL 焦点链失效: 顶层窗口置前 + 直接 Win32 SetFocus }
    Winapi.Windows.SetForegroundWindow(Handle);
    Prev := Winapi.Windows.SetFocus(FAddressBar.Edit.Handle);
    if Prev = 0 then
      Logger.Error('地址栏 Win32 SetFocus 失败 (Edit=$%x)',
        [FAddressBar.Edit.Handle]);
  end;

  Result := GetFocus = FAddressBar.Edit.Handle;
  if not Result then
  begin
    FocusH := GetFocus;
    FillChar(Cls, SizeOf(Cls), 0);
    if FocusH <> 0 then
      Winapi.Windows.GetClassName(FocusH, Cls, Length(Cls));
    Logger.Info('聚焦地址栏未生效: 焦点仍在 $%x(%s), CanFocus=%s',
      [FocusH, string(Cls), BoolToStr(FAddressBar.Edit.CanFocus, True)]);
  end;
end;

{ CEF_FOCUSADDR: 空白新标签页焦点回地址栏（异步执行, 见发送处注释）。
  立即聚焦一次, 再启动 150ms 重试定时器兜底 —— CEF 渲染窗口创建/显示
  期间可能多次抢焦点（含 TCEFWindowParent 的 WM_SETFOCUS 转发），
  单次聚焦追不上, 轮询夺回直到稳定或用户导航离开 }
procedure TBrowserForm.FocusAddrMsg(var Message: TMessage);
var
  C: TChromium;
  URL: string;
begin
  { 执行时再校验一次: 消息排队期间用户可能已切标签或已导航 }
  C := CurrentChromium;
  if C = nil then Exit;
  if not (FURLs.TryGetValue(C, URL) and SameText(URL, 'about:blank')) then
    Exit;
  TryFocusAddressBar;
  FFocusAddrRetries := 0;
  FFocusAddrTimer.Enabled := True;
end;

{ 焦点兜底轮询: 当前标签仍是 about:blank 且 Win32 焦点不在地址栏 Edit 上
  （被 CEF 渲染窗口/TCEFWindowParent 的 WM_SETFOCUS 转发抢走）→ 再聚焦。
  8 轮 × 150ms 覆盖渲染窗口创建窗口期; 用户导航或切标签会自然停止 }
procedure TBrowserForm.FocusAddrRetryTick(Sender: TObject);
var
  C: TChromium;
  URL: string;
begin
  Inc(FFocusAddrRetries);
  C := CurrentChromium;
  if (C = nil) or
    not (FURLs.TryGetValue(C, URL) and SameText(URL, 'about:blank')) or
    (FFocusAddrRetries > 8) then
  begin
    FFocusAddrTimer.Enabled := False;
    Exit;
  end;
  if GetFocus = FAddressBar.Edit.Handle then
  begin
    FFocusAddrTimer.Enabled := False;   // 已稳定在地址栏
    Exit;
  end;
  TryFocusAddressBar;

end;

{ CEF 请求关闭浏览器: 投 CEF_DESTROY 释放宿主, 关闭动作延迟给 CEF 收尾 }
procedure TBrowserForm.ChromiumClose(Sender: TObject;
  const browser: ICefBrowser; var aAction: TCefCloseBrowserAction);
begin
  Logger.Info('ChromiumClose: 浏览器请求关闭');
  if (browser <> nil) and (TCEFWindowParent(TChromium(Sender).Tag) <> nil) then
  begin
    PostMessage(Handle, CEF_DESTROY, NativeUInt(Sender), 0);
    aAction := cbaDelay;
  end;
end;

{ 释放某个标签的 CEF 宿主控件并清理字典（浏览器销毁后的统一清理）。
  alloy 运行时由 OnClose → CEF_DESTROY → BrowserDestroyMsg 调;
  chrome runtime 不触发 OnClose, 由 ChromiumBeforeClose 补投 CEF_DESTROY 调.
  注意: 本函数只释放 WinParent + DevTools + 字典, 不释放 Tab/Page ——
  Tab/Page 的释放由调用方在 CEF 渲染窗口确认销毁后另行 ForceCloseTab,
  否则 Page 窗口销毁时 CEF 渲染窗口仍作为跨线程子窗口存在, DestroyWindow
  返回 ERROR_ACCESS_DENIED(5), VCL 抛 EOSError 中断后续激活切换 → 页面空白 }
procedure TBrowserForm.DestroyBrowserForChromium(Chromium: TChromium);
var
  WinParent: TCEFWindowParent;
  CachedIcon: TIcon;
begin
  WinParent := TCEFWindowParent(Chromium.Tag);
  FreeAndNil(WinParent);
  Chromium.Tag := 0;
  { 这个标签若开着 DevTools, 一并关掉（否则 DevTools 实例悬垂） }
  CloseDevTools(Chromium);
  { 字典清理: 之前只增不减, 长时间开关标签会一直涨 }
  FURLs.Remove(Chromium);
  FIconURLs.Remove(Chromium);
  FLoadingTabs.Remove(Chromium);
  if FFindChromium = Chromium then
  begin
    if FFindBar <> nil then
      FFindBar.Visible := False;
    FFindChromium := nil;
  end;
  if FLoadingTabs.Count = 0 then
    FLoadingTimer.Enabled := False;
  if FFavIconCache.TryGetValue(Chromium, CachedIcon) then
  begin
    CachedIcon.Free;
    FFavIconCache.Remove(Chromium);
  end;
end;

{ CEF_DESTROY 落点: 释放宿主与字典; LParam=1 时删标签并延迟释放 Page;
  最后一个标签关掉后收窗 }
procedure TBrowserForm.BrowserDestroyMsg(var Message: TMessage);
var
  Chromium: TChromium;
  TabIdx: Integer;
  Page: TFHChromePage;
begin
  Chromium := TChromium(Message.WParam);
  if Chromium = nil then Exit;

  Logger.Info('BrowserDestroyMsg: 释放 CEF 宿主');
  DestroyBrowserForChromium(Chromium);
  { LParam=1: OnBeforeClose 转投（alloy/chrome 两种 runtime 统一收口）;
    LParam=0: OnClose 投递, 只释放 WinParent 让 CEF 继续关闭, Tab 留给
    随后的 OnBeforeClose → LParam=1 处理 }
  if Message.LParam = 1 then
  begin
    TabIdx := TabIndexOfChromium(Chromium);
    if TabIdx >= 0 then
    begin
      Logger.Info('BrowserDestroyMsg: 关闭标签 %d', [TabIdx]);
      Page := FHost.PageAtTabIndex(TabIdx);
      FTabs.ForceCloseTab(TabIdx);
      { KeepPagesOnClose: ForceCloseTab 链路里 Page 只进隐藏池不销毁,
        激活切换/地址栏刷新完整走完 —— 否则 Page.Free 抛异常会跳过
        DoActiveTabChange, 表现为激活标签空白、地址栏残留被关页 URL。
        Page 的真正销毁延迟一轮消息（CEF_FREEPAGE）, 错开 CEF UI 线程
        对渲染窗口的收尾 }
      PostMessage(Handle, CEF_FREEPAGE, NativeUInt(Page), 0);
    end;
  end;
  { 最后一个标签关掉 → 可以收窗了 }
  if FTabs.Tabs.Count = 0 then
  begin
    FCanClose := True;
    PostMessage(Handle, WM_CLOSE, 0, 0);
  end;
end;

{ Page 的延迟销毁（CEF_FREEPAGE）: KeepPagesOnClose 把关闭页藏进隐藏池,
  这里补上真正的 Free。若 DestroyWindow 仍失败（CEF UI 线程收尾竞态）,
  记录 OS 错误码后放弃 —— 页留在隐藏池里不可见、无人引用, 程序继续正常运行;
  错误码是定位 DestroyWindow 失败根因的关键线索 }
procedure TBrowserForm.FreePageMsg(var Message: TMessage);
var
  Page: TFHChromePage;
  Retry: Integer;
begin
  Page := TFHChromePage(Message.WParam);
  if Page = nil then Exit;
  Retry := Message.LParam;
  { FStatusPanel 已固定挂 FHost（不再动态挂 Page, 见创建处注释）——
    Page 释放时它不在被释放页上, 无跨树悬垂问题。
    此前的"Page.Free 前 Parent:=nil 断开"方案实测不可行: SetParent(nil)
    触发 RemoveControl→DestroyHandle, CEF 收尾时间窗内 DestroyWindow
    连 FStatusPanel 的句柄都销毁失败(5), 异常穿出消息处理器直接爆 }
  try
    Page.Free;
    FHost.DropHiddenPage(Page);   // 从隐藏池摘引用, 防池留悬垂指针
  except
    on E: EOSError do
    begin
      { OS error 5: CEF UI 线程对渲染窗口的收尾未完成, DestroyWindow(Page) 撞车。
        半析构对象重跑 Destroy 是幂等的（已完成部分由字段状态短路）, 重试安全;
        CEF 收尾完成后通常下一轮消息就能成功 }
      if Retry < 2 then
        PostMessage(Handle, CEF_FREEPAGE, NativeUInt(Page), Retry + 1)
      else
      begin
        { 三次仍失败: 放弃销毁 —— 同时从隐藏池与 Owner 组件树摘除半析构页,
          防退出时 DestroyComponents 二次销毁（FreeInstance 二次释放内存
          触发 EInvalidPointer）; 半析构页的内存随进程退出统一回收 }
        Logger.Error('延迟释放 Page 三次失败: OS error %d (放弃销毁, 内存随进程回收)',
          [E.ErrorCode]);
        FHost.AbandonHiddenPage(Page);
      end;
    end;
    on E: Exception do
    begin
      Logger.Error('延迟释放 Page 失败: %s - %s', [E.ClassName, E.Message]);
      FHost.AbandonHiddenPage(Page);   // 非跨线程类异常: 同样防二次销毁
    end;
  end;
end;

{ CEF_INITIALIZED 落点: 上下文就绪消息到达时若还没有标签则补建首页 }
procedure TBrowserForm.CEFInitializedMsg(var Message: TMessage);
begin
  // CEF 全局上下文就绪（OnContextInitialized 回调发来的消息）
  // 创建首页（如果还没创建）——TabbedBrowser2 同模式
  if FTabs.Tabs.Count = 0 then
    NewBrowserTab(DEFAULT_URL);
end;

{ 浏览器销毁完成: 转投 CEF_DESTROY(LParam=1) 在消息上下文里删标签
  （禁止在 CEF 回调栈内动 VCL/CEF, 否则进程被静默终止, 见体内注释） }
procedure TBrowserForm.ChromiumBeforeClose(Sender: TObject;
  const browser: ICefBrowser);
var
  C: TChromium;
begin
  Logger.Info('ChromiumBeforeClose: 剩余标签 %d', [FTabs.Tabs.Count]);
  C := TChromium(Sender);
  FPopupTabs.Remove(C);                 // 浏览器销毁, 别再留着它的引用
  { 主浏览器销毁完成 → 统一转投 CEF_DESTROY(LParam=1), 在消息上下文里释放
    WinParent + ForceCloseTab（alloy 路径 WinParent 已被 OnClose 投的 LParam=0
    释放, 此处幂等; chrome runtime 路径 Tag<>0 也从这进）。
    ⚠ 绝不能在 CEF 回调栈里直接 ForceCloseTab —— 回调运行在 CEF 的 C++ 帧
    深处, 其中 Page.Free → DestroyWindow 会同步泵消息、从 C++ 帧内重入
    VCL/CEF, 进程随即被静默终止（无异常弹窗、无日志、无 CEF FATAL, 实测
    关一个标签整个程序消失）。Tab/Page 释放必须回到 VCL 消息循环顶层执行,
    与 TabbedBrowser2 demo 的 CEF_DESTROYTAB 模式一致 }
  PostMessage(Handle, CEF_DESTROY, NativeUInt(C), 1);
end;

{ ---- favicon 桥接 ----------------------------------------------------------- }

{ 页面 favicon 地址变化: 记录最高分辨率 URL 并触发下载图标（同 URL 不重复下载） }
procedure TBrowserForm.ChromiumFavIconURLChange(Sender: TObject;
  const browser: ICefBrowser; const iconUrls: TStrings);
var
  C: TChromium;
  URL, Prev: string;
  Idx: Integer;
  CachedIcon: TIcon;
begin
  C := Sender as TChromium;
  Idx := TabIndexOfChromium(C);
  if Idx < 0 then Exit;
  if (iconUrls = nil) or (iconUrls.Count = 0) then
  begin
    { 页面没有 favicon（如 about:blank / 新标签页）: 清掉旧图标和缓存,
      退回组件默认的无图标画法（loading 期间由 spinner 占用, 不在此清） }
    FIconURLs.AddOrSetValue(C, '');
    if FFavIconCache.TryGetValue(C, CachedIcon) then
    begin
      CachedIcon.Free;
      FFavIconCache.Remove(C);
    end;
    if not FLoadingTabs.Contains(C) then
      FTabs.Tabs[Idx].Icon := nil;
    Exit;
  end;
  { CEF 的列表按质量升序排, 最后一个是分辨率最高的 }
  URL := iconUrls[iconUrls.Count - 1];
  if FIconURLs.TryGetValue(C, Prev) and (Prev = URL) then
    Exit;   // 同一 URL（重载/切页触发）不重复下载
  FIconURLs.AddOrSetValue(C, URL);
  C.DownloadImage(URL, True, 32, False);   // 结果走 OnDownloadImageFinished
end;

{ favicon 下载完成: 按 URL 反查所有记录了该 URL 的标签并赋图标
  （多个标签开同一网址很常见, 必须全部赋值） }
procedure TBrowserForm.ChromiumDownloadImageFinished(Sender: TObject;
  const imageUrl: ustring; httpStatusCode: Integer; const image: ICefImage);
var
  Pair: TPair<TChromium, string>;
  Icon: TIcon;
  Idx: Integer;
begin
  try
  { 回调里没有 browser, 按 URL 反查。注意多个标签可能记录了**同一个** URL
    （两个标签都开百度很常见）—— 必须全部赋值, 只取第一个会把图标写到
    别的标签上, 新标签就永远没图标（实测踩到） }
  if (image = nil) or (httpStatusCode <> 200) then Exit;
  Icon := CefImageToIcon(image, FTabs.ScalePx(C_FH_IconSize));
  if Icon = nil then Exit;
  try
    for Pair in FIconURLs do
      if (Pair.Value <> '') and SameText(Pair.Value, string(imageUrl)) then
      begin
        Idx := TabIndexOfChromium(Pair.Key);
        if Idx < 0 then Continue;
        ApplyFavIcon(Pair.Key, Icon);   // 写缓存 + 非 loading 时落到 Tab.Icon
      end;
  finally
    Icon.Free;
  end;
  except
    on E: Exception do
    begin
      { 单个图标失败不影响页面, 但要留痕 —— favicon 全链路出问题时日志是唯一线索 }
      Logger.Error('favicon 图标转换失败 (%s): %s - %s',
        [string(imageUrl), E.ClassName, E.Message]);
    end;
  end;
end;

{ ICefImage（BGRA 预乘位图）→ TIcon: 反预乘 + 行序翻转 + 缩放到目标像素 + 转 HICON }
function TBrowserForm.CefImageToIcon(const AImage: ICefImage; ATargetPx: Integer): TIcon;

  function UnPreMultiply(C, A: Byte): Byte; inline;
  begin
    if A = 0 then            // 全透明像素: 分母为 0, 直接黑
      Result := 0
    else if A = 255 then
      Result := C
    else
      Result := (C * 255 + A div 2) div A;
  end;

var
  W, H, x, y: Integer;
  Bits: ICefBinaryValue;
  Src, All: PByteArray;
  Row: PByteArray;
  SrcBmp, DstBmp, Mask: TBitmap;
  Info: TIconInfo;
  Size: NativeUInt;
begin
  Result := nil;
  if AImage = nil then Exit;
  W := 0; H := 0;
  { CEF 位图 = 32bpp premultiplied BGRA, 行序 top-down }
  Bits := AImage.GetAsBitmap(1.0, CEF_COLOR_TYPE_BGRA_8888,
    CEF_ALPHA_TYPE_PREMULTIPLIED, W, H);
  if (Bits = nil) or (W <= 0) or (H <= 0) then Exit;
  Size := NativeUInt(W) * NativeUInt(H) * 4;
  if Bits.Size < Size then Exit;
  All := nil;
  try
    GetMem(All, Size);
    if Bits.GetData(All, Size, 0) <> Size then Exit;

    SrcBmp := TBitmap.Create;
    try
      SrcBmp.PixelFormat := pf32bit;
      SrcBmp.SetSize(W, H);
      for y := 0 to H - 1 do
      begin
        Src := PByteArray(NativeUInt(All) + NativeUInt(y * W * 4));
        Row := SrcBmp.ScanLine[H - 1 - y];  // CEF top-down → VCL bottom-up
        for x := 0 to W - 1 do
        begin
          Row[x * 4 + 3] := Src[x * 4 + 3]; // alpha
          Row[x * 4 + 0] := UnPreMultiply(Src[x * 4 + 0], Src[x * 4 + 3]); // B
          Row[x * 4 + 1] := UnPreMultiply(Src[x * 4 + 1], Src[x * 4 + 3]); // G
          Row[x * 4 + 2] := UnPreMultiply(Src[x * 4 + 2], Src[x * 4 + 3]); // R
        end;
      end;

      { 缩到目标像素再转 HICON: CEF 给的图常是 64x64, 而 TIcon 在 VCL 的
        StretchDraw 下不保证按目标矩形缩放（实测按原尺寸画出 → 盖住标题）,
        所以这里自己缩好, 组件端 1:1 画 }
      if ATargetPx <= 0 then
        ATargetPx := W;
      DstBmp := TBitmap.Create;
      Mask := TBitmap.Create;
      try
        DstBmp.PixelFormat := pf32bit;
        DstBmp.SetSize(ATargetPx, ATargetPx);
        DstBmp.Canvas.StretchDraw(Rect(0, 0, ATargetPx, ATargetPx), SrcBmp);
        Mask.Monochrome := True;
        Mask.SetSize(ATargetPx, ATargetPx);
        Mask.Canvas.Brush.Color := clBlack;   // mask 全 0: 完全交给 alpha 通道
        Mask.Canvas.FillRect(Rect(0, 0, ATargetPx, ATargetPx));

        Info.fIcon := True;
        Info.xHotspot := 0;
        Info.yHotspot := 0;
        Info.hbmMask := Mask.Handle;
        Info.hbmColor := DstBmp.Handle;
        Result := TIcon.Create;
        Result.Handle := CreateIconIndirect(Info);
      finally
        DstBmp.Free;
        Mask.Free;
      end;
    finally
      SrcBmp.Free;
    end;
  finally
    if All <> nil then
      FreeMem(All);
  end;
end;

{ ---- loading spinner -------------------------------------------------------- }

{ 生成 Chrome 风格加载 spinner 的指定帧图标（GDI+ 抗锯齿弧 → HICON, 12 帧一圈） }
function TBrowserForm.MakeLoadingIcon(ASize, AFrame: Integer): TIcon;
const
  ARC_SWEEP  = 270;       // 弧扫过 270°（Chrome spinner 留 90° 缺口）
  FRAME_STEP = 30;        // 每帧起笔角 +30°, 12 帧一圈
var
  GPBmp: TGPBitmap;
  GPGfx: TGPGraphics;
  GPPen: TGPPen;
  Path: TGPGraphicsPath;
  DstBmp, MaskBmp: TBitmap;
  Info: TIconInfo;
  cx, cy, r, PenW, y: Integer;
  StartAng: Single;
  bd: TBitmapData;
  rc: TGPRect;
  Q: PByteArray;
begin
  Result := nil;
  if ASize <= 0 then ASize := 16;
  if not EnsureGdiPlus then Exit;

  cx := ASize div 2;
  cy := ASize div 2;
  r := ASize div 2 - 1;
  if r < 2 then r := 2;
  PenW := Max(2, ASize div 6);

  { GDI+ 画到 32bpp ARGB 位图: 抗锯齿弧 + 真半透明边缘 alpha。
    PixelFormat32bppARGB 内存字节序 = BGRA(little-endian), 与 VCL pf32bit 同,
    可直接 Move 到 DstBmp。背景初始全 0(透明黑), 弧 alpha=255, 边缘渐变 }
  GPBmp := TGPBitmap.Create(ASize, ASize, PixelFormat32bppARGB);
  try
    GPGfx := TGPGraphics.Create(GPBmp);
    try
      GPGfx.SetSmoothingMode(SmoothingModeAntiAlias);
      { GDI+ 0°=右, 正角顺时针(Y 向下)。起点 270°(=顶部), 每帧 +30° 顺时针转,
        扫 270° → 顶→右→底→左, 缺口左上 }
      StartAng := 270 + FRAME_STEP * AFrame;
      GPPen := TGPPen.Create(MakeColor(255, 66, 133, 244), Single(PenW));
      try
        GPPen.SetStartCap(LineCapRound);
        GPPen.SetEndCap(LineCapRound);
        Path := TGPGraphicsPath.Create;
        try
          Path.AddArc(cx - r, cy - r, 2 * r, 2 * r, StartAng, ARC_SWEEP);
          GPGfx.DrawPath(GPPen, Path);
        finally
          Path.Free;
        end;
      finally
        GPPen.Free;
      end;
    finally
      GPGfx.Free;
    end;

    { LockBits 取像素 → DstBmp pf32bit(BGRA 同序直接 Move) }
    DstBmp := TBitmap.Create;
    try
      DstBmp.PixelFormat := pf32bit;
      DstBmp.SetSize(ASize, ASize);
      rc.X := 0; rc.Y := 0; rc.Width := ASize; rc.Height := ASize;
      if GPBmp.LockBits(rc, ImageLockModeRead, PixelFormat32bppARGB, bd) = Ok then
      try
        for y := 0 to ASize - 1 do
        begin
          Q := DstBmp.ScanLine[y];
          Move(Pointer(NativeUInt(bd.Scan0) + NativeUInt(y * bd.Stride))^, Q[0], ASize * 4);
        end;
      finally
        GPBmp.UnlockBits(bd);
      end;

      MaskBmp := TBitmap.Create;
      try
        MaskBmp.Monochrome := True;
        MaskBmp.SetSize(ASize, ASize);
        MaskBmp.Canvas.Brush.Color := clBlack;   // 全黑 = 不透明, 交给 alpha 通道
        MaskBmp.Canvas.FillRect(Rect(0, 0, ASize, ASize));

        Info.fIcon := True;
        Info.xHotspot := 0;
        Info.yHotspot := 0;
        Info.hbmMask := MaskBmp.Handle;
        Info.hbmColor := DstBmp.Handle;
        Result := TIcon.Create;
        Result.Handle := CreateIconIndirect(Info);
      finally
        MaskBmp.Free;
      end;
    finally
      DstBmp.Free;
    end;
  finally
    GPBmp.Free;
  end;
end;

{ spinner 动画定时器: 帧序号推进, 给所有加载中的标签换下一帧图标 }
procedure TBrowserForm.LoadingTimerTick(Sender: TObject);
var
  I, TabIdx: Integer;
  C: TChromium;
  Spinner: TIcon;
begin
  if FLoadingTabs.Count = 0 then
  begin
    FLoadingTimer.Enabled := False;
    Exit;
  end;
  FLoadingFrame := (FLoadingFrame + 1) mod 12;
  Spinner := MakeLoadingIcon(FTabs.ScalePx(C_FH_IconSize), FLoadingFrame);
  try
    for I := 0 to FLoadingTabs.Count - 1 do
    begin
      C := FLoadingTabs[I];
      TabIdx := TabIndexOfChromium(C);
      if TabIdx >= 0 then
        FTabs.Tabs[TabIdx].Icon := Spinner;
    end;
  finally
    Spinner.Free;
  end;
end;

{ 写入 favicon 缓存并落到标签图标（loading 期间只进缓存, 图标位让给 spinner） }
procedure TBrowserForm.ApplyFavIcon(C: TChromium; AIcon: TIcon);
var
  Cached: TIcon;
  TabIdx: Integer;
  NewIcon: TIcon;
begin
  { 缓存更新: 复制一份独立 TIcon, 所有权归 FFavIconCache }
  if FFavIconCache.TryGetValue(C, Cached) then
    Cached.Free;
  NewIcon := TIcon.Create;
  NewIcon.Assign(AIcon);
  FFavIconCache.AddOrSetValue(C, NewIcon);
  { loading 期间 Tab.Icon 由 spinner 占用, favicon 只更新缓存, 等 loading 结束再恢复 }
  if not FLoadingTabs.Contains(C) then
  begin
    TabIdx := TabIndexOfChromium(C);
    if TabIdx >= 0 then
      FTabs.Tabs[TabIdx].Icon := AIcon;
  end;
end;

{ 加载完成后从缓存恢复标签 favicon（无缓存则清空图标） }
procedure TBrowserForm.RestoreFavIcon(C: TChromium);
var
  Cached: TIcon;
  TabIdx: Integer;
begin
  TabIdx := TabIndexOfChromium(C);
  if TabIdx < 0 then Exit;
  if FFavIconCache.TryGetValue(C, Cached) and (not Cached.Empty) then
    FTabs.Tabs[TabIdx].Icon := Cached
  else
    FTabs.Tabs[TabIdx].Icon := nil;
end;

{ 页面标题变化 → 写入标签 Caption（空白页统一显示"新标签页"） }
procedure TBrowserForm.ChromiumTitleChange(Sender: TObject;
  const browser: ICefBrowser; const title: ustring);
var
  I: Integer;
begin
  I := TabIndexOfChromium(Sender as TChromium);
  if I >= 0 then
  begin
    { 空白页的 title 事件是空串或 "about:blank": 统一显示"新标签页"（Chrome 同款） }
    if (title = '') or SameText(string(title), 'about:blank') then
      FTabs.Tabs[I].Caption := '新标签页'
    else
      FTabs.Tabs[I].Caption := title;
  end;
end;

{ 页面地址变化: 更新 FURLs 映射; 激活标签同步地址栏文本/星标/书签栏 }
procedure TBrowserForm.ChromiumAddressChange(Sender: TObject;
  const browser: ICefBrowser; const frame: ICefFrame; const url: ustring);
var
  C: TChromium;
begin
  C := Sender as TChromium;
  FURLs[C] := url;
  if C = CurrentChromium then
  begin
    { 空白页(about:blank)地址栏显示为空, 与 Chrome 一致 }
    if SameText(string(url), 'about:blank') then
      FAddressBar.Text := ''
    else
      FAddressBar.Text := url;
    { 星标随导航地址同步（Chrome: 导航完成地址栏更新时星标立即反映收藏态;
      BookmarkExists 是本地 SQLite 点查, 与 AddHistory 同在回调路径, 开销可忽略） }
    UpdateStarButton;
    { 网页打开后书签栏自动隐藏; 切回空白页标签再显示（导航入口） }
    SyncBookmarkBar;
  end;
end;

{ 加载状态变化: 刷导航按钮; 开始时标签上转 spinner 并收查找条,
  结束时停 spinner/恢复 favicon/记浏览历史/空白页聚焦地址栏 }
procedure TBrowserForm.ChromiumLoadingStateChange(Sender: TObject;
  const browser: ICefBrowser; isLoading, canGoBack, canGoForward: Boolean);
var
  C: TChromium;
  URL, Title: string;
  TabIdx: Integer;
  Spinner: TIcon;
begin
  C := Sender as TChromium;
  if C = CurrentChromium then
  begin
    FBtnBack.Enabled := canGoBack;
    FBtnForward.Enabled := canGoForward;
    SetReloadButtonLoading(isLoading);
  end;

  { 页面开始加载: 在标签上显示旋转 spinner, 加入动画驱动集合 }
  if isLoading then
  begin
    { 整页导航开始: 关闭查找栏（Chrome 同款）。此处位于 CEF 回调栈,
      不直接操作 VCL 控件, 转投消息 }
    if (C = FFindChromium) and (FFindBar <> nil) and FFindBar.Visible then
      PostMessage(Handle, CEF_FINDCLOSE, 0, 0);
    if not FLoadingTabs.Contains(C) then
    begin
      FLoadingTabs.Add(C);
      Spinner := MakeLoadingIcon(FTabs.ScalePx(C_FH_IconSize), FLoadingFrame);
      try
        TabIdx := TabIndexOfChromium(C);
        if TabIdx >= 0 then
          FTabs.Tabs[TabIdx].Icon := Spinner;
      finally
        Spinner.Free;
      end;
      if not FLoadingTimer.Enabled then
        FLoadingTimer.Enabled := True;
    end;
    Exit;
  end;

  { isLoading 从 True→False: 加载完成, 停 spinner, 恢复 favicon（从缓存） }
  if FLoadingTabs.Contains(C) then
  begin
    FLoadingTabs.Remove(C);
    if FLoadingTabs.Count = 0 then
      FLoadingTimer.Enabled := False;
    RestoreFavIcon(C);
  end;

  { 加载完成时记录浏览历史到 SQLite。title 从标签 Caption 取（OnTitleChange
    已写入），同 URL 在库里 UPSERT 累加 visit_count }
  URL := C.DocumentURL;
  if URL <> '' then
  begin
    Title := '';
    TabIdx := TabIndexOfChromium(C);
    if TabIdx >= 0 then
      Title := FTabs.Tabs[TabIdx].Caption;
    try
      HistoryDB.AddHistory(URL, Title);
    except
      on E: Exception do
        Logger.Error('记录浏览历史失败: %s - %s', [E.ClassName, E.Message]);
    end;
  end;

  { 空白新标签页加载完成: 焦点交地址栏（Chrome 同款, 可直接输入网址）。
    这是 CEF 对 about:blank 初始加载的最后一个事件, 之后不再有内部
    SetFocus 抢焦点 —— 之前在 AfterCreated/GotFocus 时机聚焦均被
    CEF 后续动作覆盖（实测）。仍走异步消息: 不在 CEF 回调栈内动 VCL 焦点 }
  if (C = CurrentChromium) and (URL <> '') and SameText(URL, 'about:blank') then
    PostMessage(Handle, CEF_FOCUSADDR, 0, 0);
end;

{ ---- 加载错误页 ------------------------------------------------------------- }

{ HTML 文本转义（& < > "）—— 错误页模板插值防注入用 }
function HtmlEscape(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;',  [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;',  [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

{ JsEscape: 把字符串转成 JS 字符串字面量内容(调用方负责加引号)。
  document.write 的参数经此转义后, HTML 里的 \ ' 换行不会破坏 JS 字面量 }
function JsEscape(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '\',   '\\',  [rfReplaceAll]);
  Result := StringReplace(Result, '''',  '\''', [rfReplaceAll]);
  Result := StringReplace(Result, #13#10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #10,   '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #13,   '\n', [rfReplaceAll]);
end;

{ 主框架加载失败: 用内置 HTML 模板渲染 Chrome 风格错误页
  （保留原失败 URL 供"重新加载"链接使用） }
procedure TBrowserForm.ChromiumLoadError(Sender: TObject;
  const browser: ICefBrowser; const frame: ICefFrame;
  errorCode: TCefErrorCode; const errorText, failedUrl: ustring);
const
  HTML_TPL =
    '<!DOCTYPE html><html><head><meta charset="utf-8"><style>' +
    'body{font-family:Segoe UI,Arial,sans-serif;background:#fff;color:#202124;' +
    'margin:0;height:100vh;display:flex;align-items:center;justify-content:center}' +
    '.box{max-width:560px;text-align:center;padding:32px}' +
    '.icon{font-size:64px;margin-bottom:12px;line-height:1}' +
    'h1{font-size:22px;font-weight:400;margin:0 0 6px}' +
    '.url{font-size:13px;color:#5f6368;word-break:break-all;margin:4px 0 18px}' +
    '.desc{font-size:14px;color:#5f6368;line-height:1.6;margin:0 0 8px}' +
    '.code{font-size:12px;color:#80868b;font-family:Consolas,monospace;margin:0 0 24px}' +
    '.btn{display:inline-block;padding:8px 24px;background:#1a73e8;color:#fff;' +
    'text-decoration:none;border-radius:4px;font-size:14px}' +
    '.btn:hover{background:#1765cc}' +
    '</style></head><body><div class="box">' +
    '<div class="icon">&#9888;&#65039;</div>' +
    '<h1>{TITLE}</h1>' +
    '<div class="url">{URL}</div>' +
    '<div class="desc">{DESC}</div>' +
    '<div class="code">错误码: {CODE}</div>' +
    '<a class="btn" href="{URL}">重新加载</a>' +
    '</div></body></html>';
var
  Title, Desc, Html, SafeUrl, Js, SymName: string;
begin
  { 只接管主框架的加载失败; 子框架(iframe/广告)失败不打扰用户 }
  if (frame = nil) or not frame.IsValid or not frame.IsMain then Exit;
  if failedUrl = '' then Exit;
  if errorCode = ERR_ABORTED then Exit;   // 用户主动取消导航(如点了别的链接), 不是错误

  case errorCode of
    ERR_CONNECTION_TIMED_OUT:      begin Title := '连接超时';       Desc := '网站响应时间过长，请检查网络连接或稍后重试。'; end;
    ERR_CONNECTION_REFUSED:        begin Title := '拒绝了连接请求'; Desc := '网站服务器拒绝了连接，可能未运行或端口被防火墙拦截。'; end;
    ERR_NAME_NOT_RESOLVED:         begin Title := '无法解析域名';   Desc := '找不到该网站的服务器 IP，请检查网址拼写或 DNS 设置。'; end;
    ERR_INTERNET_DISCONNECTED:     begin Title := '网络已断开';     Desc := '本机似乎已断开网络连接，请检查网线 / Wi-Fi。'; end;
    ERR_CONNECTION_RESET:          begin Title := '连接被重置';     Desc := '建立连接时被对方重置，服务器可能崩溃或中间链路异常。'; end;
    ERR_CONNECTION_CLOSED:         begin Title := '连接已关闭';     Desc := '连接在数据传输前被关闭。'; end;
    ERR_SSL_PROTOCOL_ERROR:        begin Title := 'SSL 协议错误';   Desc := '网站使用了不安全或不支持的 SSL/TLS 配置。'; end;
    ERR_ADDRESS_UNREACHABLE:       begin Title := '地址不可达';     Desc := '无法到达目标网络地址。'; end;
    ERR_NETWORK_CHANGED:           begin Title := '网络已变化';     Desc := '请求过程中网络连接发生切换，请重试。'; end;
    ERR_CERT_COMMON_NAME_INVALID:  begin Title := '证书域名不匹配'; Desc := '网站证书的域名与访问地址不一致，可能连接被劫持。'; end;
  else
    Title := '无法访问此网站';
    Desc := string(errorText);
    if Desc = '' then Desc := '发生未知网络错误。';
  end;

  SafeUrl := HtmlEscape(string(failedUrl));
  Html := HTML_TPL;
  Html := StringReplace(Html, '{TITLE}', HtmlEscape(Title), [rfReplaceAll]);
  Html := StringReplace(Html, '{DESC}',  HtmlEscape(Desc),  [rfReplaceAll]);
  Html := StringReplace(Html, '{URL}',   SafeUrl,           [rfReplaceAll]);
  { 错误符号名: CEF 的 errorText 就是 "ERR_NAME_NOT_RESOLVED" 这类符号(Chrome
    错误页底部显示的也是它)。空时回退到数字。DNS_PROBE_FINISHED_* 那层更细的
    DNS 探测结果 CEF 不暴露, 拿不到 }
  SymName := string(errorText);
  if SymName = '' then SymName := 'ERR_' + IntToStr(errorCode);
  Html := StringReplace(Html, '{CODE}',  HtmlEscape(SymName), [rfReplaceAll]);

  { 用 ExecuteJavaScript + document.open/write/close 重写当前文档内容,
    frame.URL 保持原失败地址不变(LoadString 会把 URL 改成 about:blank)。
    重试链接 href=原 URL, 点击即重新导航回原地址 }
  Js := 'document.open(); document.write(''' + JsEscape(Html) + '''); document.close();';
  frame.ExecuteJavaScript(Js, 'about:blank', 0);
end;

{ 页面状态文本（悬停链接 URL）→ 页面左下角浮层: 非空显示（宽度按文本自适应）,
  空文本隐藏 }
procedure TBrowserForm.ChromiumStatusMessage(Sender: TObject;
  const browser: ICefBrowser; const value: ustring);

  { 把 percent-encoded URL(%E4%B8%AD 等 UTF-8 字节序列)解码成可读中文。
    Chrome 状态条显示解码后形式; CEF 给的是原始 URL }
  function UrlDecodeToUtf8(const S: string): string;
  var
    Bytes: TBytes;
    I, J, B, Start, ChLen, Need: Integer;
    Chunk: string;
  begin
    SetLength(Bytes, Length(S) * 4);   // 解码后字节数上限
    J := 0;
    I := 1;
    while I <= Length(S) do
    begin
      if (S[I] = '%') and (I + 2 <= Length(S)) and
         CharInSet(S[I+1], ['0'..'9','A'..'F','a'..'f']) and
         CharInSet(S[I+2], ['0'..'9','A'..'F','a'..'f']) and
         TryStrToInt('$' + S[I+1] + S[I+2], B) then
      begin
        Bytes[J] := Byte(B); Inc(J); Inc(I, 3); Continue;
      end;
      if Ord(S[I]) < 128 then
      begin
        Bytes[J] := Byte(Ord(S[I])); Inc(J); Inc(I);
        Continue;
      end;
      { 非 ASCII 字符: 连同代理对一起转 UTF-8 字节。用 Win32 宽松转换,
        非法 UTF-16(孤立代理)也不会抛异常 }
      Start := I;
      Inc(I);
      if (Ord(S[Start]) >= $D800) and (Ord(S[Start]) <= $DBFF) and
         (I <= Length(S)) and (Ord(S[I]) >= $DC00) and (Ord(S[I]) <= $DFFF) then
        Inc(I);
      ChLen := I - Start;
      Chunk := Copy(S, Start, ChLen);
      Need := WideCharToMultiByte(CP_UTF8, 0, PWideChar(Chunk), ChLen, nil, 0, nil, nil);
      if Need > 0 then
      begin
        WideCharToMultiByte(CP_UTF8, 0, PWideChar(Chunk), ChLen,
          PAnsiChar(@Bytes[J]), Need, nil, nil);
        Inc(J, Need);
      end;
    end;
    SetLength(Bytes, J);
    { 必须用宽松解码: TEncoding.UTF8.GetString 走 MB_ERR_INVALID_CHARS 严格模式,
      遇到截断的 %E4%B8、GBK 编码的 %D6%D0 或 %FF 这类非法字节序列会抛
      EEncodingError("No mapping for the Unicode character exists in the target
      multi-byte code page")。MultiByteToWideChar(flags=0) 会把非法序列替换成
      U+FFFD, 状态栏显示不至于把浏览器带崩 }
    if J > 0 then
    begin
      Need := MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(@Bytes[0]), J, nil, 0);
      if Need > 0 then
      begin
        SetLength(Result, Need);
        MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(@Bytes[0]), J,
          PWideChar(Result), Need);
      end;
    end;
  end;

var
  C: TChromium;
  TabIdx: Integer;
  Page: TFHChromePage;
  TxtW, MaxW: Integer;
  DC: HDC;
  Size: TSize;
  S: string;
begin
  if FStatusPanel = nil then Exit;
  C := Sender as TChromium;
  TabIdx := TabIndexOfChromium(C);
  if TabIdx < 0 then Exit;
  Page := FHost.PageAtTabIndex(TabIdx);
  if Page = nil then Exit;

  S := UrlDecodeToUtf8(string(value));
  if S = '' then
  begin
    FStatusPanel.Visible := False;
    Exit;
  end;

  FStatusPanel.Caption := S;   // Parent 已固定 FHost, 不再动态切换
  { 宽度按文本自适应(用 GetTextExtentPoint32 度量, TPanel.Canvas 是 protected 不能直接用),
    上限页面宽 - 16(左右各 8 边距) }
  DC := GetDC(0);
  try
    SelectObject(DC, FStatusPanel.Font.Handle);
    GetTextExtentPoint32(DC, PChar(S), Length(S), Size);
  finally
    ReleaseDC(0, DC);
  end;
  TxtW := Size.cx + FTabs.ScalePx(18);   // 18 DIP = 左右 padding 8*2 + 2px 防字符裁剪余量
  MaxW := FHost.ClientWidth - FTabs.ScalePx(16);
  if TxtW > MaxW then TxtW := MaxW;
  if TxtW < FTabs.ScalePx(80) then TxtW := FTabs.ScalePx(80);
  FStatusPanel.Width := TxtW;
  FStatusPanel.Left := FTabs.ScalePx(8);
  FStatusPanel.Top := FHost.ClientHeight - FStatusPanel.Height - FTabs.ScalePx(8);
  FStatusPanel.Visible := True;
  FStatusPanel.BringToFront;
end;

{ 渲染进程终止: 记录终止原因（标签可能白屏, 可重新加载恢复） }
procedure TBrowserForm.ChromiumRenderProcessTerminated(Sender: TObject;
  const browser: ICefBrowser; status: TCefTerminationStatus);
var
  Stat: string;
begin
  case status of
    TS_ABNORMAL_TERMINATION:    Stat := '异常终止';
    TS_PROCESS_WAS_KILLED:      Stat := '被杀死';
    TS_PROCESS_CRASHED:         Stat := '崩溃';
    TS_PROCESS_OOM:             Stat := '内存不足';
  else
    Stat := '未知';
  end;
  Logger.Error('renderer 进程终止: %s (标签页可能白屏, 可重新加载恢复)', [Stat]);
end;


{ 焦点在页面内时的快捷键拦截（页面按键不经 VCL KeyPreview, 只能在此截）:
  F12 / Ctrl+F5 / Ctrl+Shift+Del / Ctrl+P / Ctrl+J / Ctrl+H / Ctrl+D /
  Ctrl+Shift+O / Ctrl+F / F3 / Esc, 各键细节见体内注释 }
procedure TBrowserForm.ChromiumPreKeyEvent(Sender: TObject;
  const browser: ICefBrowser; const event: PCefKeyEvent;
  osEvent: TCefEventHandle; out isKeyboardShortcut: Boolean; out Result: Boolean);
begin
  isKeyboardShortcut := False;
  Result := False;
  if event = nil then Exit;

  { 焦点在页面里时, 按键根本不会经过 VCL 窗体的 KeyPreview —— 只能在这里截。
    KEYEVENT_RAWKEYDOWN: 只处理"按下"那一次, 避免 keyup 时再开一次 }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = VK_F12) then
  begin
    isKeyboardShortcut := True;   // 告诉 CEF 这是宿主自己的快捷键
    Result := True;               // 吃掉: 不再传给页面
    PostMessage(Handle, CEF_OPENDEVTOOLS, 0, 0);
  end;

  { Ctrl+F5 硬刷新（绕过缓存）—— 焦点在页面里时也截 }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = VK_F5) and
     ((event^.modifiers and EVENTFLAG_CONTROL_DOWN) <> 0) then
  begin
    isKeyboardShortcut := True;
    Result := True;
    if Sender is TChromium then
      (Sender as TChromium).ReloadIgnoreCache;
  end;

  { Ctrl+Shift+Del 清除浏览数据 —— 焦点在页面里时也截（Chrome 同款快捷键） }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = VK_DELETE) and
     ((event^.modifiers and EVENTFLAG_CONTROL_DOWN) <> 0) and
     ((event^.modifiers and EVENTFLAG_SHIFT_DOWN) <> 0) then
  begin
    isKeyboardShortcut := True;
    Result := True;
    PostMessage(Handle, CEF_CLEARBROWSINGDATA, 0, 0);
  end;

  { Ctrl+P 打印 —— 焦点在页面里时也截（FormKeyDown 收不到） }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = Ord('P')) and
     ((event^.modifiers and EVENTFLAG_CONTROL_DOWN) <> 0) then
  begin
    isKeyboardShortcut := True;
    Result := True;
    PostMessage(Handle, CEF_PRINT, 0, 0);
  end;

  { Ctrl+J 打开下载窗口 —— 焦点在页面里时也截 }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = Ord('J')) and
     ((event^.modifiers and EVENTFLAG_CONTROL_DOWN) <> 0) then
  begin
    isKeyboardShortcut := True;
    Result := True;
    PostMessage(Handle, CEF_DOWNLOADS, 0, 0);
  end;

  { Ctrl+H 打开历史记录窗口 —— 焦点在页面里时也截 }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = Ord('H')) and
     ((event^.modifiers and EVENTFLAG_CONTROL_DOWN) <> 0) then
  begin
    isKeyboardShortcut := True;
    Result := True;
    PostMessage(Handle, CEF_HISTORY, 0, 0);
  end;

  { Ctrl+D 添加/修改书签 —— 焦点在页面里时也截（Chrome 同款;
    Ctrl+Shift+D 是"将所有标签页加入书签", 未实现, 不截） }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = Ord('D')) and
     ((event^.modifiers and EVENTFLAG_CONTROL_DOWN) <> 0) and
     ((event^.modifiers and EVENTFLAG_SHIFT_DOWN) = 0) then
  begin
    isKeyboardShortcut := True;
    Result := True;
    PostMessage(Handle, CEF_BOOKMARK, 0, 0);
  end;

  { Ctrl+Shift+O 书签管理器 —— 焦点在页面里时也截 }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = Ord('O')) and
     ((event^.modifiers and EVENTFLAG_CONTROL_DOWN) <> 0) and
     ((event^.modifiers and EVENTFLAG_SHIFT_DOWN) <> 0) then
  begin
    isKeyboardShortcut := True;
    Result := True;
    PostMessage(Handle, CEF_BOOKMARKSMGR, 0, 0);
  end;

  { Ctrl+F 打开页面内查找栏 }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = Ord('F')) and
     ((event^.modifiers and EVENTFLAG_CONTROL_DOWN) <> 0) then
  begin
    isKeyboardShortcut := True;
    Result := True;
    PostMessage(Handle, CEF_FIND, 0, 0);
  end;

  { F3 / Shift+F3: 查找上下一个（Chrome 打开查找栏后仍可用 F3） }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = VK_F3) then
  begin
    isKeyboardShortcut := True;
    Result := True;
    if (FFindBar <> nil) and FFindBar.Visible then
      FindStep((event^.modifiers and EVENTFLAG_SHIFT_DOWN) = 0)
    else
      PostMessage(Handle, CEF_FIND, 0, 0);
  end;

  { Esc 关闭查找栏 }
  if (event^.kind = KEYEVENT_RAWKEYDOWN) and
     (event^.windows_key_code = VK_ESCAPE) and
     (FFindBar <> nil) and FFindBar.Visible then
  begin
    isKeyboardShortcut := True;
    Result := True;
    PostMessage(Handle, CEF_FINDCLOSE, 0, 0);
  end;
end;

{ ---- 地址栏按钮 ----------------------------------------------------------- }

{ 后退按钮: 当前页可后退时执行 GoBack }
procedure TBrowserForm.FBtnBackClick(Sender: TObject);
var
  C: TChromium;
begin
  C := CurrentChromium;
  if (C <> nil) and C.CanGoBack then
    C.GoBack;
end;

{ 前进按钮: 当前页可前进时执行 GoForward }
procedure TBrowserForm.FBtnForwardClick(Sender: TObject);
var
  C: TChromium;
begin
  C := CurrentChromium;
  if (C <> nil) and C.CanGoForward then
    C.GoForward;
end;

{ 重新加载/停止两态按钮: 加载中 = 停止加载, 空闲 = 重载当前标签 }
procedure TBrowserForm.FBtnReloadClick(Sender: TObject);
var
  C: TChromium;
begin
  if FBtnReload.ButtonType = nbtStop then
  begin
    C := CurrentChromium;
    if C <> nil then
      C.StopLoad;
    SetReloadButtonLoading(False);
    Exit;
  end;
  ReloadPageAt(FTabs.ActiveTabIndex);   // 与右键菜单"重新加载"同一实现
end;

{ 首页按钮: 当前标签加载设置里的浏览器首页 }
procedure TBrowserForm.FBtnHomeClick(Sender: TObject);
var
  C: TChromium;
begin
  C := CurrentChromium;
  if C <> nil then
  begin
    C.LoadURL(Settings.EffectiveHomepage);   // 首页按钮 → 设置里的浏览器首页
    if C.Initialized then
      SetReloadButtonLoading(True);
  end;
end;

{ 地址栏导航: 无协议的输入自动补 https:// 前缀后加载
  （Go 按钮已隐藏, 回车也走这里） }
procedure TBrowserForm.FBtnGoClick(Sender: TObject);
var
  C: TChromium;
  URL: string;
begin
  C := CurrentChromium;
  if C = nil then Exit;
  URL := Trim(FAddressBar.Text);
  if URL = '' then Exit;
  if (Pos('://', URL) = 0) and (Pos('about:', URL) <> 1) then
    URL := 'https://' + URL;
  C.LoadURL(URL);
  if C.Initialized then
    SetReloadButtonLoading(True);
end;

{ 地址栏按键: 回车触发导航 }
procedure TBrowserForm.FAddressBarKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;
    FBtnGoClick(Sender);
  end;
end;

{ ---- Chrome 风格导航按钮创建 ----------------------------------------------- }

{ 创建工具栏导航按钮（后退/前进/刷新/首页/下载/⋮ 菜单）与地址栏;
  布局数值对齐 Chromium layout_constants, 详见体内注释 }
procedure TBrowserForm.CreateNavButtons;
var
  B, Y, Pad, Gap, MenuX, AddrL, AddrR, ContentH, AHeight: Integer;
begin
  { 数值对齐 Chromium 159 桌面版 chrome/browser/ui/layout_constants.cc:
      kToolbarButtonHeight    = 34      按钮外框
      kToolbarInteriorMargin  = VH(6,6) 行内留白: 上下 6 / 左右 6
      TOOLBAR_ELEMENT_PADDING = 4       每个元素的左右 margin (相邻两元素 → 8)
      TOOLBAR_STANDARD_SPACING= 9       地址栏自带的左右 margin
      LOCATION_BAR_HEIGHT     = 34      地址栏高度
    因此: 左缩进 = 6(interior) + 4(元素 margin) = 10; 相邻按钮间距 = 4+4 = 8;
          最后一个按钮到地址栏 = 4(按钮 margin) + 9(地址栏 margin) = 13;
          按钮/地址栏均居中于 46px 的内容高度（不含下边框那 1px 行）。 }
  // 布局随工具栏高度/DPI 计算, 不再写死坐标; 地址栏用 akRight 锚点随窗口拉伸
  B := FTabs.ScalePx(34);            // TOOLBAR_BUTTON_HEIGHT
  Pad := FTabs.ScalePx(10);          // interior 6 + 元素 margin 4
  Gap := FTabs.ScalePx(8);           // 元素两侧各 4px margin
  ContentH := pnlAddressBar.Height - Max(1, FTabs.ScalePx(1));   // 46, 去掉下边框
  Y := (ContentH - B) div 2;         // 垂直居中

  FBtnBack := TFHNavButton.Create(Self);
  FBtnBack.Parent := pnlAddressBar;
  FBtnBack.ButtonType := nbtBack;
  FBtnBack.SetBounds(Pad, Y, B, B);
  FBtnBack.OnClick := FBtnBackClick;

  FBtnForward := TFHNavButton.Create(Self);
  FBtnForward.Parent := pnlAddressBar;
  FBtnForward.ButtonType := nbtForward;
  FBtnForward.SetBounds(Pad + (B + Gap), Y, B, B);
  FBtnForward.OnClick := FBtnForwardClick;

  FBtnReload := TFHNavButton.Create(Self);
  FBtnReload.Parent := pnlAddressBar;
  FBtnReload.ButtonType := nbtReload;
  FBtnReload.SetBounds(Pad + 2 * (B + Gap), Y, B, B);
  FBtnReload.OnClick := FBtnReloadClick;
  FBtnReload.Hint := '重新加载';
  FBtnReload.ShowHint := True;

  FBtnHome := TFHNavButton.Create(Self);
  FBtnHome.Parent := pnlAddressBar;
  FBtnHome.ButtonType := nbtHome;
  FBtnHome.SetBounds(Pad + 3 * (B + Gap), Y, B, B);
  FBtnHome.OnClick := FBtnHomeClick;

  { ⋮ 主菜单按钮: 最右（Chrome 就是把三点放在这一排的最后）。只锚右边 }
  MenuX := pnlAddressBar.ClientWidth - Pad - B;
  FBtnMenu := TFHNavButton.Create(Self);
  FBtnMenu.Parent := pnlAddressBar;
  FBtnMenu.ButtonType := nbtMenu;
  FBtnMenu.SetBounds(MenuX, Y, B, B);
  FBtnMenu.Anchors := [akTop, akRight];
  FBtnMenu.Hint := '菜单';
  FBtnMenu.ShowHint := True;
  FBtnMenu.OnClick := FBtnMenuClick;

  { 下载按钮: 放在 ⋮ 菜单左侧（Chrome 工具栏下载图标的位置）。
    图标随后台下载状态切换: 下载中 = 托盘+下箭头, 全部完成 = 蓝色托盘+勾 }
  FBtnDownload := TFHNavButton.Create(Self);
  FBtnDownload.Parent := pnlAddressBar;
  FBtnDownload.ButtonType := nbtDownload;
  FBtnDownload.SetBounds(MenuX - B - FTabs.ScalePx(4), Y, B, B);
  FBtnDownload.Anchors := [akTop, akRight];
  FBtnDownload.Hint := '下载';
  FBtnDownload.ShowHint := True;
  FBtnDownload.OnClick := DoShowDownloadsBubble;

  { 地址栏右边界对准下载按钮（Go 按钮已隐藏）。回车仍走 FBtnGoClick 逻辑 }
  AddrL := FBtnHome.Left + FBtnHome.Width + FTabs.ScalePx(13);
  AddrR := FBtnDownload.Left - FTabs.ScalePx(13);
  AHeight := FTabs.ScalePx(34);    // LOCATION_BAR_HEIGHT
  FAddressBar := TFHAddressBar.Create(Self);
  FAddressBar.Parent := pnlAddressBar;
  FAddressBar.SetBounds(AddrL, (ContentH - AHeight) div 2,
    AddrR - AddrL, AHeight);
  FAddressBar.Anchors := [akLeft, akTop, akRight];
  FAddressBar.OnKeyPress := FAddressBarKeyPress;
  FAddressBar.OnStarClick := DoStarClick;   { 胶囊内星标 → 添加/修改书签气泡 }
end;

{ 创建标签条右侧的最小化/最大化/关闭三个窗口控制按钮（Chrome 扁平自绘） }
procedure TBrowserForm.CreateCaptionButtons;
begin
  // 窗口控制按钮（挂标签条右侧, Chrome 扁平自绘）
  // alRight 后创建的在最右 → 创建顺序: 最小化、最大化、关闭
  // 最终视觉由左至右: 最小化、最大化、关闭
  FBtnMin := TFHCaptionButton.Create(Self);
  FBtnMin.Parent := FTabs;
  FBtnMin.ButtonType := cbtMin;
  FBtnMin.Align := alRight;
  FBtnMin.Width := FTabs.ScalePx(46);
  FBtnMin.OnClick := OnCaptionBtnClick;

  FBtnMax := TFHCaptionButton.Create(Self);
  FBtnMax.Parent := FTabs;
  FBtnMax.ButtonType := cbtMax;
  FBtnMax.Align := alRight;
  FBtnMax.Width := FTabs.ScalePx(46);
  FBtnMax.OnClick := OnCaptionBtnClick;

  FBtnClose := TFHCaptionButton.Create(Self);
  FBtnClose.Parent := FTabs;
  FBtnClose.ButtonType := cbtClose;
  FBtnClose.Align := alRight;
  FBtnClose.Width := FTabs.ScalePx(46);
  FBtnClose.OnClick := OnCaptionBtnClick;
end;

{ 构建 ⋮ 主菜单（自绘 Chrome 风格, 只放本程序已实现的动作） }
procedure TBrowserForm.CreateMainMenu;
begin
  { ⋮ 弹出菜单（自绘 Chrome 风格, 见 uFHChromeMenu）。
    Chrome 那套菜单项很多, 这里只放本程序已经实现的动作 }
  FMenuPopup := TFHMenu.Create(Self);
  FMenuPopup.ScaleFactor := FTabs.ScaleFactor;   // 与工具栏同一套 DPI 换算
  FMenuPopup.Add('新建标签页', DoNewTab, '', miNewTab);
  FMenuPopup.AddSeparator;
  FMenuPopup.Add('查找', DoFind, 'Ctrl+F', miFind);
  FMenuPopup.Add('打印', DoPrint, 'Ctrl+P', miPrint);
  FMenuPopup.Add('历史记录', DoShowHistory, 'Ctrl+H', miHistory);
  FMenuPopup.Add('下载内容', DoShowDownloads, 'Ctrl+J', miDownloads);
  FMenuPopup.Add('删除浏览数据', DoClearBrowsingData, 'Ctrl+Shift+Del', miDeleteData);
  FMenuPopup.AddSeparator;
  FMenuPopup.Add('书签管理器', DoShowBookmarksManager, 'Ctrl+Shift+O', miBookmarks);

  FMenuPopup.AddSeparator;
  FZoomItem := FMenuPopup.AddZoomRow(MenuZoom);  // " − 100% + " 行
  FMenuPopup.Add('开发者工具', MnuDevToolsClick, 'F12', miDevTools);
  FMenuPopup.AddSeparator;
  FMenuPopup.Add('设置', DoShowSettings, '', miSettings);
  FMenuPopup.Add('关于 飞花浏览器', DoShowAbout, '', miAbout);
end;

{ ⋮ 菜单"关于 飞花浏览器": 打开关于对话框 }
procedure TBrowserForm.DoShowAbout(Sender: TObject);
begin
  { 关于对话框: 显示当前软件版本（exe 版本资源）与内核版本（libcef.dll） }
  ShowAboutDlg;
end;

{ ⋮ 菜单"设置": 打开设置对话框 }
procedure TBrowserForm.DoShowSettings(Sender: TObject);
begin
  { 设置对话框（首页/新标签页/下载/GPU 加速）。GPU 是 CEF 启动参数,
    对话框里已标注"需重启生效"; 其余项下一次动作即生效 }
  ShowSettingsDlg;
end;

{ ⋮ 菜单按钮: 同步当前页缩放百分比后, 在按钮正下方弹出主菜单 }
procedure TBrowserForm.FBtnMenuClick(Sender: TObject);
var
  P: TPoint;
  C: TChromium;
begin
  { 缩放行显示当前页的缩放百分比（CEF 档位表: 25%~500%） }
  FZoomItem.ZoomPct := 100;
  C := CurrentChromium;
  if C <> nil then
  try
    if C.Initialized then
      FZoomItem.ZoomPct := Round(C.ZoomPct);
  except
    on E: Exception do
      Logger.Error('读取缩放比例失败: %s - %s', [E.ClassName, E.Message]);
  end;

  { 菜单挂在按钮正下方（Chrome 就是这个位置） }
  P := FBtnMenu.ClientToScreen(Point(0, FBtnMenu.Height));
  FMenuPopup.Popup(P.X, P.Y);
end;

{ 菜单"开发者工具"项: 开关当前标签的 DevTools }
procedure TBrowserForm.MnuDevToolsClick(Sender: TObject);
begin
  OpenDevTools;
end;

{ 打印当前页（Chrome 风格打印预览） }
procedure TBrowserForm.DoPrint(Sender: TObject);
var
  C: TChromium;
begin
  C := CurrentChromium;
  if (C <> nil) and C.Initialized then
  try
    C.Print;                          // Chrome 风格打印预览（chrome runtime）
  except
    on E: Exception do
      Logger.Error('打印失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ ---- 页面内查找 ----------------------------------------------------------- }

{ 菜单"查找"/Ctrl+F: 显示页面内查找条 }
procedure TBrowserForm.DoFind(Sender: TObject);
begin
  ShowFindBar;
end;

{ 显示查找条: 定位到页面右上角, 绑定当前标签并立即按已有文本发起查找 }
procedure TBrowserForm.ShowFindBar;
var
  C: TChromium;
begin
  if FFindBar = nil then Exit;
  C := CurrentChromium;
  if (C = nil) or not C.Initialized then Exit;
  if not FFindBar.Visible then
    FFindBar.AlignToTopRight;
  FFindChromium := C;
  FFindBar.Visible := True;
  FFindBar.BringToFront;
  FFindBar.FocusSearch;
  DoFindSearch(nil);
end;

{ 隐藏查找条: 停止当前标签的查找高亮, 焦点还给页面 }
procedure TBrowserForm.HideFindBar;
var
  C, Cur: TChromium;
begin
  if (FFindBar = nil) or not FFindBar.Visible then Exit;
  FFindBar.Visible := False;
  C := FFindChromium;
  FFindChromium := nil;
  if (C <> nil) and C.Initialized then
  try
    C.StopFinding(True);
  except
    on E: Exception do
      Logger.Error('停止查找失败: %s - %s', [E.ClassName, E.Message]);
  end;
  Cur := CurrentChromium;
  if (Cur <> nil) and Cur.Initialized then
  try
    Cur.SetFocus(True);
  except
    on E: Exception do
      Logger.Error('查找关闭后恢复页面焦点失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 查找文本变化: 空文本清除高亮并归零计数, 非空发起（增量）查找 }
procedure TBrowserForm.DoFindSearch(Sender: TObject);
var
  C: TChromium;
  S: string;
begin
  if FFindBar = nil then Exit;
  C := FFindChromium;
  if (C = nil) or not C.Initialized then Exit;
  S := FFindBar.SearchText;
  if S = '' then
  begin
    C.StopFinding(True);
    FFindBar.SetResult(0, 0);
    Exit;
  end;
  C.Find(S, True, FFindBar.MatchCase, False);
end;

{ 查找上/下一个匹配（AForward=True 向下） }
procedure TBrowserForm.FindStep(AForward: Boolean);
var
  C: TChromium;
  S: string;
begin
  if FFindBar = nil then Exit;
  C := FFindChromium;
  if (C = nil) or not C.Initialized then Exit;
  S := FFindBar.SearchText;
  if S = '' then Exit;
  C.Find(S, AForward, FFindBar.MatchCase, True);
end;

{ 查找条"下一个"按钮 }
procedure TBrowserForm.DoFindNext(Sender: TObject);
begin
  FindStep(True);
end;

{ 查找条"上一个"按钮 }
procedure TBrowserForm.DoFindPrev(Sender: TObject);
begin
  FindStep(False);
end;

{ 查找条关闭按钮: 隐藏查找条 }
procedure TBrowserForm.DoFindClose(Sender: TObject);
begin
  HideFindBar;
end;

{ 查找结果回调: 把匹配总数与当前命中序号回填查找条 }
procedure TBrowserForm.ChromiumFindResult(Sender: TObject;
  const browser: ICefBrowser; identifier, count: Integer;
  const selectionRect: PCefRect; activeMatchOrdinal: Integer;
  finalUpdate: Boolean);
begin
  if (FFindBar = nil) or not FFindBar.Visible then Exit;
  if TChromium(Sender) <> FFindChromium then Exit;
  FFindBar.SetResult(count, activeMatchOrdinal);
end;

{ CEF_FIND 落点: 显示查找条 }
procedure TBrowserForm.FindBarMsg(var Message: TMessage);
begin
  ShowFindBar;
end;

{ CEF_FINDCLOSE 落点: 隐藏查找条 }
procedure TBrowserForm.FindBarCloseMsg(var Message: TMessage);
begin
  HideFindBar;
end;

{ CEF_HISTORY 落点: 打开历史记录窗口 }
procedure TBrowserForm.HistoryMsg(var Message: TMessage);
begin
  DoShowHistory(nil);
end;

{ 菜单/Ctrl+H"历史记录": 打开历史窗口（单击条目在当前标签打开） }
procedure TBrowserForm.DoShowHistory(Sender: TObject);
begin
  try
    { 历史窗口: 单击条目在当前标签页打开（同 Chrome 历史页）, 右键可开新标签页;
      右上角"清除浏览数据"复用本窗体的对话框 }
    ShowHistoryForm(OpenHistoryUrl, OpenHistoryUrlNewTab, DoClearBrowsingData);
  except
    on E: Exception do
      Logger.Error('打开历史记录窗口失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 历史/书签条目单击: 在当前标签打开; 当前页不可用时退回新标签打开 }
procedure TBrowserForm.OpenHistoryUrl(Sender: TObject; const AUrl: string);
var
  C: TChromium;
begin
  if AUrl = '' then Exit;
  C := CurrentChromium;
  if (C <> nil) and C.Initialized then
  try
    C.LoadURL(AUrl);
  except
    on E: Exception do
    begin
      Logger.Error('历史记录: 当前标签页打开失败 (%s): %s - %s',
        [AUrl, E.ClassName, E.Message]);
      NewBrowserTabAt(-1, AUrl);   // 当前页不可用则退回新标签打开
    end;
  end
  else
    NewBrowserTabAt(-1, AUrl);
end;

{ 历史/书签条目"在新标签页打开": 追加新标签加载 }
procedure TBrowserForm.OpenHistoryUrlNewTab(Sender: TObject; const AUrl: string);
begin
  if AUrl <> '' then
    NewBrowserTabAt(-1, AUrl);
end;

{ ---- 书签 ------------------------------------------------------------------ }

{ Ctrl+D 消息转投后的落点（页面里按键时走 ChromiumPreKeyEvent） }
procedure TBrowserForm.BookmarkMsg(var Message: TMessage);
begin
  DoStarClick(nil);
end;

{ CEF_BOOKMARKSMGR 落点: 打开书签管理器 }
procedure TBrowserForm.BookmarksMgrMsg(var Message: TMessage);
begin
  DoShowBookmarksManager(nil);
end;

{ 地址栏星标 / Ctrl+D → "添加书签"(未收藏)或"修改书签"(已收藏)气泡。
  名称默认取当前标签标题; 气泡失焦/Esc 关闭, 完成后经 NotifyBookmarksChanged
  刷新书签栏并回调 DoBookmarksChanged 更新星标态 }
procedure TBrowserForm.DoStarClick(Sender: TObject);
var
  C: TChromium;
  URL, Title: string;
  TabIdx: Integer;
begin
  try
    C := CurrentChromium;
    if (C = nil) or not FURLs.TryGetValue(C, URL) then Exit;
    if (URL = '') or SameText(URL, 'about:blank') then Exit;
    Title := '';
    TabIdx := FTabs.ActiveTabIndex;
    if (TabIdx >= 0) and (TabIdx < FTabs.Tabs.Count) then
      Title := FTabs.Tabs[TabIdx].Caption;
    ShowBookmarkBubble(FAddressBar.StarScreenRect, URL, Title);
  except
    on E: Exception do
      Logger.Error('打开书签气泡失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 书签任意入口增删改后回调（uFHBookmarks.NotifyBookmarksChanged）: 刷星标态 }
procedure TBrowserForm.DoBookmarksChanged(Sender: TObject);
begin
  UpdateStarButton;
end;

{ 菜单/Ctrl+Shift+O"书签管理器": 打开书签管理器窗口 }
procedure TBrowserForm.DoShowBookmarksManager(Sender: TObject);
begin
  try
    { 书签管理器: 单击条目在当前标签页打开并关闭本窗口, 右键可开新标签页;
      行内 × / 右键"删除"即时生效并同步书签栏与星标 }
    ShowBookmarksManager(OpenHistoryUrl, OpenHistoryUrlNewTab);
  except
    on E: Exception do
      Logger.Error('打开书签管理器失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;


{ 菜单/Ctrl+J"下载内容": 打开下载记录窗口 }
procedure TBrowserForm.DoShowDownloads(Sender: TObject);
begin
  try
    ShowDownloadsForm;
  except
    on E: Exception do
      Logger.Error('打开下载窗口失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 工具栏下载按钮 → "近期下载记录"气泡（按钮点击 = 开关语义, 已开则关闭） }
procedure TBrowserForm.DoShowDownloadsBubble(Sender: TObject);
begin
  try
    ShowDownloadsBubbleAtButton(False);
  except
    on E: Exception do
      Logger.Error('打开下载气泡失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 以工具栏下载按钮为锚点弹气泡。
  AAutoShow = True（下载完成自动弹）: 已开则只刷新定位, 不关闭;
  AAutoShow = False（用户点击）: 开关语义 }
procedure TBrowserForm.ShowDownloadsBubbleAtButton(AAutoShow: Boolean);
var
  P1, P2: TPoint;
  R: TRect;
begin
  if FBtnDownload = nil then Exit;
  P1 := FBtnDownload.ClientToScreen(Point(0, 0));
  P2 := FBtnDownload.ClientToScreen(Point(FBtnDownload.Width,
    FBtnDownload.Height));
  R := Rect(P1.X, P1.Y, P2.X, P2.Y);
  ShowDownloadsBubble(R, not AAutoShow);
end;

{ 图标/提示按下载状态切换:
  有进行中 → 下载中图标 + "当前共有 N 项文件正在下载中";
  全部完成 → 蓝色"托盘+勾" + "近期下载记录"; 无记录 → 普通下载图标 }
procedure TBrowserForm.UpdateDownloadButton;
var
  I, Active, Done: Integer;
begin
  if FBtnDownload = nil then Exit;
  Active := 0;
  Done := 0;
  for I := 0 to Downloads.Count - 1 do
    case Downloads[I].State of
      dsInProgress: Inc(Active);
      dsComplete:   Inc(Done);
    end;
  if Active > 0 then
  begin
    FBtnDownload.ButtonType := nbtDownload;
    FBtnDownload.Hint := Format('当前共有 %d 项文件正在下载中', [Active]);
  end
  else if Done > 0 then
  begin
    FBtnDownload.ButtonType := nbtDownloadDone;
    FBtnDownload.Hint := '近期下载记录';
  end
  else
  begin
    FBtnDownload.ButtonType := nbtDownload;
    FBtnDownload.Hint := '下载';
  end;
end;

{ 清除浏览数据: 对话框收集选项后按类清理——缓存/Cookie 走 CEF API（全量）,
  浏览历史/下载记录走自建 SQLite（支持时间范围）, 表单数据无 API 跳过 }
procedure TBrowserForm.DoClearBrowsingData(Sender: TObject);
var
  Options: TFHBrowsingDataOptions;
  TimeRange: TFHBrowsingTimeRange;
  I: Integer;
  C: TChromium;
  Since: TDateTime;
  Skipped: string;
begin
  if not ShowBrowsingDataDlg(Options, TimeRange) then Exit;
  if Options = [] then Exit;

  try
    Since := BrowsingTimeRangeSince(TimeRange);

    { 缓存 + Cookie: 遍历所有标签用 CEF API 即时清理
      ClearCache       → DevTools Network.clearBrowserCache（清内存+磁盘缓存）
      DeleteCookies('','',True) → 删全部 cookies（空 url+空 name = 全删）
      注: CEF API 不支持按时间过滤，Cookie 和缓存只能全部清除 }
    for I := 0 to FTabs.Tabs.Count - 1 do
    begin
      C := ChromiumOfPage(FHost.PageAtTabIndex(I));
      if (C <> nil) and C.Initialized then
      begin
        if bdoCache in Options then
          C.ClearCache;
        if bdoCookies in Options then
          C.DeleteCookies('', '', True);
      end;
    end;

    { 浏览历史: 从自建 SQLite 删除，支持时间范围 }
    if bdoHistory in Options then
      HistoryDB.ClearHistory(Since);

    { 下载记录: 从自建 SQLite 删除（按时间范围，保留进行中的），
      同时清内存列表里已结束的 }
    if bdoDownloads in Options then
    begin
      HistoryDB.ClearDownloads(Since);
      for I := Downloads.Count - 1 downto 0 do
        if (Downloads[I].State <> dsInProgress) and
           ((Since = 0) or (Downloads[I].StartTime >= Since)) then
          Downloads.Remove(Downloads[I].Id);
    end;

    { 表单/自动填充: CEF 内部库无公开 API，即时模式无法清理 }
    if bdoFormData in Options then
      Skipped := '表单数据'
    else
      Skipped := '';

    { 清了缓存则硬刷新当前页让用户看到效果 }
    if bdoCache in Options then
    begin
      C := CurrentChromium;
      if (C <> nil) and C.Initialized then
        C.ReloadIgnoreCache;
    end;

    if Skipped <> '' then
      Application.MessageBox(
        PChar(Format('%s 需重启程序才能彻底清理，本次已跳过。', [Skipped])),
        '提示', MB_OK or MB_ICONINFORMATION)
    else
      Application.MessageBox('浏览数据已清除。', '提示', MB_OK or MB_ICONINFORMATION);
  except
    on E: Exception do
      Logger.Error('清除浏览数据失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 下载开始: 设置里开了"下载前询问保存位置"（默认是）→ 弹系统"另存为"对话框
  （初始目录 = 默认下载位置）; 不询问或用户取消 → 直接下到默认下载位置
  （文件名去重）。不接 OnBeforeDownload 的话 CEF 会直接取消下载 ——
  这个回调是下载能跑的前提 }
procedure TBrowserForm.ChromiumBeforeDownload(Sender: TObject;
  const browser: ICefBrowser; const downloadItem: ICefDownloadItem;
  const suggestedName: ustring; const callback: ICefBeforeDownloadCallback);
var
  Path, Name: string;
  SaveDlg: TSaveDialog;
  C: TChromium;
  TabIdx: Integer;
begin
  try
    Name := string(suggestedName);
    if Name = '' then
      Name := Format('download-%d.bin', [downloadItem.Id]);
    { 弹"另存为"必须在这里（Cont 之前）: CEF 等回调返回才开下。
      用户取消不掐掉下载 —— callback 只有 Cont 没有 Cancel, 挂起会在下载
      窗口里留一个永远 0% 的死项, 所以退回默认路径继续 }
    if Settings.AskDownloadLocation then
    begin
      SaveDlg := TSaveDialog.Create(nil);
      try
        SaveDlg.Title := '保存文件';
        SaveDlg.FileName := Name;
        SaveDlg.InitialDir := Settings.EffectiveDownloadDir;
        SaveDlg.Filter := '所有文件 (*.*)|*.*';
        if SaveDlg.Execute then
          Path := SaveDlg.FileName
        else
          Path := UniqueDownloadPath(Name);
      finally
        SaveDlg.Free;
      end;
    end
    else
      Path := UniqueDownloadPath(Name);
    Downloads.Add(downloadItem.Id, string(downloadItem.Url), Path, Name);
    try
      HistoryDB.AddDownload(downloadItem.Id, string(downloadItem.Url), Path, Name);
    except
      on E: Exception do
        Logger.Error('记录下载到数据库失败: %s - %s', [E.ClassName, E.Message]);
    end;
    callback.Cont(Path, False);
    Logger.Info('开始下载: %s (%s)', [Name, Path]);

    { 弹窗转来的标签（target=_blank 下载链接）: 不能在这里关掉它。
      OnDownloadUpdated 绑定在这个浏览器实例上, 关掉浏览器就不再收到进度回调,
      下载窗口的进度会永远卡在 0。改为把标签标题改成"下载中: xxx" 留着,
      等下载完成（ChromiumDownloadUpdated 里 IsComplete）再关它。
      下载本身由 callback.Cont 交给 browser process, 标签留着不影响下载 }
    C := TChromium(Sender);
    if FPopupTabs.Contains(C) then
    begin
      TabIdx := TabIndexOfChromium(C);
      if TabIdx >= 0 then
        FTabs.Tabs[TabIdx].Caption := '下载: ' + Name;
    end;

    { 下载开始: 只更新工具栏下载按钮（图标=下载中 + 悬停提示项数）;
      全部完成的自动弹"近期下载记录"气泡在 ChromiumDownloadUpdated 里 }
    UpdateDownloadButton;
  except
    on E: Exception do
    begin
      Logger.Error('下载启动失败 (%s): %s - %s',
        [string(suggestedName), E.ClassName, E.Message]);
      { 兜底: 仍尝试走正常路径（UniqueDownloadPath + 记录）, 保证窗口里能看到、
        双击能打开; 这一步再失败才退回让 CEF 用默认路径下载 }
      try
        Path := UniqueDownloadPath(Name);
        Downloads.Add(downloadItem.Id, string(downloadItem.Url), Path, Name);
        callback.Cont(Path, False);
      except
        on E2: Exception do
          callback.Cont(string(suggestedName), False);
      end;
    end;
  end;
end;

{ 下载进度/状态变化: 刷内存列表与工具栏按钮; 刚完成时弹"近期下载记录"
  气泡、关掉弹窗转来的标签、最终状态持久化 SQLite }
procedure TBrowserForm.ChromiumDownloadUpdated(Sender: TObject;
  const browser: ICefBrowser; const downloadItem: ICefDownloadItem;
  const callback: ICefDownloadItemCallback);
var
  C: TChromium;
  Item: TFHDownloadItem;
  DbState: Integer;
begin
  try
    { Update 返回 True = 这一刻刚变成完成态。
      完成提示: 下载窗口关着则弹出来（让用户看到完成）, 开着则只刷新不抢焦
      （避免打断用户当前操作） }
    if Downloads.Update(downloadItem, callback) then
    begin
      Logger.Info('下载完成: %s', [string(downloadItem.FullPath)]);
      { 按钮切换为"已下载"蓝色图标; 主窗在前台时自动弹出"近期下载记录"气泡
        （AAutoShow=True: 已开则只刷新, 不会被 toggle 关掉） }
      UpdateDownloadButton;
      if (Application.MainForm <> nil) and Application.MainForm.Active then
        ShowDownloadsBubbleAtButton(True);
      { 弹窗转来的标签: 下载已完成, 现在可以关掉它（BeforeDownload 里留着没关,
        就是为了让 OnDownloadUpdated 能持续触发更新进度） }
      C := TChromium(Sender);
      if FPopupTabs.Contains(C) then
      begin
        FPopupTabs.Remove(C);
        C.CloseBrowser(True);
        Logger.Info('下载完成, 关闭弹窗转来的标签');
      end;
    end;

    { 下载结束（完成/取消/中断）时把最终状态持久化到 SQLite。
      进行中的不写（太频繁），内存里有即可 }
    Item := Downloads.ById(downloadItem.Id);
    if (Item <> nil) and (Item.State <> dsInProgress) then
    begin
      case Item.State of
        dsComplete:    DbState := 1;
        dsCanceled:    DbState := 2;
        dsInterrupted: DbState := 3;
      else
        DbState := 1;
      end;
      try
        HistoryDB.UpdateDownload(Item.Id, Item.Received, Item.Total, DbState, Now);
      except
        on E: Exception do
          Logger.Error('更新下载数据库失败: %s - %s', [E.ClassName, E.Message]);
      end;
    end;

    { 进度/取消/中断都刷新工具栏按钮的图标与悬停提示 }
    UpdateDownloadButton;
  except
    on E: Exception do
      Logger.Error('下载状态更新失败 (id=%d): %s - %s',
        [downloadItem.Id, E.ClassName, E.Message]);
  end;
end;

{ 网页右键菜单构建时: CEF（chrome runtime）提供的是 Chrome 原生菜单, 其中
  "在新标签页/新窗口中打开链接"由 Chrome 内部执行 —— 而我们是单窗口多标签宿主,
  CEF 侧没有"标签条"可开标签, 点它没反应。这里把这些项换成我们自己可控的
  MENU_ID_USER_FIRST 项, 由 ChromiumContextMenuCommand 统一开新标签。
  这些菜单项 ID 是 Chrome 侧的自定义值（本 fork 没有暴露成 CEF 常量）, 只能
  按标题探测 —— 先收集再删除, 避免边遍历边删导致索引错位 }
procedure TBrowserForm.ChromiumBeforeContextMenu(Sender: TObject;
  const browser: ICefBrowser; const frame: ICefFrame;
  const params: ICefContextMenuParams; const model: ICefMenuModel);
var
  I, N, Id: Integer;
  Lbl: string;
  RemoveIds: TList<Integer>;
begin
  try
    if (model = nil) or (params = nil) or (params.LinkUrl = '') then Exit;
    RemoveIds := TList<Integer>.Create;
    try
      for I := 0 to Integer(model.GetCount) - 1 do
      begin
        Lbl := string(model.GetLabelAt(I));
        if Pos('打开链接', Lbl) = 0 then Continue;
        Id := model.GetCommandIdAt(I);
        if Pos('新标签', Lbl) > 0 then
        begin
          FMenuCmdNewTab := Id;
          RemoveIds.Add(Id);
        end
        else if Pos('新窗口', Lbl) > 0 then
        begin
          FMenuCmdNewWindow := Id;      // 单窗口应用: 新窗口也当新标签
          RemoveIds.Add(Id);
        end;
      end;
      for N := 0 to RemoveIds.Count - 1 do
        model.Remove(RemoveIds[N]);
    finally
      RemoveIds.Free;
    end;
    model.InsertItemAt(0, MENU_ID_USER_FIRST, ustring('在新标签页中打开链接'));
  except
    on E: Exception do
      Logger.Error('右键菜单接管失败: %s - %s', [E.ClassName, E.Message]);
  end;
end;

{ 右键菜单命令执行: "在新标签页中打开链接"（含接管的原生项）统一转新标签 }
procedure TBrowserForm.ChromiumContextMenuCommand(Sender: TObject;
  const browser: ICefBrowser; const frame: ICefFrame;
  const params: ICefContextMenuParams; commandId: Integer;
  eventFlags: TCefEventFlags; out Result: Boolean);
begin
  Result := False;
  try
    { 我们自己加的项, 以及没替换成功的原生项 —— 统一走"转到新标签" }
    if (commandId = MENU_ID_USER_FIRST) or
       ((commandId >= 0) and ((commandId = FMenuCmdNewTab) or
         (commandId = FMenuCmdNewWindow))) then
    begin
      if (params <> nil) and (params.LinkUrl <> '') then
      begin
        FPendingPopupUrls.Add(string(params.LinkUrl));
        PostMessage(Handle, CEF_NEWTAB, 0, 0);
        Logger.Info('右键菜单"在新标签页中打开链接": %s', [string(params.LinkUrl)]);
      end;
      Result := True;              // 已处理, 不再交给 CEF 走它自己的路径
    end;
  except
    on E: Exception do
      Logger.Error('右键菜单命令执行失败 (id=%d): %s - %s',
        [commandId, E.ClassName, E.Message]);
  end;
end;

{ 弹窗拦截: 一律 Result=True 阻止 CEF 创建新窗口, 目标 URL 转投新标签。
  不能在这里直接 NewBrowserTabAt —— 回调发生在 CEF 弹窗创建路径上,
  按官方建议转投到主循环消息里再做（NewTabMsg） }
procedure TBrowserForm.ChromiumBeforePopup(Sender: TObject;
  const browser: ICefBrowser; const frame: ICefFrame;
  const targetUrl, targetFrameName: ustring;
  targetDisposition: TCefWindowOpenDisposition; userGesture: Boolean;
  const popupFeatures: TCefPopupFeatures; var windowInfo: TCefWindowInfo;
  var client: ICefClient; var settings: TCefBrowserSettings;
  var extra_info: ICefDictionaryValue; var noJavascriptAccess: Boolean;
  var Result: Boolean);
begin
  Result := True;                     // 本工程不允许 CEF 自己弹窗口
  try
    case targetDisposition of
      WOD_IGNORE_ACTION, WOD_OFF_THE_RECORD:
        Logger.Info('弹窗已忽略 (disposition=%d, url=%s)',
          [Ord(targetDisposition), string(targetUrl)]);
    else
      { 新标签/新窗口/弹窗/未知 —— 统一转新标签; 后台标签也会被带到前台
        （NewBrowserTabAt 目前总是激活新标签, 与 Chrome 的差异暂不处理） }
      if targetUrl <> '' then
      begin
        FPendingPopupUrls.Add(string(targetUrl));
        PostMessage(Handle, CEF_NEWTAB, 0, 0);
        Logger.Info('弹窗转新标签: %s (disposition=%d)',
          [string(targetUrl), Ord(targetDisposition)]);
      end;
    end;
  except
    on E: Exception do
      Logger.Error('弹窗转新标签失败 (%s): %s - %s',
        [string(targetUrl), E.ClassName, E.Message]);
  end;
end;

{ CEF_NEWTAB 落点: 逐个取出排队的 URL 开新标签, 并登记为"弹窗转来的标签"
  （下载场景下下载完成会自动关掉它） }
procedure TBrowserForm.NewTabMsg(var Message: TMessage);
var
  Url: string;
  Chromium: TChromium;
begin
  { 队列逐个取出开标签（一次弹窗可能触发多次 PostMessage, 合并处理） }
  while FPendingPopupUrls.Count > 0 do
  begin
    Url := FPendingPopupUrls[0];
    FPendingPopupUrls.Delete(0);
    NewBrowserTabAt(-1, Url);
    { 记下"弹窗转来的标签": 若目标是下载文件, 下载开始后会把它关掉,
      否则留在那里就是个永远空白的标签 }
    Chromium := ChromiumOfPage(FHost.PageAtTabIndex(FTabs.Tabs.Count - 1));
    if (Chromium <> nil) and (not FPopupTabs.Contains(Chromium)) then
      FPopupTabs.Add(Chromium);
  end;
end;

{ 缩放当前页: ADelta = -1/+1 沿 CEF 档位表加减一档, 0 = 重置 100%。
  ZoomStep 是 CEF 缓存的档位（同步可读）, 设置走 UI 线程任务（异步生效）;
  百分比直接按档位表取值回填缩放行, 不用等 CEF 异步回报 }
procedure TBrowserForm.ApplyZoom(ADelta: Integer);
var
  C: TChromium;
  Step: Integer;
begin
  C := CurrentChromium;
  if (C = nil) or not C.Initialized then Exit;
  try
    Step := C.ZoomStep;
    case ADelta of
      -1: Step := Max(Step - 1, ZOOM_STEP_MIN);
       1: Step := Min(Step + 1, ZOOM_STEP_MAX);
    else
      Step := ZOOM_STEP_DEF;            // 100%
    end;
    C.ZoomStep := Step;
    if FZoomItem <> nil then
      FZoomItem.ZoomPct := ZoomStepValues[Step];
  except
    on E: Exception do
      Logger.Error('缩放失败 (delta=%d): %s - %s', [ADelta, E.ClassName, E.Message]);
  end;
end;

{ 菜单缩放行回调: 执行缩放并回填行内显示的新百分比 }
procedure TBrowserForm.MenuZoom(Sender: TObject; ADelta: Integer;
  var ANewPct: Integer);
begin
  ApplyZoom(ADelta);
  ANewPct := FZoomItem.ZoomPct;
end;

{ 焦点在工具栏/地址栏/标签条时的快捷键（焦点在页面里时见 ChromiumPreKeyEvent）:
  Esc 关查找条 / F3 查找 / F12 DevTools / Ctrl+P·H·J·F·D·F5·0·加减 缩放 /
  Ctrl+Shift+Del 清数据 · Ctrl+Shift+O 书签管理器 }
procedure TBrowserForm.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  C: TChromium;
begin
  { 焦点在工具栏/地址栏/标签条时, F12 走这条（焦点在页面里时见 ChromiumPreKeyEvent） }
  if (Key = VK_ESCAPE) and (FFindBar <> nil) and FFindBar.Visible then
  begin
    Key := 0;
    HideFindBar;
    Exit;
  end;

  if Key = VK_F3 then
  begin
    Key := 0;
    if (FFindBar <> nil) and FFindBar.Visible then
      FindStep(not (ssShift in Shift))
    else
      ShowFindBar;
    Exit;
  end;

  if Key = VK_F12 then
  begin
    Key := 0;
    OpenDevTools;
  end
  else if Shift = [ssCtrl] then
  begin
    { Ctrl+P 打印 / Ctrl+J 下载 / Ctrl+F 查找 / Ctrl+D 书签 / Ctrl+F5 硬刷新 / Ctrl+0 重置 / Ctrl+加减 缩放（页面里按键时走 ChromiumPreKeyEvent） }
    case Key of
      Ord('P'):                begin Key := 0; DoPrint(nil); end;
      Ord('H'):                begin Key := 0; DoShowHistory(nil); end;
      Ord('J'):                begin Key := 0; DoShowDownloads(nil); end;
      Ord('F'):                begin Key := 0; ShowFindBar; end;
      Ord('D'):                begin Key := 0; DoStarClick(nil); end;
      VK_F5:                   begin Key := 0; C := CurrentChromium; if C <> nil then C.ReloadIgnoreCache; end;
      Ord('0'):                begin Key := 0; ApplyZoom(0); end;
      VK_OEM_PLUS, VK_ADD:     begin Key := 0; ApplyZoom(1); end;
      VK_OEM_MINUS, VK_SUBTRACT: begin Key := 0; ApplyZoom(-1); end;
    end;
  end
  else if Shift = [ssCtrl, ssShift] then
  begin
    { Ctrl+Shift+Del 清除浏览数据 / Ctrl+Shift+O 书签管理器（Chrome 同款快捷键。
      Ctrl+Shift+B 书签栏开关已移除——书签栏改为仅空白页/新标签页自动显示） }
    case Key of
      VK_DELETE: begin Key := 0; DoClearBrowsingData(nil); end;
      Ord('O'):  begin Key := 0; DoShowBookmarksManager(nil); end;
    end;
  end;
end;

{ 开关当前标签的 DevTools 停靠面板（已开则关, 每标签独立;
  停靠容器 + 分隔条挂在 Page 上, 可拖动调宽） }
procedure TBrowserForm.OpenDevTools;
var
  C: TChromium;
  Page: TFHChromePage;
  W: Integer;
  Host: TCEFWindowParent;
  Splitter: TSplitter;
begin
  C := CurrentChromium;
  if (C = nil) or not C.Initialized then Exit;

  { toggle: 当前标签已开 → 关掉（Chrome 同款开关行为, 每标签独立） }
  if FDevToolsHosts.ContainsKey(C) then
  begin
    CloseDevTools(C);
    Exit;
  end;

  Page := FHost.PageAtTabIndex(FTabs.ActiveTabIndex);
  if Page = nil then Exit;

  { 停靠容器: alRight 挂在页面里, 页面浏览器(alClient)自动让位并收到 Resize;
    TCEFWindowParent.Resize → UpdateSize 会把内部的 DevTools 子窗口同步成新尺寸 }
  W := Max(FTabs.ScalePx(300), Page.ClientWidth * 2 div 5);   // 约占页面 40%
  Host := TFHCEFWindowParent.Create(Page);
  Host.Name := 'DevToolsHost';
  Host.Parent := Page;
  Host.Align := alRight;
  Host.Width := W;
  Host.Color := clWhite;
  if not Host.HandleAllocated then
    Host.Handle;      // ShowDevTools 需要真实的父窗口句柄

  { 分隔条放在停靠区左侧, 可以拖动调宽（alRight 的分隔条调的就是它右边那块） }
  Splitter := TSplitter.Create(Page);
  Splitter.Parent := Page;
  Splitter.Align := alRight;
  Splitter.Width := Max(2, FTabs.ScalePx(4));
  Splitter.MinSize := FTabs.ScalePx(240);

  { 停靠的关键: VCL 版 TChromium 的重载是
      ShowDevTools(inspectElementAt: TPoint; const aDevTools: TWinControl = nil)
    内部按 控件句柄 + 控件客户区 生成"子窗口"信息 → DevTools 就长在这个控件里;
    传 nil 才是独立顶层窗口。
    ⚠️ 不要传 PCefWindowInfo —— 那是 TChromiumCore 的重载, 指针被当对象解引用
       会直接 AV（实测 Read of address 00000074）。 }
  try
    C.ShowDevTools(Point(Low(Integer), Low(Integer)), Host);
  except
    on E: Exception do
    begin
      Logger.Error('打开开发者工具失败: ' + E.ClassName + ' - ' + E.Message);
      Splitter.Free;
      Host.Free;
      Exit;
    end;
  end;
  FDevToolsHosts.Add(C, Host);
  FDevToolsSplitters.Add(C, Splitter);
end;

{ 关闭指定标签的 DevTools: 先让 CEF 摘掉 DevTools 子窗口, 再释放容器与分隔条 }
procedure TBrowserForm.CloseDevTools(AChromium: TChromium);
var
  Host: TCEFWindowParent;
  Splitter: TSplitter;
begin
  if AChromium = nil then Exit;
  if not FDevToolsHosts.TryGetValue(AChromium, Host) then Exit;
  FDevToolsHosts.Remove(AChromium);
  if FDevToolsSplitters.TryGetValue(AChromium, Splitter) then
    FDevToolsSplitters.Remove(AChromium)
  else
    Splitter := nil;
  { 带停靠容器句柄关闭: CEF4Delphi 会先把 DevTools 子窗口摘掉父窗口再关闭,
    免得它跟着 Host 一起被销毁 }
  if AChromium.Initialized then
    AChromium.CloseDevTools(Host);
  FreeAndNil(Splitter);
  FreeAndNil(Host);              // 释放后该页面浏览器(alClient)自动回满
end;

{ CEF_OPENDEVTOOLS 落点: 开关 DevTools }
procedure TBrowserForm.OpenDevToolsMsg(var Message: TMessage);
begin
  OpenDevTools;
end;

{ CEF_CLEARBROWSINGDATA 落点: 打开清除浏览数据对话框 }
procedure TBrowserForm.ClearBrowsingDataMsg(var Message: TMessage);
begin
  DoClearBrowsingData(nil);
end;

{ CEF_PRINT 落点: 打印当前页 }
procedure TBrowserForm.PrintMsg(var Message: TMessage);
begin
  DoPrint(nil);
end;

{ CEF_DOWNLOADS 落点: 打开下载记录窗口 }
procedure TBrowserForm.DownloadsMsg(var Message: TMessage);
begin
  DoShowDownloads(nil);
end;

{ 窗口控制按钮点击: 关闭 / 最大化切换 / 最小化 }
procedure TBrowserForm.OnCaptionBtnClick(Sender: TObject);
begin
  if Sender = FBtnClose then
    Close
  else if Sender = FBtnMax then
  begin
    if WindowState = wsMaximized then
      WindowState := wsNormal
    else
      WindowState := wsMaximized;
  end
  else if Sender = FBtnMin then
    WindowState := wsMinimized;
end;

{ 吞掉系统标题栏（无边框四件套之一）: 客户区顶部扩展到窗口顶供标签条绘制,
  最大化时补回一个边框宽度让客户区贴住屏幕顶, 细节见体内注释 }
procedure TBrowserForm.WMNCCalcSize(var Message: TWMNCCalcSize);
var
  Frame, NewTop: Integer;
begin
  // 关键: inherited（DefWindowProc）在 wParam=TRUE 时会把 rgrc[0] 改写成它算出的
  // 客户区矩形, 所以"新窗口矩形"必须在 inherited 之前保存。
  NewTop := 0;
  if Message.CalcValidRects then
    NewTop := Message.CalcSize_Params.rgrc[0].Top;

  inherited;
  // 吃掉系统标题栏: 把客户区顶部扩展到窗口矩形顶部,
  // 标题栏区域并入客户区供标签条绘制（保留左右下边框与阴影）
  if Message.CalcValidRects then
  begin
    if WindowState = wsMaximized then
    begin
      // 最大化时窗口矩形会向四周越出屏幕一个边框宽度（实测 150% 下也是 -8 =
      // SM_CXSIZEFRAME 4 + SM_CXPADDEDBORDER 4）。
      // 左右下由 inherited 的边框扣除刚好抵消; 顶边被扣掉"边框+标题栏",
      // 只需在新窗口矩形顶上放回一个边框宽度, 客户区即贴住屏幕顶部。
      //
      // 注意: 这里必须用"新窗口矩形"(inherited 前的 rgrc[0]), 不能用 rgrc[1]。
      // 实测: 运行中点最大化按钮时 rgrc[1] 是**上一个**窗口矩形(130),
      // 用它算出客户区顶 = 138px → 正是"最大化后标签栏不在屏幕最上面"的原因。
      Frame := GetSystemMetrics(SM_CXSIZEFRAME) +
        GetSystemMetrics(SM_CXPADDEDBORDER);
      Message.CalcSize_Params.rgrc[0].Top := NewTop + Frame;
    end
    else
      Message.CalcSize_Params.rgrc[0].Top := NewTop;
  end;
end;

{ 让所有页面重新出帧: 同步宿主尺寸 + 通知 CEF 已可见 + 请求立即重绘
  （最小化恢复/拖拽后页面白屏的修复, 五步细节见体内注释） }
procedure TBrowserForm.RefreshPageSurfaces;
var
  I: Integer;
  Chromium: TChromium;
  WinParent: TCEFWindowParent;
  Child: THandle;
begin
  { 症状: 最小化后从任务栏点回来, 页面整片白（TCEFWindowParent 的白底）,
    鼠标一划到页面上立刻就出来了 —— 说明不是没有内容, 而是 CEF 那边根本没在
    出帧: 窗口被最小化期间它把浏览器当成了"隐藏/被遮挡", 布局与合成都停了,
    而我们这边从头到尾没有告诉过它可以继续。

    所以这里在"确实是从最小化恢复"时补上全套通知:
      1) 原生子窗口还处于隐藏态就显式显示;
      2) UpdateSize 把子窗口尺寸 SetWindowPos 回宿主客户区;
      3) WasHidden(False) 明确通知 CEF 浏览器已可见 —— 这条是关键, CEF 109
         的文档要求宿主自行通报显示/隐藏, 否则恢复后不会恢复渲染;
      4) NotifyMoveOrResizeStarted + Invalidate(PET_VIEW) 请求立刻出新的一帧;
      5) InvalidateChildren 兜底重画宿主与所有子窗口。 }
  if FTabs = nil then Exit;
  for I := 0 to FTabs.Tabs.Count - 1 do
  begin
    Chromium := TChromium(FTabs.Tabs[I].Data);
    if (Chromium = nil) or (Chromium.Tag = 0) then Continue;
    if not Chromium.Initialized then Continue;
    WinParent := TCEFWindowParent(Chromium.Tag);
    if WinParent = nil then Continue;

    Child := WinParent.ChildWindowHandle;
    if (Child <> 0) and not Winapi.Windows.IsWindowVisible(Child) then
      Winapi.Windows.ShowWindow(Child, SW_SHOWNOACTIVATE);

    WinParent.UpdateSize;                    // 同步原生子窗口尺寸
    Chromium.WasResized;                     // 关键: 让 CEF 按新视口重新布局/出帧
    Chromium.WasHidden(False);               // 关键: 通知 CEF 已可见, 恢复出帧
    Chromium.NotifyMoveOrResizeStarted;
    Chromium.Invalidate(PET_VIEW);           // 立刻请求新的一帧
    WinParent.InvalidateChildren;            // 兜底重画
  end;
end;

{ CEF_RESTOREREFRESH 落点: 补一次异步迟到的页面刷新 }
procedure TBrowserForm.RestoreRefreshMsg(var Message: TMessage);
begin
  { WM_SIZE 那一刻窗口可能还没真正显示完, 补给一次异步迟到的刷新 }
  RefreshPageSurfaces;
end;

{ WM_SIZE: 最小化恢复时全量刷新页面; 拖拽/最大化逐帧同步 CEF 视口防白屏;
  窗口状态一变同步最大化按钮图标 }
procedure TBrowserForm.WMSize(var Message: TWMSize);
var
  I: Integer;
  Chromium: TChromium;
begin
  inherited;
  { WM_SIZE 能可靠地覆盖"最小化 → 从任务栏圈标/自身还原按钮恢复"这两种路径,
    这里只在"确实是从最小化恢复"时触发, 普通拖动缩放不打扰渲染。 }
  if Message.SizeType = SIZE_MINIMIZED then
    FWasMinimized := True
  else if FWasMinimized then
  begin
    { SIZE_RESTORED(0)/SIZE_MAXIMIZED(2)/SIZE_MAXSHOW(3) 都是"不再最小化",
      一律触发, 免得"最小化→直接最大化"那条路漏掉 }
    FWasMinimized := False;
    RefreshPageSurfaces;
    PostMessage(Handle, CEF_RESTOREREFRESH, 0, 0);
  end
  else if (Message.SizeType = SIZE_RESTORED) or (Message.SizeType = SIZE_MAXIMIZED) then
  begin
    { 拖拽/最大化时逐帧同步 CEF 视口。只 SetWindowPos 而不调 WasResized 时,
      CEF 的 view 尺寸会滞后于宿主窗口, 新露出的区域没有 damage → 白屏,
      要等鼠标划过产生局部 damage 才逐步补画。WasResized 内部有节流,
      每帧调用由 CEF 自行合并。 }
    if FTabs <> nil then
      for I := 0 to FTabs.Tabs.Count - 1 do
      begin
        Chromium := TChromium(FTabs.Tabs[I].Data);
        if (Chromium <> nil) and Chromium.Initialized then
          Chromium.WasResized;
      end;
    { 尺寸稳定后再补一次完整刷新（合成器出帧异步, 结束瞬间可能还没跟上） }
    if FResizeTimer <> nil then
    begin
      FResizeTimer.Enabled := False;
      FResizeTimer.Enabled := True;
    end;
  end;

  { 窗口状态一变, 最大化按钮的图标就要跟着切换（□ / ▣）; WM_SIZE 覆盖所有路径:
    点自身按钮、拖到屏幕边缘、双击标题栏、以及最小化后恢复 }
  if Assigned(FBtnMax) then
    FBtnMax.UpdateGlyph;
end;

{ WM_MOVE: 通知 CEF 重建渲染表面（跨屏拖动后白屏的修复） }
procedure TBrowserForm.WMMove(var Message: TMessage);
var
  I: Integer;
  Chromium: TChromium;
begin
  inherited;
  { 跨屏拖动（尤其到 DPI 不同的显示器）后, CEF compositor 绑定的 swap chain 仍指向
    原显示器, 不通知就会白屏。NotifyMoveOrResizeStarted 让 CEF 重新检查显示器并
    重建渲染表面 —— Chrome 自身也是在 WM_MOVE 时调这个。轻量, CEF 内部会合并。 }
  if FTabs = nil then Exit;
  for I := 0 to FTabs.Tabs.Count - 1 do
  begin
    Chromium := TChromium(FTabs.Tabs[I].Data);
    if (Chromium <> nil) and Chromium.Initialized then
    begin
      Chromium.WasHidden(False); // 关键: 通知 CEF 已可见, 恢复出帧
      Chromium.NotifyMoveOrResizeStarted;
      Chromium.Invalidate(PET_VIEW);  // 兜底重画
    end;
  end;
end;

{ WM_DPICHANGED: 跨到不同 DPI 的显示器后显式同步 CEF 原生子窗口尺寸 }
procedure TBrowserForm.WMDpiChanged(var Message: TMessage);
var
  I: Integer;
  Chromium: TChromium;
  WinParent: TCEFWindowParent;
begin
  inherited;
  { 跨到不同 DPI 的显示器: VCL 已按新 DPI 缩放控件, 但 CEF 原生子窗口(HWINDOW)
    尺寸还是旧的 → 必须显式 UpdateSize 同步, 否则渲染区错位/白屏。 }
  if FTabs = nil then Exit;
  for I := 0 to FTabs.Tabs.Count - 1 do
  begin
    Chromium := TChromium(FTabs.Tabs[I].Data);
    if (Chromium = nil) or (Chromium.Tag = 0) or not Chromium.Initialized then Continue;
    WinParent := TCEFWindowParent(Chromium.Tag);
    if WinParent <> nil then
      WinParent.UpdateSize;
    Chromium.NotifyMoveOrResizeStarted;
    Chromium.Invalidate(PET_VIEW);
  end;
end;

{ WM_EXITSIZEMOVE: 拖拽/缩放结束, 补一次完整刷新确保最终位置渲染正常 }
procedure TBrowserForm.WMExitSizeMove(var Message: TMessage);
var
  I: Integer;
  Chromium: TChromium;
  WinParent: TCEFWindowParent;
begin
  inherited;
  { 快速来回拖拽时 WM_MOVE 狂发, CEF compositor 的 swap chain 重建是异步的,
    偶尔某一帧重建未完成窗口又移走, 最终落点 compositor 状态不一致 → 白屏。
    拖拽结束(WM_EXITSIZEMOVE)补一次完整刷新, 确保最终位置渲染正常。 }
  if FTabs = nil then Exit;
  for I := 0 to FTabs.Tabs.Count - 1 do
  begin
    Chromium := TChromium(FTabs.Tabs[I].Data);
    if (Chromium = nil) or (Chromium.Tag = 0) or not Chromium.Initialized then Continue;
    WinParent := TCEFWindowParent(Chromium.Tag);
    if WinParent <> nil then
      WinParent.UpdateSize;
    Chromium.WasResized;
    Chromium.NotifyMoveOrResizeStarted;
    Chromium.Invalidate(PET_VIEW);
  end;

  { 合成器出帧是异步的: 结束瞬间的刷新可能还赶不上新视口,
    再延迟一拍补一次, 避免"鼠标划过才逐步渲染"的白屏残留 }
  if FResizeTimer <> nil then
  begin
    FResizeTimer.Enabled := False;
    FResizeTimer.Enabled := True;
  end;
end;

{ WM_ENTERSIZEMOVE: 拖拽/缩放开始, 通知 CEF 进入交互式 resize（由它自行节流渲染） }
procedure TBrowserForm.WMEnterSizeMove(var Message: TMessage);
var
  I: Integer;
  Chromium: TChromium;
begin
  inherited;
  if FTabs = nil then Exit;
  for I := 0 to FTabs.Tabs.Count - 1 do
  begin
    Chromium := TChromium(FTabs.Tabs[I].Data);
    if (Chromium <> nil) and Chromium.Initialized then
      Chromium.NotifyMoveOrResizeStarted;
  end;
end;

{ FResizeTimer 落点: 尺寸稳定后延迟补一次完整页面刷新（合成器出帧是异步的） }
procedure TBrowserForm.ResizeSettledTick(Sender: TObject);
begin
  if FResizeTimer <> nil then
    FResizeTimer.Enabled := False;
  RefreshPageSurfaces;
end;

{ WM_NCHITTEST: 正常状态补窗口上边缘可调大小; 标签条空白区当标题栏
  （系统原生接管拖动/双击最大化） }
procedure TBrowserForm.WMNCHitTest(var Message: TWMNCHitTest);
var
  P, TP: TPoint;
  Idx: Integer;
  Edge: Integer;
begin
  inherited;
  P := ScreenToClient(Point(Message.XPos, Message.YPos));
  // 最大化时系统已处理边缘; 仅在正常状态补充边缘可调大小
  if (Message.Result = htClient) and (WindowState = wsNormal) then
  begin
    Edge := 4;
    if P.Y < Edge then
      Message.Result := htTop
    else if P.Y < Edge * 2 then
    begin
      if P.X < Edge then
        Message.Result := htTopLeft
      else if P.X >= ClientWidth - Edge then
        Message.Result := htTopRight;
    end;
  end;
  // 标签条 = 标题栏: 标签条在空白区返回 HTTRANSPARENT 把命中交给本窗体,
  // 这里给出 htCaption, 系统随之用 WM_NCLBUTTONDOWN 拖动窗口、
  // WM_NCLBUTTONDBLCLK 切换最大化（落到标签/+/箭头上的由标签条自己处理）
  if (Message.Result = htClient) and (FTabs <> nil) and
     (P.Y >= 0) and (P.Y < FTabs.Height) and (P.X >= 0) and (P.X <= ClientWidth) then
  begin
    TP := FTabs.ScreenToClient(Point(Message.XPos, Message.YPos));
    if FTabs.HitKindAt(TP.X, TP.Y, Idx) = hkNone then
      Message.Result := htCaption;
  end;
end;

{ ---- 窗体 ----------------------------------------------------------------- }

{ 窗体构造: 建字典/定时器/标签条/工具栏/书签栏/主菜单/窗口控制按钮/页面容器/
  状态面板/查找条, 并从 SQLite 恢复下载记录（各段细节见体内注释） }
constructor TBrowserForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  Logger.LogDir := ExtractFilePath(ParamStr(0)) + 'Logs\';
  Logger.MinLevel := llDebug;
  Logger.Info('飞花浏览器 启动');

  { madExcept 已 hook Application.OnException, 会弹崩溃对话框 + 完整调用栈;
    此处不再覆盖, 否则 madExcept 的兜底失效 }

  FPendingCreate := TList<TFHChromePage>.Create;
  FChromiumSeq := 0;
  FURLs := TDictionary<TChromium, string>.Create;
  FIconURLs := TDictionary<TChromium, string>.Create;
  FFavIconCache := TDictionary<TChromium, TIcon>.Create;
  FLoadingTabs := TList<TChromium>.Create;
  FLoadingFrame := 0;
  FPendingPopupUrls := TStringList.Create;
  FPopupTabs := TList<TChromium>.Create;
  FDevToolsHosts := TDictionary<TChromium, TCEFWindowParent>.Create;
  FDevToolsSplitters := TDictionary<TChromium, TSplitter>.Create;
  FMenuCmdNewTab := -1;          // -1 = 尚未从 CEF 菜单里探测到
  FMenuCmdNewWindow := -1;
  FCanClose := False;

  { F12 在页面里按下时走到 CEF 那边（见 ChromiumPreKeyEvent）; 焦点在工具栏/地址栏
    时要能先被窗体看到 —— KeyPreview 是前提 }
  KeyPreview := True;
  OnKeyDown := FormKeyDown;

  FRetryTimer := TTimer.Create(Self);
  FRetryTimer.Enabled := False;
  FRetryTimer.Interval := 300;
  FRetryTimer.OnTimer := TimerTick;

  { 空白新标签页焦点兜底定时器: 150ms 轮询, 见 FocusAddrRetryTick }
  FFocusAddrTimer := TTimer.Create(Self);
  FFocusAddrTimer.Enabled := False;
  FFocusAddrTimer.Interval := 150;
  FFocusAddrTimer.OnTimer := FocusAddrRetryTick;

  // 标签条（alTop, 占用标题栏位置——最顶部）
  // 先创建, 再把 pnlAddressBar BringToFront 让它排在 FTabs 之后,
  // 这样 alTop 排列: FTabs 在最上, pnlAddressBar 在其下
  FTabs := TFHChromeTabs.Create(Self);
  FTabs.Parent := Self;
  FTabs.Align := alTop;
  // 高度不再在这里指定: 组件构造时按 C_FH_BarHeight(=41, Chrome 159 TAB_STRIP_HEIGHT)
  // 自行换算; 此处若覆盖写死旧值会把标签条顶高（150% 下 75px vs Chrome 62px）
  FTabs.OnNewButtonClick := DoNewTab;
  FTabs.OnTabClosing := DoTabClosing;
  { 右键菜单的浏览器动作（必须挂在 FHost.ChromeTabs := FTabs 之前: 容器接管时会
    把已有处理器保存下来做链式转发, NFR-7; 挂晚了会被 Hook 覆盖掉） }
  FTabs.OnTabNewToRight := DoTabNewToRight;
  FTabs.OnTabReload := DoTabReload;
  FTabs.OnTabDuplicate := DoTabDuplicate;
  // 标签条空白区当标题栏: 组件把空白区的命中测试穿透到本窗体（HTTRANSPARENT）,
  // 本窗体在 WMNCHitTest 里给出 htCaption, 由系统原生接管拖动/双击最大化
  FTabs.CaptionArea := True;
  // 配色不再覆盖: 组件默认浅色主题已对齐 Chrome 取色（条底 #D3E3FD + 纯白激活）

  // 工具栏: 白底无边框, 与页面融为一体（原 clBtnFace 灰底是"两截式"观感主因）
  pnlAddressBar.BevelOuter := bvNone;
  pnlAddressBar.ParentBackground := False;
  pnlAddressBar.Color := clWhite;
  // 新版 Chrome（Supermium 144 / Chromium 138+）工具栏行高 =
  //   LOCATION_BAR_HEIGHT(34) + TOOLBAR_INTERIOR_MARGIN VH(6,5) 的上下 6px = 46
  // 下边框 1px 与旧版一样额外占一行
  pnlAddressBar.Height := FTabs.ScalePx(46) + Max(1, FTabs.ScalePx(1));

  // 工具栏下边框: 1px 灰线把白工具栏和页面分开（地址栏描边同色 #CACED4）
  // 用对齐的子面板实现: 工具栏里的按钮/地址栏都是非对齐控件, 不受这 1px 影响
  FToolbarLine := TPanel.Create(Self);
  FToolbarLine.Parent := pnlAddressBar;
  FToolbarLine.BevelOuter := bvNone;
  FToolbarLine.ParentBackground := False;
  FToolbarLine.Color := TColor($D4CECA);      // #CACED4
  FToolbarLine.Align := alBottom;
  FToolbarLine.Height := Max(1, FTabs.ScalePx(1));
  FToolbarLine.FullRepaint := False;
  FToolbarLine.Caption := '';

  pnlAddressBar.BringToFront;

  // 导航按钮 + 地址栏（依赖 FTabs.ScalePx 与工具栏高度, 必须在其后创建）
  CreateNavButtons;

  { 书签栏: 工具栏下方一条（Chrome 同位）。VCL 的 alTop 按 Top 值升序排列
    （Vcl.Controls DoAlign 的 InsertBefore 用 ControlTop 比较）, 显式给一个
    比 pnlAddressBar 大的 Top 让它排在 工具栏下 / 页面容器(alClient) 上;
    切换 Visible 时 VCL 自动重排, 页面区随之伸缩 }
  FBookmarkBar := TFHBookmarkBar.Create(Self);
  FBookmarkBar.Parent := Self;
  FBookmarkBar.Align := alTop;
  FBookmarkBar.Top := pnlAddressBar.Top + pnlAddressBar.Height + 10;
  FBookmarkBar.Height := FTabs.ScalePx(34);
  FBookmarkBar.Visible := False;   { 初始隐藏; 首个标签建立后 SyncBookmarkBar
    自动定（启动页=网页→隐藏, 新建空白标签→显示） }
  FBookmarkBar.OnOpen := OpenHistoryUrl;         // 单击 = 当前标签页打开（同历史窗口）
  FBookmarkBar.OnOpenNewTab := OpenHistoryUrlNewTab;
  RegisterBookmarkBar(FBookmarkBar);             { 书签增删改后自动 Reload }
  RegisterBookmarksChanged(DoBookmarksChanged);  { 同上 → 刷地址栏星标态 }

  { ⋮ 菜单同样依赖 FTabs.ScaleFactor 做 DPI 换算, 所以排在 FTabs 之后创建
    （放在最前面会读到 nil 的 FTabs 字段 → AV） }
  CreateMainMenu;

  // 窗口控制按钮（挂标签条右侧, 满条高）
  CreateCaptionButtons;
  FBtnMin.Height := FTabs.Height;
  FBtnMax.Height := FTabs.Height;
  FBtnClose.Height := FTabs.Height;
  FTabs.RightReserved := FTabs.ScalePx(46) * 3;  // 避让三个控制按钮

  // 页面容器
  FHost := TFHChromePageHost.Create(Self);
  FHost.Parent := Self;
  FHost.Align := alClient;
  FHost.OnPageChanged := DoPageChanged;
  { KeepPagesOnClose: 关闭的 Page 先藏进隐藏池（无 DestroyWindow）, 由
    CEF_FREEPAGE 延迟销毁 —— 关闭链路的激活切换/地址栏刷新不被
    DestroyWindow 失败打断（详见 BrowserDestroyMsg / FreePageMsg） }
  FHost.KeepPagesOnClose := True;
  FHost.ChromeTabs := FTabs;

  // 启动兜底定时器: 保证"双击程序一定能出来一个首页标签", 不受 CEF 上下文
  // 就绪时机（早于/晚于 FormShow）影响
  FEnsureHomeTimer := TTimer.Create(Self);
  FEnsureHomeTimer.Enabled := False;
  FEnsureHomeTimer.Interval := 300;
  FEnsureHomeTimer.OnTimer := EnsureHomeTick;

  { loading spinner 动画定时器: 仅在有标签正在加载时启用, 80ms 一帧 }
  FLoadingTimer := TTimer.Create(Self);
  FLoadingTimer.Enabled := False;
  FLoadingTimer.Interval := 80;
  FLoadingTimer.OnTimer := LoadingTimerTick;

  { 拖拽/缩放结束后的延迟补帧: 150ms 让 CEF 合成器完成上一帧 }
  FResizeTimer := TTimer.Create(Self);
  FResizeTimer.Enabled := False;
  FResizeTimer.Interval := 150;
  FResizeTimer.OnTimer := ResizeSettledTick;

  { 链接悬停提示面板: 浮在页面区左下角, 显示鼠标悬停链接的 URL。
    固定挂 FHost（Owner=Self; 若动态挂 Page 则 Owner/Parent 跨树——
    Page 释放时连坐销毁 FStatusPanel 句柄且留悬垂 FParent, 退出期
    EInvalidPointer 实测教训; "Parent:=nil 断开"也会撞 CEF 收尾时间窗,
    SetParent(nil)→RemoveControl→DestroyHandle 连 FStatusPanel 句柄
    都销毁失败(5)）。切页时由 UpdateAddressBar 清空显示 }
  FStatusPanel := TPanel.Create(Self);
  FStatusPanel.Parent := FHost;
  FStatusPanel.BevelOuter := bvNone;
  FStatusPanel.BevelKind := bkFlat;
  FStatusPanel.Color := clWhite;
  FStatusPanel.ParentBackground := False;
  FStatusPanel.ParentFont := False;
  FStatusPanel.Font.Name := 'Microsoft YaHei UI';  // 含中英文字形, 避免 Segoe UI 中文回退异常
  FStatusPanel.Font.Height := -FTabs.ScalePx(12); // 12 DIP; 负值=按像素定字号, 必须随 DPI 换算
  FStatusPanel.Font.Color := TColor($43403C);   // #3C4043
  FStatusPanel.Alignment := taLeftJustify;
  FStatusPanel.Padding.Left := FTabs.ScalePx(8);
  FStatusPanel.Padding.Right := FTabs.ScalePx(8);
  FStatusPanel.Height := FTabs.ScalePx(24);
  FStatusPanel.Visible := False;

  { 页面内查找条: 与状态栏一样固定挂 FHost（不随 Page 释放）, 浮在页面右上角 }
  FFindBar := TFHFindBar.Create(Self);
  FFindBar.Parent := FHost;
  FFindBar.Anchors := [akTop, akRight];
  FFindBar.Visible := False;
  FFindBar.OnSearch := DoFindSearch;
  FFindBar.OnFindNext := DoFindNext;
  FFindBar.OnFindPrev := DoFindPrev;
  FFindBar.OnClose := DoFindClose;

  { 重启恢复: 从 UserData\History.db 载入下载记录（Chrome 同款跨会话保留;
    写侧在下载事件回调, 此前缺加载侧 → 程序重启后下载记录消失） }
  try
    Downloads.LoadFromDb;
  except
    on E: Exception do
      Logger.Error('恢复下载记录失败: %s - %s', [E.ClassName, E.Message]);
  end;
  UpdateDownloadButton;
end;

{ FEnsureHomeTimer 落点: 启动兜底 —— 只要还没有任何标签, 就在 CEF 上下文
  就绪后补建首页（与 FormShow/CEF_INITIALIZED 双保险） }
procedure TBrowserForm.EnsureHomeTick(Sender: TObject);
begin
  { 兜底: 只要还没有任何标签, 就在上下文就绪后补建首页（不会重复创建:
    NewBrowserTab 一进来就 AddPage, 下一 tick 看到 Tabs.Count>0 就停） }
  if FTabs = nil then Exit;
  if FTabs.Tabs.Count > 0 then
  begin
    FEnsureHomeTimer.Enabled := False;
    Exit;
  end;
  if (GlobalCEFApp <> nil) and GlobalCEFApp.GlobalContextInitialized then
    NewBrowserTab(Settings.EffectiveHomepage);
end;

{ 窗体显示: CEF 上下文已就绪则立即建首页标签, 否则等 CEF_INITIALIZED 消息;
  启动兜底定时器常开 }
procedure TBrowserForm.FormShow(Sender: TObject);
begin
  // TabbedBrowser2 同模式: 检查 GlobalContextInitialized
  // True → 立即创建首页; False → 等 OnContextInitialized 回调发 CEF_INITIALIZED
  if (GlobalCEFApp <> nil) and GlobalCEFApp.GlobalContextInitialized then
    NewBrowserTab(Settings.EffectiveHomepage);   // 启动页 = 设置里的浏览器首页
  FEnsureHomeTimer.Enabled := True;
end;

{ 关闭确认: 先走 CEF 两段式关闭所有标签（未初始化的直接强制关）,
  全部标签收完（FCanClose=True）才允许真正收窗 }
procedure TBrowserForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
var
  I: Integer;
  Chromium: TChromium;
  Page: TFHChromePage;
begin
  CanClose := FCanClose;
  if not FCanClose then
  begin
    Logger.Info('FormCloseQuery: 请求关闭 %d 个标签', [FTabs.Tabs.Count]);
    { 倒序: 无浏览器/未初始化的标签没有关闭链路可走（CloseBrowser 被跳过,
      永远等不到 OnBeforeClose → 没有任何事件删掉这个 Tab → 窗体关不掉）,
      直接 ForceCloseTab 走隐藏池+延迟释放; 已初始化的正常发 CloseBrowser }
    for I := FTabs.Tabs.Count - 1 downto 0 do
    begin
      Chromium := ChromiumOfPage(FHost.PageAtTabIndex(I));
      if (Chromium = nil) or not Chromium.Initialized then
      begin
        Page := FHost.PageAtTabIndex(I);
        FTabs.ForceCloseTab(I);
        if Page <> nil then
          PostMessage(Handle, CEF_FREEPAGE, NativeUInt(Page), 0);
      end
      else
        Chromium.CloseBrowser(True);
    end;
    { 全部标签都无需走 CEF 关闭链路时 Count 已 0 —— 在这里直接收窗,
      否则 FCanClose 永远不会被置 True }
    if FTabs.Tabs.Count = 0 then
    begin
      FCanClose := True;
      PostMessage(Handle, WM_CLOSE, 0, 0);
    end;
  end;
end;

{ 窗体析构: 停定时器 → 关 DevTools → 释放字典/favicon 缓存 → 逐个隔离释放
  TChromium → 退出期停损吞异常（窗口/内存由进程回收, 细节见体内注释） }
destructor TBrowserForm.Destroy;
var
  Pair: TPair<TChromium, TCEFWindowParent>;
  FavPair: TPair<TChromium, TIcon>;
  I: Integer;
begin
  { 先停定时器, 避免释放过程中 tick 访问已失效对象 }
  if FLoadingTimer <> nil then FLoadingTimer.Enabled := False;
  if FResizeTimer <> nil then FResizeTimer.Enabled := False;
  if FEnsureHomeTimer <> nil then FEnsureHomeTimer.Enabled := False;
  if FRetryTimer <> nil then FRetryTimer.Enabled := False;
  { 状态面板固定挂 FHost（Owner=Self, 同一棵释放树）, 无跨树顺序问题;
    注意不要在这里 Parent:=nil —— 那会触发 RemoveControl→DestroyHandle,
    CEF 收尾时间窗内销毁句柄会撞 OS error 5 }
  { 关掉所有还开着的 DevTools（否则 CEF 浏览器销毁时 DevTools 悬垂） }
  for Pair in FDevToolsHosts do
    if Pair.Key.Initialized then
      Pair.Key.CloseDevTools(Pair.Value);
  FPendingCreate.Free;
  FURLs.Free;
  FIconURLs.Free;
  for FavPair in FFavIconCache do
    FavPair.Value.Free;
  FFavIconCache.Free;
  FLoadingTabs.Free;
  FPendingPopupUrls.Free;
  FPopupTabs.Free;
  FDevToolsSplitters.Free;
  FDevToolsHosts.Free;
  { 退出期逐个释放 TChromium 并记录: DoneApplication 早于 uCEFApplication
    finalization 的 StopChrome, CEF 收尾未完成时, 组件内部 CEF 引用释放
    可能触发二次销毁（实测栈: DoneApplication → DestroyComponents →
    TObject.Free → FreeInstance）。逐个隔离 + 日志既能定位异常实例,
    又保证单个实例异常不中断整个退出流程 }
  for I := Self.ComponentCount - 1 downto 0 do
    if Self.Components[I] is TChromium then
    begin
      Logger.Info('Destroy: 释放 TChromium (index=%d)', [I]);
      try
        Self.Components[I].Free;
      except
        on E: Exception do
          Logger.Error('Destroy: TChromium 释放异常 %s - %s',
            [E.ClassName, E.Message]);
      end;
    end;
  { 退出期停损: 窗口/内存由进程退出统一回收; 吞掉任何异常保证退出流程
    走完（DoneApplication 早于 uCEFApplication finalization 的 CEF shutdown,
    退出期窗口销毁撞上 CEF 未收尾的渲染窗口是预期现象, 由系统回收）;
    记为 Warn 表明预期内、无功能影响; 其它异常类型仍值得排查, 细节写日志 }
  try
    inherited Destroy;
  except
    on E: Exception do
      Logger.Warn('退出期停损(预期内, CEF shutdown 晚于窗口销毁, 窗口由系统回收): %s - %s',
        [E.ClassName, E.Message]);
  end;
end;

end.