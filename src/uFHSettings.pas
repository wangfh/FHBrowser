{==============================================================================
  单元: uFHSettings
  职责: 浏览器用户设置的内存持有与持久化（INI）。
        覆盖: 浏览器首页 / 新标签页模式（指定网址 / 空白页）/ 下载前询问
        保存位置与默认下载位置 / GPU 加速开关。

  持久化位置: exe 同目录 UserData\settings.ini（与 uFHHistoryDB 的
        History.db 同一用户数据目录, 随程序目录整体携带）。unit 的
        initialization 自动 Load, 主窗体/CEF 初始化之前就绪 ——
        GPU 开关必须在 FHCEFAppCreate 里读到。

  使用约定:
    - Home 按钮 / 启动页          → Settings.EffectiveHomepage
    - 新建标签页                  → Settings.NewTabMode（ntmUrl 用 EffectiveNewTabUrl）
    - OnBeforeDownload            → Settings.AskDownloadLocation 决定是否弹"另存为"
    - 下载目录兜底                → Settings.EffectiveDownloadDir（空 = 系统"下载"）
    - GPU 加速                    → Settings.EnableGPU（改动后重启浏览器生效）
==============================================================================}
unit uFHSettings;

interface

uses
  System.SysUtils, System.IniFiles,
  Winapi.Windows, Winapi.ShlObj, Winapi.ActiveX;

type
  { 新标签页打开什么 }
  TFHNewTabMode = (ntmUrl, ntmBlank);    // 指定网址 / 空白页

  TFHSettings = class
  private
    FHomepage: string;              // 浏览器首页
    FNewTabMode: TFHNewTabMode;     // 新标签页模式
    FNewTabUrl: string;             // 新标签页 = 指定网址时的网址
    FAskDownloadLocation: Boolean;  // 下载文件前询问保存位置（默认是）
    FDownloadDir: string;           // 默认下载位置（空 = 系统下载文件夹）
    FEnableGPU: Boolean;            // GPU 加速（默认不启用, 重启生效）

    function GetEffectiveHomepage: string;
    function GetEffectiveNewTabUrl: string;
    function GetEffectiveDownloadDir: string;
  public
    procedure Load;
    procedure Save;
    { 带兜底的取值: 空配置回退默认, 调用方不用再判空 }
    property Homepage: string read FHomepage write FHomepage;
    property NewTabMode: TFHNewTabMode read FNewTabMode write FNewTabMode;
    property NewTabUrl: string read FNewTabUrl write FNewTabUrl;
    property AskDownloadLocation: Boolean read FAskDownloadLocation
      write FAskDownloadLocation;
    property DownloadDir: string read FDownloadDir write FDownloadDir;
    property EnableGPU: Boolean read FEnableGPU write FEnableGPU;

    property EffectiveHomepage: string read GetEffectiveHomepage;
    property EffectiveNewTabUrl: string read GetEffectiveNewTabUrl;
    property EffectiveDownloadDir: string read GetEffectiveDownloadDir;
  end;

{ 全局设置单例（unit initialization 时已 Load, 无需手工初始化） }
function Settings: TFHSettings;

implementation

uses
  uLogger;

const
  C_INI_FILE      = 'settings.ini';
  C_INI_SECTION   = 'Settings';
  { 各项默认值 }
  C_DEF_HOME      = 'https://www.baidu.com';
  C_DEF_NEWTABURL = 'https://www.baidu.com';
  C_DEF_ASKSAVE   = True;
  C_DEF_GPU       = False;


var
  GSettings: TFHSettings = nil;

{ 全局设置单例: 首次访问时创建并立即 Load（此后一直复用） }
function Settings: TFHSettings;
begin
  if GSettings = nil then
  begin
    GSettings := TFHSettings.Create;
    GSettings.Load;
  end;
  Result := GSettings;
end;

{ 设置文件全路径: exe 同目录 UserData\settings.ini（目录不存在自动创建） }
function IniFileName: string;
var
  Dir: string;
begin
  Dir := ExtractFilePath(ParamStr(0)) + 'UserData';
  ForceDirectories(Dir);
  Result := IncludeTrailingPathDelimiter(Dir) + C_INI_FILE;
end;

{ ---- TFHSettings ----------------------------------------------------------- }

{ 从 INI 读入全部设置项（缺项用默认值） }
procedure TFHSettings.Load;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniFileName);
  try
    FHomepage            := Ini.ReadString(C_INI_SECTION, 'Homepage', C_DEF_HOME);
    FNewTabMode          := TFHNewTabMode(Ini.ReadInteger(C_INI_SECTION,
                            'NewTabMode', Ord(ntmUrl)));
    FNewTabUrl           := Ini.ReadString(C_INI_SECTION, 'NewTabUrl', C_DEF_NEWTABURL);
    FAskDownloadLocation := Ini.ReadBool(C_INI_SECTION, 'AskDownloadLocation',
                            C_DEF_ASKSAVE);
    FDownloadDir         := Ini.ReadString(C_INI_SECTION, 'DownloadDir', '');
    FEnableGPU           := Ini.ReadBool(C_INI_SECTION, 'EnableGPU', C_DEF_GPU);

  finally
    Ini.Free;
  end;
end;

{ 把全部设置项写回 INI（设置对话框"确定"时调用） }
procedure TFHSettings.Save;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniFileName);
  try
    Ini.WriteString(C_INI_SECTION, 'Homepage', FHomepage);
    Ini.WriteInteger(C_INI_SECTION, 'NewTabMode', Ord(FNewTabMode));
    Ini.WriteString(C_INI_SECTION, 'NewTabUrl', FNewTabUrl);
    Ini.WriteBool(C_INI_SECTION, 'AskDownloadLocation', FAskDownloadLocation);
    Ini.WriteString(C_INI_SECTION, 'DownloadDir', FDownloadDir);
    Ini.WriteBool(C_INI_SECTION, 'EnableGPU', FEnableGPU);

    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

{ 首页取值: 配置为空时回退默认首页（百度） }
function TFHSettings.GetEffectiveHomepage: string;
begin
  Result := Trim(FHomepage);
  if Result = '' then
    Result := C_DEF_HOME;
end;

{ 新标签页网址取值: 配置为空时回退默认网址 }
function TFHSettings.GetEffectiveNewTabUrl: string;
begin
  Result := Trim(FNewTabUrl);
  if Result = '' then
    Result := C_DEF_NEWTABURL;
end;

{ 下载目录取值: 配置为空时回退系统"下载"文件夹（SHGetKnownFolderPath,
  失败再退 %USERPROFILE%\Downloads）, 结果恒带尾分隔符 }
function TFHSettings.GetEffectiveDownloadDir: string;
var
  P: PWideChar;
  Known: string;
begin
  Result := Trim(FDownloadDir);
  if Result <> '' then
    Exit(IncludeTrailingPathDelimiter(Result));
  { 未设置 → 系统"下载"文件夹（SHGetKnownFolderPath, 失败退回
    %USERPROFILE%\Downloads —— 与 uFHDownloads.DownloadsDir 同一套兜底,
    这里独立实现以免设置单元反向依赖下载单元 } 
  Known := '';
  P := nil;
  if Succeeded(SHGetKnownFolderPath(
       StringToGUID('{374DE290-123F-4565-9164-39C4925E467B}'), 0, 0, P)) then
  try
    Known := P;
  finally
    CoTaskMemFree(P);
  end;
  if Known = '' then
    Known := GetEnvironmentVariable('USERPROFILE') + '\Downloads';
  Result := IncludeTrailingPathDelimiter(Known);
end;

initialization

finalization
  FreeAndNil(GSettings);

end.