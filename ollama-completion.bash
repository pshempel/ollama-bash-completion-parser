#!/bin/bash
# File: etc/bash_completion.d/ollama-completion.bash
# Version: 3.1.0.003
# Description: Dynamic ollama completion using AST parser for authoritative command discovery
# Author: Maya - Integrated AST parser system for modern Linux
# Target: bash 5.2+, GNU coreutils, modern Linux only
# Purpose: Position-aware, context-aware completion using ollama's own source code
# Changes in v3.1.0.003: Fixed constraint logic to also exclude already-used flags (no duplicates)
#
# Core Functions:
# 1. Use AST parser to get authoritative command definitions from ollama source
# 2. Smart caching with version-based invalidation and GitHub rate limiting
# 3. Context-aware completion (models vs flags vs files) based on parsed structure
# 4. Position-aware completion (after model specified, offer flags)
# 5. System-safe operation (never block shell, graceful degradation)

# Only define once to prevent conflicts
if [[ "${__OLLAMA_COMPLETION_V3_LOADED:-}" == "1" ]]; then
    return 0
fi

# Remove any existing ollama completion
complete -r ollama 2>/dev/null || true

#=============================================================================
# CONFIGURATION
#=============================================================================
readonly __OLLAMA_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ollama-completion"
readonly __OLLAMA_PARSER_BIN="/usr/local/bin/ollama-cmd-parser"
readonly __OLLAMA_GITHUB_URL_TEMPLATE="https://raw.githubusercontent.com/ollama/ollama/v%s/cmd/cmd.go"

# Cache TTLs (in seconds) - Added buffer to prevent edge cases
readonly __OLLAMA_CACHE_TTL_COMMANDS=2100   # 35 minutes for parsed commands
readonly __OLLAMA_CACHE_TTL_MODELS=1800     # 30 minutes for models
readonly __OLLAMA_CACHE_TTL_VERSION=86400   # 24 hours for version check

# Safety limits
readonly __OLLAMA_TIMEOUT=5                 # Command timeout
readonly __OLLAMA_MIN_FETCH_INTERVAL=300    # 5 minutes between GitHub fetches
readonly __OLLAMA_LOCK_TIMEOUT=10           # Lock acquisition timeout

#=============================================================================
# DEBUGGING FUNCTIONS
#=============================================================================

# Debug output - only when OLLAMA_COMPLETION_DEBUG=1
__ollama_debug() {
    if [[ "${OLLAMA_COMPLETION_DEBUG:-}" == "1" ]]; then
        echo "DEBUG: $*" >&2
    fi
}

# Debug function to show current completion state
__ollama_debug_state() {
    if [[ "${OLLAMA_COMPLETION_DEBUG:-}" == "1" ]]; then
        echo "=== OLLAMA COMPLETION DEBUG ===" >&2
        echo "Command: ${1:-unknown}" >&2
        echo "cur='${2:-empty}'" >&2
        echo "prev='${3:-empty}'" >&2
        echo "cword='${4:-empty}'" >&2
        echo "words=(${COMP_WORDS[*]:-empty})" >&2
        echo "===============================" >&2
    fi
}

#=============================================================================
# DEPENDENCY VALIDATION
#=============================================================================

# Validate all dependencies upfront - fail fast with clear messages
__ollama_validate_dependencies() {
    local missing_tools=()
    local warnings=()
    
    # Check ollama availability and basic functionality
    if ! command -v ollama >/dev/null 2>&1; then
        missing_tools+=("ollama - install from https://ollama.ai")
        return 1
    fi
    
    # Test ollama responds to basic commands
    if ! ollama --version >/dev/null 2>&1; then
        missing_tools+=("ollama --version fails - check ollama installation")
        return 1
    fi
    
    # Check required tools
    if ! command -v curl >/dev/null 2>&1; then
        missing_tools+=("curl - install with: apt install curl")
    fi
    
    if [[ ! -x "$__OLLAMA_PARSER_BIN" ]]; then
        missing_tools+=("ollama-cmd-parser at $__OLLAMA_PARSER_BIN - run install-parser.sh")
    fi
    
    # Report missing required tools
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "Error: Missing required tools for ollama completion:" >&2
        printf "  - %s\n" "${missing_tools[@]}" >&2
        return 1
    fi
    
    # Check optional tools - warn but don't fail
    if ! command -v jq >/dev/null 2>&1; then
        warnings+=("jq not found - using fallback JSON parsing (install with: apt install jq)")
    fi
    
    # Test ollama server connectivity (non-fatal)
    if ! ollama list >/dev/null 2>&1; then
        warnings+=("ollama server not responding - completion will use cached data only")
    fi
    
    # Report warnings
    if [[ ${#warnings[@]} -gt 0 ]]; then
        printf "Warning: %s\n" "${warnings[@]}" >&2
    fi
    
    return 0
}

#=============================================================================
# SYSTEM HEALTH AND SAFETY CHECKS
#=============================================================================

# Check if system is stressed and we should minimize resource usage
__ollama_system_health_check() {
    # Check disk space (need at least 1MB free)
    local free_kb
    free_kb=$(df "$__OLLAMA_CACHE_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [[ $free_kb -lt 1024 ]]; then
        return 1  # Insufficient disk space
    fi

    # Check load average (don't stress the system further)
    if [[ -r /proc/loadavg ]]; then
        local load
        load=$(cut -d' ' -f1 /proc/loadavg | cut -d'.' -f1)
        if [[ $load -gt 10 ]]; then
            return 1  # System too loaded
        fi
    fi

    return 0
}

# Check if required tools are available
__ollama_tools_available() {
    command -v ollama >/dev/null 2>&1 && \
    command -v curl >/dev/null 2>&1 && \
    [[ -x "$__OLLAMA_PARSER_BIN" ]]
}

#=============================================================================
# UTILITY FUNCTIONS
#=============================================================================

# Safe cache directory creation
__ollama_ensure_cache_dir() {
    if [[ ! -d "$__OLLAMA_CACHE_DIR" ]]; then
        if ! mkdir -p "$__OLLAMA_CACHE_DIR" 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}

# Acquire exclusive lock with timeout
__ollama_acquire_lock() {
    local lockfile="$1"
    local timeout="${2:-$__OLLAMA_LOCK_TIMEOUT}"
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        if (set -C; echo $$ > "$lockfile") 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        ((count++))
    done
    return 1
}

# Release lock
__ollama_release_lock() {
    local lockfile="$1"
    [[ -f "$lockfile" ]] && rm -f "$lockfile" 2>/dev/null
}

# Check if cache file is fresh
__ollama_cache_is_fresh() {
    local cache_file="$1"
    local ttl="$2"
    
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    
    local cache_age
    cache_age=$(stat -c %Y "$cache_file" 2>/dev/null) || return 1
    local now=$(date +%s)
    
    [[ $((now - cache_age)) -lt $ttl ]]
}

# Safe ollama command execution with timeout and validation
__ollama_exec() {
    if ! command -v ollama >/dev/null 2>&1; then
        echo "Error: ollama command not available" >&2
        return 1
    fi
    timeout "$__OLLAMA_TIMEOUT" ollama "$@" 2>/dev/null
}

#=============================================================================
# VERSION AND CACHE MANAGEMENT
#=============================================================================

# Get ollama version for cache invalidation - FIXED: use --version not version
__ollama_get_version() {
    local version_cache="$__OLLAMA_CACHE_DIR/version"
    
    if __ollama_cache_is_fresh "$version_cache" "$__OLLAMA_CACHE_TTL_VERSION"; then
        cat "$version_cache" 2>/dev/null && return
    fi
    
    local version
    # FIXED: Use --version instead of version command
    version=$(__ollama_exec --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9\.]+)?' || echo "unknown")
    
    if [[ -n "$version" && "$version" != "unknown" ]]; then
        echo "$version" > "$version_cache" 2>/dev/null
        echo "$version"
    else
        echo "unknown"
    fi
}

# Check if we can download (rate limiting)
__ollama_can_download() {
    local last_fetch_file="$__OLLAMA_CACHE_DIR/last_fetch"
    
    if [[ -f "$last_fetch_file" ]]; then
        local last_fetch
        last_fetch=$(cat "$last_fetch_file" 2>/dev/null || echo "0")
        local now=$(date +%s)
        if [[ $((now - last_fetch)) -lt $__OLLAMA_MIN_FETCH_INTERVAL ]]; then
            return 1  # Too soon since last fetch
        fi
    fi
    
    return 0
}

# Record successful download
__ollama_record_download() {
    date +%s > "$__OLLAMA_CACHE_DIR/last_fetch" 2>/dev/null
}

# Download and parse ollama source
__ollama_update_commands_cache() {
    local version="$1"
    local commands_cache="$__OLLAMA_CACHE_DIR/commands_v${version}.json"
    local lockfile="$__OLLAMA_CACHE_DIR/download.lock"
    local temp_cmd_file="$__OLLAMA_CACHE_DIR/cmd_v${version}.go.tmp"
    local temp_json_file="$__OLLAMA_CACHE_DIR/commands_v${version}.json.tmp"
    
    # Quick check if another process already updated
    if __ollama_cache_is_fresh "$commands_cache" "$__OLLAMA_CACHE_TTL_COMMANDS"; then
        return 0
    fi
    
    # System health check
    if ! __ollama_system_health_check; then
        return 1
    fi
    
    # Rate limiting check
    if ! __ollama_can_download; then
        return 1
    fi
    
    # Acquire download lock
    if ! __ollama_acquire_lock "$lockfile"; then
        return 1
    fi
    
    # Double-check after acquiring lock
    if __ollama_cache_is_fresh "$commands_cache" "$__OLLAMA_CACHE_TTL_COMMANDS"; then
        __ollama_release_lock "$lockfile"
        return 0
    fi
    
    # Download source
    local github_url
    printf -v github_url "$__OLLAMA_GITHUB_URL_TEMPLATE" "$version"
    
    if ! curl -f -s --max-time 10 "$github_url" > "$temp_cmd_file" 2>/dev/null; then
        # Try main branch as fallback
        if ! curl -f -s --max-time 10 "https://raw.githubusercontent.com/ollama/ollama/main/cmd/cmd.go" > "$temp_cmd_file" 2>/dev/null; then
            __ollama_release_lock "$lockfile"
            rm -f "$temp_cmd_file" 2>/dev/null
            return 1
        fi
    fi
    
    # Parse with AST parser
    if "$__OLLAMA_PARSER_BIN" "$temp_cmd_file" > "$temp_json_file" 2>/dev/null; then
        # Update version in JSON and move to final location
        if command -v jq >/dev/null 2>&1; then
            jq --arg ver "$version" '.version = $ver' "$temp_json_file" > "$commands_cache" 2>/dev/null
        else
            # Fallback without jq - just move the file
            mv "$temp_json_file" "$commands_cache"
        fi
        __ollama_record_download
    else
        # Parser failed, clean up
        __ollama_release_lock "$lockfile"
        rm -f "$temp_cmd_file" "$temp_json_file" 2>/dev/null
        return 1
    fi
    
    # Cleanup
    rm -f "$temp_cmd_file" "$temp_json_file" 2>/dev/null
    __ollama_release_lock "$lockfile"
    return 0
}

# Get cached command definitions
__ollama_get_commands_cache() {
    local version="$1"
    local commands_cache="$__OLLAMA_CACHE_DIR/commands_v${version}.json"
    
    if [[ -f "$commands_cache" ]] && __ollama_cache_is_fresh "$commands_cache" "$__OLLAMA_CACHE_TTL_COMMANDS"; then
        echo "$commands_cache"
        return 0
    fi
    
    return 1
}

# Clear all completion caches
__ollama_clear_cache() {
    if [[ -d "$__OLLAMA_CACHE_DIR" ]]; then
        rm -f "$__OLLAMA_CACHE_DIR"/* 2>/dev/null
        echo "Ollama completion cache cleared"
    fi
}

#=============================================================================
# COMMAND AND MODEL DISCOVERY
#=============================================================================

# Get command info from cached JSON
__ollama_get_command_info() {
    local command="$1"
    local cache_file="$2"
    
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        jq -r ".commands.${command} // empty" "$cache_file" 2>/dev/null
    else
        # Fallback parsing without jq (basic grep/sed)
        grep -A 20 "\"${command}\":" "$cache_file" 2>/dev/null | head -20
    fi
}

# Get command flags from cached JSON
__ollama_get_command_flags() {
    local command="$1"
    local cache_file="$2"
    
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        jq -r ".commands.${command}.flags[]?.name // empty" "$cache_file" 2>/dev/null | \
            sed 's/^/--/' | tr '\n' ' '
    else
        # Fallback: basic pattern matching
        grep -A 50 "\"${command}\":" "$cache_file" 2>/dev/null | \
            grep '"name":' | head -20 | \
            sed 's/.*"name": *"\([^"]*\)".*/--\1/' | tr '\n' ' '
    fi
}

# Check if command expects model arguments based on parsed data
__ollama_command_expects_models() {
    local command="$1"
    local cache_file="$2"
    
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        local min_args
        min_args=$(jq -r ".commands.${command}.min_args // 0" "$cache_file" 2>/dev/null)
        [[ "$min_args" -gt 0 ]]
    else
        # Fallback: check usage pattern
        local usage
        usage=$(grep -A 5 "\"${command}\":" "$cache_file" | grep '"usage":' | head -1)
        [[ "$usage" =~ MODEL ]]
    fi
}

# Get flags that respect command-line constraint violations
__ollama_get_constraint_aware_flags() {
    local command="$1"
    local cache_file="$2"
    
    if [[ ! -f "$cache_file" ]] || ! command -v jq >/dev/null 2>&1; then
        # Fallback to all flags if constraint parsing fails
        __ollama_debug "No constraint data available, offering all flags"
        __ollama_get_command_flags "$command" "$cache_file"
        return
    fi
    
    # Scan entire command line for used flags
    local used_flags=()
    for ((i=2; i<${#words[@]}; i++)); do
        local word="${words[i]}"
        if [[ "$word" == --* ]]; then
            # Remove -- prefix for comparison
            local flag_name="${word#--}"
            used_flags+=("$flag_name")
        fi
    done
    
    __ollama_debug "Found used flags: ${used_flags[*]}"
    
    # Get all mutual exclusion groups for this command
    local mutex_groups
    mutex_groups=$(jq -r ".commands.${command}.constraints.mutually_exclusive[]? | @json" "$cache_file" 2>/dev/null)
    
    # Find which mutex groups are "occupied" by used flags
    local excluded_flags=()
    while IFS= read -r group_json; do
        if [[ -n "$group_json" && "$group_json" != "null" ]]; then
            # Parse the group array
            local group_flags
            group_flags=$(echo "$group_json" | jq -r '.[]' 2>/dev/null)
            
            # Check if any used flag is in this group
            local group_occupied=false
            while IFS= read -r group_flag; do
                if [[ -n "$group_flag" ]]; then
                    for used_flag in "${used_flags[@]}"; do
                        if [[ "$used_flag" == "$group_flag" ]]; then
                            group_occupied=true
                            __ollama_debug "Mutex group occupied by flag: $used_flag"
                            break 2
                        fi
                    done
                fi
            done <<< "$group_flags"
            
            # If group is occupied, exclude all other flags from this group
            if [[ "$group_occupied" == "true" ]]; then
                while IFS= read -r group_flag; do
                    if [[ -n "$group_flag" ]]; then
                        # Don't exclude already used flags (allow them to appear for consistency)
                        local already_used=false
                        for used_flag in "${used_flags[@]}"; do
                            if [[ "$used_flag" == "$group_flag" ]]; then
                                already_used=true
                                break
                            fi
                        done
                        if [[ "$already_used" == "false" ]]; then
                            excluded_flags+=("$group_flag")
                            __ollama_debug "Excluding flag due to constraint: $group_flag"
                        fi
                    fi
                done <<< "$group_flags"
            fi
        fi
    done <<< "$mutex_groups"
    
    # Get all flags for this command
    local all_flags
    all_flags=$(jq -r ".commands.${command}.flags[]?.name // empty" "$cache_file" 2>/dev/null)
    
    # Filter out excluded flags AND already-used flags
    local allowed_flags=()
    while IFS= read -r flag_name; do
        if [[ -n "$flag_name" ]]; then
            local is_excluded=false
            local is_already_used=false
            
            # Check if flag is in exclusion list (mutex conflict)
            for excluded_flag in "${excluded_flags[@]}"; do
                if [[ "$flag_name" == "$excluded_flag" ]]; then
                    is_excluded=true
                    break
                fi
            done
            
            # Check if flag is already used in command
            for used_flag in "${used_flags[@]}"; do
                if [[ "$flag_name" == "$used_flag" ]]; then
                    is_already_used=true
                    __ollama_debug "Excluding already-used flag: $flag_name"
                    break
                fi
            done
            
            # Only include if not excluded and not already used
            if [[ "$is_excluded" == "false" && "$is_already_used" == "false" ]]; then
                allowed_flags+=("--$flag_name")
            fi
        fi
    done <<< "$all_flags"
    
    __ollama_debug "Final allowed flags: ${allowed_flags[*]}"
    
    # Output the allowed flags
    printf "%s " "${allowed_flags[@]}"
}

# Get available models with improved error handling
__ollama_get_models() {
    local models_cache="$__OLLAMA_CACHE_DIR/models.cache"
    local lockfile="$__OLLAMA_CACHE_DIR/models.lock"
    
    # Return cached if fresh
    if __ollama_cache_is_fresh "$models_cache" "$__OLLAMA_CACHE_TTL_MODELS"; then
        local models
        models=$(cat "$models_cache" 2>/dev/null | tr '\n' ' ')
        __ollama_debug "Using cached models: $models"
        echo "$models"
        return
    fi
    
    # Quick system check
    if ! __ollama_system_health_check || ! __ollama_acquire_lock "$lockfile"; then
        # Fallback to cached data even if stale
        if [[ -f "$models_cache" ]]; then
            local models
            models=$(cat "$models_cache" 2>/dev/null | tr '\n' ' ')
            __ollama_debug "Using stale cached models: $models"
            echo "$models"
        fi
        return 1
    fi
    
    # Double-check after lock
    if __ollama_cache_is_fresh "$models_cache" "$__OLLAMA_CACHE_TTL_MODELS"; then
        __ollama_release_lock "$lockfile"
        local models
        models=$(cat "$models_cache" 2>/dev/null | tr '\n' ' ')
        __ollama_debug "Using fresh cached models: $models"
        echo "$models"
        return
    fi
    
    # Get models with proper error handling
    local models
    if models=$(__ollama_exec list | awk 'NR>1 && /^[a-zA-Z0-9]/ {print $1}' | grep -v '^$' | sort); then
        if [[ -n "$models" ]]; then
            echo "$models" > "$models_cache" 2>/dev/null
            local model_list
            model_list=$(echo "$models" | tr '\n' ' ')
            __ollama_debug "Fresh models retrieved: $model_list"
            echo "$model_list"
        fi
    else
        # ollama list failed, use stale cache if available
        if [[ -f "$models_cache" ]]; then
            local models
            models=$(cat "$models_cache" 2>/dev/null | tr '\n' ' ')
            __ollama_debug "ollama list failed, using stale cache: $models"
            echo "$models"
        fi
    fi
    
    __ollama_release_lock "$lockfile"
}

# Get running models
__ollama_get_running_models() {
    __ollama_exec ps | awk 'NR>1 && /^[a-zA-Z0-9]/ {print $1}' | grep -v '^$' | tr '\n' ' '
}

#=============================================================================
# BASH COMPLETION FIXES
#=============================================================================

# Fix bash colon word-splitting issue for model names like "llama3.1:latest"
__ollama_fix_colon_splitting() {
    local cur="$1"
    local prev="$2"
    local cword="$3"
    shift 3
    local words=("$@")
    
    __ollama_debug "Colon fix called with cur='$cur', prev='$prev', cword='$cword'"
    __ollama_debug "Words array: (${words[*]})"
    
    # Check if we have a colon-split situation
    if [[ "$prev" == ":" && $cword -ge 3 ]]; then
        # Reconstruct the full model name from split parts
        local base_word="${words[cword-2]}"
        local reconstructed="${base_word}:${cur}"
        __ollama_debug "Colon split detected! Reconstructing '$base_word' + ':' + '$cur' = '$reconstructed'"
        echo "$reconstructed"
    else
        __ollama_debug "No colon split detected, returning cur='$cur' unchanged"
        echo "$cur"
    fi
}

#=============================================================================
# POSITION-AWARE COMPLETION LOGIC
#=============================================================================

# Hybrid position/content-aware logic - best of both worlds
__ollama_has_model_specified() {
    local command="$1"
    local cache_file="$2"
    local cur="$3"  # Current word being typed
    
    # If user is still typing (cur != ""), use content-based logic
    # If user finished typing (cur == ""), use position-based logic
    
    if [[ -n "$cur" ]]; then
        # Content-based: User is typing, don't assume position is filled
        __ollama_debug "has_model_specified: User typing cur='$cur', returning false (let them finish)"
        return 1  # Let them finish typing/autocomplete
    else
        # Position-based: User finished typing, check if argument slots filled
        
        # Get expected argument structure from cache
        local min_args
        if command -v jq >/dev/null 2>&1; then
            min_args=$(jq -r ".commands.${command}.min_args // 0" "$cache_file" 2>/dev/null)
        else
            # Fallback: assume common patterns
            case "$command" in
                show|stop|pull|push|rm) min_args=1 ;;
                cp) min_args=2 ;;
                run) min_args=1 ;;
                *) min_args=0 ;;
            esac
        fi
        
        # Count non-flag arguments provided (skip command itself)
        local arg_count=0
        for ((i=2; i<COMP_CWORD; i++)); do
            local word="${COMP_WORDS[i]}"
            # Skip flags
            [[ "$word" == -* ]] && continue
            ((arg_count++))
        done
        
        __ollama_debug "has_model_specified: command='$command', min_args=$min_args, arg_count=$arg_count"
        
        # If we have enough args for this command, position is filled
        [[ $arg_count -ge $min_args ]]
    fi
}

# Smart context-aware completion using hybrid logic
__ollama_complete_context() {
    local command="$1"
    local cur="$2"
    local prev="$3"
    local cache_file="$4"
    
    __ollama_debug "Context completion called: command='$command', cur='$cur', prev='$prev'"
    
    # Handle flag-specific completions
    case "$prev" in
        --file|-f)
            # File completion will be handled by compgen -f
            return
            ;;
        --format)
            echo "json"
            return
            ;;
        --host)
            echo "0.0.0.0 127.0.0.1 localhost"
            return
            ;;
        --port)
            echo "11434 8080 3000"
            return
            ;;
        --keepalive)
            echo "5m 10m 30m 1h"
            return
            ;;
        --quantize|-q)
            echo "q4_K_M q4_K_S q5_K_M q5_K_S q8_0"
            return
            ;;
        --template|--system|--modelfile|--parameters|--license|--verbose|--insecure|--nowordwrap|--think|--hidethinking)
            # Check command-line constraint violations
            __ollama_debug "Boolean flag '$prev' detected, checking full command constraints"
            __ollama_get_constraint_aware_flags "$command" "$cache_file"
            return
            ;;
    esac
    
    # If current word starts with -, always offer flags
    if [[ "$cur" == -* ]]; then
        __ollama_debug "Current word starts with -, offering flags"
        __ollama_get_command_flags "$command" "$cache_file"
        return
    fi
    
    # Command-specific logic based on parsed structure
    case "$command" in
        run|show|pull|push|rm|stop)
            if __ollama_command_expects_models "$command" "$cache_file"; then
                if __ollama_has_model_specified "$command" "$cache_file" "$cur"; then
                    # Position filled, offer flags
                    __ollama_debug "Position filled for '$command', offering flags"
                    __ollama_get_command_flags "$command" "$cache_file"
                else
                    # Position not filled, offer models (with filtering if typing)
                    if [[ "$command" == "stop" ]]; then
                        local running_models
                        running_models=$(__ollama_get_running_models)
                        __ollama_debug "Offering running models for '$command': $running_models"
                        echo "$running_models"
                    else
                        local models
                        models=$(__ollama_get_models)
                        __ollama_debug "Offering all models for '$command': $models"
                        echo "$models"
                    fi
                fi
            else
                # Command doesn't expect models, offer flags
                __ollama_debug "Command '$command' doesn't expect models, offering flags"
                __ollama_get_command_flags "$command" "$cache_file"
            fi
            ;;
        cp)
            # cp needs source and destination models
            local arg_count=0
            for ((i=2; i<COMP_CWORD; i++)); do
                local word="${COMP_WORDS[i]}"
                [[ "$word" == -* ]] && continue
                ((arg_count++))
            done
            
            # Account for current word being typed
            if [[ -n "$cur" && "$cur" != -* ]]; then
                ((arg_count++))
            fi
            
            __ollama_debug "cp command: arg_count=$arg_count"
            if [[ $arg_count -lt 2 ]]; then
                local models
                models=$(__ollama_get_models)
                __ollama_debug "cp offering models: $models"
                echo "$models"
            else
                __ollama_debug "cp offering flags"
                __ollama_get_command_flags "$command" "$cache_file"
            fi
            ;;
        list|ls|ps|version|serve)
            # These commands don't take model arguments, only flags
            __ollama_debug "Command '$command' only takes flags"
            __ollama_get_command_flags "$command" "$cache_file"
            ;;
        help)
            if [[ $COMP_CWORD -eq 2 ]]; then
                # First arg to help - offer commands
                if command -v jq >/dev/null 2>&1; then
                    jq -r '.commands | keys[]' "$cache_file" 2>/dev/null | tr '\n' ' '
                fi
            else
                __ollama_get_command_flags "$command" "$cache_file"
            fi
            ;;
        create)
            if [[ $COMP_CWORD -eq 2 ]]; then
                # New model name - no completion
                __ollama_debug "create command at position 2, no completion"
                return
            else
                __ollama_get_command_flags "$command" "$cache_file"
            fi
            ;;
        *)
            # Unknown command, try basic completion
            if __ollama_command_expects_models "$command" "$cache_file"; then
                if __ollama_has_model_specified "$command" "$cache_file" "$cur"; then
                    __ollama_get_command_flags "$command" "$cache_file"
                else
                    echo "$(__ollama_get_models)"
                fi
            else
                __ollama_get_command_flags "$command" "$cache_file"
            fi
            ;;
    esac
}

#=============================================================================
# MAIN COMPLETION FUNCTION
#=============================================================================

__ollama_complete() {
    local cur prev words cword
    _init_completion || return
    
    # Debug current state BEFORE any processing
    __ollama_debug_state "${words[1]:-unknown}" "$cur" "$prev" "$cword"
    
    # Fix bash colon word-splitting for model names (preprocessing only)
    cur=$(__ollama_fix_colon_splitting "$cur" "$prev" "$cword" "${words[@]}")
    
    # Debug state AFTER colon fix
    __ollama_debug "After colon fix: cur='$cur'"
    
    # Ensure cache directory exists (quick check)
    if ! __ollama_ensure_cache_dir; then
        # Fallback completion if cache setup fails
        COMPREPLY=($(compgen -W "run show pull push list ps help version" -- "$cur"))
        return
    fi
    
    # Get ollama version
    local version
    version=$(__ollama_get_version)
    
    case $cword in
        1)
            # Complete main commands
            local cache_file
            if cache_file=$(__ollama_get_commands_cache "$version"); then
                # Use cached commands
                if command -v jq >/dev/null 2>&1; then
                    local commands
                    commands=$(jq -r '.commands | keys[]' "$cache_file" 2>/dev/null | tr '\n' ' ')
                    COMPREPLY=($(compgen -W "$commands --help --version" -- "$cur"))
                else
                    # Fallback without jq
                    COMPREPLY=($(compgen -W "run show pull push list ps cp rm create stop serve help version --help --version" -- "$cur"))
                fi
            else
                # Try background update and use fallback
                if __ollama_tools_available; then
                    (__ollama_update_commands_cache "$version" &)
                fi
                COMPREPLY=($(compgen -W "run show pull push list ps cp rm create stop serve help version --help --version" -- "$cur"))
            fi
            ;;
        *)
            local command="${words[1]}"
            local cache_file
            
            # Get commands cache
            if cache_file=$(__ollama_get_commands_cache "$version"); then
                # Use parsed command structure for completion
                
                # Handle file completion for specific flags
                case "$prev" in
                    --file|-f)
                        COMPREPLY=($(compgen -f -- "$cur"))
                        return
                        ;;
                esac
                
                # Get context-appropriate completions
                local completions
                completions=$(__ollama_complete_context "$command" "$cur" "$prev" "$cache_file")
                __ollama_debug "Context completions for '$command': '$completions'"
                
                if [[ -n "$completions" ]]; then
                    __ollama_debug "Running compgen -W '$completions' -- '$cur'"
                    __ollama_debug "Length of cur: ${#cur}, characters: $(printf '%q' "$cur")"
                    local compgen_result
                    compgen_result=$(compgen -W "$completions" -- "$cur")
                    __ollama_debug "Raw compgen command would be: compgen -W \"$completions\" -- \"$cur\""
                    __ollama_debug "Raw compgen result: '$compgen_result'"
                    
                    # Handle colon-split output filtering
                    if [[ "$prev" == ":" && $cword -ge 3 ]]; then
                        local base_word="${words[cword-2]}"
                        __ollama_debug "Colon-split output: filtering results to remove '$base_word:' prefix"
                        local filtered_results=()
                        while IFS= read -r line; do
                            if [[ "$line" == "$base_word:"* ]]; then
                                local suffix="${line#$base_word:}"
                                __ollama_debug "Filtering '$line' → '$suffix'"
                                filtered_results+=("$suffix")
                            fi
                        done <<< "$compgen_result"
                        COMPREPLY=("${filtered_results[@]}")
                        __ollama_debug "Final filtered COMPREPLY: (${COMPREPLY[*]})"
                    else
                        COMPREPLY=($compgen_result)
                        __ollama_debug "No filtering needed, COMPREPLY: (${COMPREPLY[*]})"
                    fi
                else
                    __ollama_debug "No completions found"
                    COMPREPLY=()
                fi
            else
                # Cache miss - try update in background and provide improved fallback
                if __ollama_tools_available; then
                    (__ollama_update_commands_cache "$version" &)
                fi
                
                # Improved fallback completion with hybrid logic
                case "$command" in
                    run|show|pull|push|rm|stop)
                        if [[ "$cur" == -* ]]; then
                            COMPREPLY=($(compgen -W "--help" -- "$cur"))
                        else
                            # Use hybrid logic: if typing, help autocomplete; if done, check position
                            if [[ -n "$cur" ]]; then
                                # User typing, offer all models for autocomplete
                                local models
                                models=$(__ollama_get_models)
                                __ollama_debug "Fallback: offering models for typing user: '$models'"
                                if [[ -n "$models" ]]; then
                                    __ollama_debug "Fallback: running compgen -W '$models' -- '$cur'"
                                    __ollama_debug "Fallback: Length of cur: ${#cur}, characters: $(printf '%q' "$cur")"
                                    __ollama_debug "Fallback: Raw compgen command: compgen -W \"$models\" -- \"$cur\""
                                    local compgen_result
                                    compgen_result=$(compgen -W "$models" -- "$cur")
                                    __ollama_debug "Fallback: raw compgen result: '$compgen_result'"
                                    
                                    # Handle colon-split output filtering in fallback too
                                    if [[ "$prev" == ":" && $cword -ge 3 ]]; then
                                        local base_word="${words[cword-2]}"
                                        __ollama_debug "Fallback: Colon-split output: filtering results to remove '$base_word:' prefix"
                                        local filtered_results=()
                                        while IFS= read -r line; do
                                            if [[ "$line" == "$base_word:"* ]]; then
                                                local suffix="${line#$base_word:}"
                                                __ollama_debug "Fallback: Filtering '$line' → '$suffix'"
                                                filtered_results+=("$suffix")
                                            fi
                                        done <<< "$compgen_result"
                                        COMPREPLY=("${filtered_results[@]}")
                                        __ollama_debug "Fallback: Final filtered COMPREPLY: (${COMPREPLY[*]})"
                                    else
                                        COMPREPLY=($compgen_result)
                                        __ollama_debug "Fallback: No filtering needed, COMPREPLY: (${COMPREPLY[*]})"
                                    fi
                                else
                                    COMPREPLY=()
                                fi
                            else
                                # User done typing, check if position filled
                                local required_args
                                case "$command" in
                                    show|stop|pull|push|rm) required_args=1 ;;
                                    run) required_args=1 ;;
                                    *) required_args=0 ;;
                                esac
                                
                                # Count provided args
                                local arg_count=0
                                for ((i=2; i<cword; i++)); do
                                    [[ "${words[i]}" != -* ]] && ((arg_count++))
                                done
                                
                                if [[ $arg_count -ge $required_args ]]; then
                                    # Position filled, offer flags
                                    COMPREPLY=($(compgen -W "--help" -- "$cur"))
                                else
                                    # Position not filled, offer models
                                    local models
                                    models=$(__ollama_get_models)
                                    if [[ -n "$models" ]]; then
                                        COMPREPLY=($(compgen -W "$models" -- "$cur"))
                                    else
                                        COMPREPLY=()
                                    fi
                                fi
                            fi
                        fi
                        ;;
                    list|ls|ps|version|serve)
                        # These commands only take flags
                        COMPREPLY=($(compgen -W "--help" -- "$cur"))
                        ;;
                    *)
                        # Unknown command
                        if [[ "$cur" == -* ]]; then
                            COMPREPLY=($(compgen -W "--help" -- "$cur"))
                        else
                            COMPREPLY=()
                        fi
                        ;;
                esac
            fi
            ;;
    esac
    
    __ollama_debug "Final COMPREPLY: (${COMPREPLY[*]})"
}

#=============================================================================
# REGISTRATION AND INITIALIZATION
#=============================================================================

# Validate dependencies before registering completion
if __ollama_validate_dependencies; then
    # Dependencies OK - register completion
    __OLLAMA_COMPLETION_V3_LOADED=1
    
    # Register completion function
    complete -F __ollama_complete ollama
    
    # Provide cache management commands
    if ! alias ollama-completion-clear >/dev/null 2>&1; then
        alias ollama-completion-clear='__ollama_clear_cache'
    fi
    
    # Auto-refresh very old cache (7+ days) on shell startup
    if [[ -d "$__OLLAMA_CACHE_DIR" ]]; then
        __ollama_old_cache_files=$(find "$__OLLAMA_CACHE_DIR" -name "*.json" -mtime +7 2>/dev/null)
        if [[ -n "$__ollama_old_cache_files" ]]; then
            # Silently clear very old cache in background
            (__ollama_clear_cache >/dev/null 2>&1 &)
        fi
        unset __ollama_old_cache_files
    fi
else
    # Dependencies failed - don't register completion
    echo "Ollama completion disabled due to dependency issues" >&2
fi
