unit uLogger;
{
  独立日志单元：全局单例、多线程安全、支持日志级别
  使用方法：
    1. 程序启动时设置日志目录、文件名格式和最低级别（不设置则使用默认值）：
       Logger.LogDir := 'UserData\Logs\';
       Logger.FileNameFormat := 'yyyymmdd';   // 按日期生成文件名，如 20261008.log
       Logger.MinLevel := llInfo;             // 低于 Info 级别的日志不写入
    2. 任意线程中写日志（多线程安全，写入失败不抛异常，不影响业务流程）：
       Logger.Debug('调试消息: %d', [100]);   // DEBUG 级别
       Logger.Info('普通消息');               // INFO 级别
       Logger.Warn('警告消息');               // WARN 级别
       Logger.Error('错误消息: %s', ['原因']); // ERROR 级别
       Logger.Write(llTrace, '跟踪消息');     // 指定级别
       Logger.Write('普通消息');              // 不指定级别时默认 INFO
}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.IOUtils;

type
  // 日志级别（从小到大，级别越高越重要）
  TLogLevel = (llTrace, llDebug, llInfo, llWarn, llError);

  TLogger = class
  private
    _lock: TCriticalSection;   // 多线程写入锁
    _logDir: string;           // 日志目录
    _fileNameFormat: string;   // 日志文件名格式（FormatDateTime 格式串）
    _minLevel: TLogLevel;      // 最低写入级别，低于该级别的日志不写入
    _curFileName: string;      // 当前已打开的日志文件全路径
    _fileStream: TFileStream;  // 当前打开的日志文件流
    procedure SetLogDir(const Value: string);
    procedure SetFileNameFormat(const Value: string);
    function BuildFileName: string;  // 按格式生成当前日志文件全路径
    procedure EnsureStream;          // 确保文件流可用（目录/文件名变化时自动切换）
    procedure CloseStream;           // 关闭当前文件流
  public
    constructor Create;
    destructor Destroy; override;
    // 写入指定级别的日志（自动带时间、级别前缀，追加到文件尾）
    procedure Write(ALevel: TLogLevel; const AMessage: string); overload;
    // 格式化写入指定级别的日志
    procedure Write(ALevel: TLogLevel; const AMessage: string; const AArgs: array of const); overload;
    // 写入一条日志（不指定级别时默认 INFO，兼容旧调用）
    procedure Write(const AMessage: string); overload;
    // 格式化写入一条日志（默认 INFO 级别，兼容旧调用）
    procedure Write(const AMessage: string; const AArgs: array of const); overload;
    // 各级别便捷写入方法
    procedure Debug(const AMessage: string); overload;
    procedure Debug(const AMessage: string; const AArgs: array of const); overload;
    procedure Info(const AMessage: string); overload;
    procedure Info(const AMessage: string; const AArgs: array of const); overload;
    procedure Warn(const AMessage: string); overload;
    procedure Warn(const AMessage: string; const AArgs: array of const); overload;
    procedure Error(const AMessage: string); overload;
    procedure Error(const AMessage: string; const AArgs: array of const); overload;
    // 日志目录（目录不存在时写入前自动创建）
    property LogDir: string read _logDir write SetLogDir;
    // 日志文件名格式（FormatDateTime 格式串），默认 'yyyymmdd' 按天生成文件
    property FileNameFormat: string read _fileNameFormat write SetFileNameFormat;
    // 最低写入级别，低于该级别的日志不写入，默认 llTrace 全部写入
    property MinLevel: TLogLevel read _minLevel write _minLevel;
  end;

// 全局单例访问入口
function Logger: TLogger;
// 日志级别转字符串（TRACE/DEBUG/INFO/WARN/ERROR）
function LogLevelToStr(ALevel: TLogLevel): string;
// 字符串转日志级别（不区分大小写，无法识别时默认 llInfo）
function StrToLogLevel(const S: string): TLogLevel;

implementation

var
  _GLogger: TLogger = nil;

function Logger: TLogger;
begin
  Result := _GLogger;
end;

function LogLevelToStr(ALevel: TLogLevel): string;
const
  LevelNames: array[TLogLevel] of string = ('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  Result := LevelNames[ALevel];
end;

function StrToLogLevel(const S: string): TLogLevel;
begin
  if SameText(S, 'TRACE') then Result := llTrace
  else if SameText(S, 'DEBUG') then Result := llDebug
  else if SameText(S, 'WARN') then Result := llWarn
  else if SameText(S, 'ERROR') then Result := llError
  else Result := llInfo;
end;

{ TLogger }

constructor TLogger.Create;
begin
  inherited Create;
  _lock := TCriticalSection.Create;
  _fileStream := nil;
  _curFileName := '';
  _fileNameFormat := 'yyyymmdd';
  _minLevel := llTrace;
  // 默认日志目录：程序目录下的 Logs 子目录
  _logDir := TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), 'Logs');
end;

destructor TLogger.Destroy;
begin
  CloseStream;
  _lock.Free;
  inherited Destroy;
end;

procedure TLogger.SetLogDir(const Value: string);
begin
  if Value = '' then Exit;
  _lock.Enter;
  try
    if _logDir <> Value then
    begin
      _logDir := Value;
      CloseStream; // 目录变化后关闭旧流，下次写入时按新目录重新打开
    end;
  finally
    _lock.Leave;
  end;
end;

procedure TLogger.SetFileNameFormat(const Value: string);
begin
  if Value = '' then Exit;
  _lock.Enter;
  try
    if _fileNameFormat <> Value then
    begin
      _fileNameFormat := Value;
      CloseStream; // 格式变化后关闭旧流，下次写入时按新格式重新打开
    end;
  finally
    _lock.Leave;
  end;
end;

function TLogger.BuildFileName: string;
begin
  Result := TPath.Combine(_logDir, FormatDateTime(_fileNameFormat, Now) + '.log');
end;

procedure TLogger.EnsureStream;
var
  NewFileName: string;
  Preamble: TBytes;
begin
  NewFileName := BuildFileName;
  // 文件名未变化（未跨天/未改配置）且流已打开，直接复用当前流
  if (_fileStream <> nil) and SameText(NewFileName, _curFileName) then
    Exit;

  CloseStream;
  // 目录不存在时自动创建
  if not TDirectory.Exists(_logDir) then
    ForceDirectories(_logDir);

  if FileExists(NewFileName) then
    _fileStream := TFileStream.Create(NewFileName, fmOpenReadWrite or fmShareDenyWrite)
  else
    _fileStream := TFileStream.Create(NewFileName, fmCreate or fmShareDenyWrite);

  // 新文件先写入 UTF-8 BOM，方便记事本等工具识别编码
  if _fileStream.Size = 0 then
  begin
    Preamble := TEncoding.UTF8.GetPreamble;
    if Length(Preamble) > 0 then
      _fileStream.WriteBuffer(Preamble[0], Length(Preamble));
  end;

  _fileStream.Position := _fileStream.Size; // 定位到文件尾，追加写入
  _curFileName := NewFileName;
end;

procedure TLogger.CloseStream;
begin
  if _fileStream <> nil then
  begin
    _fileStream.Free;
    _fileStream := nil;
  end;
  _curFileName := '';
end;

procedure TLogger.Write(ALevel: TLogLevel; const AMessage: string);
var
  LineBytes: TBytes;
begin
  // 低于最低级别的日志不写入（不进锁，减少无谓的锁竞争）
  if ALevel < _minLevel then Exit;
  _lock.Enter;
  try
    try
      EnsureStream;
      LineBytes := TEncoding.UTF8.GetBytes(
        Format('%s [%s]: %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), LogLevelToStr(ALevel), AMessage]) + #13#10);
      _fileStream.WriteBuffer(LineBytes[0], Length(LineBytes));
    except
      // 写入失败（磁盘满、文件被占用等）时关闭流并静默处理，不影响业务流程
      CloseStream;
    end;
  finally
    _lock.Leave;
  end;
end;

procedure TLogger.Write(ALevel: TLogLevel; const AMessage: string; const AArgs: array of const);
begin
  Write(ALevel, Format(AMessage, AArgs));
end;

procedure TLogger.Write(const AMessage: string);
begin
  Write(llInfo, AMessage);
end;

procedure TLogger.Write(const AMessage: string; const AArgs: array of const);
begin
  Write(llInfo, Format(AMessage, AArgs));
end;

procedure TLogger.Debug(const AMessage: string);
begin
  Write(llDebug, AMessage);
end;

procedure TLogger.Debug(const AMessage: string; const AArgs: array of const);
begin
  Write(llDebug, Format(AMessage, AArgs));
end;

procedure TLogger.Info(const AMessage: string);
begin
  Write(llInfo, AMessage);
end;

procedure TLogger.Info(const AMessage: string; const AArgs: array of const);
begin
  Write(llInfo, Format(AMessage, AArgs));
end;

procedure TLogger.Warn(const AMessage: string);
begin
  Write(llWarn, AMessage);
end;

procedure TLogger.Warn(const AMessage: string; const AArgs: array of const);
begin
  Write(llWarn, Format(AMessage, AArgs));
end;

procedure TLogger.Error(const AMessage: string);
begin
  Write(llError, AMessage);
end;

procedure TLogger.Error(const AMessage: string; const AArgs: array of const);
begin
  Write(llError, Format(AMessage, AArgs));
end;

initialization
  _GLogger := TLogger.Create;

finalization
  _GLogger.Free;
  _GLogger := nil;

end.