#!/bin/bash
# Standalone installer for Terminal. Never executes remote code.
set -euo pipefail
export LC_ALL=C

task_version='2.1.0'
task_build='30'
task_dmg_sha='aeb17ef9a8b7b38df5f4f779d554ce338acf2e34bcbc37a3ed12b853ef5b4f79'
task_dmg_url='https://github.com/Atlantik56/MacUSBStudio/releases/download/v2.1.0/Mac.USB.Studio-2.1.0.dmg'
task_destination="$HOME/Applications"
task_image=''
task_verify_only=0
task_open=1
task_yes=0
task_temp=''
task_mount=''
task_stage=''
task_lock=''
task_backup=''
task_target=''

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
cleanup() {
  local task_status=$? task_may_remove_temp=1
  trap - EXIT
  if [[ -n "$task_backup" && -d "$task_backup" && ! -e "$task_target" && ! -L "$task_target" ]]; then
    /bin/mv "$task_backup" "$task_target" || printf 'Прежняя копия сохранена: %s\n' "$task_backup" >&2
  fi
  if [[ -n "$task_mount" ]]; then
    if ! /usr/bin/hdiutil detach "$task_mount" >/dev/null; then
      printf 'Не удалось отключить установочный DMG: %s\n' "$task_mount" >&2
      task_may_remove_temp=0
      [[ "$task_status" -ne 0 ]] || task_status=1
    fi
  fi
  [[ -z "$task_stage" ]] || /bin/rm -rf "$task_stage"
  if [[ -n "$task_temp" && "$task_may_remove_temp" -eq 1 ]]; then /bin/rm -rf "$task_temp"; fi
  [[ -z "$task_lock" ]] || /bin/rmdir "$task_lock" 2>/dev/null || true
  exit "$task_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) task_verify_only=1; task_open=0; shift ;;
    --no-open) task_open=0; shift ;;
    --yes) task_yes=1; shift ;;
    --image|--destination)
      [[ $# -ge 2 && -n "$2" ]] || fail "Нужен аргумент для $1."
      if [[ "$1" == '--image' ]]; then task_image="$2"; else task_destination="$2"; fi
      shift 2 ;;
    *) fail "Неизвестный параметр: $1" ;;
  esac
done
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'Нужна macOS.'
[[ "$EUID" -ne 0 ]] || fail 'Запустите скрипт от своего пользователя, без sudo.'
task_os=$(/usr/bin/sw_vers -productVersion)
(( ${task_os%%.*} >= 13 )) || fail 'Нужна macOS 13 или новее.'

printf 'Mac USB Studio %s (%s) — установка для текущего пользователя.\n' "$task_version" "$task_build"
printf 'Скрипт скачает фиксированный релиз с GitHub и проверит SHA-256 и подписи.\n'
printf 'USB не изменяется. Пароль администратора для установки не нужен.\n\n'
if [[ "$task_verify_only" -eq 0 && "$task_yes" -eq 0 ]]; then
  [[ -t 0 ]] || fail 'Запустите скрипт в Terminal; автоматический запуск требует --yes.'
  printf 'Установить в %s? Прежняя копия сохранится. [д/Н] ' "$task_destination"
  IFS= read -r task_answer || exit 0
  case "$task_answer" in д|Д|да|Да|y|Y|yes|YES) ;; *) printf 'Установка отменена.\n'; exit 0 ;; esac
fi

check_processes() {
  local task_name task_code
  for task_name in MacUSBStudio MacUSBRecorder; do
    if /usr/bin/pgrep -x "$task_name" >/dev/null; then
      fail 'Mac USB Studio или процесс записи работает. Дождитесь окончания записи, закройте приложение и повторите запуск скрипта.'
    else
      task_code=$?
      [[ "$task_code" -eq 1 ]] || fail 'Не удалось проверить процессы; установка остановлена.'
    fi
  done
}
read_plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
verify_app() {
  [[ -d "$1" && ! -L "$1" ]] || fail 'В образе нет ожидаемого приложения.'
  [[ "$(read_plist "$1" CFBundleIdentifier)" == 'local.mac-usb-studio' ]] || fail 'Неверный идентификатор приложения.'
  [[ "$(read_plist "$1" CFBundleShortVersionString)" == "$task_version" ]] || fail 'Неверная версия приложения.'
  [[ "$(read_plist "$1" CFBundleVersion)" == "$task_build" ]] || fail 'Неверный номер сборки.'
  /usr/bin/codesign --verify --strict --all-architectures "$1" 2>&1 || fail 'Подпись приложения повреждена.'
  /usr/bin/codesign --verify --strict --all-architectures "$1/Contents/Helpers/MacUSBRecorder" 2>&1 || fail 'Подпись процесса записи повреждена.'
}
require_unquarantined() {
  local task_attributes
  task_attributes=$(/usr/bin/xattr -r "$1") || fail 'Не удалось проверить атрибуты файлов.'
  [[ "$task_attributes" != *com.apple.quarantine* ]] || fail 'macOS пометила скачанные файлы карантином. Скрипт не снимает его. Используйте обычную установку DMG и разрешение запуска в настройках macOS.'
}
version_greater() {
  local task_left task_right task_index task_l task_r
  IFS='.' read -r -a task_left <<< "$1"
  IFS='.' read -r -a task_right <<< "$2"
  for (( task_index=0; task_index<${#task_left[@]} || task_index<${#task_right[@]}; task_index++ )); do
    task_l=${task_left[task_index]:-0}; task_r=${task_right[task_index]:-0}
    if (( 10#$task_l > 10#$task_r )); then return 0; fi
    if (( 10#$task_l < 10#$task_r )); then return 1; fi
  done
  return 1
}
check_target() {
  [[ ! -L "$task_target" ]] || fail 'Путь приложения является символической ссылкой.'
  if [[ -e "$task_target" ]]; then
    [[ -d "$task_target" && "$(read_plist "$task_target" CFBundleIdentifier)" == 'local.mac-usb-studio' ]] || fail 'В папке назначения есть другой файл или приложение с таким именем.'
    local task_old_version task_old_build
    task_old_version=$(read_plist "$task_target" CFBundleShortVersionString) || fail 'Не удалось прочитать версию прежней копии.'
    task_old_build=$(read_plist "$task_target" CFBundleVersion) || fail 'Не удалось прочитать номер прежней сборки.'
    [[ "$task_old_version" =~ ^[0-9]+(\.[0-9]+)*$ && "$task_old_build" =~ ^[0-9]+$ ]] || fail 'Версия прежней копии неизвестна.'
    if version_greater "$task_old_version" "$task_version" ||
       { [[ "$task_old_version" == "$task_version" ]] && (( 10#$task_old_build > 10#$task_build )); }; then
      fail 'Установлена более новая версия. Этот скрипт не понижает версию.'
    fi
  fi
}

if [[ "$task_verify_only" -eq 0 ]]; then
  check_processes
  [[ "$task_destination" == /* && "$task_destination" != '/' ]] || fail 'Неверная папка установки.'
  [[ ! -L "$task_destination" ]] || fail 'Папка установки является символической ссылкой.'
  /bin/mkdir -p "$task_destination"
  task_destination=$(cd "$task_destination" && pwd -P)
  [[ -w "$task_destination" ]] || fail 'Нет доступа к папке установки.'
  task_target="$task_destination/Mac USB Studio.app"
  task_lock_path="$task_destination/.mac-usb-studio-install.lock"
  /bin/mkdir "$task_lock_path" 2>/dev/null || fail 'Другая установка работает или осталась папка .mac-usb-studio-install.lock. Приложение не изменено.'
  task_lock="$task_lock_path"
  check_target
fi

task_temp=$(/usr/bin/mktemp -d /private/tmp/mac-usb-studio-install.XXXXXX)
if [[ -z "$task_image" ]]; then
  printf 'Скачивание Mac USB Studio с GitHub…\n'
  /usr/bin/curl --fail --location --progress-bar --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 2 \
    --output "$task_temp/release.dmg" "$task_dmg_url" || fail 'Загрузка не завершилась. Приложение не изменено.'
else
  [[ -f "$task_image" ]] || fail 'DMG не найден.'
  /usr/bin/ditto "$task_image" "$task_temp/release.dmg"
fi
task_actual_sha=$(/usr/bin/shasum -a 256 "$task_temp/release.dmg")
[[ "${task_actual_sha%% *}" == "$task_dmg_sha" ]] || fail 'SHA-256 не совпадает с фиксированным релизом. Приложение не изменено.'
printf 'SHA-256 подтверждён. Проверяю приложение…\n'
require_unquarantined "$task_temp/release.dmg"
/bin/mkdir "$task_temp/volume"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$task_temp/volume" "$task_temp/release.dmg" >/dev/null || fail 'Не удалось открыть установочный DMG.'
task_mount="$task_temp/volume"
task_source="$task_mount/Mac USB Studio.app"
verify_app "$task_source"
require_unquarantined "$task_source"
if [[ "$task_verify_only" -eq 1 ]]; then
  printf 'Релиз %s (%s) проверен. Установка не выполнялась.\n' "$task_version" "$task_build"
  exit 0
fi

task_stage=$(/usr/bin/mktemp -d "$task_destination/.mac-usb-studio-install.XXXXXX")
printf 'Копирование приложения…\n'
/usr/bin/ditto "$task_source" "$task_stage/Mac USB Studio.app"
verify_app "$task_stage/Mac USB Studio.app"
require_unquarantined "$task_stage/Mac USB Studio.app"
/usr/bin/hdiutil detach "$task_mount" >/dev/null || fail 'Не удалось отключить установочный DMG; приложение не изменено.'
task_mount=''
check_processes
check_target
if [[ -e "$task_target" ]]; then
  task_backup_candidate="$task_destination/Mac USB Studio.previous-$(/bin/date +%Y%m%d-%H%M%S)-$$.app"
  [[ ! -e "$task_backup_candidate" && ! -L "$task_backup_candidate" ]] || fail 'Путь резервной копии занят.'
  /bin/mv "$task_target" "$task_backup_candidate"
  task_backup="$task_backup_candidate"
fi
/bin/mv "$task_stage/Mac USB Studio.app" "$task_target"
printf 'Mac USB Studio %s установлен:\n%s\n' "$task_version" "$task_target"
[[ -z "$task_backup" ]] || printf '\nПрежняя копия сохранена:\n%s\n' "$task_backup"
printf '\nПароль администратора и доступ к USB запрашиваются позже при записи в приложении.\n'
if [[ "$task_open" -eq 1 ]]; then
  /usr/bin/open "$task_target" || printf 'Откройте установленное приложение из указанной папки.\n'
fi
