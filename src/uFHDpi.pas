unit uFHDpi;

{==============================================================================
  进程级 DPI 感知（必须在任何窗口/字体创建之前生效）
  ---------------------------------------------------------------------------
  为什么必须放在本单元的 initialization、且排在 dpr uses 的第一位:

    Vcl.Forms 的 initialization 会调用 InitProcs → Vcl.Controls 的 InitControls,
    那里执行 Screen := TScreen.Create(nil), 而 TScreen 构造时就把
      FPixelsPerInch := GetDeviceCaps(DC, LOGPIXELSY)
    缓存下来了。若在此之前进程仍是 DPI Unaware, 缓存到的就是 Windows 谎报的 96,
    之后无论什么时候再去 SetProcessDpiAwarenessContext 都改不回来。

  实测（本机 150%, 6 个步骤）:
    在主 begin 里调用  -> Screen.PixelsPerInch = 96   ScalePx(36) = 36  (无效)
    在 uses 首位单元的 initialization 里调用
                       -> Screen.PixelsPerInch = 144  ScalePx(36) = 54  (生效)

  不声明感知的后果: 组件里所有 ScalePx / ScaleCanvas 退化成乘以 1, 窗口被系统
  位图拉伸 1.5 倍 —— UI 与网页双重模糊。

  降级顺序: PMv2 (Win10 1607+) → PMv1 (Win8.1+) → System Aware (Win7)
==============================================================================}

interface

{ 96 DPI 基准逻辑像素 → 当前屏幕实际像素（进程已声明 Per-Monitor 感知）。

  项目内各窗口/控件不要再自写 ScalePx, 一律调用这里 —— 实现唯一化。
  注意: 本单元必须保持"最先初始化"（dpr uses 首位），因此不得 uses
  Vcl.Forms（其 initialization 会提前缓存 DPI）——DPI 一律走 Win32 查询 }
function FHScalePx(P: Integer): Integer;

{ 96 DPI 基准逻辑像素 → 按指定缩放因子换算
  （组件的自定义 ScaleFactor 场景: 菜单/标签条等） }
function FHScalePxBy(P: Integer; AFactor: Single): Integer;

{ 当前屏幕缩放因子 = 实际 DPI / 96（1.0 / 1.25 / 1.5 ...） }
function FHScreenScaleFactor: Single;

implementation

uses
  Winapi.Windows;

const
  DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4;
  PROCESS_PER_MONITOR_DPI_AWARE = 2;

{ 当前屏幕缩放因子: 直接查屏幕 DC 的实际 DPI（进程已感知, 不会被系统谎报 96） }
function FHScreenScaleFactor: Single;
var
  DC: HDC;
  DPI: Integer;
begin
  DC := GetDC(0);
  try
    DPI := GetDeviceCaps(DC, LOGPIXELSY);
  finally
    ReleaseDC(0, DC);
  end;
  if DPI <= 0 then
    DPI := 96;
  Result := DPI / 96;
end;

function FHScalePx(P: Integer): Integer;
begin
  Result := Round(P * FHScreenScaleFactor);
  if (P > 0) and (Result = 0) then
    Result := 1;
end;

function FHScalePxBy(P: Integer; AFactor: Single): Integer;
begin
  Result := Round(P * AFactor);
end;

{ 声明进程 DPI 感知（只在 initialization 里调用一次）。
  按系统能力从高到低逐级降级尝试, 任一成功即返回:
    1) SetProcessDpiAwarenessContext(PMv2)  Win10 1607+ —— 逐显示器 v2（首选）
    2) SetProcessDpiAwareness(PM)           Win8.1+   —— 逐显示器 v1（shcore.dll）
    3) SetProcessDPIAware                   Win7      —— 仅系统级感知
  三个 API 均为运行时动态解析, 不存在于旧系统时跳过该级, 保证 Win7~Win11 全兼容 }

procedure EnableDpiAwareness;
type
  TSetCtx = function(value: THandle): BOOL; stdcall;
  TSetAware = function(value: Integer): HRESULT; stdcall;
  TSetSystemAware = function: BOOL; stdcall;
var
  User32, Shcore: HMODULE;
  P: Pointer;
begin
  User32 := GetModuleHandle('user32.dll');
  if User32 <> 0 then
  begin
    P := GetProcAddress(User32, 'SetProcessDpiAwarenessContext');
    if Assigned(P) then
    begin
      TSetCtx(P)(THandle(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2));
      Exit;
    end;
  end;

  Shcore := LoadLibrary('shcore.dll');
  if Shcore <> 0 then
  try
    P := GetProcAddress(Shcore, 'SetProcessDpiAwareness');
    if Assigned(P) then
    begin
      TSetAware(P)(PROCESS_PER_MONITOR_DPI_AWARE);
      Exit;
    end;
  finally
    FreeLibrary(Shcore);
  end;

  if User32 <> 0 then
  begin
    P := GetProcAddress(User32, 'SetProcessDPIAware');
    if Assigned(P) then
      TSetSystemAware(P)();
  end;
end;

initialization
  EnableDpiAwareness;

end.
