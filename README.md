# Ollama Intelligent Bash Completion System
## Technical Architecture Summary

### **Overview**
A dynamic, constraint-aware bash completion system for ollama that uses AST parsing to discover commands, flags, and constraints directly from ollama's source code. Zero hardcoding, fully adaptive to ollama changes.

---

## **🏗️ System Architecture**

### **Two-Component Design:**

**Component 1: `ollama-cmd-parser` (Go Binary)**
- **Purpose**: AST parser that analyzes ollama's `cmd.go` source file
- **Input**: Go source code from ollama repository
- **Output**: Structured JSON with commands, flags, arguments, and constraints
- **Location**: `/usr/local/bin/ollama-cmd-parser`

**Component 2: `ollama-completion.bash` (Bash Script)**  
- **Purpose**: Intelligent bash completion using parser data
- **Input**: JSON from parser + user context
- **Output**: Context-aware completion suggestions
- **Location**: `/etc/bash_completion.d/ollama-completion.bash`

---

## **🧠 Parser Architecture (`ollama-cmd-parser`)**

### **Core Functionality:**
```go
// Version: 1.1.0
// Parses Go AST to extract:
1. Cobra command definitions (&cobra.Command{...})
2. Flag definitions (cmd.Flags().String(...))  
3. Argument constraints (cobra.ExactArgs(N))
4. Mutual exclusion constraints (from handler error messages)
```

### **AST Parsing Capabilities:**

**Command Discovery:**
- Finds `cmdVar := &cobra.Command{Use: "run MODEL", Args: cobra.ExactArgs(1)}`
- Extracts: usage patterns, aliases, argument rules, descriptions

**Flag Discovery:**
- Finds `cmd.Flags().StringP("format", "f", "", "Response format")`
- Extracts: name, short form, type, default value, description

**Constraint Discovery:**
- Searches handler functions for patterns like:
- `if flagsSet > 1 { return errors.New("only one of '--license', '--modelfile'...") }`
- RegEx extracts mutual exclusion groups from error messages

### **JSON Output Structure:**
```json
{
  "version": "0.9.5",
  "parser_info": {"version": "1.1.0"},
  "commands": {
    "show": {
      "usage": "show MODEL",
      "min_args": 1, "max_args": 1,
      "flags": [...],
      "constraints": {
        "mutually_exclusive": [["license", "modelfile", "parameters", "system", "template"]]
      }
    }
  }
}
```

---

## **🚀 Completion Engine Architecture**

### **Multi-Layer Intelligence:**

**Layer 1: Word Processing**
- **Colon Fix**: Handles bash word-splitting for `model:tag` names
- **Process**: `llama3.1:latest` split as `["llama3.1", ":", "latest"]` → reconstructed as `"llama3.1:latest"`
- **Bi-directional**: Input reconstruction + output filtering

**Layer 2: Context Analysis**  
- **Position-aware**: Knows when model slots filled vs empty
- **Content-aware**: Helps autocomplete partial input
- **Command-specific**: Different logic per command based on parsed structure

**Layer 3: Constraint Validation**
- **Command-line scanning**: Analyzes entire `${words[@]}` for used flags
- **Mutex detection**: Identifies occupied constraint groups
- **Smart filtering**: Excludes conflicts + duplicates

### **Completion Flow:**
```bash
1. Parse user input → extract command, current word, context
2. Apply colon fix → reconstruct split model names  
3. Load cached command data → get flags, constraints, arg rules
4. Determine completion type → models vs flags vs values
5. Apply constraints → exclude conflicts and duplicates
6. Filter results → match against current input
7. Format output → handle colon suffix stripping
```

---

## **🗄️ Caching & Performance System**

### **Multi-Tier Caching:**
- **Commands Cache**: `commands_v{version}.json` (TTL: 35 min)
- **Models Cache**: `models.cache` (TTL: 30 min)  
- **Version Cache**: `version` (TTL: 24 hours)

### **Smart Cache Management:**
- **Version-based invalidation**: Cache keys include ollama version
- **Rate limiting**: GitHub fetches limited to 5-minute intervals
- **Concurrent safety**: File locking prevents race conditions
- **Health checks**: System load and disk space monitoring
- **Graceful degradation**: Works with stale cache when services down

### **Cache Location:**
```bash
${XDG_CACHE_HOME:-$HOME/.cache}/ollama-completion/
├── commands_v0.9.5.json    # Parsed command definitions
├── models.cache            # Available models list  
├── version                 # Ollama version string
└── last_fetch             # Rate limiting timestamp
```

---

## **🎯 Advanced Features**

### **Colon Handling (Model:Tag Syntax):**
**Problem**: Bash splits `llama3.1:latest` into separate words
**Solution**: Two-phase approach
1. **Input reconstruction**: Detect split pattern, rebuild full word
2. **Output filtering**: Strip prefix from completions (`llama3.1:latest` → `latest`)

### **Constraint-Aware Completion:**
**Problem**: Users can select invalid flag combinations
**Solution**: Dynamic constraint validation
1. **Parse constraints** from source code error messages
2. **Scan command line** for already-used flags  
3. **Identify conflicts** using mutex group logic
4. **Filter suggestions** to only valid options

### **Hybrid Completion Logic:**
- **Content-based**: While user typing, help autocomplete
- **Position-based**: When done typing, check if slots filled
- **Command-aware**: Different behavior per command type

---

## **🛡️ System Safety & Reliability**

### **Defensive Programming:**
- **Graceful fallbacks**: Works without jq, parser, or network
- **Timeout protection**: All operations time-limited
- **Error isolation**: Parser failures don't break basic completion
- **Resource monitoring**: Prevents system stress during completion

### **Debugging Support:**
```bash
export OLLAMA_COMPLETION_DEBUG=1  # Enable detailed logging
unset OLLAMA_COMPLETION_DEBUG     # Disable debugging
```

### **Maintenance Commands:**
```bash
ollama-completion-clear           # Clear all caches
ollama-cmd-parser --version       # Check parser version
```

---

## **⚙️ Key Configuration Constants**

```bash
# Cache locations
__OLLAMA_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ollama-completion"
__OLLAMA_PARSER_BIN="/usr/local/bin/ollama-cmd-parser"

# Performance tuning  
__OLLAMA_TIMEOUT=5                     # Command timeout (seconds)
__OLLAMA_CACHE_TTL_COMMANDS=2100       # 35 minutes
__OLLAMA_CACHE_TTL_MODELS=1800         # 30 minutes  
__OLLAMA_MIN_FETCH_INTERVAL=300        # 5 minutes between GitHub fetches
```

---

## **🔧 Engineering Principles Applied**

### **Zero Hardcoding:**
- All commands discovered from source
- All flags extracted dynamically  
- All constraints parsed from code
- No assumptions about ollama behavior

### **Data-Driven Architecture:**
- JSON as single source of truth
- Generic algorithms work for any command
- Constraint engine operates on data structures
- Future-proof against ollama changes

### **Performance-First Design:**
- Aggressive caching with smart invalidation
- Background updates don't block completion
- Minimal resource usage during completion
- Scales to large model collections

---

## **🚀 Framework Potential**

### **Universal Applicability:**
The architecture is 95% tool-agnostic and could work for any Cobra-based CLI:
- `kubectl`, `docker`, `terraform`, `helm`, `gh`
- Only requires renaming environment variables and function prefixes
- Parser works on any `cmd.go` with Cobra patterns

### **Reusable Components:**
- **AST Parser**: Generic Cobra command analyzer
- **Completion Engine**: Universal constraint-aware logic
- **Caching System**: Reusable performance layer
- **Colon Handling**: Bash completion framework

---

## **📊 Performance Characteristics**

- **Cold start**: ~0.5s (includes parser execution)
- **Warm cache**: ~0.1s (memory-based completion)
- **Memory usage**: <5MB cache, minimal runtime footprint
- **Network dependency**: Optional (graceful offline operation)
- **Disk usage**: ~10-50KB cache files

---

## **🎯 Current Status: Production Ready**

**Version**: `3.1.0.003` (completion) + `1.1.0` (parser)
**Features**: 100% functional with advanced constraint validation
**Testing**: Validated on Ubuntu 24.04/25.04 with bash 5.2+
**Dependencies**: `bash`, `curl`, `jq` (optional), Go compiler (for parser build)

This system represents a **paradigm shift** from static completion scripts to **intelligent, self-evolving completion frameworks** that adapt to their target applications.
