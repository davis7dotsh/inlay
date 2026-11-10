Unicode True
RequestExecutionLevel user
ManifestDPIAware true
AllowSkipFiles off
Name "Inlay"
OutFile "../build/windows/Inlay-Setup.exe"
; Keep a portable installation at Programs\Inlay\Inlay.exe usable for rollback.
InstallDir "$LOCALAPPDATA\Programs\Inlay\Client"
Icon "Inlay.ico"
!ifndef BUILD_ID
    !define BUILD_ID "Development"
!endif
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\InlayClient"
!include "MUI2.nsh"
!define MUI_WELCOMEPAGE_TITLE "Install Inlay for Windows"
!define MUI_WELCOMEPAGE_TEXT "Install Inlay for your Windows account. If you are updating an installer-based copy, finish dictating and quit it from the tray first. Your settings and server connection will be kept."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TEXT "Open Inlay from the Start menu. If you were using a portable copy, quit it from the tray first."
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section
    SetShellVarContext current
    SetOutPath "$INSTDIR"
    File "../build/windows/Inlay.exe"
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    CreateShortcut "$SMPROGRAMS\Inlay.lnk" "$INSTDIR\Inlay.exe"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "Inlay"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${BUILD_ID}"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Inlay"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\Inlay.exe"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
    IfErrors 0 done
    Abort "Could not finish registering Inlay. Run setup again to repair the installation."
    done:
SectionEnd

Section "Uninstall"
    SetShellVarContext current
    Delete "$INSTDIR\Inlay.exe"
    IfErrors 0 removeRegistration
    Abort "Could not remove Inlay. Quit it from the tray and try again."
    removeRegistration:
    Delete "$SMPROGRAMS\Inlay.lnk"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"
SectionEnd
