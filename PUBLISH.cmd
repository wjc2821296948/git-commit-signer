@echo off
setlocal EnableExtensions
pushd "%~dp0"

echo.
echo Git Commit Signer - Publish to GitHub
 echo =====================================
echo This script creates a PUBLIC repository and pushes the V0.1 source.
echo It uses your existing global SSH commit-signing configuration.
echo.

if exist ".git" (
    echo [ERROR] This folder already contains a .git directory.
    echo To avoid changing an existing repository, publishing has been stopped.
    goto :failed
)

where git.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Git was not found in PATH.
    goto :failed
)

where gh.exe >nul 2>&1
if errorlevel 1 (
    if not exist "D:\GitHub-CLI\gh.exe" (
        echo [ERROR] GitHub CLI was not found in PATH or D:\GitHub-CLI\gh.exe.
        goto :failed
    )
    set "GH_EXE=D:\GitHub-CLI\gh.exe"
) else (
    set "GH_EXE=gh"
)

"%GH_EXE%" auth status >nul 2>&1
if errorlevel 1 (
    echo [ERROR] GitHub CLI is not authenticated. Run: gh auth login
    goto :failed
)

set "GH_LOGIN="
for /f "delims=" %%A in ('"%GH_EXE%" api user --jq .login 2^>nul') do set "GH_LOGIN=%%A"
if /i not "%GH_LOGIN%"=="wjc2821296948" (
    echo [ERROR] Expected GitHub account: wjc2821296948
    echo [ERROR] Current GitHub CLI account: %GH_LOGIN%
    goto :failed
)

echo [OK] GitHub CLI account: %GH_LOGIN%

set "GPG_FORMAT="
for /f "delims=" %%A in ('git config --global --get gpg.format 2^>nul') do set "GPG_FORMAT=%%A"
if /i not "%GPG_FORMAT%"=="ssh" (
    echo [ERROR] Global gpg.format is not ssh.
    goto :failed
)

set "SIGNING_KEY="
for /f "delims=" %%A in ('git config --global --get user.signingkey 2^>nul') do set "SIGNING_KEY=%%A"
if not defined SIGNING_KEY (
    echo [ERROR] Global user.signingkey is not configured.
    goto :failed
)
if not exist "%SIGNING_KEY%" (
    echo [ERROR] Configured SSH signing public key was not found:
    echo %SIGNING_KEY%
    goto :failed
)

set "AUTO_SIGN="
for /f "delims=" %%A in ('git config --global --get commit.gpgsign 2^>nul') do set "AUTO_SIGN=%%A"
if /i not "%AUTO_SIGN%"=="true" (
    echo [ERROR] Global commit.gpgsign is not true.
    goto :failed
)

set "GIT_NAME="
for /f "delims=" %%A in ('git config --get user.name 2^>nul') do set "GIT_NAME=%%A"
set "GIT_EMAIL="
for /f "delims=" %%A in ('git config --get user.email 2^>nul') do set "GIT_EMAIL=%%A"
if not defined GIT_NAME (
    echo [ERROR] Git user.name is not configured.
    goto :failed
)
if not defined GIT_EMAIL (
    echo [ERROR] Git user.email is not configured.
    goto :failed
)

echo [OK] SSH signing format: %GPG_FORMAT%
echo [OK] Automatic commit signing: %AUTO_SIGN%
echo [OK] Signing public key exists.
echo [OK] Git author: %GIT_NAME% ^<%GIT_EMAIL%^>
echo.
echo About to create: https://github.com/wjc2821296948/git-commit-signer
echo Visibility: PUBLIC
echo.
choice /c YN /n /m "Continue and publish this repository? [Y/N] "
if errorlevel 2 goto :cancelled

git init -b main
if errorlevel 1 goto :failed

git add -A
if errorlevel 1 goto :failed

git commit -m "Initial release: Git Commit Signer v0.1.0"
if errorlevel 1 goto :failed

git cat-file -p HEAD | findstr /c:"BEGIN SSH SIGNATURE" >nul
if errorlevel 1 (
    echo [ERROR] The initial commit does not contain an SSH signature.
    echo [ERROR] No GitHub repository has been created or pushed.
    goto :failed
)

echo [OK] Initial commit contains an SSH signature.
echo.

"%GH_EXE%" repo create wjc2821296948/git-commit-signer --public --source . --remote origin --push --description "Windows-first GitHub repository inventory and commit-signing audit tool"
if errorlevel 1 (
    echo [ERROR] GitHub repository creation or push failed.
    echo [INFO] The signed local commit is still available in this folder.
    goto :failed
)

echo.
echo [SUCCESS] Repository published:
echo https://github.com/wjc2821296948/git-commit-signer
echo.
pause
popd
exit /b 0

:cancelled
echo [CANCELLED] No repository was created.
pause
popd
exit /b 0

:failed
echo.
echo [FAILED] No automatic retry was attempted.
pause
popd
exit /b 1
