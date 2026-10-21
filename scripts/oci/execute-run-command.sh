#!/usr/bin/env bash

#==============================================================================
# OCI RUN COMMAND EXECUTION
#==============================================================================

set -euo pipefail

: "${AUTOMATION_DIRECTORY:?AUTOMATION_DIRECTORY is required}"
: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required}"
: "${OCI_REGION:?OCI_REGION is required}"
: "${RUN_COMMAND_DISPLAY_NAME:?RUN_COMMAND_DISPLAY_NAME is required}"
: "${RUN_COMMAND_RESULTS_DIRECTORY:?RUN_COMMAND_RESULTS_DIRECTORY is required}"
: "${RUN_COMMAND_SCRIPT_PATH:?RUN_COMMAND_SCRIPT_PATH is required}"
: "${RUN_COMMAND_TARGETS:?RUN_COMMAND_TARGETS is required}"
: "${RUN_COMMAND_TIMEOUT_SECONDS:?RUN_COMMAND_TIMEOUT_SECONDS is required}"

mkdir -p "$RUN_COMMAND_RESULTS_DIRECTORY"
overall_exit_code=0
target_names=()
target_instances=()
target_commands=()

while IFS= read -r target; do
  target_name=$(jq -r '.name' <<< "$target")
  instance_id=$(jq -r '.instance_id' <<< "$target")
  arguments=$(jq -c '.arguments' <<< "$target")
  if [[ -n "${RUN_COMMAND_SECRET_ARGUMENT:-}" ]]; then
    arguments=$(jq -c --arg secret_argument "$RUN_COMMAND_SECRET_ARGUMENT" '. + [$secret_argument]' <<< "$arguments")
  fi
  if [[ -n "${RUN_COMMAND_ADDITIONAL_SECRET_ARGUMENT:-}" ]]; then
    arguments=$(jq -c --arg secret_argument "$RUN_COMMAND_ADDITIONAL_SECRET_ARGUMENT" '. + [$secret_argument]' <<< "$arguments")
  fi
  if [[ -n "${RUN_COMMAND_TERTIARY_SECRET_ARGUMENT:-}" ]]; then
    arguments=$(jq -c --arg secret_argument "$RUN_COMMAND_TERTIARY_SECRET_ARGUMENT" '. + [$secret_argument]' <<< "$arguments")
  fi
  argument_line=$(jq -r '[.[] | @sh] | "set -- " + join(" ")' <<< "$arguments")
  command_text=$(printf '%s\n%s' "$argument_line" "$(cat "$AUTOMATION_DIRECTORY/$RUN_COMMAND_SCRIPT_PATH")")
  command_size=$(printf '%s' "$command_text" | wc -c | tr -d ' ')

  if (( command_size > 4096 )); then
    printf 'Rendered command for %s exceeds the 4096-byte inline limit.\n' "$target_name" >&2
    overall_exit_code=1
    continue
  fi

  content=$(jq -n --arg text "$command_text" '{source: {sourceType: "TEXT", text: $text}, output: {outputType: "TEXT"}}')
  target_payload=$(jq -n --arg instance_id "$instance_id" '{instanceId: $instance_id}')
  response=$(oci instance-agent command create \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --content "$content" \
    --display-name "${RUN_COMMAND_DISPLAY_NAME}-${target_name}" \
    --region "$OCI_REGION" \
    --target "$target_payload" \
    --timeout-in-seconds "$RUN_COMMAND_TIMEOUT_SECONDS")

  command_id=$(jq -r '.data.id' <<< "$response")
  if [[ -z "$command_id" || "$command_id" == "null" ]]; then
    printf 'OCI did not return a command OCID for %s.\n' "$target_name" >&2
    overall_exit_code=1
    continue
  fi

  printf 'Dispatched %s to %s as %s.\n' "$RUN_COMMAND_DISPLAY_NAME" "$target_name" "$command_id"
  target_names+=("$target_name")
  target_instances+=("$instance_id")
  target_commands+=("$command_id")
done < <(jq -c '.[]' <<< "$RUN_COMMAND_TARGETS")

#==============================================================================
# PARALLEL COMPLETION POLLING
#==============================================================================

# Oracle Cloud Agent can take minutes to pick up a command, so every target is
# dispatched first and polled together instead of waiting on each host in turn.
deadline=$(( $(date +%s) + RUN_COMMAND_TIMEOUT_SECONDS + 600 ))
pending=()
output_deadlines=()
for index in "${!target_names[@]}"; do
  pending+=("$index")
  output_deadlines[index]=0
done

while (( ${#pending[@]} > 0 && $(date +%s) < deadline )); do
  still_pending=()
  for index in ${pending[@]+"${pending[@]}"}; do
    target_name="${target_names[index]}"
    result_file="$RUN_COMMAND_RESULTS_DIRECTORY/${target_name}.json"
    execution=$(oci instance-agent command-execution get \
      --command-id "${target_commands[index]}" \
      --instance-id "${target_instances[index]}" \
      --region "$OCI_REGION")
    lifecycle_state=$(jq -r '.data."lifecycle-state"' <<< "$execution")
    printf 'Target %s is %s.\n' "$target_name" "$lifecycle_state"

    case "$lifecycle_state" in
      SUCCEEDED)
        printf '%s\n' "$execution" > "$result_file"
        command_output=$(jq -r '.data.content.text // ""' <<< "$execution")
        if [[ -n "${RUN_COMMAND_REQUIRED_OUTPUT_MARKER:-}" ]] && ! grep -Fq "$RUN_COMMAND_REQUIRED_OUTPUT_MARKER" <<< "$command_output"; then
          if (( output_deadlines[index] == 0 )); then
            output_deadlines[index]=$(( $(date +%s) + 120 ))
          fi
          if (( $(date +%s) < output_deadlines[index] )); then
            still_pending+=("$index")
            continue
          fi
          printf 'Required output marker is missing for %s.\n' "$target_name" >&2
          printf 'Run Command did not succeed for %s.\n' "$target_name" >&2
          overall_exit_code=1
        fi
        ;;
      FAILED|TIMED_OUT|CANCELED)
        printf '%s\n' "$execution" > "$result_file"
        printf 'Run Command did not succeed for %s.\n' "$target_name" >&2
        overall_exit_code=1
        ;;
      *)
        still_pending+=("$index")
        ;;
    esac
  done
  pending=(${still_pending[@]+"${still_pending[@]}"})
  if (( ${#pending[@]} > 0 )); then
    sleep 5
  fi
done

for index in ${pending[@]+"${pending[@]}"}; do
  printf 'Run Command did not succeed for %s.\n' "${target_names[index]}" >&2
  overall_exit_code=1
done

exit "$overall_exit_code"
