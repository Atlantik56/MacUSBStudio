#!/bin/bash
# Installs the fixed public release for the current user. No global Gatekeeper changes.
set -euo pipefail
export LC_ALL=C

task_version='2.1.0'
task_build='30'
task_zip_sha='bb5bb76649c74b196a5b434949676d30defd42ce558085b1503334a83f712ba0'
task_zip_url='https://github.com/Atlantik56/MacUSBStudio/releases/download/v2.1.0/Mac.USB.Studio-2.1.0.zip'
task_destination="$HOME/Applications"
task_archive=''
task_open=1
task_verify_only=0
task_temp=''
task_stage=''
task_lock=''
task_backup=''
task_target=''

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Установка Mac USB Studio 2.1.0 (30) для текущего пользователя.
  bash install.sh                         Установить в ~/Applications и открыть
  bash install.sh --no-open               Установить без запуска окна
  bash install.sh --verify-only           Проверить релиз без установки
  bash install.sh --archive FILE          Использовать сохранённый ZIP того же релиза
  bash install.sh --destination DIR       Выбрать абсолютный путь папки установки

Скрипт проверяет SHA-256 и локальные ad-hoc подписи. Только у установленной
копии Mac USB Studio удаляется com.apple.quarantine. Это обход проверки
происхождения Gatekeeper, а не подпись или нотарификация Apple.
USAGE
}
cleanup() {
  local task_status=$?
  trap - EXIT
  if [[ -n "$task_backup" && -d "$task_backup" && ! -e "$task_target" && ! -L "$task_target" ]]; then
    /bin/mv "$task_backup" "$task_target" || printf 'Предыдущая копия сохранена: %s\n' "$task_backup" >&2
  fi
  [[ -z "$task_stage" ]] || /bin/rm -rf "$task_stage"
  [[ -z "$task_temp" ]] || /bin/rm -rf "$task_temp"
  [[ -z "$task_lock" ]] || /bin/rmdir "$task_lock" 2>/dev/null || true
  exit "$task_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open) task_open=0; shift ;;
    --verify-only) task_verify_only=1; task_open=0; shift ;;
    --archive|--destination)
      [[ $# -ge 2 && -n "$2" ]] || fail "Нужен аргумент для $1."
      if [[ "$1" == '--archive' ]]; then task_archive="$2"; else task_destination="$2"; fi
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Неизвестный параметр: $1" ;;
  esac
done
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'Этот скрипт работает только в macOS.'
[[ "$EUID" -ne 0 ]] || fail 'Запустите скрипт от своего пользователя, без sudo.'
task_os=$(/usr/bin/sw_vers -productVersion)
(( ${task_os%%.*} >= 13 )) || fail 'Нужна macOS 13 или новее.'

check_processes() {
  local task_name task_code
  for task_name in MacUSBStudio MacUSBRecorder; do
    if /usr/bin/pgrep -x "$task_name" >/dev/null; then
      fail 'Mac USB Studio или процесс записи работает. Дождитесь завершения записи и закройте приложение.'
    else
      task_code=$?
      [[ "$task_code" -eq 1 ]] || fail 'Не удалось проверить запущенные процессы; установка остановлена.'
    fi
  done
}
read_plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
verify_app() {
  [[ -d "$1" && ! -L "$1" ]] || fail 'В архиве нет ожидаемого приложения.'
  [[ "$(read_plist "$1" CFBundleIdentifier)" == 'local.mac-usb-studio' ]] || fail 'Неверный идентификатор приложения.'
  [[ "$(read_plist "$1" CFBundleShortVersionString)" == "$task_version" ]] || fail 'Неверная версия приложения.'
  [[ "$(read_plist "$1" CFBundleVersion)" == "$task_build" ]] || fail 'Неверный номер сборки.'
  /usr/bin/codesign --verify --strict --all-architectures "$1" || fail 'Подпись приложения повреждена.'
  /usr/bin/codesign --verify --strict --all-architectures "$1/Contents/Helpers/MacUSBRecorder" || fail 'Подпись процесса записи повреждена.'
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
  [[ ! -L "$task_target" ]] || fail 'Путь приложения является символической ссылкой; установка остановлена.'
  if [[ -e "$task_target" ]]; then
    [[ -d "$task_target" && "$(read_plist "$task_target" CFBundleIdentifier)" == 'local.mac-usb-studio' ]] || fail 'В папке назначения уже есть другой файл или приложение с таким именем.'
    local task_old_version task_old_build
    task_old_version=$(read_plist "$task_target" CFBundleShortVersionString) || fail 'Не удалось прочитать версию установленной копии.'
    task_old_build=$(read_plist "$task_target" CFBundleVersion) || fail 'Не удалось прочитать номер установленной сборки.'
    [[ "$task_old_version" =~ ^[0-9]+(\.[0-9]+)*$ && "$task_old_build" =~ ^[0-9]+$ ]] || fail 'Версия установленной копии неизвестна; установка остановлена.'
    if version_greater "$task_old_version" "$task_version" ||
       { [[ "$task_old_version" == "$task_version" ]] && (( 10#$task_old_build > 10#$task_build )); }; then
      fail 'Установлена более новая версия Mac USB Studio. Этот скрипт не понижает версию.'
    fi
  fi
}

printf 'Mac USB Studio %s (%s).\n' "$task_version" "$task_build"
printf 'У этой копии приложения будет снят карантин скачанного файла; нотарификации Apple нет.\n'
task_temp=$(/usr/bin/mktemp -d /private/tmp/mac-usb-studio-download.XXXXXX)
if [[ -z "$task_archive" ]]; then
  printf 'Скачивание фиксированного релиза с GitHub…\n'
  /usr/bin/curl --fail --location --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 2 \
    --output "$task_temp/release.zip" "$task_zip_url" || fail 'Загрузка не завершилась. Приложение не изменено.'
else
  [[ -f "$task_archive" ]] || fail 'Сохранённый ZIP не найден.'
  /bin/cp "$task_archive" "$task_temp/release.zip"
fi
task_actual_sha=$(/usr/bin/shasum -a 256 "$task_temp/release.zip")
[[ "${task_actual_sha%% *}" == "$task_zip_sha" ]] || fail 'SHA-256 архива не совпадает с фиксированным релизом. Установка не запускалась.'
printf 'SHA-256 подтверждён. Проверка приложения…\n'
/usr/bin/ditto -x -k "$task_temp/release.zip" "$task_temp/unpacked"
task_source="$task_temp/unpacked/Mac USB Studio.app"
verify_app "$task_source"
if [[ "$task_verify_only" -eq 1 ]]; then
  printf 'Релиз %s (%s) проверен. Установка и снятие карантина не выполнялись.\n' "$task_version" "$task_build"
  exit 0
fi

check_processes
[[ "$task_destination" == /* && "$task_destination" != '/' ]] || fail 'Папка установки должна иметь абсолютный путь, отличный от /.'
/bin/mkdir -p "$task_destination"
task_destination=$(cd "$task_destination" && pwd -P)
[[ -w "$task_destination" ]] || fail 'Нет доступа к папке установки. Запустите без sudo с папкой по умолчанию.'
task_target="$task_destination/Mac USB Studio.app"
task_lock_path="$task_destination/.mac-usb-studio-install.lock"
/bin/mkdir "$task_lock_path" 2>/dev/null || fail 'Другая установка уже работает или осталась папка .mac-usb-studio-install.lock. Приложение не изменено.'
task_lock="$task_lock_path"
check_target
task_stage=$(/usr/bin/mktemp -d "$task_destination/.mac-usb-studio-install.XXXXXX")
/usr/bin/ditto "$task_source" "$task_stage/Mac USB Studio.app"
verify_app "$task_stage/Mac USB Studio.app"
/usr/bin/xattr -dr com.apple.quarantine "$task_stage/Mac USB Studio.app" || fail 'Не удалось снять карантин с подготовленной копии.'
verify_app "$task_stage/Mac USB Studio.app"
check_processes
check_target
if [[ -e "$task_target" ]]; then
  task_backup_candidate="$task_destination/Mac USB Studio.previous-$(/bin/date +%Y%m%d-%H%M%S)-$$.app"
  [[ ! -e "$task_backup_candidate" && ! -L "$task_backup_candidate" ]] || fail 'Путь резервной копии уже занят.'
  /bin/mv "$task_target" "$task_backup_candidate"
  task_backup="$task_backup_candidate"
fi
/bin/mv "$task_stage/Mac USB Studio.app" "$task_target"
printf 'Установлено: %s\n' "$task_target"
[[ -z "$task_backup" ]] || printf 'Прежняя копия сохранена: %s\n' "$task_backup"
printf 'USB не изменён. Пароль администратора и доступ к USB запрашиваются при записи в приложении.\n'
if [[ "$task_open" -eq 1 ]]; then
  /usr/bin/open "$task_target" || printf 'Приложение установлено. Откройте его из указанной папки.\n'
fi
