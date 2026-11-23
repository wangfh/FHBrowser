{==============================================================================
  uFHCEFApp —— CEF 全局应用对象（GlobalCEFApp）的封装
  ----------------------------------------------------------------------------
  职责: GlobalCEFApp 的创建、配置、启动、销毁，以及"上下文就绪"回调的登记。
        语言随操作系统: 启动即读取 Windows 显示语言, 设置 Locale（浏览器 UI 语言）
        与 AcceptLanguageList（网页请求的 Accept-Language 请求头）。
  设计: 本单元不认识任何窗体（不引用 uBrowserMain），窗体那边把回调过程传进来，
        依赖方向单向 —— dpr → uFHCEFApp / dpr → uBrowserMain。

  使用（FHBrowser.dpr 里的顺序不能变）:
      FHCEFAppCreate(GlobalCEFApp_OnContextInitialized);   // 1. 建+配
      if FHCEFAppStartMainProcess then                      // 2. 起主进程
      begin
        Application.Initialize;                            // 3. 之后才建窗体
        ...
      end;

  为什么必须在建窗体之前: CEF 的多进程模型要求主进程先起来, 且
  GlobalCEFApp.GlobalContextInitialized 为 True 之后才允许 CreateBrowser
  （详见 uCEFChromiumCore.CreateBrowser 的注释）。
==============================================================================}

unit uFHCEFApp;

interface

uses
  Winapi.Windows,
  System.SysUtils,
  uCEFApplication,
  uCEFConstants;

type
  { GlobalCEFApp 上下文就绪回调（与 uCEFApplicationEvents.TOnContextInitializedEvent
    同签名; 用普通过程类型, 免得引用方被迫写成对象方法） }
  TFHCEFContextInitializedProc = procedure;

{ 创建并配置 GlobalCEFApp（幂等: 已存在则直接返回）。
  AOnContextInitialized 可为空 —— 为空时上层需自行轮询 GlobalContextInitialized。
  AExeDir 为空时取 ParamStr(0) 所在目录。 }
procedure FHCEFAppCreate(const AOnContextInitialized: TFHCEFContextInitializedProc = nil;
                         const AExeDir: string = '');

{ 启动 CEF 主进程。True = 可以继续建窗体; False = 不要往下走（浏览器不可用）。 }
function FHCEFAppStartMainProcess: Boolean;

{ GlobalCEFApp 是否已就绪 }
function FHCEFAppContextInitialized: Boolean;

{ 本次实际采用的 CEF 语言（形如 zh-CN）; 未创建前返回空串 }
function FHCEFAppLocale: string;

{ 释放。一般不用调 —— 进程退出时由系统回收; 需要在一个进程里反复起停才用。 }
procedure FHCEFAppFree;

implementation

uses
  uFHSettings, uLogger;

const
  { cache 必须落到 exe 同级目录的 cache\ 下: 没有可读写的缓存目录 CEF 起不了浏览器 }
  CEF_CACHE_DIR = 'cache';
  { CEF 自己的详细日志; LOGSEVERITY_INFO 足以看清 plugin/GPU/网络加载情况 }
  CEF_LOG_FILE  = 'debug.log';
  { Chromium 的语言包目录 (**/*.pak), locale 名必须在这里面有对应文件 }
  CEF_LOCALES_DIR = 'locales';
  { 语言包缺失/推导失败时的兜底 }
  CEF_LOCALE_FALLBACK = 'en-US';
  { LCIDToLocaleName 需要的缓冲区大小（MSDN: LOCALE_NAME_MAX_LENGTH = 85） }
  LOCALE_NAME_MAX_LEN = 85;

var
  GCreated: Boolean;
  GLocale: string;

{ 统一基准目录: 显式传入则补尾分隔符, 否则用 exe 所在目录 }
function ExeDir(const AExeDir: string): string;
begin
  if AExeDir <> '' then
    Result := IncludeTrailingPathDelimiter(AExeDir)
  else
    Result := ExtractFilePath(ParamStr(0));
end;

{ ---- 语言 ---------------------------------------------------------------- }

{ 当前用户的操作系统 UI 语言 → Chromium 的 locale 名（zh-CN / en-US / pt-BR ...）。
  GetUserDefaultUILanguage 取的是"Windows 显示语言"（不是区域/数字格式）,
  LCIDToLocaleName 负责 LCID → IETF 名称（Vista 起可用, CEF 109 要求 Win7+）。 }
function DetectOSLocale: string;
var
  Lcid: DWORD;      // LCID 在各 Delphi 版本的 RTL 里有/没有不定, 直接用 DWORD
  Buf: array[0..LOCALE_NAME_MAX_LEN] of Char;
  N: Integer;
begin
  Result := '';
  FillChar(Buf, SizeOf(Buf), 0);
  Lcid := GetUserDefaultUILanguage;
  N := LCIDToLocaleName(Lcid, Buf, LOCALE_NAME_MAX_LEN, 0);
  if N > 0 then
    Result := Buf;
end;

function LocalePakExists(const AExeDir, ALocale: string): Boolean;
begin
  Result := (ALocale <> '') and
    FileExists(ExeDir(AExeDir) + CEF_LOCALES_DIR + PathDelim + ALocale + '.pak');
end;

{ 定出最终要给 CEF 的 locale: 必须是 locales\ 下真实存在的那个 .pak 的名字,
  否则 Chromium 找不到语言包会静默退回英文 UI。
  依次降级: 原名(zh-Hans-CN) → 语言+地区(zh-CN) → 纯语言(fr) → en-US }
function ResolveCefLocale(const AExeDir: string): string;
var
  Name, Lang, Region: string;
  Parts: TArray<string>;
begin
  Name := DetectOSLocale;
  if Name = '' then
    Exit(CEF_LOCALE_FALLBACK);

  Parts  := Name.Split(['-']);
  Lang   := Parts[0];
  Region := '';
  if Length(Parts) >= 2 then
    Region := Parts[Length(Parts) - 1];

  if LocalePakExists(AExeDir, Name) then
    Exit(Name);
  if (Region <> '') and LocalePakExists(AExeDir, Lang + '-' + Region) then
    Exit(Lang + '-' + Region);
  if LocalePakExists(AExeDir, Lang) then
    Exit(Lang);
  Result := CEF_LOCALE_FALLBACK;
end;

{ HTTP 的 Accept-Language 请求头内容列表（逗号分隔, 按优先级降序） }
function BuildAcceptLanguage(const ALocale: string): string;
var
  Lang: string;
begin
  Lang := Copy(ALocale, 1, Pos('-', ALocale) - 1);
  if Lang = '' then
    Lang := ALocale;
  if Lang = 'en' then
    Exit('en-US,en');
  Result := ALocale + ',' + Lang + ',en-US,en';
end;

{ ---- 生命周期 ------------------------------------------------------------ }

procedure FHCEFAppCreate(const AOnContextInitialized: TFHCEFContextInitializedProc;
                         const AExeDir: string);
begin
  if GlobalCEFApp <> nil then
    Exit;

  GlobalCEFApp            := TCefApplication.Create;
  GlobalCEFApp.cache      := ExeDir(AExeDir) + CEF_CACHE_DIR;
  { GPU 加速默认不启用（设置里可改, 重启浏览器后生效 —— CEF 启动参数,
    运行中无法切换）。默认关是因为部分老机器/虚拟机驱动不稳, 页面会花屏 }
  GlobalCEFApp.EnableGPU := Settings.EnableGPU;
  { Chrome 风格运行时（CEF 109 可选）: 打印才有 Chrome 那种"左预览右选项"的
    打印预览窗口 —— 默认的 alloy 运行时里 Chromium.Print() 只触发
    PrintHandler 回调, 没有任何打印 UI }
  //GlobalCEFApp.ChromeRuntime := True;
  GlobalCEFApp.EnablePrintPreview:=True;
  { 持久化用户偏好与 session cookies 到 cache 目录。DevTools 前端的语言设置
    存在 DevTools 浏览器的 localStorage（chrome-devtools:// Origin）, 开启持久化
    后该 storage 可能跟随主 RequestContext 落盘 —— 否则每次 ShowDevTools 创建
    新 DevTools 实例, localStorage 丢失, 语言选择不保留 }
  GlobalCEFApp.PersistUserPreferences := True;
  GlobalCEFApp.PersistSessionCookies  := True;
  GlobalCEFApp.LogFile    := ExeDir(AExeDir) + CEF_LOG_FILE;
  GlobalCEFApp.LogSeverity := LOGSEVERITY_INFO;
  { 跟随操作系统语言: 浏览器 UI 语言 + 网页请求的 Accept-Language 都用这一份。
    必须在 StartMainProcess 之前设置 —— locale 是 cef_initialize 的入参 }
  GLocale := ResolveCefLocale(AExeDir);
  GlobalCEFApp.Locale := GLocale;
  GlobalCEFApp.AcceptLanguageList := BuildAcceptLanguage(GLocale);
  { TabbedBrowser2 同模式: 上下文就绪后异步通知窗体（窗体句柄可能还没建好,
    所以那边做好了"句柄没建/还没收到"的兜底 —— 见 TBrowserForm.EnsureHomeTick） }
  GlobalCEFApp.OnContextInitialized := AOnContextInitialized;

  GCreated := True;
end;

function FHCEFAppStartMainProcess: Boolean;
begin
  Result := (GlobalCEFApp <> nil) and GlobalCEFApp.StartMainProcess;
end;

function FHCEFAppContextInitialized: Boolean;
begin
  Result := (GlobalCEFApp <> nil) and GlobalCEFApp.GlobalContextInitialized;
end;

function FHCEFAppLocale: string;
begin
  Result := GLocale;
end;

procedure FHCEFAppFree;
begin
  if GCreated and (GlobalCEFApp <> nil) then
  begin
    GlobalCEFApp.Free;
    GlobalCEFApp := nil;
  end;
  GCreated := False;
  GLocale  := '';
end;

end.
