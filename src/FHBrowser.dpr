program FHBrowser;

{==============================================================================
  FHBrowser（飞花浏览器）—— 浏览器主工程（Delphi 11 + CEF4Win7 + FHChromeTabs）
  ----------------------------------------------------------------------------
  品牌: 飞花浏览器；口号: 轻如飞花，浏览无界（技术标识与文件名仍用 FHBrowser）
  项目定位: Chrome 风格多标签浏览器应用
  技术栈: Delphi 11 VCL + CEF4Win7 (CEF 109 / Chromium 109) + FHChromeTabs 组件
  依赖:
    - CEF4Win7 源码: 环境变量 CEF4WIN7 指向其根目录
      （工程搜索路径为 $(CEF4WIN7)\source）
    - CEF 运行时二进制（libcef.dll 等）: 需与 exe 同目录
      可从本项目 Release 附件的运行时压缩包解压到 bin\
  关键约定:
    - GlobalCEFApp 必须在工程最早时机创建并 StartMainProcess（先于任何窗体）
    - 组件本体零 CEF 依赖, 本工程仅宿主侧引用 uCEF* 单元
==============================================================================}

{$I cef.inc}

uses
{$IFDEF MADEXCEPT}
  { madExcept 为商业组件: 未安装时不定义 MADEXCEPT 即可正常编译 }
  madExcept,
  madLinkDisAsm,
  madListHardware,
  madListProcesses,
  madListModules,
{$ENDIF}
  uFHDpi in 'uFHDpi.pas',
  Winapi.Windows,
  Vcl.Forms,
  SysUtils,
  uFHCEFApp in 'uFHCEFApp.pas',
  uFHChromeTabs in 'components\uFHChromeTabs.pas',
  uFHChromePageHost in 'components\uFHChromePageHost.pas',
  uLogger in 'uLogger.pas',
  uFHDownloads in 'uFHDownloads.pas',
  uFHChromeWidgets in 'uFHChromeWidgets.pas',
  uFHBrowsingDataDlg in 'uFHBrowsingDataDlg.pas',
  uFHAboutDlg in 'uFHAboutDlg.pas',
  uFHSettings in 'uFHSettings.pas',
  uFHSettingsDlg in 'uFHSettingsDlg.pas',
  uFHHistoryDB in 'uFHHistoryDB.pas',
  uFHHistory in 'uFHHistory.pas',
  uFHBookmarks in 'uFHBookmarks.pas',
  uBrowserMain in 'uBrowserMain.pas' {BrowserForm};

{ 工程主资源（*.res）：应用图标（dproj Icon_MainIcon）+ 版本信息（dproj VerInfo）。
  不要再单独链接 FHBrowser_version.res：两个 res 都含 VERSIONINFO，链接器会整份丢弃
  FHBrowser.res，连图标一起丢掉（H2161）。 }
{$R *.res}
{$SetPEFlags IMAGE_FILE_LARGE_ADDRESS_AWARE}

begin
  { 进程 DPI 感知已由 uFHDpi 单元的 initialization 完成（见该单元注释） }

  { 最早时机初始化 CEF（先于任何窗体）: cache/GPU/LogFile 等配置与上下文就绪
    回调的登记都在 uFHCEFApp 单元里, 本工程只在这里按顺序调用 }
  FHCEFAppCreate(GlobalCEFApp_OnContextInitialized);

  if FHCEFAppStartMainProcess then
    begin
      Application.Initialize;
      Application.MainFormOnTaskbar := True;
      {设置时间格式}
      SetLocaleInfo(LOCALE_SYSTEM_DEFAULT, LOCALE_SSHORTDATE, 'yyyy-MM-dd');
      Application.UpdateFormatSettings := False;
      FormatSettings.LongDateFormat := 'yyyy-MM-dd';
      FormatSettings.ShortDateFormat := 'yyyy-MM-dd';
      FormatSettings.LongTimeFormat := 'hh:nn:ss';
      FormatSettings.ShortTimeFormat := 'hh:nn:ss';
      FormatSettings.DateSeparator := '-';
      FormatSettings.timeSeparator := ':';
      FormatSettings.ShortDayNames[1] := '日';
      FormatSettings.ShortDayNames[2] := '一';
      FormatSettings.ShortDayNames[3] := '二';
      FormatSettings.ShortDayNames[4] := '三';
      FormatSettings.ShortDayNames[5] := '四';
      FormatSettings.ShortDayNames[6] := '五';
      FormatSettings.ShortDayNames[7] := '六';
      Application.CreateForm(TBrowserForm, BrowserForm);
      Application.Run;
    end;
end.