#ifndef AppVersion
  #error Pass AppVersion, BundleDir and RuntimeDir to ISCC.
#endif

[Setup]
AppId={{413220BB-955D-4BDB-94A0-1A1CEA4682E9}
AppName=All in One
AppVersion={#AppVersion}
AppPublisher=S. M. Shahin Reza Sifat
AppPublisherURL=https://github.com/shahinrezasifat/all-in-one
DefaultDirName={localappdata}\Programs\All in One
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\snaptube_pure.exe
OutputBaseFilename=all-in-one-v{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#RuntimeDir}\vc_redist.x64.exe"; Flags: dontcopy
Source: "{#RuntimeDir}\MicrosoftEdgeWebview2Setup.exe"; Flags: dontcopy

[Icons]
Name: "{userprograms}\All in One"; Filename: "{app}\snaptube_pure.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\snaptube_pure.exe"; WorkingDir: "{app}"; Description: "Launch All in One"; Flags: nowait postinstall skipifsilent

[Code]
const
  RuntimeKey = 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';
  WebViewKey = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function HasVisualCpp: Boolean;
var
  Installed, Major, Minor: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM64, RuntimeKey, 'Installed', Installed) and
    (Installed = 1) and
    RegQueryDWordValue(HKLM64, RuntimeKey, 'Major', Major) and
    RegQueryDWordValue(HKLM64, RuntimeKey, 'Minor', Minor) and
    ((Major > 14) or ((Major = 14) and (Minor >= 38)));
end;

function HasWebViewAt(const Root: Integer): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(Root, WebViewKey, 'pv', Version) and
    (Version <> '') and (Version <> '0.0.0.0');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
  if not HasVisualCpp then
  begin
    ExtractTemporaryFile('vc_redist.x64.exe');
    if not ShellExec('runas', ExpandConstant('{tmp}\vc_redist.x64.exe'),
        '/install /quiet /norestart', '', SW_HIDE, ewWaitUntilTerminated, Code) or
        ((Code <> 0) and (Code <> 3010) and (Code <> 1638)) or not HasVisualCpp then
    begin
      Result := 'Microsoft Visual C++ Runtime could not be installed. Allow administrator access or install the x64 runtime from Microsoft, then retry.';
      Exit;
    end;
    NeedsRestart := Code = 3010;
  end;

  if not (HasWebViewAt(HKLM32) or HasWebViewAt(HKCU)) then
  begin
    ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
    if not Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'),
        '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, Code) or
        not (HasWebViewAt(HKLM32) or HasWebViewAt(HKCU)) then
      Result := 'Microsoft Edge WebView2 Runtime could not be installed. Connect to the internet or install it from Microsoft, then retry.';
  end;
end;
