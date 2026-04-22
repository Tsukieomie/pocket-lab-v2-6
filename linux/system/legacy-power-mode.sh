#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-status}"

CPUFREQ_DIR="/sys/devices/system/cpu/cpufreq"
GPU_POWER_LEVEL="/sys/class/drm/card0/device/power_dpm_force_performance_level"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    echo "Example: sudo ./legacy-power-mode.sh performance" >&2
    exit 1
  fi
}

policies() {
  find "${CPUFREQ_DIR}" -maxdepth 1 -type d -name 'policy*' | sort
}

read_first_policy_value() {
  local file="$1"
  local first
  first="$(policies | head -n1)"
  [[ -n "${first}" && -f "${first}/${file}" ]] && cat "${first}/${file}"
}

write_all_policies() {
  local file="$1"
  local value="$2"
  local changed=0
  while IFS= read -r policy; do
    if [[ -f "${policy}/${file}" ]]; then
      printf '%s' "${value}" > "${policy}/${file}"
      changed=1
    fi
  done < <(policies)
  return $changed
}

set_global_boost() {
  local value="$1"
  if [[ -f "${CPUFREQ_DIR}/boost" ]]; then
    printf '%s' "${value}" > "${CPUFREQ_DIR}/boost"
  fi
}

set_gpu_level() {
  local value="$1"
  if [[ -f "${GPU_POWER_LEVEL}" ]]; then
    printf '%s' "${value}" > "${GPU_POWER_LEVEL}"
  fi
}

show_status() {
  echo "Mode snapshot:"
  echo

  local active_profile
  active_profile="$(powerprofilesctl get 2>/dev/null || true)"
  if [[ -n "${active_profile}" ]]; then
    echo "power-profiles-daemon: ${active_profile}"
  fi

  if [[ -f "${CPUFREQ_DIR}/boost" ]]; then
    echo "global boost: $(cat "${CPUFREQ_DIR}/boost")"
  fi

  local gpu_level=""
  if [[ -f "${GPU_POWER_LEVEL}" ]]; then
    gpu_level="$(cat "${GPU_POWER_LEVEL}")"
    echo "amdgpu power level: ${gpu_level}"
  fi

  echo
  while IFS= read -r policy; do
    echo "$(basename "${policy}")"
    for file in scaling_driver scaling_governor cpuinfo_min_freq cpuinfo_max_freq scaling_min_freq scaling_max_freq boost cpb bios_limit scaling_cur_freq cpuinfo_avg_freq; do
      if [[ -f "${policy}/${file}" ]]; then
        echo "  ${file}: $(cat "${policy}/${file}")"
      fi
    done
  done < <(policies)
}

apply_performance() {
  require_root

  local max_freq
  max_freq="$(read_first_policy_value cpuinfo_max_freq)"

  write_all_policies scaling_governor performance || true
  if [[ -n "${max_freq}" ]]; then
    write_all_policies scaling_max_freq "${max_freq}" || true
  fi

  set_global_boost 1

  if [[ -f "${GPU_POWER_LEVEL}" ]]; then
    set_gpu_level high || set_gpu_level auto || true
  fi

  echo "Applied performance mode."
  show_status
}

apply_balanced() {
  require_root

  local min_freq max_freq
  min_freq="$(read_first_policy_value cpuinfo_min_freq)"
  max_freq="$(read_first_policy_value cpuinfo_max_freq)"

  if grep -qw schedutil <(read_first_policy_value scaling_available_governors || true); then
    write_all_policies scaling_governor schedutil || true
  else
    write_all_policies scaling_governor ondemand || true
  fi

  if [[ -n "${min_freq}" ]]; then
    write_all_policies scaling_min_freq "${min_freq}" || true
  fi
  if [[ -n "${max_freq}" ]]; then
    write_all_policies scaling_max_freq "${max_freq}" || true
  fi

  set_global_boost 1

  if [[ -f "${GPU_POWER_LEVEL}" ]]; then
    set_gpu_level auto || true
  fi

  echo "Applied balanced mode."
  show_status
}

apply_powersave() {
  require_root

  local min_freq
  min_freq="$(read_first_policy_value cpuinfo_min_freq)"

  if grep -qw powersave <(read_first_policy_value scaling_available_governors || true); then
    write_all_policies scaling_governor powersave || true
  else
    write_all_policies scaling_governor schedutil || true
  fi

  if [[ -n "${min_freq}" ]]; then
    write_all_policies scaling_min_freq "${min_freq}" || true
    write_all_policies scaling_max_freq "${min_freq}" || true
  fi

  set_global_boost 0

  if [[ -f "${GPU_POWER_LEVEL}" ]]; then
    set_gpu_level low || set_gpu_level auto || true
  fi

  echo "Applied power-saver mode."
  show_status
}

usage() {
  cat <<'EOF'
Usage:
  ./legacy-power-mode.sh status
  sudo ./legacy-power-mode.sh performance
  sudo ./legacy-power-mode.sh balanced
  sudo ./legacy-power-mode.sh power-saver
EOF
}

case "${MODE}" in
  status)
    show_status
    ;;
  performance)
    apply_performance
    ;;
  balanced)
    apply_balanced
    ;;
  power-saver|powersave)
    apply_powersave
    ;;
  *)
    usage
    exit 1
    ;;
esac
