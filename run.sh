#!/usr/bin/env bash
# =============================================================================
# Dreamlog - 올인원 실행 스크립트
#
#   이 스크립트 하나로:
#     1) Android SDK 탐지 (없으면 프로젝트 안 ./android-sdk 로 자동 설치)
#     2) 필요한 SDK 패키지 / 시스템 이미지 설치
#     3) AVD(에뮬레이터 가상 기기) 생성 (없을 때만)
#     4) 앱 빌드 (./gradlew :app:assembleDebug)
#     5) 에뮬레이터 부팅
#     6) APK 설치
#     7) 앱 실행
#
#   macOS(Apple Silicon/Intel) 와 Linux 모두 지원합니다.
#   모든 도구/캐시는 프로젝트 폴더 안에만 설치됩니다(전역 설치 없음).
#
#   사용법:
#     ./run.sh                # 빌드 + 에뮬 실행 + 설치 + 앱 실행
#     ./run.sh --headless     # 에뮬레이터 창 없이(서버/CI용)
#     ./run.sh --window       # 강제로 창 띄우기(GUI 환경)
#     ./run.sh --build-only    # 빌드만
#     ./run.sh --cold         # 스냅샷 무시하고 콜드 부팅
#     ./run.sh --wipe         # AVD 데이터 초기화 후 부팅
#     ./run.sh -h | --help
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 설정값
# ---------------------------------------------------------------------------
APP_ID="com.dreamlog.app"
MAIN_ACTIVITY=".MainActivity"
AVD_NAME="dreamlog"
API="35"
DEVICE_PROFILE="pixel_7"
CMDLINE_TOOLS_VERSION="11076708"   # 자동 부트스트랩 시 받을 command-line tools 버전

# 프로젝트 루트 = 이 스크립트가 있는 디렉토리
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 모든 Android 관련 파일을 프로젝트 안에 격리
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$PROJECT_DIR/.gradle}"
export ANDROID_USER_HOME="$PROJECT_DIR/.android"
export ANDROID_AVD_HOME="$PROJECT_DIR/.android/avd"
mkdir -p "$ANDROID_AVD_HOME"

# ---------------------------------------------------------------------------
# 옵션 파싱
# ---------------------------------------------------------------------------
HEADLESS=""        # "" = 자동, 1 = 강제 headless, 0 = 강제 window
BUILD_ONLY=0
COLD_BOOT=0
WIPE_DATA=0
for arg in "$@"; do
  case "$arg" in
    --headless)   HEADLESS=1 ;;
    --window)     HEADLESS=0 ;;
    --build-only) BUILD_ONLY=1 ;;
    --cold)       COLD_BOOT=1 ;;
    --wipe)       WIPE_DATA=1 ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "알 수 없는 옵션: $arg (도움말: ./run.sh --help)"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 색상 로그
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_END=$'\033[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_END=""
fi
info() { echo "${C_INFO}▶ $*${C_END}"; }
ok()   { echo "${C_OK}✔ $*${C_END}"; }
warn() { echo "${C_WARN}⚠ $*${C_END}"; }
err()  { echo "${C_ERR}✘ $*${C_END}" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# OS / 아키텍처 감지
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin) HOST_OS="mac" ;;
  Linux)  HOST_OS="linux" ;;
  *) die "지원하지 않는 OS: $(uname -s)" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ABI="arm64-v8a" ;;
  x86_64|amd64)  ABI="x86_64" ;;
  *) die "지원하지 않는 아키텍처: $(uname -m)" ;;
esac
SYSTEM_IMAGE="system-images;android-${API};google_apis;${ABI}"
info "환경: OS=${HOST_OS}, ABI=${ABI}, 시스템 이미지=${SYSTEM_IMAGE}"

# headless 자동 결정: Linux 이고 DISPLAY 가 없으면 headless
if [ -z "$HEADLESS" ]; then
  if [ "$HOST_OS" = "linux" ] && [ -z "${DISPLAY:-}" ]; then
    HEADLESS=1
  else
    HEADLESS=0
  fi
fi

# ---------------------------------------------------------------------------
# Android SDK 탐지 (없으면 프로젝트 안에 자동 설치)
# ---------------------------------------------------------------------------
find_sdk() {
  local candidates=(
    "$PROJECT_DIR/android-sdk"
    "${ANDROID_HOME:-}"
    "${ANDROID_SDK_ROOT:-}"
  )
  if [ "$HOST_OS" = "mac" ]; then
    candidates+=("$HOME/Library/Android/sdk")
  else
    candidates+=("$HOME/Android/Sdk")
  fi
  for c in "${candidates[@]}"; do
    [ -n "$c" ] || continue
    if [ -x "$c/cmdline-tools/latest/bin/sdkmanager" ] || [ -d "$c/platform-tools" ]; then
      echo "$c"; return 0
    fi
  done
  return 1
}

bootstrap_sdk() {
  local sdk="$PROJECT_DIR/android-sdk"
  warn "Android SDK를 찾지 못해 프로젝트 안($sdk)에 command-line tools를 설치합니다."
  local zip_os
  [ "$HOST_OS" = "mac" ] && zip_os="mac" || zip_os="linux"
  local url="https://dl.google.com/android/repository/commandlinetools-${zip_os}-${CMDLINE_TOOLS_VERSION}_latest.zip"
  mkdir -p "$sdk/cmdline-tools"
  local tmp="$sdk/cmdline-tools/_dl.zip"
  info "다운로드: $url"
  curl -fsSL -o "$tmp" "$url" || die "command-line tools 다운로드 실패"
  rm -rf "$sdk/cmdline-tools/_x"; mkdir -p "$sdk/cmdline-tools/_x"
  unzip -q "$tmp" -d "$sdk/cmdline-tools/_x"
  rm -rf "$sdk/cmdline-tools/latest"
  mv "$sdk/cmdline-tools/_x/cmdline-tools" "$sdk/cmdline-tools/latest"
  rm -rf "$sdk/cmdline-tools/_x" "$tmp"
  echo "$sdk"
}

SDK_DIR="$(find_sdk || true)"
if [ -z "$SDK_DIR" ]; then
  SDK_DIR="$(bootstrap_sdk)"
fi
export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
ok "SDK 위치: $SDK_DIR"

SDKMANAGER="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$SDK_DIR/cmdline-tools/latest/bin/avdmanager"
ADB="$SDK_DIR/platform-tools/adb"
EMULATOR="$SDK_DIR/emulator/emulator"

# local.properties (Gradle 가 SDK 경로를 찾도록) - 현재 SDK 위치로 갱신
printf 'sdk.dir=%s\n' "$SDK_DIR" > "$PROJECT_DIR/local.properties"

# ---------------------------------------------------------------------------
# 필요한 SDK 패키지 설치
# ---------------------------------------------------------------------------
ensure_packages() {
  local need=()
  [ -x "$ADB" ]                         || need+=("platform-tools")
  [ -x "$EMULATOR" ]                    || need+=("emulator")
  [ -d "$SDK_DIR/platforms/android-${API}" ]   || need+=("platforms;android-${API}")
  [ -d "$SDK_DIR/build-tools/${API}.0.0" ]     || need+=("build-tools;${API}.0.0")
  [ -d "$SDK_DIR/system-images/android-${API}/google_apis/${ABI}" ] || need+=("$SYSTEM_IMAGE")

  if [ "${#need[@]}" -gt 0 ]; then
    info "SDK 패키지 설치: ${need[*]}"
    yes | "$SDKMANAGER" --sdk_root="$SDK_DIR" --licenses >/dev/null 2>&1 || true
    "$SDKMANAGER" --sdk_root="$SDK_DIR" "${need[@]}"
  fi
  # 다운로드 후 경로 재설정
  ADB="$SDK_DIR/platform-tools/adb"
  EMULATOR="$SDK_DIR/emulator/emulator"
  ok "SDK 패키지 확인 완료"
}
ensure_packages

# ---------------------------------------------------------------------------
# Linux: KVM 가속 점검
# ---------------------------------------------------------------------------
check_kvm() {
  [ "$HOST_OS" = "linux" ] || return 0
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ok "KVM 하드웨어 가속 사용 가능"
  else
    warn "KVM(/dev/kvm) 접근 권한이 없어 에뮬레이터가 매우 느릴 수 있습니다."
    echo "   아래 명령으로 권한을 부여하세요(비밀번호 필요):"
    echo "     sudo usermod -aG kvm \"$USER\" && newgrp kvm"
    echo "   또는 즉시 적용(재부팅 시 초기화):"
    echo "     sudo setfacl -m u:\"$USER\":rw /dev/kvm"
  fi
}
check_kvm

# ---------------------------------------------------------------------------
# AVD 생성 (없을 때만)
# ---------------------------------------------------------------------------
ensure_avd() {
  if "$AVDMANAGER" list avd 2>/dev/null | grep -q "Name: ${AVD_NAME}$"; then
    ok "AVD '${AVD_NAME}' 이미 존재"
    return 0
  fi
  info "AVD '${AVD_NAME}' 생성 중 (${DEVICE_PROFILE}, ${SYSTEM_IMAGE})"
  if ! echo "no" | "$AVDMANAGER" create avd \
        -n "$AVD_NAME" -k "$SYSTEM_IMAGE" -d "$DEVICE_PROFILE" --force 2>/dev/null; then
    warn "기기 프로필 '${DEVICE_PROFILE}' 사용 실패 → 기본 프로필로 재시도"
    echo "no" | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" --force
  fi
  ok "AVD '${AVD_NAME}' 생성 완료"
}
ensure_avd

# ---------------------------------------------------------------------------
# 앱 빌드
# ---------------------------------------------------------------------------
info "앱 빌드: ./gradlew :app:assembleDebug"
( cd "$PROJECT_DIR" && ./gradlew :app:assembleDebug )
APK="$PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK" ] || die "APK를 찾을 수 없습니다: $APK"
ok "빌드 완료: $APK"

if [ "$BUILD_ONLY" -eq 1 ]; then
  ok "빌드만 수행(--build-only). 종료."
  exit 0
fi

# ---------------------------------------------------------------------------
# 에뮬레이터 부팅
# ---------------------------------------------------------------------------
"$ADB" start-server >/dev/null 2>&1 || true

emulator_online() {
  "$ADB" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/{found=1} END{exit found?0:1}'
}

if emulator_online; then
  ok "이미 실행 중인 에뮬레이터를 사용합니다."
else
  info "에뮬레이터 부팅: ${AVD_NAME} ($([ "$HEADLESS" -eq 1 ] && echo headless || echo window))"
  EMU_OPTS=(-avd "$AVD_NAME" -netdelay none -netspeed full -no-boot-anim)
  [ "$COLD_BOOT" -eq 1 ] && EMU_OPTS+=(-no-snapshot-load)
  [ "$WIPE_DATA" -eq 1 ] && EMU_OPTS+=(-wipe-data)
  if [ "$HEADLESS" -eq 1 ]; then
    EMU_OPTS+=(-no-window -no-audio -gpu swiftshader_indirect)
  fi
  mkdir -p "$ANDROID_USER_HOME"
  EMU_LOG="$ANDROID_USER_HOME/emulator.log"
  nohup "$EMULATOR" "${EMU_OPTS[@]}" >"$EMU_LOG" 2>&1 &
  EMU_PID=$!
  info "에뮬레이터 PID=$EMU_PID, 로그: $EMU_LOG"

  info "기기 연결 대기..."
  "$ADB" wait-for-device
  info "부팅 완료 대기 (최대 5분)..."
  boot_ok=0
  for _ in $(seq 1 150); do
    if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      boot_ok=1; break
    fi
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
      err "에뮬레이터 프로세스가 종료되었습니다. 로그 확인:"; tail -20 "$EMU_LOG" >&2; exit 1
    fi
    sleep 2
  done
  [ "$boot_ok" -eq 1 ] || die "에뮬레이터 부팅 시간 초과. 로그: $EMU_LOG"
  ok "에뮬레이터 부팅 완료"
fi

# 잠금 화면 해제(있다면)
"$ADB" shell input keyevent 82 >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# APK 설치 & 앱 실행
# ---------------------------------------------------------------------------
info "APK 설치 중..."
"$ADB" install -r "$APK"
ok "설치 완료: $APP_ID"

info "앱 실행..."
"$ADB" shell am start -n "${APP_ID}/${APP_ID}${MAIN_ACTIVITY}" >/dev/null
ok "Dreamlog 실행 완료 🎉"

if [ "$HEADLESS" -eq 1 ]; then
  echo
  info "headless 모드입니다. 현재 화면을 PNG로 저장하려면:"
  echo "   \"$ADB\" exec-out screencap -p > screen.png"
fi
