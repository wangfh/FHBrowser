unit uFHChromePageHost;

{==============================================================================
  FHChromeTabs 扩展单元 —— 页面容器 TFHChromePageHost
  ----------------------------------------------------------------------------
  对应需求文档 docs/需求文档.md:
    - 第 3.3 节 扩展形态（关联机制/所有权/视觉衔接/Pin 语义）
    - 第 7.2 节 公开 API 草案
    - FP-1 页面数据模型 / FP-2 标签↔页面同步 / FP-3 新建页联动
  约定:
    - 单向依赖: 本单元依赖 uFHChromeTabs; 标签条不知道本单元存在
    - 零 CEF 依赖: 不 uses 任何 uCEF* 单元（文档 14.1; TChromium 只是普通
      TWinControl, 宿主可 Page.InsertControl 挂载）
    - NFR-7 事件不被吞: 容器先同步内部状态, 再链式调用宿主原事件处理器
  已知限制（v1 契约）:
    - 标签增删请经容器 AddPage/或在关联前完成; 宿主绕过容器直接改 Tabs
      后将 ChromeTabs 置 nil 再重挂即可触发 ResyncPages 重同步
    - 宿主在容器挂钩之后修改标签条事件属性会覆盖容器钩子; 重新关联一次
      （nil→tabs）即可刷新（文档 3.3.3 注记）
==============================================================================}

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  Winapi.Windows, Winapi.Messages, Vcl.Controls, Vcl.Forms, Vcl.Graphics,
  uFHChromeTabs;

type
  TFHChromePageHost = class;   // 前置声明

  { ---- TFHChromePage: 单个页面（文档 FP-1） ---------------------------- }
  TFHChromePage = class(TWinControl)
  private
    FPageHost: TFHChromePageHost;   // 容器引用（同单元可互访私有）
    FTab: TFHChromeTab;             // 反向引用: 对象身份关联（文档 3.3.1）
    FFrame: TFrame;                 // 便捷挂载; 所有权归宿主（FP-1）
    function GetCaption: string;
    procedure SetCaption(const Value: string);
    procedure SetFrame(Value: TFrame);
    function GetPageIndex: Integer;
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;
    { ---- Keep/复用支持（同单元友好访问; 文档 FP-1"恢复标签"体验） ---- }
    { BackupCaption: Tab 活着时把标题备份到自有 Caption（Keep 关闭路径,
      OnTabClosing 锚点调用——OnTabClosed 时 Tab 已删, getter 将悬垂） }
    procedure BackupCaption;
    { DetachTab: 断开 FTab（Tab 已删除, 防悬垂指针; 标题已先备份） }
    procedure DetachTab;
    { AttachTab: 复用时挂新 Tab 并还原备份标题（ReuseHiddenPage 调用） }
    procedure AttachTab(ATab: TFHChromeTab);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Tab: 只读反向引用, 由容器在创建时赋值（对象身份关联, 文档 3.3.1） }
    property Tab: TFHChromeTab read FTab;
    { PageIndex: 实时从 Tabs.IndexOf(Tab) 解析, 天然免疫索引错位（3.3.1） }
    property PageIndex: Integer read GetPageIndex;
    property PageHost: TFHChromePageHost read FPageHost;
  published
    { Caption: 读写透传 Tab.Caption（真源在标签）; stored=False 不持久化 }
    property Caption: string read GetCaption write SetCaption stored False;
    { Frame: 赋值自动 Parent+alClient; 页面销毁仅 Parent:=nil 归还宿主 }
    property Frame: TFrame read FFrame write SetFrame;
    property Color default clWhite;   // 默认取 Theme.PageHostColor（容器赋值）
    property OnEnter;
    property OnExit;
  end;

  { ---- 容器事件（文档 6.2） -------------------------------------------- }
  TFHPageEvent = procedure(Sender: TObject; Page: TFHChromePage) of object;
  TFHPageChangedEvent = procedure(Sender: TObject; OldIndex, NewIndex: Integer) of object;

  { ---- TFHChromePageHost: 页面容器（文档 3.3 / FP-2） ------------------ }
  TFHChromePageHost = class(TCustomControl)
  private
    FChromeTabs: TFHChromeTabs;
    FPages: TObjectList<TFHChromePage>;   // 顺序与 Tabs 平行（3.3.3）
    { FHiddenPages: KeepPagesOnClose 关闭时 Extract 的页面（LIFO 复用池）;
      非拥有列表——页面 Owner=容器, 由组件机制统一释放（NFR-3） }
    FHiddenPages: TObjectList<TFHChromePage>;
    { FAbandonedPages: 释放失败被放弃的半析构页（见 AbandonHiddenPage）;
      析构时必须先从 Owner 组件树摘除, 防退出时二次销毁触发 EInvalidPointer }
    FAbandonedPages: TList<TFHChromePage>;
    FActivePageIndex: Integer;
    FAutoAppendPage: Boolean;
    FKeepPagesOnClose: Boolean;
    FMaxHiddenPages: Integer;
    FAppliedColor: TColor;          // 已下发到页面的底色（主题联动用）
    // 宿主原事件处理器快照（链式转发, NFR-7; 见单元头"已知限制"）
    FSaveOnActiveTabChange: TFHTabSwitchEvent;
    FSaveOnTabClosing: TFHTabAllowEvent;
    FSaveOnTabClosed: TFHTabIndexEvent;
    FSaveOnTabMoved: TFHTabMoveEvent;
    FSaveOnNewButtonClick: TNotifyEvent;
    FSaveOnTabPinChanged: TFHTabPinEvent;
    FSaveOnTabsThemeChanged: TNotifyEvent;
    // 容器事件
    FOnPageAdded: TFHPageEvent;
    FOnPageRemoved: TFHPageEvent;
    FOnPageChanged: TFHPageChangedEvent;
    procedure SetChromeTabs(Value: TFHChromeTabs);
    procedure SetAutoAppendPage(Value: Boolean);
    procedure SetKeepPagesOnClose(Value: Boolean);
    procedure SetMaxHiddenPages(Value: Integer);
    // 订阅/退订
    procedure HookTabs;
    procedure UnhookTabs;
    { ResyncPages: 关联后按 Tabs 对齐页面（宿主绕过容器改过 Tabs 的重同步,
      文档 3.3.3 注记: 直接改 Tabs 后重挂 ChromeTabs 即触发） }
    procedure ResyncPages;
    // 同步层（容器先同步, 再链式转发宿主原处理器）
    procedure HandleActiveTabChange(Sender: TObject; OldIndex, NewIndex: Integer);
    procedure HandleTabClosing(Sender: TObject; TabIndex: Integer;
      var AllowClose: Boolean);
    procedure HandleTabClosed(Sender: TObject; TabIndex: Integer);
    procedure HandleTabMoved(Sender: TObject; FromIndex, ToIndex: Integer);
    procedure HandleNewButtonClick(Sender: TObject);
    procedure HandleTabPinChanged(Sender: TObject; TabIndex: Integer;
      Pinned: Boolean);
    procedure HandleTabsThemeChanged(Sender: TObject);
    // 内部
    function CreatePage(ATab: TFHChromeTab): TFHChromePage;
    function EffectivePageHostColor: TColor;
    procedure ApplyThemeColor;
    procedure ResortPagesToTabs;
    function GetHiddenPageCount: Integer;
    procedure DoPageAdded(Page: TFHChromePage);
    procedure DoPageRemoved(Page: TFHChromePage);
    procedure DoPageChanged(OldIndex, NewIndex: Integer);
  protected
    procedure Paint; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { AddPage: Tabs.Add + Pages.Add 原子完成, 新页自动激活（FP-1/FP-3） }
    function AddPage: TFHChromePage; overload;
    { InsertPage(AIndex): 与 AddPage 同语义, 但插在指定位置而不是末尾
      （"在右侧新增标签页"/"复制"用）。AIndex 越界自动夹到 [0, Count]; 负数=末尾。
      注意 Tabs.Insert 不做 Pinned 区重排, 位置由调用方负责算好 }
    function InsertPage(AIndex: Integer): TFHChromePage;
    { AddPage(AControl): 复用宿主已有控件版本（如已建好的 TChromium/TFrame） }
    function AddPage(AControl: TWinControl): TFHChromePage; overload;
    { ReuseHiddenPage: 取回最近隐藏的页面（KeepPagesOnClose 保留的, LIFO）,
      重建对应标签并还原标题、激活——浏览器"恢复标签"体验（FP-1）;
      无隐藏页返回 nil。页上内容控件（如 TChromium）原样保留 }
    function ReuseHiddenPage: TFHChromePage;
    { DropHiddenPage: 从隐藏池摘出页引用（延迟释放成功后调用, 防池留悬垂指针;
      池满时容器对池内页的自动 Free 不再命中已释放对象） }
    procedure DropHiddenPage(Page: TFHChromePage);
    { AbandonHiddenPage: 释放失败（DestroyWindow 抛 EOSError）后放弃销毁——
      页处于半析构态（析构链中断, 内存未归还）, 必须同时从隐藏池与 Owner
      组件树摘除, 否则退出时 TComponent.DestroyComponents 二次销毁它,
      FreeInstance 二次释放内存触发 EInvalidPointer。半析构页的内存泄漏
      由进程退出统一回收 }
    procedure AbandonHiddenPage(Page: TFHChromePage);
    function PageByTab(ATab: TFHChromeTab): TFHChromePage;
    function PageAtTabIndex(TabIndex: Integer): TFHChromePage;
    procedure ShowPage(TabIndex: Integer);
    property Pages: TObjectList<TFHChromePage> read FPages;
    { PageCount: 当前可见页面数（与 Tabs.Count 平行） }
    function PageCount: Integer;
    function IndexOfPage(Page: TFHChromePage): Integer;
    { HiddenPageCount: Keep 关闭后保留待复用的页面数（只读） }
    property HiddenPageCount: Integer read GetHiddenPageCount;
    property ActivePageIndex: Integer read FActivePageIndex;
  published
    property Align default alClient;   // 默认充满剩余客户区（文档 3.3）
    { ChromeTabs: 关联标签条; 赋值订阅事件, 置 nil 退订还原（FP-2） }
    property ChromeTabs: TFHChromeTabs read FChromeTabs write SetChromeTabs;
    property AutoAppendPage: Boolean read FAutoAppendPage write SetAutoAppendPage default True;
    property KeepPagesOnClose: Boolean read FKeepPagesOnClose write SetKeepPagesOnClose default False;
    { MaxHiddenPages: 隐藏页池上限（默认 10）。超限释放最旧页——否则每个关闭的
      标签都把整个 TChromium 常驻内存, 长时间使用只涨不降 }
    property MaxHiddenPages: Integer read FMaxHiddenPages write SetMaxHiddenPages default 10;
    property OnPageAdded: TFHPageEvent read FOnPageAdded write FOnPageAdded;
    property OnPageRemoved: TFHPageEvent read FOnPageRemoved write FOnPageRemoved;
    property OnPageChanged: TFHPageChangedEvent read FOnPageChanged write FOnPageChanged;
  end;


implementation

{ ============================ TFHChromePage ============================== }

constructor TFHChromePage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := clWhite;                 // published default 一致
  ControlStyle := ControlStyle + [csOpaque];
end;

destructor TFHChromePage.Destroy;
begin
  // Frame 所有权归宿主（文档 FP-1/FP-2）: 仅解除父子关系, 不释放
  if FFrame <> nil then
  begin
    FFrame.Parent := nil;
    FFrame := nil;
  end;
  inherited Destroy;
end;

function TFHChromePage.GetCaption: string;
begin
  // 透传: 真源在 Tab.Caption（文档 FP-1）
  if FTab <> nil then
    Result := FTab.Caption
  else
    Result := inherited Caption;
end;

procedure TFHChromePage.SetCaption(const Value: string);
begin
  if FTab <> nil then
    FTab.Caption := Value
  else
    inherited Caption := Value;
end;

procedure TFHChromePage.SetFrame(Value: TFrame);
begin
  if FFrame = Value then Exit;
  if FFrame <> nil then
    FFrame.Parent := nil;
  FFrame := Value;
  if FFrame <> nil then
  begin
    FFrame.Parent := Self;
    FFrame.Align := alClient;
  end;
end;

function TFHChromePage.GetPageIndex: Integer;
begin
  // IndexOf 实时解析: 拖拽/增删后天然免疫索引错位（文档 3.3.1）
  if (FTab <> nil) and (FPageHost <> nil) and (FPageHost.FChromeTabs <> nil) then
    Result := FPageHost.FChromeTabs.Tabs.IndexOf(FTab)
  else
    Result := -1;
end;

procedure TFHChromePage.WMEraseBkgnd(var Message: TWMEraseBkgnd);
var
  BkBrush: HBRUSH;
begin
  // 页面底色（文档 4.4 PageHostColor; TWinControl 默认不画背景故自绘）
  BkBrush := CreateSolidBrush(ColorToRGB(Color));
  FillRect(Message.DC, ClientRect, BkBrush);
  DeleteObject(BkBrush);
  Message.Result := 1;
end;

procedure TFHChromePage.BackupCaption;
begin
  // Tab 活着时备份标题到自有 Caption（GetCaption 在 FTab=nil 时回退读它）
  // ——必须赶在 Tab 删除前（OnTabClosing 锚点）, OnTabClosed 时已悬垂
  if FTab <> nil then
    inherited Caption := FTab.Caption;
end;

procedure TFHChromePage.DetachTab;
begin
  // 断开已删除 Tab 的引用（防悬垂指针）; 标题已由 BackupCaption 备份
  FTab := nil;
end;

procedure TFHChromePage.AttachTab(ATab: TFHChromeTab);
begin
  // 复用: 挂新 Tab 并还原备份标题（ReuseHiddenPage 场景）
  FTab := ATab;
  if (FTab <> nil) and (inherited Caption <> '') then
    FTab.Caption := inherited Caption;
end;

{ =========================== TFHChromePageHost =========================== }

constructor TFHChromePageHost.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FPages := TObjectList<TFHChromePage>.Create(True);   // 容器拥有页面（FP-1）
  // 隐藏池: 非拥有（页面 Owner=容器, 组件机制统一释放, NFR-3）——
  // 若用拥有列表会与 Owner 机制双重释放 AV
  FHiddenPages := TObjectList<TFHChromePage>.Create(False);
  FAbandonedPages := TList<TFHChromePage>.Create;
  FActivePageIndex := -1;
  FAutoAppendPage := True;
  FKeepPagesOnClose := False;
  FMaxHiddenPages := 10;
  FAppliedColor := clNone;   // 未下发, 首次 ApplyThemeColor 必定生效
  Align := alClient;
  StyleElements := [];
  Width := 400;
  Height := 300;
end;

destructor TFHChromePageHost.Destroy;
var
  I: Integer;
begin
  UnhookTabs;   // 还原宿主原事件处理器（NFR-7）
  { 已放弃的半析构页: 先从 Owner 组件树摘除再进 inherited ——
    否则 DestroyComponents 会二次销毁它们（FreeInstance 二次释放内存） }
  for I := 0 to FAbandonedPages.Count - 1 do
    RemoveComponent(FAbandonedPages[I]);
  FAbandonedPages.Free;
  { 退出路径: DoneApplication 早于 uCEFApplication finalization 的
    StopChrome, CEF 对渲染窗口的收尾未完成 —— WinParent 死时其跨线程的
    CEF 渲染窗口被系统转挂到 Page 的子窗口链, 收尾前 DestroyWindow(Page)
    返回 ERROR_ACCESS_DENIED(5)（实测栈: TFHChromePageHost.Destroy →
    DestroyComponents → Page.Destroy → DestroyWindowHandle）。
    进程即将退出, 窗口/内存由 OS 统一回收 —— 把剩余页从 Owner 组件树
    摘除、列表不再拥有它们, 跳过 VCL 析构（不调 DestroyWindow(Page)）;
    Page 的 HWND 由随后容器自己的 DestroyWindow 连坐销毁（系统行为,
    不经 VCL RemoveControl, 不抛异常） }
  for I := 0 to FHiddenPages.Count - 1 do
    RemoveComponent(FHiddenPages[I]);   // 池里重试中/未处理的页同样摘除
  FHiddenPages.Free;   // 非拥有列表: 仅清引用
  FPages.OwnsObjects := False;   // 列表不能 Free 目标页, 由 OS 回收
  for I := 0 to FPages.Count - 1 do
    RemoveComponent(FPages[I]);
  FPages.Free;   // 释放全部页面（Frame 已在页面析构中归还宿主）
  { 退出期异常不在此吞: 冒泡到 TBrowserForm.Destroy 统一停损并记日志
    （见宿主 Destroy 的 TChromium 逐个释放与 inherited 停损段） }
  inherited Destroy;
end;

procedure TFHChromePageHost.SetChromeTabs(Value: TFHChromeTabs);
begin
  if FChromeTabs = Value then Exit;
  UnhookTabs;
  FChromeTabs := Value;
  if FChromeTabs <> nil then
  begin
    // 没有 FreeNotification 就收不到 Notification(opRemove):
    // 标签条先于容器释放时 FChromeTabs 悬垂, 下一次访问即 AV（原通知是死代码）
    FChromeTabs.FreeNotification(Self);
    HookTabs;
    ResyncPages;   // 关联即对齐（S6: 宿主先建 Tabs 再挂容器的场景）
  end;
  FAppliedColor := clNone;   // 关联变了 → 底色重新下发
  ApplyThemeColor;
  Invalidate;
end;

procedure TFHChromePageHost.SetAutoAppendPage(Value: Boolean);
begin
  FAutoAppendPage := Value;
end;

procedure TFHChromePageHost.SetKeepPagesOnClose(Value: Boolean);
begin
  FKeepPagesOnClose := Value;
end;

procedure TFHChromePageHost.SetMaxHiddenPages(Value: Integer);
var
  Page: TFHChromePage;
begin
  if Value < 0 then
    Value := 0;
  FMaxHiddenPages := Value;
  while FHiddenPages.Count > FMaxHiddenPages do
  begin
    Page := FHiddenPages[0];
    FHiddenPages.Delete(0);
    Page.Free;   // 页面是容器 owned component, Free 后自动从 Owner 列表移除
  end;
end;

procedure TFHChromePageHost.HookTabs;
begin
  // 保存宿主已注册处理器 → 容器占用事件槽位（文档 3.3.3 / NFR-7）
  FSaveOnActiveTabChange := FChromeTabs.OnActiveTabChange;
  FSaveOnTabClosing := FChromeTabs.OnTabClosing;
  FSaveOnTabClosed := FChromeTabs.OnTabClosed;
  FSaveOnTabMoved := FChromeTabs.OnTabMoved;
  FSaveOnNewButtonClick := FChromeTabs.OnNewButtonClick;
  FSaveOnTabPinChanged := FChromeTabs.OnTabPinChanged;
  FSaveOnTabsThemeChanged := FChromeTabs.OnThemeChanged;
  FChromeTabs.OnActiveTabChange := HandleActiveTabChange;
  FChromeTabs.OnTabClosing := HandleTabClosing;   // Keep 备份锚点（FP-1）
  FChromeTabs.OnTabClosed := HandleTabClosed;
  FChromeTabs.OnTabMoved := HandleTabMoved;
  FChromeTabs.OnNewButtonClick := HandleNewButtonClick;
  // Pin 会让标签在集合里重排 → 必须由本容器同步页面顺序（原来靠 Tabs.Move
  // 顺带发出的 OnTabMoved, 属副作用依赖）
  FChromeTabs.OnTabPinChanged := HandleTabPinChanged;
  FChromeTabs.OnThemeChanged := HandleTabsThemeChanged;
end;

procedure TFHChromePageHost.UnhookTabs;
begin
  if FChromeTabs = nil then Exit;
  // 还原宿主原处理器（见单元头"已知限制": 挂钩后宿主直接改事件会失效）
  FChromeTabs.OnActiveTabChange := FSaveOnActiveTabChange;
  FChromeTabs.OnTabClosing := FSaveOnTabClosing;
  FChromeTabs.OnTabClosed := FSaveOnTabClosed;
  FChromeTabs.OnTabMoved := FSaveOnTabMoved;
  FChromeTabs.OnNewButtonClick := FSaveOnNewButtonClick;
  FChromeTabs.OnTabPinChanged := FSaveOnTabPinChanged;
  FChromeTabs.OnThemeChanged := FSaveOnTabsThemeChanged;
  FSaveOnActiveTabChange := nil;
  FSaveOnTabClosing := nil;
  FSaveOnTabClosed := nil;
  FSaveOnTabMoved := nil;
  FSaveOnNewButtonClick := nil;
  FSaveOnTabPinChanged := nil;
  FSaveOnTabsThemeChanged := nil;
end;

procedure TFHChromePageHost.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  // 标签条被释放时安全解关联（NFR-4）
  if (Operation = opRemove) and (AComponent = FChromeTabs) then
  begin
    UnhookTabs;
    FChromeTabs := nil;
  end;
end;

procedure TFHChromePageHost.ResyncPages;
var
  I: Integer;
  Page: TFHChromePage;
begin
  if FChromeTabs = nil then Exit;
  // 1) 删孤儿页（对应 Tab 已被宿主直接从 Tabs 删除）
  for I := FPages.Count - 1 downto 0 do
    if FChromeTabs.Tabs.IndexOf(FPages[I].FTab) < 0 then
      FPages.Delete(I);
  // 2) 补缺失页（宿主先建 Tabs 后挂容器的场景; 保持与 Tabs 平行顺序）
  for I := 0 to FChromeTabs.Tabs.Count - 1 do
    if PageByTab(FChromeTabs.Tabs[I]) = nil then
    begin
      Page := CreatePage(FChromeTabs.Tabs[I]);
      FPages.Insert(I, Page);
    end;
  // 3) 显示页与激活标签对齐
  ShowPage(FChromeTabs.ActiveTabIndex);
end;

{ ---- 同步层（容器先同步, 再链式转发宿主原处理器, NFR-7） ---------------- }

procedure TFHChromePageHost.HandleActiveTabChange(Sender: TObject;
  OldIndex, NewIndex: Integer);
begin
  ShowPage(NewIndex);   // 文档 3.3.3: 激活切换 → 显示对应页
  if Assigned(FSaveOnActiveTabChange) then
    FSaveOnActiveTabChange(Sender, OldIndex, NewIndex);
end;

procedure TFHChromePageHost.HandleTabClosing(Sender: TObject; TabIndex: Integer;
  var AllowClose: Boolean);
begin
  // Keep 备份锚点（FP-1）: 趁 Tab 活着把标题存入页面自有副本——
  // OnTabClosed 时 Tab 已删, 页面 Caption getter 将悬垂。普通关闭与 CEF
  // 两段式关闭（阶段一也走 OnTabClosing）均覆盖; 唯宿主直接 ForceCloseTab
  // 无前置 Closing → 复用时标题降级为"新标签页"（注释在 ReuseHiddenPage）
  if FKeepPagesOnClose and (TabIndex >= 0) and (TabIndex < FPages.Count) then
    FPages[TabIndex].BackupCaption;
  if Assigned(FSaveOnTabClosing) then
    FSaveOnTabClosing(Sender, TabIndex, AllowClose);
end;

procedure TFHChromePageHost.HandleTabClosed(Sender: TObject; TabIndex: Integer);
var
  Page, Drop: TFHChromePage;
begin
  // TabIndex = 删除前索引; Pages 与 Tabs 平行同步（文档 3.3.3）
  if (TabIndex >= 0) and (TabIndex < FPages.Count) then
  begin
    Page := FPages[TabIndex];
    DoPageRemoved(Page);   // 删除前触发（文档 6.2, 含 Keep 的隐藏）
    if FKeepPagesOnClose then
    begin
      Page.Visible := False;
      Page.DetachTab;   // 断开已删 Tab 引用（防悬垂; 标题已在 Closing 备份）
      FPages.Extract(Page);
      FHiddenPages.Add(Page);   // LIFO 复用池（"恢复标签", FP-1）
      // 池上限: 超限释放最旧页（连同其 CEF 内容）——否则 Keep 模式下内存只涨不降
      while FHiddenPages.Count > FMaxHiddenPages do
      begin
        Drop := FHiddenPages[0];
        FHiddenPages.Delete(0);
        Drop.Free;
      end;
    end
    else
      FPages.Delete(TabIndex);
  end;
  if Assigned(FSaveOnTabClosed) then
    FSaveOnTabClosed(Sender, TabIndex);
end;

procedure TFHChromePageHost.HandleTabMoved(Sender: TObject; FromIndex,
  ToIndex: Integer);
begin
  // 拖拽排序 → 页面同步平移, 保持与 Tabs 平行（文档 3.3.3）
  if (FromIndex >= 0) and (FromIndex < FPages.Count) then
    FPages.Move(FromIndex, ToIndex);
  // 被移动的可能是激活标签 → 激活索引已变, 重新对齐可见页
  if FChromeTabs <> nil then
    ShowPage(FChromeTabs.ActiveTabIndex);
  if Assigned(FSaveOnTabMoved) then
    FSaveOnTabMoved(Sender, FromIndex, ToIndex);
end;

procedure TFHChromePageHost.HandleNewButtonClick(Sender: TObject);
begin
  // FP-3 宿主注册优先: 宿主注册了 OnNewButtonClick 则自处理, 容器不代劳
  if Assigned(FSaveOnNewButtonClick) then
    FSaveOnNewButtonClick(Sender)
  else if FAutoAppendPage then
    AddPage;
end;

procedure TFHChromePageHost.HandleTabPinChanged(Sender: TObject;
  TabIndex: Integer; Pinned: Boolean);
begin
  // Pin/Unpin 会重排标签集合 → 按 Tab 对象身份重建页面顺序, 并重新对齐可见页
  ResortPagesToTabs;
  if FChromeTabs <> nil then
    ShowPage(FChromeTabs.ActiveTabIndex);
  if Assigned(FSaveOnTabPinChanged) then
    FSaveOnTabPinChanged(Sender, TabIndex, Pinned);
end;

procedure TFHChromePageHost.HandleTabsThemeChanged(Sender: TObject);
begin
  // 主题 token 变更 → 页面底色跟随（否则深色主题下条/页两套配色）
  FAppliedColor := clNone;
  ApplyThemeColor;
end;

{ Pin/Unpin 重排标签集合后, 按 Tab 对象身份重建 FPages 顺序（保持与 Tabs 平行）;
  数量不一致或有孤立页时不动, 交给 ResyncPages 全量重同步 }
procedure TFHChromePageHost.ResortPagesToTabs;
var
  Ordered: TArray<TFHChromePage>;
  I, N: Integer;
begin
  if FChromeTabs = nil then Exit;
  N := FChromeTabs.Tabs.Count;
  if (N <> FPages.Count) or (N = 0) then Exit;   // 数量不一致交给 ResyncPages
  SetLength(Ordered, N);
  for I := 0 to N - 1 do
  begin
    Ordered[I] := PageByTab(FChromeTabs.Tabs[I]);
    if Ordered[I] = nil then Exit;   // 有孤立页: 不做有风险的重排
  end;
  FPages.OwnsObjects := False;   // 仅重排顺序, 不能触发释放
  try
    FPages.Clear;
    for I := 0 to N - 1 do
      FPages.Add(Ordered[I]);
  finally
    FPages.OwnsObjects := True;
  end;
end;

procedure TFHChromePageHost.ApplyThemeColor;
var
  I: Integer;
  C: TColor;
begin
  C := EffectivePageHostColor;
  if C = FAppliedColor then Exit;
  FAppliedColor := C;
  for I := 0 to FPages.Count - 1 do
    FPages[I].Color := C;
  for I := 0 to FHiddenPages.Count - 1 do
    FHiddenPages[I].Color := C;
  Invalidate;
end;

{ ---- 页面管理 ------------------------------------------------------------ }

function TFHChromePageHost.CreatePage(ATab: TFHChromeTab): TFHChromePage;
begin
  Result := TFHChromePage.Create(Self);
  Result.FPageHost := Self;
  Result.FTab := ATab;   // 对象身份关联（文档 3.3.1）
  Result.Color := EffectivePageHostColor;
  Result.Parent := Self;
  Result.Align := alClient;   // 充满容器——否则尺寸为默认值, CEF 渲染窗口创建在错误尺寸 HWND 上→白屏
  Result.Visible := False;
end;

function TFHChromePageHost.InsertPage(AIndex: Integer): TFHChromePage;
var
  Tab: TFHChromeTab;
  Idx: Integer;
begin
  if FChromeTabs = nil then
    raise EInvalidOperation.Create(
      'TFHChromePageHost: 未关联 ChromeTabs（ChromeTabs=nil）');   // 验收 T18
  Idx := AIndex;
  if Idx < 0 then
    Idx := FChromeTabs.Tabs.Count;         // 负数视为追加到末尾
  if Idx > FChromeTabs.Tabs.Count then
    Idx := FChromeTabs.Tabs.Count;
  Tab := FChromeTabs.Tabs.Insert(Idx);
  // 默认标题（Chrome 行为: 新标签页; 宿主可随后改写, 如 CEF OnTitleChange）
  Tab.Caption := '新标签页';
  Result := CreatePage(Tab);
  // Pages 与 Tabs 必须同序平行（FPages 用下标访问, 见 PageAtTabIndex）
  FPages.Insert(Idx, Result);
  // 新页自动激活（文档 FP-3, Chrome 行为）; 触发 HandleActiveTabChange→ShowPage。
  // 注意 setter 对"值没变"不触发事件: 往当前活动索引处插入时（新标签占据了
  // 原活动位置, 原活动标签整体后移）, Idx = 原 ActiveTabIndex → 不会走事件,
  // 新页会停留在 Visible=False。这里补一次 ShowPage 兜底（幂等）
  FChromeTabs.ActiveTabIndex := Idx;
  ShowPage(Idx);
  DoPageAdded(Result);
end;

function TFHChromePageHost.AddPage: TFHChromePage;
begin
  Result := InsertPage(-1);   // 末尾追加
end;

function TFHChromePageHost.AddPage(AControl: TWinControl): TFHChromePage;
begin
  Result := AddPage;
  if AControl <> nil then
  begin
    AControl.Parent := Result;
    AControl.Align := alClient;   // 复用宿主已有控件（如 TChromium, 文档 14.2）
  end;
end;

function TFHChromePageHost.ReuseHiddenPage: TFHChromePage;
var
  Tab: TFHChromeTab;
begin
  // 恢复标签（FP-1）: LIFO 取最近隐藏页 → 重建 Tab + 还原备份标题 → 激活。
  // 页上内容控件（如 TChromium）原样保留——"恢复标签"体验的核心价值。
  // 标题来源: HandleTabClosing 的 BackupCaption; 若宿主未走 Closing
  // （直接 ForceCloseTab）则还原为页面默认, 即"新标签页"降级
  Result := nil;
  if (FChromeTabs = nil) or (FHiddenPages.Count = 0) then Exit;
  Result := FHiddenPages.Last;
  FHiddenPages.Delete(FHiddenPages.Count - 1);   // 非拥有列表: 仅移除引用
  Tab := FChromeTabs.Tabs.Add;                  // 构造尾 Changed→重排（时序修复）
  Result.AttachTab(Tab);                        // 挂新 Tab + 还原备份标题
  Result.Color := EffectivePageHostColor;       // 复用页底色可能已随主题变化
  FPages.Add(Result);
  // 复用页激活（复刻 AddPage 路径; 触发 HandleActiveTabChange→ShowPage）
  FChromeTabs.ActiveTabIndex := FChromeTabs.Tabs.Count - 1;
  // 页面重新入列, 宿主需要同样的通知（如为恢复的页重建 CEF / 加载 URL）
  DoPageAdded(Result);
end;

procedure TFHChromePageHost.DropHiddenPage(Page: TFHChromePage);
begin
  // 非拥有列表: 仅摘引用。延迟释放成功后调用, 防止池留悬垂指针
  // （池满时容器对池内页 Drop.Free 会二次释放已释放对象）
  if Page = nil then Exit;
  FHiddenPages.Extract(Page);
end;

procedure TFHChromePageHost.AbandonHiddenPage(Page: TFHChromePage);
begin
  if Page = nil then Exit;
  FHiddenPages.Extract(Page);
  { 从 Owner 组件树摘除半析构页: RemoveComponent 只操作容器的组件列表与
    Page 的 Owner 回指字段——半析构对象内存仍有效（FreeInstance 未执行,
    内存未归还）, 这些操作安全。摘除后退出路径 TComponent.DestroyComponents
    不再枚举到它, 避免 FreeInstance 二次释放内存触发 EInvalidPointer }
  RemoveComponent(Page);
  FAbandonedPages.Add(Page);
end;

function TFHChromePageHost.GetHiddenPageCount: Integer;
begin
  Result := FHiddenPages.Count;
end;

function TFHChromePageHost.PageByTab(ATab: TFHChromeTab): TFHChromePage;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FPages.Count - 1 do
    if FPages[I].FTab = ATab then
      Exit(FPages[I]);
end;

function TFHChromePageHost.PageAtTabIndex(TabIndex: Integer): TFHChromePage;
begin
  if (TabIndex >= 0) and (TabIndex < FPages.Count) then
    Result := FPages[TabIndex]
  else
    Result := nil;
end;

function TFHChromePageHost.PageCount: Integer;
begin
  Result := FPages.Count;
end;

function TFHChromePageHost.IndexOfPage(Page: TFHChromePage): Integer;
begin
  if Page = nil then
    Result := -1
  else
    Result := FPages.IndexOf(Page);
end;

{ 显示指定索引的页面并隐藏其余（TabIndex=-1 = 全部隐藏成空白底色）,
  激活页变化时发 OnPageChanged }
procedure TFHChromePageHost.ShowPage(TabIndex: Integer);
var
  I, Old: Integer;
begin
  Old := FActivePageIndex;
  if (TabIndex < 0) or (TabIndex >= FPages.Count) then
  begin
    // 全部关闭 → 空白底色（文档 FP-2）: 必须逐个隐藏, 否则最后一个页面
    // 会一直停留在容器里遮住底色
    for I := 0 to FPages.Count - 1 do
      FPages[I].Visible := False;
    FActivePageIndex := -1;
    Invalidate;
    if Old <> -1 then
      DoPageChanged(Old, -1);
    Exit;
  end;
  FActivePageIndex := TabIndex;
  // 仅 Visible 翻转, 不重绘非激活页（NFR-1）
  for I := 0 to FPages.Count - 1 do
    FPages[I].Visible := (I = TabIndex);
  FPages[TabIndex].BringToFront;
  if Old <> TabIndex then
    DoPageChanged(Old, TabIndex);
end;

function TFHChromePageHost.EffectivePageHostColor: TColor;
begin
  if (FChromeTabs <> nil) and (FChromeTabs.Theme <> nil) then
    Result := FChromeTabs.Theme.PageHostColor
  else
    Result := clWhite;
end;

procedure TFHChromePageHost.Paint;
begin
  // 容器底色 = Theme.PageHostColor, 与激活标签 TabActiveFill 一致形成一体观感
  // （文档 4.4 / 3.3.1 视觉衔接; 无边框无 Bevel）
  ApplyThemeColor;   // 主题变化时把新底色同步给所有页面（含隐藏池）
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FAppliedColor;
  Canvas.FillRect(Rect(0, 0, Width, Height));
end;

{ ---- 容器事件触发器 ------------------------------------------------------ }

procedure TFHChromePageHost.DoPageAdded(Page: TFHChromePage);
begin
  if Assigned(FOnPageAdded) then
    FOnPageAdded(Self, Page);
end;

procedure TFHChromePageHost.DoPageRemoved(Page: TFHChromePage);
begin
  if Assigned(FOnPageRemoved) then
    FOnPageRemoved(Self, Page);
end;

procedure TFHChromePageHost.DoPageChanged(OldIndex, NewIndex: Integer);
begin
  if Assigned(FOnPageChanged) then
    FOnPageChanged(Self, OldIndex, NewIndex);
end;


end.